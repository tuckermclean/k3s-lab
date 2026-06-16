# Auth comes from the OpenStack RC file you download from the OVH manager
# (Public Cloud > Users & Roles > download OpenRC v3, then `source openrc.sh`),
# or from a clouds.yaml entry selected with var.os_cloud. Either way the
# credentials live in your environment, not in this repo.
provider "openstack" {
  region = var.region
  cloud  = var.os_cloud != "" ? var.os_cloud : null
}

# Only contacted when manage_dns = true (all ovh resources/data are counted out
# otherwise), so empty credentials are fine for a compute-only apply.
provider "ovh" {
  endpoint           = var.ovh_endpoint
  application_key    = var.ovh_application_key
  application_secret = var.ovh_application_secret
  consumer_key       = var.ovh_consumer_key
}
