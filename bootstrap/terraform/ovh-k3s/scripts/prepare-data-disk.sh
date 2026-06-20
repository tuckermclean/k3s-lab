#!/usr/bin/env bash
# prepare-data-disk.sh — format, mount, and configure the per-node data disk.
#
# Idempotent: safe to run multiple times on a live node.
#
# Required env vars (set by the Terraform null_resource):
#   VOLUME_ID   OpenStack volume UUID (used to locate the device by serial)
#   MOUNT       Host mount point, e.g. /mnt/data
#
# After this script runs, reboot the node to activate the bind mounts for
# /var/lib/longhorn and /var/lib/rancher/k3s/storage.  Reboot nodes one at
# a time — Longhorn keeps 2 replicas so one node can be down safely.

set -euo pipefail

MOUNT="${MOUNT:-/mnt/data}"
VOLUME_ID="${VOLUME_ID:?VOLUME_ID env var is required}"

# ── Step 1: locate the device ──────────────────────────────────────────────
# OpenStack/OVH virtio disks appear under /dev/disk/by-id/ with a serial that
# matches the first 20 hex chars of the volume UUID (dashes stripped).
SERIAL="$(echo "$VOLUME_ID" | tr -d '-' | cut -c1-20)"
echo "==> Locating device for volume $VOLUME_ID (serial prefix: $SERIAL)..."

DEV=""

# Primary: match by virtio serial
for path in /dev/disk/by-id/virtio-*; do
  [[ -e "$path" ]] || continue
  if [[ "$path" == *"$SERIAL"* ]]; then
    DEV="$(readlink -f "$path")"
    echo "    Found via virtio serial: $DEV ($path)"
    break
  fi
done

# Fallback: largest unpartitioned, unformatted, unmounted block device
if [[ -z "$DEV" ]]; then
  echo "    Virtio serial not found; scanning for blank block device..."
  while IFS= read -r candidate; do
    dev="/dev/$candidate"
    # Skip if already mounted
    findmnt "$dev" &>/dev/null && continue
    # Skip if it has partitions
    lsblk -n "$dev" 2>/dev/null | grep -q 'part' && continue
    # Skip if it already has a recognisable filesystem or partition table
    blkid "$dev" &>/dev/null && continue
    DEV="$dev"
    echo "    Using fallback device: $DEV"
    break
  done < <(lsblk -nd --output NAME,SIZE --sort SIZE 2>/dev/null | awk '{print $1}' | tail -r 2>/dev/null \
           || lsblk -nd --output NAME,SIZE --sort SIZE 2>/dev/null | awk '{print $1}' | tac)
fi

if [[ -z "$DEV" ]]; then
  echo "ERROR: Could not locate data volume device." \
       "Verify the volume is attached: openstack server show <id>" >&2
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
