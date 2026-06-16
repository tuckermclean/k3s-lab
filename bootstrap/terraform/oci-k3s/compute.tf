resource "oci_core_instance" "server" {
  count               = var.server_count
  availability_domain = var.availability_domain != "" ? var.availability_domain : local.ad_names[count.index % length(local.ad_names)]
  compartment_id      = var.compartment_ocid
  display_name        = "k3s-server-${count.index + 1}"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus_per_node
    memory_in_gbs = var.memory_gbs_per_node
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    private_ip       = local.server_private_ips[count.index]
    assign_public_ip = true
    hostname_label   = "k3s-server-${count.index + 1}"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    # Server-0 initializes the cluster; the rest join it. k3s retries the join,
    # so parallel creation is fine even before server-0 is fully up.
    user_data = base64encode(count.index == 0 ? local.cloudinit_server_first : local.cloudinit_server_join)
  }
}

resource "oci_core_instance" "agent" {
  count               = var.agent_count
  availability_domain = var.availability_domain != "" ? var.availability_domain : local.ad_names[count.index % length(local.ad_names)]
  compartment_id      = var.compartment_ocid
  display_name        = "k3s-agent-${count.index + 1}"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus_per_node
    memory_in_gbs = var.memory_gbs_per_node
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    private_ip       = local.agent_private_ips[count.index]
    assign_public_ip = true
    hostname_label   = "k3s-agent-${count.index + 1}"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.cloudinit_agent)
  }

  depends_on = [oci_core_instance.server]
}
