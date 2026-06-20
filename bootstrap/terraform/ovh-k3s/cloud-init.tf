resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

locals {
  # node-1 initializes the cluster; the rest join it via its public IP, which
  # is known only after node-1 is created (hence the first/rest split below).
  first_ip = openstack_compute_instance_v2.first.access_ip_v4

  cloudinit_first = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    role                = "server-first"
    k3s_token           = random_password.k3s_token.result
    flannel_backend     = var.flannel_backend
    first_ip            = "" # unused for the first node
    data_volume_size_gb = var.data_volume_size_gb
    data_mount_point    = var.data_mount_point
  })

  cloudinit_join = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    role                = "server-join"
    k3s_token           = random_password.k3s_token.result
    flannel_backend     = var.flannel_backend
    first_ip            = local.first_ip
    data_volume_size_gb = var.data_volume_size_gb
    data_mount_point    = var.data_mount_point
  })

  cloudinit_agent = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    role                = "agent"
    k3s_token           = random_password.k3s_token.result
    flannel_backend     = var.flannel_backend
    first_ip            = local.first_ip
    data_volume_size_gb = var.data_volume_size_gb
    data_mount_point    = var.data_mount_point
  })
}
