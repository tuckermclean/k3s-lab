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
data "authentik_scope_mapping" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

data "authentik_scope_mapping" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_scope_mapping" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}
