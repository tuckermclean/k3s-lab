#!/bin/bash

set -euo pipefail

OUT_DIR="k8s-snapshot-clean"
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

echo "📦 Dumping Kubernetes manifests into '$OUT_DIR'..."

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
        ' - > "$DEST"
    fi
  done
done

echo "✅ Done. Your sanitized manifests are in: $OUT_DIR/"

