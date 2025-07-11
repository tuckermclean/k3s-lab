#!/bin/bash

# Complete setup script for k3s-lab cluster
# This script sets up the entire GitOps environment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Setting up k3s-lab GitOps cluster...${NC}"

# Check prerequisites
echo -e "${GREEN}Checking prerequisites...${NC}"

if ! command -v kubectl >/dev/null 2>&1; then
    echo -e "${RED}❌ kubectl is not installed${NC}"
    exit 1
fi

if ! command -v flux >/dev/null 2>&1; then
    echo -e "${RED}❌ flux CLI is not installed${NC}"
    echo -e "${YELLOW}Install with: curl -s https://fluxcd.io/install.sh | sudo bash${NC}"
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo -e "${RED}❌ openssl is not installed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites check passed${NC}"

# Check cluster connectivity
echo -e "${GREEN}Checking cluster connectivity...${NC}"
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "${RED}❌ Cannot connect to Kubernetes cluster${NC}"
    echo -e "${YELLOW}Make sure your kubeconfig is set up correctly${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Cluster connectivity confirmed${NC}"

# Generate secrets
echo -e "${GREEN}🔐 Generating secrets...${NC}"
./scripts/generate-secrets.sh

# Install Flux (if not already installed)
echo -e "${GREEN}📦 Installing Flux...${NC}"
if ! kubectl get namespace flux-system >/dev/null 2>&1; then
    echo -e "${YELLOW}Installing Flux controllers...${NC}"
    kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
    
    # Wait for Flux to be ready
    echo -e "${YELLOW}Waiting for Flux controllers to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=source-controller -n flux-system --timeout=300s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kustomize-controller -n flux-system --timeout=300s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=helm-controller -n flux-system --timeout=300s
else
    echo -e "${GREEN}✅ Flux is already installed${NC}"
fi

# Create GitRepository
echo -e "${GREEN}📁 Setting up GitRepository...${NC}"
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

# Create Kustomization
echo -e "${GREEN}🔧 Setting up Kustomization...${NC}"
kubectl apply -f clusters/k3s-lab/flux-kustomization.yaml

# Wait for reconciliation
echo -e "${GREEN}⏳ Waiting for initial reconciliation...${NC}"
sleep 30

# Check status
echo -e "${GREEN}📊 Checking deployment status...${NC}"
echo -e "${BLUE}Flux status:${NC}"
flux get all

echo -e "${BLUE}GitOps-managed resources:${NC}"
kubectl get all -l app.kubernetes.io/part-of=gitops

echo -e "${BLUE}Namespace status:${NC}"
kubectl get namespaces | grep -E "(authentik|media|cert-manager|flux-system)"

echo -e "${GREEN}🎉 Setup complete!${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Monitor reconciliation: flux logs --follow"
echo -e "  2. Check specific resources: kubectl get pods -n authentik"
echo -e "  3. View logs: kubectl logs -n authentik -l app.kubernetes.io/name=authentik"
echo -e "  4. Access services: kubectl get ingress -A" 