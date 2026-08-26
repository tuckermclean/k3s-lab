# Remote state in S3 (same bucket the cluster uses for Longhorn/Postgres
# backups) so `terraform apply` is safe from any machine — no more local-state
# divergence. S3-native locking (use_lockfile) needs Terraform >= 1.10.
# One-time migration from the previous local state:
#   make migrate-authentik-state
terraform {
  backend "s3" {
    bucket       = "k3s-lab-backups"
    key          = "terraform/authentik.tfstate"
    region       = "us-west-2"
    use_lockfile = true
  }
}
