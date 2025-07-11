#!/bin/bash

# Flux-compatible secret generation script
# This script can be run as a Kubernetes Job or manually

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🔐 Generating secrets for Flux deployment...${NC}"

# Function to generate random password
generate_password() {
    openssl rand -base64 32
}

# Function to generate random secret key
generate_secret_key() {
    openssl rand -base64 40
}

# Function to create or update a secret
create_secret() {
    local namespace=$1
    local secret_name=$2
    local key=$3
    local value=$4
    
    echo -e "${YELLOW}Creating secret ${secret_name} in namespace ${namespace}...${NC}"
    
    # Check if secret exists
    if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
        echo -e "${YELLOW}Secret ${secret_name} already exists, skipping...${NC}"
        return 0
    else
        echo -e "${YELLOW}Creating new secret ${secret_name}...${NC}"
        kubectl create secret generic "$secret_name" \
            --from-literal="$key=$value" \
            -n "$namespace" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
}

# Generate secrets
echo -e "${GREEN}Generating random passwords and keys...${NC}"

POSTGRES_PASSWORD=$(generate_password)
AUTHENTIK_SECRET_KEY=$(generate_secret_key)

# Create namespaces if they don't exist
kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace media --dry-run=client -o yaml | kubectl apply -f -

# Create secrets
echo -e "${GREEN}Creating Kubernetes secrets...${NC}"
create_secret "authentik" "authentik-postgresql-secret" "password" "$POSTGRES_PASSWORD"
create_secret "authentik" "authentik-secret" "secretKey" "$AUTHENTIK_SECRET_KEY"

echo -e "${GREEN}✅ Secrets generated and stored successfully!${NC}"
echo -e "${YELLOW}Note: These secrets are now stored in Kubernetes and will persist across cluster restarts.${NC}" 