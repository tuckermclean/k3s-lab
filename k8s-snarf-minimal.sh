#!/bin/bash

set -euo pipefail

OUT_DIR="k8s-snapshot-minimal"
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

echo "📦 Dumping minimal Kubernetes manifests into '$OUT_DIR'..."

mkdir -p "$OUT_DIR"

for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  for resource in "${RESOURCES[@]}"; do
    echo "🔍 Namespace: $ns | Resource: $resource"
    DEST="$OUT_DIR/$ns/$resource.yaml"
    mkdir -p "$(dirname "$DEST")"

    if kubectl get "$resource" -n "$ns" &>/dev/null; then
      kubectl get "$resource" -n "$ns" -o yaml |
        yq eval '
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
        ' - > "$DEST"
    fi
  done
done

echo "✅ Done. Your minimal manifests are in: $OUT_DIR/" 