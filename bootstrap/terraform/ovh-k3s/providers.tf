# Auth comes from the OpenStack RC file you download from the OVH manager
# (Public Cloud > Users & Roles > download OpenRC v3, then `source openrc.sh`),
# or from a clouds.yaml entry selected with var.os_cloud. Either way the
# credentials live in your environment, not in this repo.
provider "openstack" {
  region = var.region
  cloud  = var.os_cloud != "" ? var.os_cloud : null
}
