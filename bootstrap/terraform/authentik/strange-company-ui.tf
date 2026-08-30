# Proxy provider — forward_single mode protects kanban.dcxxiv.com (the
# strange-company operator console, served at /ui by the control plane) via
# Traefik forwardAuth. The embedded outpost (running inside authentik-server)
# handles the auth checks. The control-plane UI authenticates nothing itself,
# so this Authentik gate is what keeps every card, artifact and agent
# transcript from being world-readable. Vikunja formerly served this host;
# its ingress is now disabled (Vikunja keeps running as the internal board
# backend).
resource "authentik_provider_proxy" "strange_company_ui" {
  name               = "StrangeCompanyUI"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://kanban.dcxxiv.com"
}

resource "authentik_application" "strange_company_ui" {
  name              = "Strange Company Console"
  slug              = "strange-company-ui"
  protocol_provider = authentik_provider_proxy.strange_company_ui.id
  meta_launch_url   = "https://kanban.dcxxiv.com"
}
