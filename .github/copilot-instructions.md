# k3s-lab — AI Assistant Context

Flux v2 GitOps repo for a k3s cluster. Primary cluster: `clusters/ovh-lab/` (bootstrapped). `clusters/oci-lab/` is a separate, not-yet-bootstrapped cluster.

## Architecture

- `apps/` — one dir per application (namespace, kustomization, manifests)
- `infrastructure/` — cluster infrastructure (Traefik, cert-manager, Longhorn, JuiceFS, authentik, monitoring)
- `clusters/ovh-lab/` — Flux Kustomization resources wiring the repo to the cluster

## Conventions

- **Ingress:** Traefik `IngressRoute` CRDs throughout. Never use standard `Ingress` objects.
- **TLS:** cert-manager, ClusterIssuer `letsencrypt-prod` (Cloudflare DNS01). Each app needs a `Certificate` resource — IngressRoute does not support cert-manager annotations.
- **Storage:** Longhorn is the default StorageClass. Use JuiceFS for ReadWriteMany / shared access.
- **Secrets:** This repo uses **SOPS + age**. Secrets are committed to Git as `*.sops.yaml` files and decrypted at apply time by Flux's kustomize-controller. Never create plaintext `Secret` manifests or out-of-band cluster secrets. To add or edit a secret, run `make edit-secret FILE=<path>` (or `sops <path>` directly). Do not write unencrypted secret values anywhere in the repo.
- **Labels:** Tag resources with `app.kubernetes.io/part-of: gitops`.

## Live App Set

The authoritative list of active apps and infrastructure components is `clusters/ovh-lab/kustomization.yaml`. Do not rely on any hardcoded app list in this file — consult that file for the current set.

## Authentication

Every app is protected by authentik forward auth. Each app namespace needs a `Middleware` named `authentik` with a `forwardAuth` address pointing to the relevant outpost in the `authentik` namespace. The IngressRoute references `name: authentik`. The outpost must be configured in authentik as domain-level forward auth with `authentik_host_browser: https://auth.dcxxiv.com/` and the app's provider assigned to it. See `apps/nodecast-tv/` (active) for the reference implementation — `middleware.yaml` + IngressRoute.

## Node Notes

- The cluster is 3 OVH nodes (`k3s-ovh-1/2/3`), all control-plane + etcd, no taints — workloads schedule anywhere.
- Provisioned via Terraform (`bootstrap/terraform/ovh-k3s/`); cloud-init is generated from templates in that module, not from hand-maintained per-node files.

## Workflow

- Never push directly to main. Feature branch → PR.
- Preview changes: `flux diff kustomization <name> -n flux-system`
- Force reconcile: `flux reconcile kustomization <name> -n flux-system`
- Adding an app: `apps/<name>/` + `clusters/ovh-lab/<name>-kustomization.yaml` + entry in `clusters/ovh-lab/kustomization.yaml` + Middleware for auth.
- See README for full project structure and additional operational commands.
