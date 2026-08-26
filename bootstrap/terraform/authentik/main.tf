terraform {
  required_version = ">= 1.10"
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token
}
