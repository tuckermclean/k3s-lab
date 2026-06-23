variable "authentik_url" {
  description = "Authentik base URL"
  type        = string
  default     = "https://auth.dcxxiv.com"
}

variable "authentik_token" {
  description = "Authentik API token — create a service account token in the Authentik admin UI"
  type        = string
  sensitive   = true
}

variable "grafana_client_id" {
  description = "OAuth2 client ID for Grafana. Must match GF_AUTH_GENERIC_OAUTH_CLIENT_ID in infrastructure/monitoring/secret.sops.yaml"
  type        = string
  default     = "grafana"
}

variable "grafana_client_secret" {
  description = "OAuth2 client secret for Grafana. Must match GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET in infrastructure/monitoring/secret.sops.yaml"
  type        = string
  sensitive   = true
}

variable "weave_client_id" {
  description = "OAuth2 client ID for Weave GitOps. Must match clientID in infrastructure/weave-gitops/secret.sops.yaml"
  type        = string
  default     = "weave-gitops"
}

variable "weave_client_secret" {
  description = "OAuth2 client secret for Weave GitOps. Must match clientSecret in infrastructure/weave-gitops/secret.sops.yaml"
  type        = string
  sensitive   = true
}

variable "nodecast_client_id" {
  description = "OAuth2 client ID for NodeCast TV. Must match OIDC_CLIENT_ID in apps/nodecast-tv/secret.sops.yaml"
  type        = string
  default     = "nodecast-tv"
}

variable "nodecast_client_secret" {
  description = "OAuth2 client secret for NodeCast TV. Must match OIDC_CLIENT_SECRET in apps/nodecast-tv/secret.sops.yaml"
  type        = string
  sensitive   = true
}
