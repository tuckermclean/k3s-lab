#!/bin/bash
set -euo pipefail

MODE=${1:-balanced}
OUT_DIR="k8s-snapshot-${MODE}"

RESOURCES=(
  deployments
  services
  ingresses
  configmaps
  secrets
  statefulsets
  daemonsets
  pods
  persistentvolumeclaims
  serviceaccounts
  roles
  rolebindings
  clusterroles
  clusterrolebindings
  customresourcedefinitions
)

get_yq_filter() {
  local mode=$1
  
  case $mode in
    minimal)
      cat << 'EOF'
# Remove all runtime metadata
del(
  .items[].metadata.uid,
  .items[].metadata.selfLink,
  .items[].metadata.resourceVersion,
  .items[].metadata.generation,
  .items[].metadata.creationTimestamp,
  .items[].metadata.managedFields,
  .items[].status
) |
# For secrets, only keep structure, remove all data
.items[] |= (
  select(.kind == "Secret") | .data = {}
) |
# For CRDs, keep only essential structure
.items[] |= (
  select(.kind == "CustomResourceDefinition") | 
  .spec.versions[].schema.openAPIV3Schema = {
    "type": "object",
    "properties": {}
  }
) |
# Remove all large annotations
.items[].metadata.annotations = {} |
# Remove labels except essential ones
.items[].metadata.labels |= (
  with_entries(
    select(.key | test("^(app|app.kubernetes.io|k8s-app|component)$"))
  )
)
EOF
      ;;
    balanced)
      cat << 'EOF'
# Remove runtime metadata
del(
  .items[].metadata.uid,
  .items[].metadata.selfLink,
  .items[].metadata.resourceVersion,
  .items[].metadata.generation,
  .items[].metadata.creationTimestamp,
  .items[].metadata.managedFields,
  .items[].status
) |
# For secrets, keep small data, redact large base64
.items[] |= (
  select(.kind == "Secret") | 
  .data |= (
    with_entries(
      select(.value | length <= 100)
    )
  )
) |
# For CRDs, keep structure but remove verbose descriptions
.items[] |= (
  select(.kind == "CustomResourceDefinition") | 
  .spec.versions[].schema.openAPIV3Schema |= (
    del(.description) |
    .properties |= (
      with_entries(
        .value |= del(.description)
      )
    )
  )
) |
# Remove very large annotations (base64 data)
.items[].metadata.annotations |= (
  with_entries(
    select(.value | length <= 200)
  )
)
EOF
      ;;
    clean)
      cat << 'EOF'
# Remove runtime metadata
del(
  .items[].metadata.uid,
  .items[].metadata.selfLink,
  .items[].metadata.resourceVersion,
  .items[].metadata.generation,
  .items[].metadata.creationTimestamp,
  .items[].metadata.managedFields,
  .items[].status
) |
# For secrets, only keep essential data, remove large base64 content
.items[] |= (
  select(.kind == "Secret") | 
  .data |= (
    with_entries(
      if .key | test("^(tls\\.(crt|key)|ca\\.crt|token|password|hash|release)$") then
        .value = "REDACTED_BASE64_DATA"
      else
        .
      end
    )
  )
) |
# For CRDs, remove verbose OpenAPI schemas but keep structure
.items[] |= (
  select(.kind == "CustomResourceDefinition") | 
  .spec.versions[].schema.openAPIV3Schema |= (
    .properties |= (
      with_entries(
        .value |= (
          if has("description") then
            .description = "REDACTED_DESCRIPTION"
          else
            .
          end
        )
      )
    )
  )
) |
# Remove large annotations that contain base64 data
.items[].metadata.annotations |= (
  with_entries(
    if .value | test("^[A-Za-z0-9+/=]{100,}$") then
      .value = "REDACTED_BASE64_ANNOTATION"
    else
      .
    end
  )
)
EOF
      ;;
    *)
      echo "Unknown mode: $mode. Use minimal, balanced, or clean." >&2
      exit 1
      ;;
  esac
}

main() {
  echo "📦 Dumping ${MODE} Kubernetes manifests into '$OUT_DIR'..."
  
  mkdir -p "$OUT_DIR"
  
  for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    for resource in "${RESOURCES[@]}"; do
      echo "🔍 Namespace: $ns | Resource: $resource"
      DEST="$OUT_DIR/$ns/$resource.yaml"
      mkdir -p "$(dirname "$DEST")"

      if kubectl get "$resource" -n "$ns" &>/dev/null; then
        kubectl get "$resource" -n "$ns" -o yaml | \
          yq eval "$(get_yq_filter "$MODE")" - > "$DEST"
      fi
    done
  done

  echo "✅ Done. Your ${MODE} manifests are in: $OUT_DIR/"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
