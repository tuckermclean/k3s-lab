# Proxy provider — forward_single mode protects agent.dcxxiv.com via Traefik forwardAuth.
# The embedded outpost (running inside authentik-server) handles the auth checks.
resource "authentik_provider_proxy" "agent_os" {
  name               = "AgentOS"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://agent.dcxxiv.com"
}

resource "authentik_application" "agent_os" {
  name              = "AgentOS"
  slug              = "agent-os"
  protocol_provider = authentik_provider_proxy.agent_os.id
  meta_launch_url   = "https://agent.dcxxiv.com"
}
