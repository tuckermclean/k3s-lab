# Configure multipathd on the running node fleet to ignore Longhorn's iSCSI
# devices. multipathd (default Ubuntu config) otherwise claims Longhorn's
# IET/VIRTUAL-DISK block devices and holds them open, so kubelet cannot mount
# Longhorn PVCs ("already mounted or mount point busy", exit status 32).
#
# Fresh nodes get the same blacklist via cloud-init (write_files); these
# null_resources converge the already-running fleet. Mirrors the
# prepare_data_disk_* pattern in storage.tf. Re-runs when the script changes.
#
# Ref: https://longhorn.io/kb/troubleshooting-volume-with-multipath/

resource "null_resource" "configure_multipath_first" {
  depends_on = [openstack_compute_instance_v2.first]

  triggers = {
    script_sha = filesha256("${path.module}/scripts/configure-multipath.sh")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      HOST="${openstack_compute_instance_v2.first.access_ip_v4}"
      SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        -i ${pathexpand(var.ssh_private_key_path)} ${var.ssh_user}@$HOST"

      echo "==> Waiting for SSH on k3s-ovh-1 ($HOST)..."
      for i in $(seq 1 30); do $SSH true 2>/dev/null && break || sleep 10; done

      echo "==> Running configure-multipath.sh on k3s-ovh-1..."
      $SSH "sudo bash -s" < ${path.module}/scripts/configure-multipath.sh
    EOT
  }
}

resource "null_resource" "configure_multipath_rest" {
  count      = var.node_count - 1
  depends_on = [openstack_compute_instance_v2.rest]

  triggers = {
    script_sha = filesha256("${path.module}/scripts/configure-multipath.sh")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      HOST="${openstack_compute_instance_v2.rest[count.index].access_ip_v4}"
      SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        -i ${pathexpand(var.ssh_private_key_path)} ${var.ssh_user}@$HOST"

      echo "==> Waiting for SSH on k3s-ovh-${count.index + 2} ($HOST)..."
      for i in $(seq 1 30); do $SSH true 2>/dev/null && break || sleep 10; done

      echo "==> Running configure-multipath.sh on k3s-ovh-${count.index + 2}..."
      $SSH "sudo bash -s" < ${path.module}/scripts/configure-multipath.sh
    EOT
  }
}

resource "null_resource" "configure_multipath_agent" {
  count      = var.agent_count
  depends_on = [openstack_compute_instance_v2.agent]

  triggers = {
    script_sha = filesha256("${path.module}/scripts/configure-multipath.sh")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      HOST="${openstack_compute_instance_v2.agent[count.index].access_ip_v4}"
      SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        -i ${pathexpand(var.ssh_private_key_path)} ${var.ssh_user}@$HOST"

      echo "==> Waiting for SSH on k3s-ovh-agent-${count.index + 1} ($HOST)..."
      for i in $(seq 1 30); do $SSH true 2>/dev/null && break || sleep 10; done

      echo "==> Running configure-multipath.sh on k3s-ovh-agent-${count.index + 1}..."
      $SSH "sudo bash -s" < ${path.module}/scripts/configure-multipath.sh
    EOT
  }
}
