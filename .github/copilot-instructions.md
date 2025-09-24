# Copilot Instructions for k3s-lab

This repository manages a single-cluster Kubernetes lab using Flux v2 (GitOps). AI agents should follow these concise, actionable rules to be productive quickly:

## Architecture Overview
- **GitOps Pattern**: All cluster state is managed via manifests in this repo. Flux watches and reconciles changes automatically.
- **Key Directories**:
  - `apps/`: Application manifests (per-app `kustomization.yaml`, `namespace.yaml`, HelmRelease or plain resources). Examples: `apps/jellyfin/helmrelease.yaml`, `apps/minecraft-bedrock/deployment.yaml`.
  - `infrastructure/`: Cluster infra (Traefik, cert-manager, NFS provisioner). Each has its own kustomization and HelmRelease.
  - `clusters/k3s-lab/`: Flux Kustomizations that point the cluster to app and infra folders (e.g. `clusters/k3s-lab/jellyfin-kustomization.yaml`). The `flux-system/` folder here contains the bootstrap artifacts (`gotk-components.yaml`, `gotk-sync.yaml`).
- **Data Flow**: Changes in manifests are picked up by Flux, which applies them to the cluster. Secrets are generated at runtime and not stored in Git.

## Developer Workflow
- **Bootstrap**: Use `flux bootstrap github ...` to connect cluster to repo (see README for full command).
-- **Setup**: There is no repository setup script in `scripts/` (README is out of date). Manual steps to bootstrap are: create a K3s cluster, install Flux with `flux bootstrap github ...` pointing `--path=./clusters/k3s-lab`, then let Flux reconcile the `flux-system` kustomizations in `clusters/k3s-lab/flux-system`.
- **Change Management**:
  - Edit manifests in feature branches.
  - Test changes locally with `flux diff kustomization clusters/k3s-lab` (or individual kustomizations, e.g. `flux diff kustomization jellyfin -n flux-system`).
  - Create a PR and merge to `main`. Flux kustomizations under `clusters/k3s-lab/` will reconcile in-cluster.
-- **Verification**:
  - Use `flux get all` and `kubectl get all -l app.kubernetes.io/part-of=gitops` to check resource status.
  - Force reconciliation per-kustomization: `flux reconcile kustomization <name> -n flux-system`, e.g. `flux reconcile kustomization jellyfin -n flux-system`.

## Project Conventions
-- **No secrets in Git**: This repo does not include SOPS-encrypted secrets. Secrets are expected to be created in-cluster (or managed externally). Do not add plaintext secrets.
- **Resource Labeling**: All resources use `app.kubernetes.io/part-of: gitops` for easy filtering.
- **Kustomize overlays**: Cluster config is managed via overlays in `clusters/k3s-lab/`.
- **HelmReleases**: Apps are deployed via HelmRelease manifests in their respective `apps/` subfolders.

## Integration Points (practical notes)
- **Flux v2**: Kustomizations in `clusters/k3s-lab/` use a `GitRepository` named `flux-system`. See `clusters/k3s-lab/flux-system/*` for bootstrap artifacts.
- **Traefik**: Deployed via `infrastructure/traefik/helmrelease.yaml` as a DaemonSet + LoadBalancer; ingressClass is `traefik` and used by app ingresses.
- **Cert-Manager**: ClusterIssuers live in `infrastructure/cert-manager-config/clusterissuer.yaml` and use HTTP01 via Traefik. Update these if you change DNS or ACME email.
- **NFS**: The nfs-subdir-external-provisioner is configured in `infrastructure/nfs-provisioner/helmrelease.yaml` and points to an external server `openmediavault.home.dcxxiv.com` (repository uses this host in PVs/Helm values). This is environment-specific—do not assume it will exist on other environments.

## Debugging & Troubleshooting (concrete)
- Check Flux controllers and kustomization status:
  - `kubectl get pods -n flux-system`
  - `flux get kustomizations -n flux-system`
  - `flux logs --follow`
- Inspect kustomization reconciliation and events:
  - `kubectl describe kustomization <name> -n flux-system`
  - `flux events`
- Common repo-specific pitfalls:
  - README references `./scripts/setup.sh`, but `scripts/` is empty—do not rely on that script.
  - Several manifests (e.g. `apps/jellyfin/media-volume.yaml`, `infrastructure/nfs-provisioner/helmrelease.yaml`) reference `openmediavault.home.dcxxiv.com`. Ensure any target environment has an appropriate NFS server or update these manifests.
  - Cert-manager ClusterIssuers use a personal email and ACME staging/prod endpoints in `infrastructure/cert-manager-config/clusterissuer.yaml` — replace with your own email when bootstrapping.

## Practical examples (paths)
- Add an app: create `apps/<name>/kustomization.yaml`, include `namespace.yaml` and either `helmrelease.yaml` or raw manifests, then add a Kustomization in `clusters/k3s-lab/` or update `clusters/k3s-lab/kustomization.yaml` to include it.
- Update Traefik: edit `infrastructure/traefik/helmrelease.yaml` and the corresponding kustomization `clusters/k3s-lab/traefik-kustomization.yaml` will pick it up.
- Inspect Jellyfin example: `apps/jellyfin/helmrelease.yaml`, `apps/jellyfin/media-ingress.yaml`, `apps/jellyfin/media-volume.yaml` show hostname affinity, traefik ingress TLS, and NFS-backed PVs.

---
If anything in these instructions is unclear or you want more detail about a specific area (e.g. how HelmRelease values are structured in this repo, or how to change the NFS backend), tell me which area and I'll expand with examples and automated checks.
