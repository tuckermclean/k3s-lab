#!/usr/bin/env bash
# configure-multipath.sh — stop multipathd from claiming Longhorn's iSCSI block
# devices. Without this, multipathd grabs Longhorn's IET/VIRTUAL-DISK devices and
# holds them open, so kubelet fails to mount Longhorn PVCs with
# "already mounted or mount point busy" (exit status 32).
#
# Idempotent: safe to run repeatedly on a live node.
# Ref: https://longhorn.io/kb/troubleshooting-volume-with-multipath/

set -euo pipefail

CONF_DIR=/etc/multipath/conf.d
CONF_FILE="$CONF_DIR/longhorn.conf"

echo "==> Writing Longhorn multipath blacklist to $CONF_FILE..."
mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" <<'EOF'
# Managed by Terraform (bootstrap/terraform/ovh-k3s). Do not edit by hand.
# Prevents multipathd from grabbing Longhorn's iSCSI frontend devices
# (vendor IET / product VIRTUAL-DISK), which otherwise blocks Longhorn PVC
# mounts with "already mounted or mount point busy".
blacklist {
    device {
        vendor "IET"
        product "VIRTUAL-DISK"
    }
}
EOF

# If multipathd isn't installed, the blacklist file is enough for a fresh boot.
if ! command -v multipathd >/dev/null 2>&1; then
  echo "==> multipathd not present — blacklist file written for future use."
  exit 0
fi

echo "==> Reloading multipathd config..."
multipathd reconfigure || systemctl reload multipathd || systemctl restart multipathd || true
sleep 2

echo "==> Flushing any stale Longhorn (IET/VIRTUAL-DISK) multipath maps..."
# `multipath -f` fails safely if a map is genuinely in use; tolerate that.
mapfile -t MAPS < <(multipath -ll 2>/dev/null | awk '/IET,VIRTUAL-DISK/{print $1}')
if [[ ${#MAPS[@]} -eq 0 ]]; then
  echo "    No Longhorn multipath maps present."
else
  for m in "${MAPS[@]}"; do
    echo "    Flushing map: $m"
    if multipath -f "$m"; then
      echo "      flushed."
    else
      echo "      WARNING: could not flush $m (in use?) — leaving as-is." >&2
    fi
  done
fi

echo "==> multipath -ll after reconfigure:"
multipath -ll 2>&1 | sed 's/^/    /' || true

echo "==> configure-multipath.sh complete on $(hostname)"
