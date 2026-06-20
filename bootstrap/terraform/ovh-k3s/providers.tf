# Auth comes from the OpenStack RC file you download from the OVH manager
# (Public Cloud > Users & Roles > download OpenRC v3, then `source openrc.sh`),
# or from a clouds.yaml entry selected with var.os_cloud. Either way the
# credentials live in your environment, not in this repo.
provider "openstack" {
  region = var.region
  cloud  = var.os_cloud != "" ? var.os_cloud : null
}

# API token read from CLOUDFLARE_API_TOKEN env var (exported by tf.sh from secrets.sops.yaml).
# Only contacts Cloudflare when manage_dns = true.
provider "cloudflare" {}
