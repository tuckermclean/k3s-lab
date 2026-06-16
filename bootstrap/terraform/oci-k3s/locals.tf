data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  # All ADs in the region. Instances are spread across these to dodge
  # AD-specific "Out of host capacity" on the free A1 pool (and for HA).
  ad_names = data.oci_identity_availability_domains.ads.availability_domains[*].name

  vcn_cidr    = "10.0.0.0/16"
  subnet_cidr = "10.0.1.0/24"

  # Deterministic static private IPs so join targets are known before boot.
  # Servers: .11, .12, .13 ...   Agents: .21, .22 ...
  server_private_ips = [for i in range(var.server_count) : cidrhost(local.subnet_cidr, 11 + i)]
  agent_private_ips  = [for i in range(var.agent_count) : cidrhost(local.subnet_cidr, 21 + i)]

  first_server_ip = local.server_private_ips[0]
  lb_ip           = oci_core_public_ip.api.ip_address

  total_ocpus  = (var.server_count + var.agent_count) * var.ocpus_per_node
  total_memory = (var.server_count + var.agent_count) * var.memory_gbs_per_node
}

# Fail fast if the requested topology exceeds the Always Free pool, before any
# instance create call is attempted (and rejected) by OCI.
resource "null_resource" "free_tier_guardrail" {
  lifecycle {
    precondition {
      condition     = local.total_ocpus <= var.free_tier_max_ocpus
      error_message = "Requested ${local.total_ocpus} OCPUs exceeds free_tier_max_ocpus (${var.free_tier_max_ocpus})."
    }
    precondition {
      condition     = local.total_memory <= var.free_tier_max_memory_gbs
      error_message = "Requested ${local.total_memory} GB exceeds free_tier_max_memory_gbs (${var.free_tier_max_memory_gbs})."
    }
  }
}
