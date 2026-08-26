# OAuth2/OIDC provider — the Hermes web dashboard authenticates natively via
# Authentik SSO (self-hosted OIDC). It is a PUBLIC client using authorization
# code + PKCE (S256), so there is NO client secret. The dashboard is configured
# with HERMES_DASHBOARD_OIDC_ISSUER=https://auth.dcxxiv.com/application/o/hermes/
# and HERMES_DASHBOARD_OIDC_CLIENT_ID=hermes-dashboard (see the HelmRelease); it
# discovers endpoints from {issuer}/.well-known/openid-configuration and calls
# back to https://hermes.dcxxiv.com/auth/callback. Access: any authenticated
# user (no group binding). Replaces the former forward-auth proxy provider.
resource "authentik_provider_oauth2" "hermes" {
  name               = "Hermes"
  client_id          = "hermes-dashboard"
  client_type        = "public"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id
  allowed_redirect_uris = [
    { url = "https://hermes.dcxxiv.com/auth/callback", matching_mode = "strict" },
  ]

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]

  # A Terraform-created oauth2 provider defaults grant_types to [] → Authentik
  # rejects every authorize as invalid_request; set it explicitly.
  grant_types                = ["authorization_code", "refresh_token"]
  sub_mode                   = "hashed_user_id"
  access_token_validity      = "hours=1"
  refresh_token_validity     = "days=30"
  include_claims_in_id_token = true
}

resource "authentik_application" "hermes" {
  name              = "Hermes"
  slug              = "hermes"
  protocol_provider = authentik_provider_oauth2.hermes.id
  meta_launch_url   = "https://hermes.dcxxiv.com"
}
