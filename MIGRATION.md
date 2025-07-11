# Migration Guide: Old Structure to Flux GitOps

This document outlines the changes made during the repository refactoring to follow Flux GitOps best practices.

## What Changed

### Before (Old Structure)
```
.
├── all.yaml                    # 17,871 lines of mixed manifests
├── authentik-values.yaml       # Scattered configuration
├── certificate.yaml           # Root-level certificates
├── clusters/lab/apps/         # Mixed apps and infrastructure
│   ├── traefik/              # Infrastructure in apps/
│   ├── cert-manager/         # Infrastructure in apps/
│   ├── nfs-provisioner/      # Infrastructure in apps/
│   ├── authentik/            # Application
│   ├── jellyfin/             # Application
│   └── dashboard/            # Application
```

### After (New Structure)
```
.
├── apps/                      # Applications only
│   ├── authentik/            # Identity provider
│   ├── jellyfin/             # Media server
│   └── dashboard/            # Kubernetes dashboard
├── infrastructure/           # Infrastructure components
│   ├── traefik/             # Ingress controller
│   ├── cert-manager/        # Certificate management
│   └── nfs-provisioner/     # Storage provisioner
└── clusters/k3s-lab/        # Cluster configuration
    ├── kustomization.yaml   # Kustomize resources
    └── flux-kustomization.yaml # Flux management
```

## Key Improvements

### 1. Clear Separation of Concerns
- **Infrastructure**: Cluster-level components (traefik, cert-manager, nfs-provisioner)
- **Applications**: User-facing services (authentik, jellyfin, dashboard)
- **Cluster**: Flux configuration and cluster-specific settings

### 2. Proper GitOps Labels
All resources now have `app.kubernetes.io/part-of: gitops` label for easy identification:
```bash
kubectl get all -l app.kubernetes.io/part-of=gitops
```

### 3. Prune Configuration
Flux will automatically remove resources that are no longer in Git:
```yaml
spec:
  prune: true
  interval: 10m
```

### 4. Organized File Structure
- Configuration files moved to appropriate component directories
- Values files properly named and located
- Certificates organized by component

## Migration Steps

### 1. Backup Current State
```bash
# Export current Helm releases
./export-helm-state.sh

# Backup any custom configurations
kubectl get all -o yaml > backup-all.yaml
```

### 2. Update Flux Bootstrap
If you need to re-bootstrap Flux with the new structure:
```bash
# Uninstall current Flux (if needed)
flux uninstall --silent

# Bootstrap with new path
flux bootstrap github \
  --owner=your-github-username \
  --repository=k3s-lab \
  --branch=main \
  --path=./clusters/k3s-lab \
  --personal
```

### 3. Verify Migration
```bash
# Check Flux status
flux get all

# Verify all resources are labeled
kubectl get all -l app.kubernetes.io/part-of=gitops

# Check reconciliation
flux trace
```

## File Mappings

| Old Location | New Location | Notes |
|-------------|-------------|-------|
| `clusters/lab/apps/traefik/` | `infrastructure/traefik/` | Infrastructure component |
| `clusters/lab/apps/cert-manager/` | `infrastructure/cert-manager/` | Infrastructure component |
| `clusters/lab/apps/nfs-provisioner/` | `infrastructure/nfs-provisioner/` | Infrastructure component |
| `clusters/lab/apps/authentik/` | `apps/authentik/` | Application |
| `clusters/lab/apps/jellyfin/` | `apps/jellyfin/` | Application |
| `clusters/lab/apps/dashboard/` | `apps/dashboard/` | Application |
| `authentik-values.yaml` | `apps/authentik/values.yaml` | Renamed and moved |
| `certificate.yaml` | `infrastructure/cert-manager/certificate.yaml` | Moved to cert-manager |
| `media-volume.yaml` | `apps/jellyfin/media-volume.yaml` | Moved to jellyfin app |

## Troubleshooting

### Common Issues After Migration

1. **Missing Resources**: Check that all files were moved correctly
2. **Reconciliation Failures**: Verify kustomization.yaml files are correct
3. **Label Issues**: Ensure all resources have the gitops label

### Rollback Plan

If issues occur, you can rollback by:
1. Reverting the Git commit
2. Running `flux reconcile kustomization clusters/k3s-lab`
3. Or restoring from the backup: `kubectl apply -f backup-all.yaml`

## Next Steps

1. **Test the new structure** with `flux diff kustomization clusters/k3s-lab`
2. **Add monitoring** with Grafana/Loki using the gitops labels
3. **Implement secrets management** with SOPS if not already done
4. **Add policy management** with OPA Gatekeeper or similar 