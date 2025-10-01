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
  # Copilot instructions — k3s-lab (Flux GitOps)

  This repo manages a single k3s cluster using Flux v2 (GitOps). The file below is a concise, actionable cheat-sheet for AI agents to be productive quickly.

  Key ideas
  - Repo = desired cluster state. Flux reconciles changes from `clusters/k3s-lab/` -> `apps/`, `infrastructure/`.
  - Manifests are YAML + Kustomize overlays and HelmRelease objects. No runtime secrets are checked into Git.

  Essential locations (refer to these files when changing behavior)
  - `apps/` — per-app folders. Examples: `apps/jellyfin/helmrelease.yaml`, `apps/minecraft-bedrock/deployment.yaml`.
  - `infrastructure/` — cluster infra HelmReleases (Traefik, cert-manager, NFS). Example: `infrastructure/traefik/helmrelease.yaml`.
  - `clusters/k3s-lab/` — Kustomizations that glue Git -> cluster. Bootstrap artifacts: `clusters/k3s-lab/flux-system/gotk-components.yaml`, `gotk-sync.yaml`.

  Quick workflows (commands you will use)
  - Bootstrap cluster: flux bootstrap github ... --path=./clusters/k3s-lab (see `README.md` for exact example).
  - Preview changes: flux diff kustomization <name> -n flux-system or `flux diff kustomization clusters/k3s-lab`.
  - Force reconcile: flux reconcile kustomization <name> -n flux-system (e.g. `jellyfin`, `traefik`).
  - Inspect status: flux get all -n flux-system; kubectl get all -l app.kubernetes.io/part-of=gitops
  - Debug: kubectl describe kustomization <name> -n flux-system; flux events; flux logs --follow

  Project-specific conventions
  - Do NOT commit plaintext secrets. There are no SOPS-encrypted secrets in this repo.
  - Resources are labeled with `app.kubernetes.io/part-of: gitops` — use this for filtering and queries.
  - Apps use HelmRelease manifests inside `apps/<name>/`. Kustomize overlays live in `clusters/k3s-lab/`.
  - There is no `scripts/setup.sh` (README mentions it) — bootstrapping is manual via Flux commands.

  Integration notes / gotchas
  - Traefik ingressClass: `traefik`. See `apps/*/media-ingress.yaml` (e.g. `apps/jellyfin/media-ingress.yaml`) for TLS/host examples.
  - Cert-manager ClusterIssuer: `infrastructure/cert-manager-config/clusterissuer.yaml` uses HTTP-01 via Traefik — update ACME email/DNS when bootstrapping.
  - NFS: `infrastructure/nfs-provisioner/helmrelease.yaml` and some PVs reference `openmediavault.home.dcxxiv.com`. This is environment-specific — replace or provide equivalent NFS backend.

  Common tasks with file examples
  - Add an app: create `apps/<name>/kustomization.yaml`, `apps/<name>/namespace.yaml`, and `apps/<name>/helmrelease.yaml` or manifests; then add or update `clusters/k3s-lab/kustomization.yaml` to include the app.
  - Change Traefik config: edit `infrastructure/traefik/helmrelease.yaml` and then `flux reconcile kustomization traefik -n flux-system`.

  If something is unclear or you need additional examples (e.g., HelmRelease value patterns, PV/StorageClass conventions), tell me which area and I will expand with targeted file references and quick verification steps.

  ---
  Files worth inspecting first: `README.md`, `clusters/k3s-lab/flux-system/*`, `apps/jellyfin/*`, `infrastructure/traefik/helmrelease.yaml`, `infrastructure/nfs-provisioner/helmrelease.yaml`.

