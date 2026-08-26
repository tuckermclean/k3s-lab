# Proxy provider — forward_single mode gates hermes.dcxxiv.com via Traefik
# forwardAuth (embedded outpost). Hermes' dashboard basic-auth is mandatory (it
# refuses to bind without it); Authentik authenticates the user and a Traefik
# header-injection middleware supplies that basic-auth downstream, so users see
# only the Authentik login. Access: any authenticated user (no group binding).
resource "authentik_provider_proxy" "hermes" {
  name               = "Hermes"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://hermes.dcxxiv.com"
}

resource "authentik_application" "hermes" {
  name              = "Hermes"
  slug              = "hermes"
  protocol_provider = authentik_provider_proxy.hermes.id
  meta_launch_url   = "https://hermes.dcxxiv.com"
}
