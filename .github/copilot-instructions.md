# AI Assistant Instructions for k3s-lab

This repository manages a single-cluster Kubernetes lab using Flux v2 (GitOps). Follow these concise rules to be effective:

Architecture
- GitOps: All state is defined in this repo; Flux reconciles automatically.
- Key directories:
  - apps/: Application manifests (per-app kustomization, namespace, HelmRelease/plain resources). Examples: apps/jellyfin/*, apps/minecraft-bedrock/*, apps/openhands/*.
  - infrastructure/: Cluster infra (Traefik, cert-manager, NFS provisioner).
  - clusters/k3s-lab/: Flux Kustomizations wiring repo paths to the cluster. flux-system/ contains gotk-*.yaml bootstrap artifacts.

Workflow
- Bootstrap: flux bootstrap github ... --path=./clusters/k3s-lab (see README for exact command).
- Changes: edit manifests in a feature branch; preview with flux diff kustomization <name> -n flux-system; open a PR.
- Verification: flux get all; kubectl get all -l app.kubernetes.io/part-of=gitops; flux reconcile kustomization <name> -n flux-system.

Conventions
- No secrets in Git. Create Kubernetes Secrets in-cluster and reference them via envFrom.secretRef.
- Label resources with app.kubernetes.io/part-of: gitops.
- Ingress uses Traefik (ingressClassName: traefik). TLS via cert-manager ClusterIssuers in infrastructure/cert-manager-config/.

Integration notes
- Traefik: infrastructure/traefik/helmrelease.yaml (DaemonSet + LoadBalancer). UDP entrypoint used by apps/minecraft-bedrock/.
- Cert-manager: ClusterIssuers in infrastructure/cert-manager-config/clusterissuer.yaml (HTTP01 via Traefik). Update ACME email/domains for your environment.
- NFS: infrastructure/nfs-provisioner/helmrelease.yaml sets storageClass nfs-provisioner; some PVs reference openmediavault.home.dcxxiv.com. Replace with your NFS server as needed.

Common tasks
- Add an app: create apps/<name>/ kustomization and manifests; include it under clusters/k3s-lab/kustomization.yaml as a Kustomization (see existing -kustomization.yaml files).
- Update Traefik/cert-manager: edit infra manifests then flux reconcile kustomization <name> -n flux-system.

PR etiquette for AI agents
- Never push to main. Create a feature branch, commit focused changes, and open a draft PR unless told otherwise.
- Do not add plaintext secrets, large binaries, or build artifacts. Respect .gitignore.
- Keep changes minimal and aligned with current repo structure.

Debug quick refs
- kubectl get pods -n flux-system; flux get kustomizations -n flux-system
- flux logs --follow; flux events
- kubectl describe kustomization <name> -n flux-system
