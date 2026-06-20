#!/usr/bin/env bash
# tf.sh — Terraform wrapper that decrypts secrets.sops.env before running.
#
# Usage: ./tf.sh <terraform subcommand> [args...]
#   ./tf.sh plan
#   ./tf.sh apply -auto-approve
#   ./tf.sh destroy -auto-approve
#
# Bootstrap from scratch:
#   1. cp secrets.env.example secrets.env
#   2. Fill in all values (OpenStack creds from OVH manager OpenRC v3, GitHub PAT)
#   3. sops --encrypt --input-type dotenv --output-type dotenv secrets.env > secrets.sops.env
#   4. rm secrets.env
#   5. git add secrets.sops.env && git commit
#   6. ./tf.sh init && ./tf.sh apply -auto-approve

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOPS_ENV="$SCRIPT_DIR/secrets.sops.env"

if [[ ! -f "$SOPS_ENV" ]]; then
  echo "ERROR: $SOPS_ENV not found." >&2
  echo "" >&2
  echo "  cp secrets.env.example secrets.env" >&2
  echo "  # fill in your credentials" >&2
  echo "  sops --encrypt --input-type dotenv --output-type dotenv secrets.env > secrets.sops.env" >&2
  echo "  rm secrets.env && git add secrets.sops.env" >&2
  exit 1
fi

# Decrypt and export all vars into this process, then hand off to terraform.
set -a
eval "$(sops -d --input-type dotenv --output-type dotenv "$SOPS_ENV")"
set +a

exec terraform "$@"
