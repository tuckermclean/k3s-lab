# K3s Lab - GitOps Repository

This repository follows the Flux v2 GitOps pattern for managing a single-cluster Kubernetes lab environment.

## Repository Structure

```
.
├── apps/                    # Application HelmReleases & values
│   ├── authentik/          # Identity provider
│   ├── jellyfin/           # Media server
│   └── dashboard/          # Kubernetes dashboard
├── infrastructure/         # Cluster infrastructure components
│   ├── traefik/           # Ingress controller
│   ├── cert-manager/      # Certificate management
│   └── nfs-provisioner/   # Storage provisioner
└── clusters/
    └── k3s-lab/           # Cluster-specific configuration
        ├── kustomization.yaml
        └── flux-kustomization.yaml
```

## Quick Start

### Prerequisites

- A K3s (or Kubernetes) cluster
- Flux CLI installed and authenticated to your Git provider
- `kubectl` configured to access your cluster

### Bootstrap

Flux bootstrap is the supported way to install Flux and point it at this repo. Example:

```bash
flux bootstrap github \
  --owner=yourusername \
  --repository=k3s-lab \
  --branch=main \
  --path=./clusters/k3s-lab \
  --personal
```

If you rely on cluster-local resources (Storage, DNS, LoadBalancer), ensure they exist before reconciling the app kustomizations (see "Environment-specific notes" below).

### Verify Deployment

```bash
# Check Flux controllers and sources
flux get all

# Check all GitOps-managed resources
kubectl get all -l app.kubernetes.io/part-of=gitops

# View reconciliation trace for a Kustomization or resource
flux trace
```


## Components

### Infrastructure

- **Traefik**: Ingress controller (see `infrastructure/traefik/helmrelease.yaml`) deployed as a DaemonSet + LoadBalancer.
- **Cert-Manager**: Certificate management (see `infrastructure/cert-manager/helmrelease.yaml` and `infrastructure/cert-manager-config/clusterissuer.yaml`). ClusterIssuers use HTTP01 via Traefik by default.
- **NFS Provisioner**: `nfs-subdir-external-provisioner` configured in `infrastructure/nfs-provisioner/helmrelease.yaml`.

### Applications

- **Jellyfin**: Media streaming server (`apps/jellyfin/*`).
- **Jellyseerr**: Media request manager (`apps/jellyseerr/*`).
- **Minecraft Bedrock**: Game server (`apps/minecraft-bedrock/*`).

## Development Workflow

1. Make changes in a feature branch (edit manifests under `apps/` or `infrastructure/`).
2. Test diffs locally with Flux (per-kustomization):

```bash
# show what would change for all cluster overlays
flux diff kustomization clusters/k3s-lab

# or target a single kustomization (recommended during development)
flux diff kustomization jellyfin -n flux-system
```

3. Create a PR and merge to `main`.
4. Flux will reconcile the Kustomizations declared in `clusters/k3s-lab/`.

## Useful Commands

```bash
# Show diffs
flux diff kustomization clusters/k3s-lab

# Force reconciliation for a named kustomization
flux reconcile kustomization <name> -n flux-system

# Follow Flux logs
flux logs --follow

# List HelmReleases in a namespace
flux get helmreleases -n media
```

## Security Notes

- **No plaintext secrets in Git**: This repo does not include SOPS-encrypted secrets. Create secrets in-cluster or use external secret management.
- **Certificates**: cert-manager will manage TLS certs for Ingress objects annotated to use ClusterIssuers (see `infrastructure/cert-manager-config/clusterissuer.yaml`). Replace the email/ACME endpoints with your values when bootstrapping.
- **Labels**: Most resources are labeled with `app.kubernetes.io/part-of: gitops` for easy selection.

## Troubleshooting

### Common Issues

1. Reconciliation failures: check `flux logs --follow` and `kubectl describe kustomization <name> -n flux-system`.
2. Missing resources: ensure file paths referenced by kustomizations exist (each `apps/<name>/kustomization.yaml` includes namespace/helmrelease/resources).
3. Environment mismatches: many manifests assume an NFS backend and a working DNS/LoadBalancer.

### Debug commands

```bash
# Flux and controller health
kubectl get pods -n flux-system
flux get kustomizations -n flux-system

# Reconciliation events
flux events

# Inspect a Kustomization
kubectl describe kustomization jellyfin -n flux-system
```

### Fix

- Several manifests reference an external NFS server: `openmediavault.home.dcxxiv.com` (see `apps/jellyfin/media-volume.yaml` and `infrastructure/nfs-provisioner/helmrelease.yaml`). Update these or provide an equivalent NFS server in your environment before applying PVs/PVCs.
- `infrastructure/cert-manager-config/clusterissuer.yaml` contains example ACME accounts/emails. Replace them with your own email and appropriate ACME endpoints for production.
