#!/bin/bash

set -euo pipefail

OUT_DIR="k8s-snapshot-balanced"
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

echo "📦 Dumping balanced Kubernetes manifests into '$OUT_DIR'..."

mkdir -p "$OUT_DIR"

for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  for resource in "${RESOURCES[@]}"; do
    echo "🔍 Namespace: $ns | Resource: $resource"
    DEST="$OUT_DIR/$ns/$resource.yaml"
    mkdir -p "$(dirname "$DEST")"

    if kubectl get "$resource" -n "$ns" &>/dev/null; then
      kubectl get "$resource" -n "$ns" -o yaml |
        yq eval '
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
        ' - > "$DEST"
    fi
  done
done

echo "✅ Done. Your balanced manifests are in: $OUT_DIR/" 