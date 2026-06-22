# Proxy provider — forward_single mode protects orch.dcxxiv.com via Traefik forwardAuth.
# The embedded outpost (running inside authentik-server) handles the auth checks.
# Note: only the PWA/API routes are gated; the GitHub webhook path is left public
# in the IngressRoute (it authenticates via the OPERATOR_SECRET_KEY HMAC, not SSO).
resource "authentik_provider_proxy" "orchestrator" {
  name               = "Orchestrator"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://orch.dcxxiv.com"
}

resource "authentik_application" "orchestrator" {
  name              = "Orchestrator"
  slug              = "orchestrator"
  protocol_provider = authentik_provider_proxy.orchestrator.id
  meta_launch_url   = "https://orch.dcxxiv.com"
}
