# K3s Lab - GitOps Repository

This repository follows the Flux GitOps pattern for managing a single-cluster Kubernetes lab environment.

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

- K3s cluster running
- Flux CLI installed
- GitHub repository with this content

### Bootstrap Flux

```bash
# Bootstrap Flux pointing to this repository
flux bootstrap github \
  --owner=your-github-username \
  --repository=k3s-lab \
  --branch=main \
  --path=./clusters/k3s-lab \
  --personal
```

### Verify Deployment

```bash
# Check Flux status
flux get all

# Check all GitOps-managed resources
kubectl get all -l app.kubernetes.io/part-of=gitops

# View reconciliation status
flux trace
```

## Components

### Infrastructure

- **Traefik**: Ingress controller for routing external traffic
- **Cert-Manager**: Automated SSL certificate management
- **NFS Provisioner**: Dynamic storage provisioning

### Applications

- **Authentik**: Identity and access management
- **Jellyfin**: Media streaming server
- **Dashboard**: Kubernetes web UI

## Development Workflow

1. **Make changes** in feature branch
2. **Test locally** with `flux diff kustomization clusters/k3s-lab`
3. **Create PR** and merge to main
4. **Flux reconciles** automatically

## Useful Commands

```bash
# Check what would change
flux diff kustomization clusters/k3s-lab

# Force reconciliation
flux reconcile kustomization clusters/k3s-lab

# View logs
flux logs --follow

# Check specific component
flux get helmreleases -n authentik
```

## Security Notes

- Secrets are managed via Flux's secret management
- Certificates are automatically renewed by cert-manager
- All resources are labeled with `app.kubernetes.io/part-of: gitops`

## Troubleshooting

### Common Issues

1. **Reconciliation failures**: Check `flux logs` for detailed error messages
2. **Missing resources**: Ensure all referenced files exist in the repository
3. **Secret issues**: Verify SOPS encryption if using encrypted secrets

### Debug Commands

```bash
# Check Flux system status
kubectl get pods -n flux-system

# View reconciliation events
flux events

# Check specific resource health
kubectl describe kustomization clusters/k3s-lab -n flux-system
``` 