# Admin group — referenced by Grafana's role_attribute_path:
#   contains(groups[*], 'authentik Admins') && 'Admin' || 'Viewer'
resource "authentik_group" "admins" {
  name         = "authentik Admins"
  is_superuser = true
}

# Custom scope mapping that injects 'groups' into the profile scope response.
# Authentik's built-in profile scope does not include groups by default; this
# mapping runs when a client requests 'profile' and adds the groups list so
# Grafana's role_attribute_path JMESPath expression can find it.
resource "authentik_property_mapping_provider_scope" "groups" {
  name       = "OAuth Mapping: groups"
  scope_name = "profile"
  expression = "return [group.name for group in request.user.ak_groups.all()]"
}
