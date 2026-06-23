# Proxy provider — forward_single mode protects deluge.dcxxiv.com via Traefik forwardAuth.
# The embedded outpost (running inside authentik-server) handles the auth checks.
resource "authentik_provider_proxy" "deluge" {
  name               = "Deluge"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://deluge.dcxxiv.com"
}

resource "authentik_application" "deluge" {
  name              = "Deluge"
  slug              = "deluge"
  protocol_provider = authentik_provider_proxy.deluge.id
  meta_launch_url   = "https://deluge.dcxxiv.com"
}
