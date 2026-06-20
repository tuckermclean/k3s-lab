# Dynamic lookups for Authentik auto-created singletons (UUIDs change on every fresh install).
# The http provider queries the API at plan time so import blocks never need hardcoded UUIDs.

data "http" "admins_group" {
  url = "${var.authentik_url}/api/v3/core/groups/?name=authentik+Admins"
  request_headers = {
    Authorization = "Bearer ${var.authentik_token}"
  }
}

data "http" "embedded_outpost" {
  url = "${var.authentik_url}/api/v3/outposts/instances/?name=authentik+Embedded+Outpost"
  request_headers = {
    Authorization = "Bearer ${var.authentik_token}"
  }
}

locals {
  admins_group_id      = jsondecode(data.http.admins_group.response_body).results[0].pk
  embedded_outpost_id  = jsondecode(data.http.embedded_outpost.response_body).results[0].pk
}

# Default flows — created automatically by Authentik on first boot
data "authentik_flow" "default_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_invalidation" {
  slug = "default-provider-invalidation-flow"
}

# Self-signed certificate — auto-created by Authentik on first boot
data "authentik_certificate_key_pair" "default" {
  name = "authentik Self-signed Certificate"
}

# Built-in scope mappings
data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}
