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

# Generate secrets (robust, idempotent, no overwrites)
echo -e "${GREEN}🔐 Generating secrets...${NC}"

# Function to generate random password
generate_password() {
    openssl rand -base64 32
}

# Function to generate random secret key
generate_secret_key() {
    openssl rand -base64 40
}

# Function to create or patch a secret key only if missing or empty
create_or_patch_secret() {
    local namespace=$1
    local secret_name=$2
    local key=$3
    local value=$4

    # Check if secret exists
    if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
        # Check if key exists and is non-empty
        current=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.$key}" 2>/dev/null || echo "")
        if [[ -z "$current" || "$current" == "IiIi" ]]; then
            echo -e "${YELLOW}Patching $secret_name/$key with new value${NC}"
            kubectl patch secret "$secret_name" -n "$namespace" --type='merge' -p "{\"data\": {\"$key\": \"$(echo -n "$value" | base64)\"}}"
        else
            echo -e "${YELLOW}$secret_name/$key already set, skipping${NC}"
        fi
    else
        echo -e "${YELLOW}Creating $secret_name with $key${NC}"
        kubectl create secret generic "$secret_name" -n "$namespace" --from-literal="$key=$value"
    fi
}

# Create namespaces if they don't exist
kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace media --dry-run=client -o yaml | kubectl apply -f -

# Generate secrets
POSTGRES_PASSWORD=$(generate_password)
AUTHENTIK_SECRET_KEY=$(generate_secret_key)

# Create or patch secrets
create_or_patch_secret "authentik" "authentik-postgresql-secret" "password" "$POSTGRES_PASSWORD"
create_or_patch_secret "authentik" "authentik-secret" "secretKey" "$AUTHENTIK_SECRET_KEY"

echo -e "${GREEN}✅ Secrets generated and stored successfully!${NC}"
echo -e "${YELLOW}Note: These secrets are now stored in Kubernetes and will persist across cluster restarts.${NC}"

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