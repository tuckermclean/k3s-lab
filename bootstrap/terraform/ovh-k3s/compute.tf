# node-1: initializes the embedded-etcd cluster.
resource "openstack_compute_instance_v2" "first" {
  name            = "k3s-ovh-1"
  flavor_name     = var.flavor_name
  image_name      = var.image_name
  key_pair        = openstack_compute_keypair_v2.k3s.name
  security_groups = [openstack_networking_secgroup_v2.k3s.name]
  user_data       = local.cloudinit_first

  network {
    name = data.openstack_networking_network_v2.ext.name
  }

  # user_data is only consumed at first boot; changing the cloud-init template
  # should not recreate a running node.
  lifecycle {
    ignore_changes = [user_data]
  }
}

# node-2..n: join node-1.
resource "openstack_compute_instance_v2" "rest" {
  count           = var.node_count - 1
  name            = "k3s-ovh-${count.index + 2}"
  flavor_name     = var.flavor_name
  image_name      = var.image_name
  key_pair        = openstack_compute_keypair_v2.k3s.name
  security_groups = [openstack_networking_secgroup_v2.k3s.name]
  user_data       = local.cloudinit_join

  network {
    name = data.openstack_networking_network_v2.ext.name
  }

  depends_on = [openstack_compute_instance_v2.first]

  lifecycle {
    ignore_changes = [user_data]
  }
}

# Optional agents (worker-only).
resource "openstack_compute_instance_v2" "agent" {
  count           = var.agent_count
  name            = "k3s-ovh-agent-${count.index + 1}"
  flavor_name     = var.flavor_name
  image_name      = var.image_name
  key_pair        = openstack_compute_keypair_v2.k3s.name
  security_groups = [openstack_networking_secgroup_v2.k3s.name]
  user_data       = local.cloudinit_agent

  network {
    name = data.openstack_networking_network_v2.ext.name
  }

  depends_on = [openstack_compute_instance_v2.first]

  lifecycle {
    ignore_changes = [user_data]
  }
}
