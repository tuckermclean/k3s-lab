terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "k3s-lab-backups"
    key          = "terraform/state/ovh-k3s"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
