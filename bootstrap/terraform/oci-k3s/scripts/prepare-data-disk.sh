#!/usr/bin/env bash
# prepare-data-disk.sh — format, mount, and configure the per-node data disk (OCI).
#
# Idempotent: safe to run multiple times on a live node.
#
# Required env vars (set by the Terraform null_resource):
#   MOUNT          Host mount point, e.g. /mnt/data
#   DATA_SIZE_GBS  Expected size (GB) of the attached data volume — used as a
#                  fallback match when the OCI oracleoci symlink isn't present.
#
# After this script runs, reboot the node to activate the bind mounts for
# /var/lib/longhorn and /var/lib/rancher/k3s/storage.  Reboot nodes one at
# a time — Longhorn keeps 2 replicas so one node can be down safely.

set -euo pipefail

MOUNT="${MOUNT:-/mnt/data}"
DATA_SIZE_GBS="${DATA_SIZE_GBS:?DATA_SIZE_GBS env var is required}"

# ── Step 1: locate the device ──────────────────────────────────────────────
# OCI attaches paravirtualized Block Volumes as ordinary virtio-scsi block
# devices — there is no OpenStack-style volume-UUID serial to match against.
# The stock Oracle-provided Ubuntu image ships udev rules that additionally
# expose a stable, human-readable symlink per attached volume, assigned in
# attach order: /dev/oracleoci/oraclevda is always the boot volume,
# oraclevdb the first extra volume, oraclevdc the second, etc. Exactly one
# data volume is attached per node here, so prefer oraclevdb.
echo "==> Locating data disk (expected size: ${DATA_SIZE_GBS} GB)..."

DEV=""

# Primary: the OCI-provided stable symlink for the first non-boot volume.
if [[ -e /dev/oracleoci/oraclevdb ]]; then
  DEV="$(readlink -f /dev/oracleoci/oraclevdb)"
  echo "    Found via /dev/oracleoci/oraclevdb: $DEV"
fi

# Fallback: scan for an unpartitioned, unformatted, unmounted block device
# whose size is within 10% of the expected data volume size. Do NOT assume
# a fixed device name (e.g. /dev/vdb) — the boot volume, not the data
# volume, is sometimes enumerated last depending on attach timing.
if [[ -z "$DEV" ]]; then
  echo "    /dev/oracleoci/oraclevdb not present; scanning by size..."
  EXPECT_BYTES=$((DATA_SIZE_GBS * 1000 * 1000 * 1000))
  TOLERANCE=$((EXPECT_BYTES / 10))
  while IFS= read -r name size; do
    [[ -z "$size" || "$size" == "0" ]] && continue
    dev="/dev/$name"
    findmnt "$dev" &>/dev/null && continue
    lsblk -n "$dev" 2>/dev/null | grep -q 'part' && continue
    blkid "$dev" &>/dev/null && continue
    diff=$((size > EXPECT_BYTES ? size - EXPECT_BYTES : EXPECT_BYTES - size))
    if ((diff <= TOLERANCE)); then
      DEV="$dev"
      echo "    Using size-matched fallback device: $DEV (${size} bytes)"
      break
    fi
  done < <(lsblk -bnd --output NAME,SIZE 2>/dev/null)
fi

if [[ -z "$DEV" ]]; then
  echo "ERROR: Could not locate data volume device." \
       "Verify the volume is attached: oci compute volume-attachment list --instance-id <id>" >&2
  exit 1
fi
echo "==> Using device: $DEV"

# ── Step 2: format (only if blank) ─────────────────────────────────────────
if ! blkid "$DEV" &>/dev/null; then
  echo "==> Formatting $DEV as ext4 (label: data)..."
  mkfs.ext4 -L data -m 1 "$DEV"
else
  echo "==> $DEV already has a filesystem — skipping format."
fi

# ── Step 3: mount at $MOUNT with nofail fstab entry ─────────────────────────
mkdir -p "$MOUNT"

FSTAB_ENTRY="LABEL=data ${MOUNT} ext4 defaults,nofail 0 2"
if ! grep -qF "LABEL=data ${MOUNT}" /etc/fstab; then
  echo "==> Adding fstab entry: $FSTAB_ENTRY"
  echo "$FSTAB_ENTRY" >> /etc/fstab
else
  echo "==> fstab entry for ${MOUNT} already present."
fi

if ! findmnt -rn "${MOUNT}" &>/dev/null; then
  echo "==> Mounting ${MOUNT}..."
  mount "$MOUNT"
else
  echo "==> ${MOUNT} already mounted."
fi

echo "==> Disk mounted:"
df -h "$MOUNT"

# ── Step 4: create subdirectories ───────────────────────────────────────────
mkdir -p "${MOUNT}/longhorn"
mkdir -p "${MOUNT}/local-path"
echo "==> Subdirectories ready: ${MOUNT}/longhorn  ${MOUNT}/local-path"

# ── Step 5: prepare bind mounts for existing storage paths ──────────────────
# We rsync any existing data onto the new disk, add fstab bind-mount entries,
# and attempt a live bind-mount where safe (no open files).
# Longhorn keeps processes open in /var/lib/longhorn, so that bind mount will
# activate on the next reboot.  /var/lib/rancher/k3s/storage is low-traffic
# and is attempted live.

setup_bind_mount() {
  local SRC="$1"   # existing path on root disk (target of bind)
  local DST="$2"   # path on new disk (source of bind)
  local LABEL="$3"

  echo ""
  echo "==> Bind mount setup: $DST → $SRC  ($LABEL)"

  mkdir -p "$SRC" "$DST"

  # Rsync: copy existing data to the new disk location (skip if already done)
  if [[ -n "$(ls -A "$SRC" 2>/dev/null)" ]]; then
    if [[ -z "$(ls -A "$DST" 2>/dev/null)" ]]; then
      echo "    Syncing existing data from $SRC to $DST..."
      rsync -a --info=progress2 "$SRC/" "$DST/"
    else
      echo "    $DST already contains data — skipping rsync."
    fi
  else
    echo "    $SRC is empty — no data to sync."
  fi

  # fstab bind entry (idempotent)
  local BIND_ENTRY="${DST} ${SRC} none bind,nofail,x-systemd.requires=local-fs.target 0 0"
  if ! grep -qF "${DST} ${SRC}" /etc/fstab; then
    echo "    Adding fstab bind entry: $BIND_ENTRY"
    echo "$BIND_ENTRY" >> /etc/fstab
  else
    echo "    fstab bind entry for $SRC already present."
  fi

  # Live bind-mount attempt
  if findmnt --source "$DST" --target "$SRC" &>/dev/null; then
    echo "    $SRC is already bind-mounted — nothing to do."
  elif lsof +D "$SRC" 2>/dev/null | grep -q .; then
    echo "    Open files detected in $SRC — bind mount will activate on next reboot."
  else
    echo "    No open files in $SRC — mounting now..."
    mount --bind "$DST" "$SRC"
    echo "    Bind mount active."
  fi
}

setup_bind_mount "/var/lib/longhorn"             "${MOUNT}/longhorn"    "Longhorn data"
setup_bind_mount "/var/lib/rancher/k3s/storage"  "${MOUNT}/local-path"  "k3s local-path"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  prepare-data-disk.sh complete on $(hostname)"
echo "══════════════════════════════════════════════════════"
echo ""
df -h "$MOUNT"
echo ""
echo "  fstab entries configured for:"
echo "    ${MOUNT}                       (primary disk mount)"
echo "    /var/lib/longhorn              → ${MOUNT}/longhorn"
echo "    /var/lib/rancher/k3s/storage   → ${MOUNT}/local-path"
echo ""
echo "  ACTION REQUIRED: reboot this node to activate any pending bind mounts."
echo "  Reboot nodes ONE AT A TIME — Longhorn (2 replicas) tolerates one node"
echo "  offline. Verify Longhorn is healthy before rebooting the next node:"
echo "    kubectl -n longhorn-system get nodes.longhorn.io"
echo ""
