resource "authentik_provider_oauth2" "weave_gitops" {
  name               = "Weave GitOps"
  client_id          = var.weave_client_id
  client_secret      = var.weave_client_secret
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id

  # issuerURL in oidc-auth Secret uses the application slug: /application/o/weave-gitops/
  # The slug on authentik_application below must stay "weave-gitops" to match.
  redirect_uris = ["https://flux.dcxxiv.com/oauth2/callback"]

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]

  sub_mode               = "hashed_user_id"
  access_token_validity  = "hours=1"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "weave_gitops" {
  name              = "Weave GitOps"
  slug              = "weave-gitops"
  protocol_provider = authentik_provider_oauth2.weave_gitops.id
  meta_launch_url   = "https://flux.dcxxiv.com"
}
