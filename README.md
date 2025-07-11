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
- kubectl configured to access your cluster

### Option 1: Let Flux Handle Everything (Recommended)

Flux will automatically:
- Generate random secrets via a Kubernetes Job
- Install all infrastructure components
- Deploy all applications

```bash
# Bootstrap Flux (on your VM)
flux bootstrap github \
  --owner=yourusername \
  --repository=k3s-lab \
  --branch=main \
  --path=./clusters/k3s-lab \
  --personal
```

### Option 2: Manual Setup First

If you prefer to set up secrets manually before Flux:

```bash
# Run the complete setup script
./scripts/setup.sh
```

This script will:
- Generate random secrets and store them securely in Kubernetes
- Install Flux controllers
- Set up GitRepository and Kustomization
- Deploy all applications and infrastructure

### Manual Setup

If you prefer manual setup:

```bash
# 1. Generate secrets
./scripts/generate-secrets.sh

# 2. Install Flux
kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml

# 3. Create GitRepository
kubectl apply -f - <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m
  url: file://$(pwd)
  ref:
    branch: main
EOF

# 4. Create Kustomization
kubectl apply -f clusters/k3s-lab/flux-kustomization.yaml
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

- **Secrets are generated randomly** and stored securely in Kubernetes
- **No secrets are stored in Git** - they're generated fresh each time
- **Certificates are automatically renewed** by cert-manager
- **All resources are labeled** with `app.kubernetes.io/part-of: gitops`
- **Backup encryption** is available with GPG (optional)

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