# Admin group — referenced by Grafana's role_attribute_path:
#   contains(groups[*], 'authentik Admins') && 'Admin' || 'Viewer'
# Authentik creates this group on first boot; import brings it under Terraform management.
import {
  to = authentik_group.admins
  id = "66e20b4d-aded-42e1-8ec3-561fb7e447ac"
}

resource "authentik_group" "admins" {
  name         = "authentik Admins"
  is_superuser = true
  users        = [data.authentik_user.akadmin.id]
}

# Default admin user — added to both admin groups below
data "authentik_user" "akadmin" {
  username = "akadmin"
}

# Kubernetes admins group — members get cluster-admin via ClusterRoleBinding in infrastructure/weave-gitops/rbac.yaml
resource "authentik_group" "k8s_admins" {
  name         = "k8s Admins"
  is_superuser = false
  users        = [data.authentik_user.akadmin.id]
}

# Groups injected into 'profile' scope — Grafana requests 'openid email profile'
resource "authentik_property_mapping_provider_scope" "groups_profile" {
  name       = "OAuth Mapping: groups (profile)"
  scope_name = "profile"
  expression = "return [group.name for group in request.user.ak_groups.all()]"
}

# Groups injected into 'groups' scope — Weave GitOps requests 'openid email groups'
resource "authentik_property_mapping_provider_scope" "groups_scope" {
  name       = "OAuth Mapping: groups (groups)"
  scope_name = "groups"
  expression = "return [group.name for group in request.user.ak_groups.all()]"
}
