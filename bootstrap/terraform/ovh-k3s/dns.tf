# Cloudflare DNS — round-robin apex A records across all nodes.
# Subdomains are CNAMEs to dcxxiv.com and resolve automatically via these records.
# Enabled by default (manage_dns = true). API token comes from CLOUDFLARE_API_TOKEN
# env var, exported by tf.sh from secrets.sops.yaml.

locals {
  all_node_ips = concat(
    [openstack_compute_instance_v2.first.access_ip_v4],
    openstack_compute_instance_v2.rest[*].access_ip_v4,
  )
}

data "cloudflare_zones" "this" {
  count = var.manage_dns ? 1 : 0
  filter {
    name = var.dns_zone
  }
}

resource "cloudflare_record" "apex" {
  for_each = var.manage_dns ? toset(local.all_node_ips) : toset([])
  zone_id  = data.cloudflare_zones.this[0].zones[0].id
  name     = "@"
  content  = each.value
  type     = "A"
  ttl      = 1
}
