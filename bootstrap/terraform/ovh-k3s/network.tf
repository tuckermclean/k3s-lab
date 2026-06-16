# OVH's public network. Instances attached to it get a routable public IP
# directly (no floating IP / NAT).
data "openstack_networking_network_v2" "ext" {
  name = "Ext-Net"
}

resource "openstack_compute_keypair_v2" "k3s" {
  name       = "k3s-ovh"
  public_key = var.ssh_public_key
}

resource "openstack_networking_secgroup_v2" "k3s" {
  name        = "k3s-ovh"
  description = "k3s cluster on OVH Public Cloud"
}

# SSH from the allowed CIDR.
resource "openstack_networking_secgroup_rule_v2" "ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.api_allowed_cidr
  security_group_id = openstack_networking_secgroup_v2.k3s.id
}

# Kubernetes API from the allowed CIDR.
resource "openstack_networking_secgroup_rule_v2" "api" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = var.api_allowed_cidr
  security_group_id = openstack_networking_secgroup_v2.k3s.id
}

# All intra-cluster traffic between nodes in this group: covers wireguard
# 51820/udp, etcd 2379-2380, kubelet 10250, flannel, etc.
resource "openstack_networking_secgroup_rule_v2" "intra" {
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.k3s.id
  security_group_id = openstack_networking_secgroup_v2.k3s.id
}

# Optional HTTP/HTTPS for a future Traefik ingress.
resource "openstack_networking_secgroup_rule_v2" "http" {
  for_each          = var.enable_http_ingress ? toset(["80", "443"]) : toset([])
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = tonumber(each.key)
  port_range_max    = tonumber(each.key)
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k3s.id
}
