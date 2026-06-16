resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

locals {
  cloudinit_server_first = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    role         = "server-first"
    k3s_token    = random_password.k3s_token.result
    lb_ip        = local.lb_ip
    api_dns_name = var.api_dns_name
    first_ip     = local.first_server_ip
  })

  cloudinit_server_join = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    role         = "server-join"
    k3s_token    = random_password.k3s_token.result
    lb_ip        = local.lb_ip
    api_dns_name = var.api_dns_name
    first_ip     = local.first_server_ip
  })

  cloudinit_agent = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    role         = "agent"
    k3s_token    = random_password.k3s_token.result
    lb_ip        = local.lb_ip
    api_dns_name = var.api_dns_name
    first_ip     = local.first_server_ip
  })
}
