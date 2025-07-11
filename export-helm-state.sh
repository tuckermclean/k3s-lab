#!/bin/bash
set -euo pipefail

mkdir -p helm-values manifests charts

# Update repos so helm knows what it can pull
helm repo update

echo "Fetching all Helm releases..."
helm list --all-namespaces -o json | jq -c '.[]' | while read -r release; do
  name=$(echo "$release" | jq -r .name)
  namespace=$(echo "$release" | jq -r .namespace)
  chart_full=$(echo "$release" | jq -r .chart)  # e.g., authentik-2025.6.3
  chart_name=$(echo "$chart_full" | sed -E 's/-(v?[0-9].*)$//')  # strip version
  chart_version=$(echo "$chart_full" | grep -oE '[0-9]+(\.[0-9]+)+')

  echo "🔹 Processing $name in $namespace (chart: $chart_name, version: $chart_version)"

  # Try to find repo
  repo=""
  while read -r line; do
    repo_name=$(echo "$line" | awk '{print $1}')
    helm search repo "$repo_name/$chart_name" --version "$chart_version" | grep -q "$chart_name" && repo=$repo_name && break
  done < <(helm repo list | tail -n +2)

  if [[ -z "$repo" ]]; then
    echo "⚠️ Could not find repo for $chart_name. Skipping pull."
    echo "# (could not render template)" > "manifests/${name}.yaml"
    continue
  fi

  chart_ref="$repo/$chart_name"
  helm pull "$chart_ref" --version "$chart_version" --untar --untardir charts || {
    echo "⚠️ Failed to pull chart $chart_ref"
    echo "# (could not render template)" > "manifests/${name}.yaml"
    continue
  }

  helm get values "$name" -n "$namespace" -o yaml > "helm-values/${name}.yaml" || echo "# (no values found)" > "helm-values/${name}.yaml"

  chart_path="./charts/$chart_name"
  helm template "$name" "$chart_path" -n "$namespace" -f "helm-values/${name}.yaml" > "manifests/${name}.yaml"
done

echo "✅ Done exporting Helm releases."
