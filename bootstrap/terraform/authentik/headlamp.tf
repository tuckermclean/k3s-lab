# Proxy provider — forward_single mode protects headlamp.dcxxiv.com via Traefik forwardAuth.
# The embedded outpost (running inside authentik-server) handles the auth checks.
resource "authentik_provider_proxy" "headlamp" {
  name               = "Headlamp"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://headlamp.dcxxiv.com"
}

resource "authentik_application" "headlamp" {
  name              = "Headlamp"
  slug              = "headlamp"
  protocol_provider = authentik_provider_proxy.headlamp.id
  meta_launch_url   = "https://headlamp.dcxxiv.com"
}

# Import the Authentik-created embedded outpost so we can assign proxy providers to it.
# UUID sourced from authentik-server pod logs: ak-outpost-d0ed712987414d8d84d112304d0f2a26
import {
  to = authentik_outpost.embedded
  id = "d0ed7129-8741-4d8d-84d1-12304d0f2a26"
}

resource "authentik_provider_proxy" "longhorn" {
  name               = "Longhorn"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://longhorn.dcxxiv.com"
}

resource "authentik_application" "longhorn" {
  name              = "Longhorn"
  slug              = "longhorn"
  protocol_provider = authentik_provider_proxy.longhorn.id
  meta_launch_url   = "https://longhorn.dcxxiv.com"
}

resource "authentik_provider_proxy" "juicefs_dashboard" {
  name               = "JuiceFS Dashboard"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://juicefs.dcxxiv.com"
}

resource "authentik_application" "juicefs_dashboard" {
  name              = "JuiceFS Dashboard"
  slug              = "juicefs-dashboard"
  protocol_provider = authentik_provider_proxy.juicefs_dashboard.id
  meta_launch_url   = "https://juicefs.dcxxiv.com"
}

resource "authentik_provider_proxy" "juicefs_s3" {
  name               = "JuiceFS S3 Gateway"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
  external_host      = "https://s3.dcxxiv.com"
}

resource "authentik_application" "juicefs_s3" {
  name              = "JuiceFS S3 Gateway"
  slug              = "juicefs-s3"
  protocol_provider = authentik_provider_proxy.juicefs_s3.id
  meta_launch_url   = "https://s3.dcxxiv.com"
}

resource "authentik_outpost" "embedded" {
  name               = "authentik Embedded Outpost"
  type               = "proxy"
  protocol_providers = [
    authentik_provider_proxy.headlamp.id,
    authentik_provider_proxy.longhorn.id,
    authentik_provider_proxy.juicefs_dashboard.id,
    authentik_provider_proxy.juicefs_s3.id,
  ]

  lifecycle {
    # Authentik owns the outpost config and service_connection; don't overwrite.
    ignore_changes = [config, service_connection]
  }
}
