#!/usr/bin/env bash
# tf.sh — Terraform wrapper that decrypts secrets.sops.yaml before running.
# Prefer using top-level make targets (make plan-aws-backup, make apply-aws-backup, etc.)
# which handle age key recovery automatically.
#
# Direct usage:
#   export SOPS_AGE_KEY_FILE=/tmp/k3s-lab-age.agekey  # from: make recover-age-key
#   ./tf.sh plan
#   ./tf.sh apply -auto-approve

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOPS_FILE="$SCRIPT_DIR/secrets.sops.yaml"

if [[ ! -f "$SOPS_FILE" ]]; then
  echo "ERROR: $SOPS_FILE not found." >&2
  echo "" >&2
  echo "  cp $SCRIPT_DIR/secrets.yaml.example $SCRIPT_DIR/secrets.yaml" >&2
  echo "  # fill in your AWS provisioning credentials (IAM user with S3+IAM admin)" >&2
  echo "  cp $SCRIPT_DIR/secrets.yaml $SCRIPT_DIR/secrets.sops.yaml" >&2
  echo "  SOPS_AGE_KEY_FILE=/tmp/k3s-lab-age.agekey sops -e -i $SCRIPT_DIR/secrets.sops.yaml" >&2
  echo "  rm $SCRIPT_DIR/secrets.yaml" >&2
  echo "  git add $SCRIPT_DIR/secrets.sops.yaml && git commit" >&2
  echo "" >&2
  echo "Or from the repo root: make init-aws-backup" >&2
  exit 1
fi

# Use age key from env if set; fall back to the temp path from 'make recover-age-key'
: "${SOPS_AGE_KEY_FILE:=/tmp/k3s-lab-age.agekey}"
export SOPS_AGE_KEY_FILE

# Decrypt YAML and export each key as an env var (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
eval "$(sops -d "$SOPS_FILE" | python3 -c "
import yaml, sys, shlex
for k, v in yaml.safe_load(sys.stdin).items():
    print(f'export {k}={shlex.quote(str(v))}')
")"

exec terraform "$@"
