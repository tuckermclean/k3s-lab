# Embedded outpost — runs inside authentik-server, handles proxy auth for all protected apps.
# UUID is looked up dynamically so this survives cluster rebuilds without hardcoded IDs.
import {
  to = authentik_outpost.embedded
  id = local.embedded_outpost_id
}

resource "authentik_outpost" "embedded" {
  name = "authentik Embedded Outpost"
  type = "proxy"
  protocol_providers = [
    authentik_provider_proxy.headlamp.id,
    authentik_provider_proxy.longhorn.id,
    authentik_provider_proxy.juicefs_dashboard.id,
    authentik_provider_proxy.juicefs_s3.id,
    authentik_provider_proxy.orchestrator.id,
    authentik_provider_proxy.deluge.id,
    authentik_provider_proxy.agent_os.id,
    authentik_provider_proxy.juggler.id,
  ]

  # authentik_host is the URL the browser is redirected to for login.
  # The embedded outpost uses IPC (not HTTP) for internal API calls, so this only affects redirects.
  config = jsonencode({
    authentik_host          = "https://auth.dcxxiv.com"
    authentik_host_browser  = ""
    authentik_host_insecure = false
    log_level               = "info"
    kubernetes_namespace    = "authentik"
    kubernetes_replicas     = 1
    kubernetes_service_type = "ClusterIP"
    object_naming_template  = "ak-outpost-%(name)s"
    refresh_interval        = "minutes=5"
  })

  lifecycle {
    ignore_changes = [service_connection]
  }
}
