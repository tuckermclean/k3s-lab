# Cloudflare DNS — round-robin A records for the "oci" subdomain, resolving
# oci.dcxxiv.com to all server node public IPs. App hostnames for this
# cluster are CNAMEs to oci.dcxxiv.com (unmanaged here) — same pattern as
# ovh-k3s/dns.tf's apex A records + subdomain CNAMEs, just one level down
# so the OCI standby cluster doesn't own the production apex.
#
# Enabled by default (manage_dns = true). API token comes from
# CLOUDFLARE_API_TOKEN env var, exported by tf.sh from secrets.sops.yaml.

data "cloudflare_zones" "this" {
  count = var.manage_dns ? 1 : 0
  filter {
    name = var.dns_zone
  }
}

resource "cloudflare_record" "oci" {
  count    = var.manage_dns ? var.server_count : 0
  zone_id  = data.cloudflare_zones.this[0].zones[0].id
  name     = "oci"
  content  = oci_core_instance.server[count.index].public_ip
  type     = "A"
  ttl      = 1
}
