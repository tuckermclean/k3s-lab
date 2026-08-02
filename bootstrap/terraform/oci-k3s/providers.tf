provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = pathexpand(var.api_private_key_path)
  region           = var.region
}

# API token read from CLOUDFLARE_API_TOKEN env var (exported by tf.sh from secrets.sops.yaml).
# Only contacts Cloudflare when manage_dns = true.
provider "cloudflare" {}
