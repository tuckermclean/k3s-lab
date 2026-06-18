terraform {
  required_version = ">= 1.5"
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2025.8"
    }
  }
}

provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token
}
