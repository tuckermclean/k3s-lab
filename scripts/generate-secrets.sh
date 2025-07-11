#!/bin/bash

# Generate and manage secrets for the k3s-lab cluster
# This script generates random secrets and stores them in Kubernetes

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔐 Generating secrets for k3s-lab cluster...${NC}"

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
        echo -e "${YELLOW}Secret ${secret_name} already exists, updating...${NC}"
        kubectl patch secret "$secret_name" -n "$namespace" -p="{\"data\":{\"$key\":\"$(echo -n "$value" | base64)\"}}"
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

# Create secrets
echo -e "${GREEN}Creating Kubernetes secrets...${NC}"

# Create namespace if it doesn't exist
kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -

# Create authentik secrets
create_secret "authentik" "authentik-postgresql-secret" "password" "$POSTGRES_PASSWORD"
create_secret "authentik" "authentik-secret" "secretKey" "$AUTHENTIK_SECRET_KEY"

# Create media namespace if it doesn't exist
kubectl create namespace media --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✅ Secrets generated and stored successfully!${NC}"
echo -e "${YELLOW}Note: These secrets are now stored in Kubernetes and will persist across cluster restarts.${NC}"
echo -e "${YELLOW}The values are not stored in Git - they are generated fresh each time this script runs.${NC}"

# Optional: Save secrets to a local file for backup (encrypted)
if command -v gpg >/dev/null 2>&1; then
    echo -e "${GREEN}Creating encrypted backup of secrets...${NC}"
    cat > /tmp/secrets-backup.yaml <<EOF
# Encrypted backup of generated secrets
# Generated on: $(date)
# 
# POSTGRES_PASSWORD: $POSTGRES_PASSWORD
# AUTHENTIK_SECRET_KEY: $AUTHENTIK_SECRET_KEY
EOF
    
    # Encrypt with GPG if available
    if [ -n "$GPG_KEY" ]; then
        gpg --encrypt --recipient "$GPG_KEY" /tmp/secrets-backup.yaml
        echo -e "${GREEN}Encrypted backup saved to /tmp/secrets-backup.yaml.gpg${NC}"
    else
        echo -e "${YELLOW}GPG key not set, saving unencrypted backup to /tmp/secrets-backup.yaml${NC}"
        echo -e "${RED}⚠️  WARNING: This file contains secrets! Delete it after backing up!${NC}"
    fi
else
    echo -e "${YELLOW}GPG not available, skipping encrypted backup${NC}"
fi

echo -e "${GREEN}🎉 Secret generation complete!${NC}" 