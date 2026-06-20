# Per-node Cinder data disks — expand Longhorn + local-path storage capacity.
#
# Added as standalone volume + attachment resources so existing instances are
# NOT recreated. After apply, prepare-data-disk.sh runs on each node via
# null_resource to format the disk, mount it, and set up fstab bind-mount
# entries for /var/lib/longhorn and /var/lib/rancher/k3s/storage.
#
# The bind mounts activate on the next node reboot. Reboot nodes one at a time
# (the longhorn defaultReplicaCount of 2 tolerates one node offline at a time).

locals {
  data_volumes_enabled = var.data_volume_size_gb > 0
}

# --- Cinder volumes (one per node) ---

resource "openstack_blockstorage_volume_v3" "first" {
  count       = local.data_volumes_enabled ? 1 : 0
  name        = "k3s-ovh-1-data"
  size        = var.data_volume_size_gb
  volume_type = var.data_volume_type
}

resource "openstack_blockstorage_volume_v3" "rest" {
  count       = local.data_volumes_enabled ? var.node_count - 1 : 0
  name        = "k3s-ovh-${count.index + 2}-data"
  size        = var.data_volume_size_gb
  volume_type = var.data_volume_type
}

resource "openstack_blockstorage_volume_v3" "agent" {
  count       = local.data_volumes_enabled ? var.agent_count : 0
  name        = "k3s-ovh-agent-${count.index + 1}-data"
  size        = var.data_volume_size_gb
  volume_type = var.data_volume_type
}

# --- Volume attachments (separate resources — do not recreate instances) ---

resource "openstack_compute_volume_attach_v2" "first" {
  count       = local.data_volumes_enabled ? 1 : 0
  instance_id = openstack_compute_instance_v2.first.id
  volume_id   = openstack_blockstorage_volume_v3.first[count.index].id
}

resource "openstack_compute_volume_attach_v2" "rest" {
  count       = local.data_volumes_enabled ? var.node_count - 1 : 0
  instance_id = openstack_compute_instance_v2.rest[count.index].id
  volume_id   = openstack_blockstorage_volume_v3.rest[count.index].id
}

resource "openstack_compute_volume_attach_v2" "agent" {
  count       = local.data_volumes_enabled ? var.agent_count : 0
  instance_id = openstack_compute_instance_v2.agent[count.index].id
  volume_id   = openstack_blockstorage_volume_v3.agent[count.index].id
}

# --- Disk prep on running nodes ---
#
# Mirrors the local-exec/SSH pattern from flux.tf. Triggers on the volume ID
# so re-running apply after a replacement re-provisions the disk.

resource "null_resource" "prepare_data_disk_first" {
  count = local.data_volumes_enabled ? 1 : 0

  depends_on = [openstack_compute_volume_attach_v2.first]

  triggers = {
    volume_id = openstack_blockstorage_volume_v3.first[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      HOST="${openstack_compute_instance_v2.first.access_ip_v4}"
      VOLUME_ID="${openstack_blockstorage_volume_v3.first[count.index].id}"
      MOUNT="${var.data_mount_point}"
      SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        -i ${pathexpand(var.ssh_private_key_path)} ${var.ssh_user}@$HOST"

      echo "==> Waiting for SSH on k3s-ovh-1 ($HOST)..."
      for i in $(seq 1 30); do $SSH true 2>/dev/null && break || sleep 10; done

      echo "==> Running prepare-data-disk.sh on k3s-ovh-1..."
      $SSH "sudo VOLUME_ID='$VOLUME_ID' MOUNT='$MOUNT' bash -s" \
        < ${path.module}/scripts/prepare-data-disk.sh
    EOT
  }
}

resource "null_resource" "prepare_data_disk_rest" {
  count = local.data_volumes_enabled ? var.node_count - 1 : 0

  depends_on = [openstack_compute_volume_attach_v2.rest]

  triggers = {
    volume_id = openstack_blockstorage_volume_v3.rest[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      HOST="${openstack_compute_instance_v2.rest[count.index].access_ip_v4}"
      VOLUME_ID="${openstack_blockstorage_volume_v3.rest[count.index].id}"
      MOUNT="${var.data_mount_point}"
      SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        -i ${pathexpand(var.ssh_private_key_path)} ${var.ssh_user}@$HOST"

      echo "==> Waiting for SSH on k3s-ovh-${count.index + 2} ($HOST)..."
      for i in $(seq 1 30); do $SSH true 2>/dev/null && break || sleep 10; done

      echo "==> Running prepare-data-disk.sh on k3s-ovh-${count.index + 2}..."
      $SSH "sudo VOLUME_ID='$VOLUME_ID' MOUNT='$MOUNT' bash -s" \
        < ${path.module}/scripts/prepare-data-disk.sh
    EOT
  }
}

resource "null_resource" "prepare_data_disk_agent" {
  count = local.data_volumes_enabled ? var.agent_count : 0

  depends_on = [openstack_compute_volume_attach_v2.agent]

  triggers = {
    volume_id = openstack_blockstorage_volume_v3.agent[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      HOST="${openstack_compute_instance_v2.agent[count.index].access_ip_v4}"
      VOLUME_ID="${openstack_blockstorage_volume_v3.agent[count.index].id}"
      MOUNT="${var.data_mount_point}"
      SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        -i ${pathexpand(var.ssh_private_key_path)} ${var.ssh_user}@$HOST"

      echo "==> Waiting for SSH on k3s-ovh-agent-${count.index + 1} ($HOST)..."
      for i in $(seq 1 30); do $SSH true 2>/dev/null && break || sleep 10; done

      echo "==> Running prepare-data-disk.sh on k3s-ovh-agent-${count.index + 1}..."
      $SSH "sudo VOLUME_ID='$VOLUME_ID' MOUNT='$MOUNT' bash -s" \
        < ${path.module}/scripts/prepare-data-disk.sh
    EOT
  }
}
