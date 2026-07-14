# Proxy provider — forward_single mode protects juggler.dcxxiv.com via Traefik forwardAuth.
# The embedded outpost (running inside authentik-server) handles the auth checks.
# Juggler ships no authentication of its own, so this is the only access-control layer.
resource "authentik_provider_proxy" "juggler" {
  name               = "Juggler"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://juggler.dcxxiv.com"
}

resource "authentik_application" "juggler" {
  name              = "Juggler"
  slug              = "juggler"
  protocol_provider = authentik_provider_proxy.juggler.id
  meta_launch_url   = "https://juggler.dcxxiv.com"
}
