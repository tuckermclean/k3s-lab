# Proxy provider — forward_single mode protects paperclip.dcxxiv.com (the
# Paperclip AI-agent orchestration UI). The embedded outpost (running inside
# authentik-server) handles the auth checks via Traefik forwardAuth. Paperclip
# runs in deploymentExposure=private, treating this Authentik gate as the
# trusted front, so only members of the authorized Authentik flow reach it.
resource "authentik_provider_proxy" "paperclip" {
  name               = "Paperclip"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://paperclip.dcxxiv.com"
}

resource "authentik_application" "paperclip" {
  name              = "Paperclip"
  slug              = "paperclip"
  protocol_provider = authentik_provider_proxy.paperclip.id
  meta_launch_url   = "https://paperclip.dcxxiv.com"
}
