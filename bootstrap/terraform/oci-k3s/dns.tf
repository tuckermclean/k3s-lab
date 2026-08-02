# Cloudflare DNS — round-robin A records for the "oci" subdomain, resolving
# oci.dcxxiv.com to all server node public IPs. App hostnames for this
# cluster are CNAMEs to oci.dcxxiv.com (unmanaged here) — same pattern as
# ovh-k3s/dns.tf's apex A records + subdomain CNAMEs, just one level down
# so the OCI standby cluster doesn't own the production apex.
#
# Enabled by default (manage_dns = true). API token comes from
# CLOUDFLARE_API_TOKEN env var, exported by tf.sh from secrets.sops.yaml.
#
# --- OVH -> OCI cutover (apex) ---
# manage_apex_dns (default false) is the one-way cutover switch: it does NOT
# replace the oci.dcxxiv.com record above, which stays forever as a permanent
# secondary hostname per the migration spec. At cutover time:
#   1. Set manage_apex_dns = true here (oci-k3s) AND manage_dns = false on
#      ovh-k3s (so ovh-k3s/dns.tf's cloudflare_record.apex stops managing the
#      apex — avoids both modules fighting over the same "@" record).
#   2. terraform apply on oci-k3s.
#   3. The bare dcxxiv.com apex now round-robins across the OCI node public
#      IPs instead of OVH's.
# Leave manage_apex_dns = false until that deliberate cutover step; until
# then OVH continues to own the apex.

data "cloudflare_zones" "this" {
  count = (var.manage_dns || var.manage_apex_dns) ? 1 : 0
  filter {
    name = var.dns_zone
  }
}

resource "cloudflare_record" "oci" {
  count   = var.manage_dns ? var.server_count : 0
  zone_id = data.cloudflare_zones.this[0].zones[0].id
  name    = "oci"
  content = oci_core_instance.server[count.index].public_ip
  type    = "A"
  ttl     = 1
}

# Apex "@" record — off by default (see cutover comment above). Uses count,
# not for_each, deliberately: OCI public IPs are only known after apply
# (not at plan time), and for_each keyed on unknown values fails. This
# mirrors the same fix already applied to cloudflare_record.oci above.
resource "cloudflare_record" "apex" {
  count   = var.manage_apex_dns ? var.server_count : 0
  zone_id = data.cloudflare_zones.this[0].zones[0].id
  name    = "@"
  content = oci_core_instance.server[count.index].public_ip
  type    = "A"
  ttl     = 1
}
