# OAuth2/OIDC provider — Vikunja logs users in natively via Authentik SSO
# (grafana pattern). Users auto-provision on first login. Access: any
# authenticated user (no group binding). The client secret is pinned in SOPS
# (apps/strange-company/vikunja-oidc-config.sops.yaml) and exported to
# TF_VAR_vikunja_client_secret by `make apply-authentik`.
resource "authentik_provider_oauth2" "vikunja" {
  name               = "Vikunja"
  client_id          = var.vikunja_client_id
  client_secret      = var.vikunja_client_secret
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id
  allowed_redirect_uris = [
    { url = "https://kanban.dcxxiv.com/auth/openid/authentik", matching_mode = "strict" },
  ]

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]

  # grant_types is optional+computed: a Terraform-created provider defaults to
  # an EMPTY list, which makes Authentik reject every authorization-code request
  # as invalid_request ("the request is otherwise malformed"). Set it explicitly.
  grant_types = ["authorization_code", "refresh_token"]

  sub_mode                   = "hashed_user_id"
  access_token_validity      = "hours=1"
  refresh_token_validity     = "days=30"
  include_claims_in_id_token = true
}

resource "authentik_application" "vikunja" {
  name              = "Vikunja"
  slug              = "vikunja"
  protocol_provider = authentik_provider_oauth2.vikunja.id
  meta_launch_url   = "https://kanban.dcxxiv.com"
}
