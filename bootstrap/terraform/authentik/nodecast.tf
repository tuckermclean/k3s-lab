resource "authentik_provider_oauth2" "nodecast" {
  name               = "NodeCast TV"
  client_id          = var.nodecast_client_id
  client_secret      = var.nodecast_client_secret
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id
  allowed_redirect_uris = [
    { url = "https://tv.dcxxiv.com/api/auth/oidc/callback", matching_mode = "strict" },
  ]

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]

  sub_mode                   = "hashed_user_id"
  access_token_validity      = "hours=1"
  refresh_token_validity     = "days=30"
  include_claims_in_id_token = true
}

resource "authentik_application" "nodecast" {
  name              = "NodeCast TV"
  slug              = "nodecast-tv"
  protocol_provider = authentik_provider_oauth2.nodecast.id
  meta_launch_url   = "https://tv.dcxxiv.com"
}
