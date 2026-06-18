resource "authentik_provider_oauth2" "grafana" {
  name               = "Grafana"
  client_id          = var.grafana_client_id
  client_secret      = var.grafana_client_secret
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id
  redirect_uris      = ["https://grafana.dcxxiv.com/login/generic_oauth"]

  property_mappings = [
    data.authentik_scope_mapping.openid.id,
    data.authentik_scope_mapping.email.id,
    data.authentik_scope_mapping.profile.id,
    authentik_scope_mapping.groups.id,
  ]

  sub_mode                   = "hashed_user_id"
  access_token_validity      = "hours=1"
  refresh_token_validity     = "days=30"
  include_claims_in_id_token = true
}

resource "authentik_application" "grafana" {
  name              = "Grafana"
  slug              = "grafana"
  protocol_provider = authentik_provider_oauth2.grafana.id
  meta_launch_url   = "https://grafana.dcxxiv.com"
}
