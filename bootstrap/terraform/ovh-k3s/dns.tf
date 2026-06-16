# Optional OVH managed DNS. Enabled with manage_dns = true; otherwise every
# resource/data here is counted out and the ovh provider is never contacted.

locals {
  all_node_ips = concat(
    [openstack_compute_instance_v2.first.access_ip_v4],
    openstack_compute_instance_v2.rest[*].access_ip_v4,
  )

  # One {subdomain, ip} pair per (subdomain x node) -> round-robin A records.
  dns_pairs = var.manage_dns ? flatten([
    for sub in var.dns_subdomains : [
      for ip in local.all_node_ips : { sub = sub, ip = ip }
    ]
  ]) : []
}

# Reads the zone so we can output the nameservers OVH assigned to it.
data "ovh_domain_zone" "this" {
  count = var.manage_dns ? 1 : 0
  name  = var.dns_zone
}

resource "ovh_domain_zone_record" "a" {
  count     = length(local.dns_pairs)
  zone      = var.dns_zone
  subdomain = local.dns_pairs[count.index].sub
  fieldtype = "A"
  ttl       = 300
  target    = local.dns_pairs[count.index].ip
}
