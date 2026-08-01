# Per-node OCI Block Volumes — expand Longhorn + local-path storage capacity,
# separate from the boot volume. Mirrors ovh-k3s's Cinder data-disk pattern
# (bootstrap/terraform/ovh-k3s/storage.tf).
#
# Added as standalone volume + attachment resources so existing instances are
# NOT recreated. After apply, prepare-data-disk.sh runs on each node via
# null_resource to format the disk, mount it, and set up fstab bind-mount
# entries for /var/lib/longhorn and /var/lib/rancher/k3s/storage.
#
# The bind mounts activate on the next node reboot. Reboot nodes one at a time
# (the longhorn defaultReplicaCount of 2 tolerates one node offline at a time).

locals {
  data_volumes_enabled = var.data_volume_size_gbs > 0
}

# --- OCI Block Volumes (one per node) ---

resource "oci_core_volume" "server" {
  count               = local.data_volumes_enabled ? var.server_count : 0
  compartment_id      = var.compartment_ocid
  availability_domain = oci_core_instance.server[count.index].availability_domain
  display_name        = "k3s-server-${count.index + 1}-data"
  size_in_gbs         = var.data_volume_size_gbs
}

resource "oci_core_volume" "agent" {
  count               = local.data_volumes_enabled ? var.agent_count : 0
  compartment_id      = var.compartment_ocid
  availability_domain = oci_core_instance.agent[count.index].availability_domain
  display_name        = "k3s-agent-${count.index + 1}-data"
  size_in_gbs         = var.data_volume_size_gbs
}

# --- Volume attachments (separate resources — do not recreate instances) ---
# paravirtualized: no in-guest iSCSI attach/login step needed (unlike OCI's
# default iscsi attachment type), which keeps prepare-data-disk.sh simple.

resource "oci_core_volume_attachment" "server" {
  count           = local.data_volumes_enabled ? var.server_count : 0
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.server[count.index].id
  volume_id       = oci_core_volume.server[count.index].id
  display_name    = "k3s-server-${count.index + 1}-data-attach"
}

resource "oci_core_volume_attachment" "agent" {
  count           = local.data_volumes_enabled ? var.agent_count : 0
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.agent[count.index].id
  volume_id       = oci_core_volume.agent[count.index].id
  display_name    = "k3s-agent-${count.index + 1}-data-attach"
}

# --- Disk prep on running nodes ---
#
# Mirrors the local-exec/SSH pattern from flux.tf and ovh-k3s/storage.tf.
# Triggers on the volume ID so re-running apply after a replacement
# re-provisions the disk.

resource "null_resource" "prepare_data_disk_server" {
  count = local.data_volumes_enabled ? var.server_count : 0

  depends_on = [oci_core_volume_attachment.server]

  triggers = {
    volume_id = oci_core_volume.server[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      HOST="${oci_core_instance.server[count.index].public_ip}"
      SIZE_GBS="${var.data_volume_size_gbs}"
      MOUNT="${var.data_mount_point}"
      SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        -i ${pathexpand(var.ssh_private_key_path)} ubuntu@$HOST"

      echo "==> Waiting for SSH on k3s-server-${count.index + 1} ($HOST)..."
      for i in $(seq 1 30); do $SSH true 2>/dev/null && break || sleep 10; done

      echo "==> Running prepare-data-disk.sh on k3s-server-${count.index + 1}..."
      $SSH "sudo DATA_SIZE_GBS='$SIZE_GBS' MOUNT='$MOUNT' bash -s" \
        < ${path.module}/scripts/prepare-data-disk.sh
    EOT
  }
}

resource "null_resource" "prepare_data_disk_agent" {
  count = local.data_volumes_enabled ? var.agent_count : 0

  depends_on = [oci_core_volume_attachment.agent]

  triggers = {
    volume_id = oci_core_volume.agent[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      HOST="${oci_core_instance.agent[count.index].public_ip}"
      SIZE_GBS="${var.data_volume_size_gbs}"
      MOUNT="${var.data_mount_point}"
      SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        -i ${pathexpand(var.ssh_private_key_path)} ubuntu@$HOST"

      echo "==> Waiting for SSH on k3s-agent-${count.index + 1} ($HOST)..."
      for i in $(seq 1 30); do $SSH true 2>/dev/null && break || sleep 10; done

      echo "==> Running prepare-data-disk.sh on k3s-agent-${count.index + 1}..."
      $SSH "sudo DATA_SIZE_GBS='$SIZE_GBS' MOUNT='$MOUNT' bash -s" \
        < ${path.module}/scripts/prepare-data-disk.sh
    EOT
  }
}
