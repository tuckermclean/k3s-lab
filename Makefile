# k3s-lab Makefile
# Automates the bootstrap, secret management, and DR steps for the cluster.
#
# Prerequisites (already installed on Arch): age, sops, kubectl, flux
#
# DR quick-start: see README.md → "Bootstrapping / DR"
#
# Day-to-day:
#   make edit-secret FILE=infrastructure/authentik/secret.sops.yaml
#   make decrypt-secret FILE=infrastructure/authentik/secret.sops.yaml

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Paths / config
# ---------------------------------------------------------------------------
AGE_KEY_ENC    := bootstrap/age.agekey.age
AGE_KEY_TMP    := /tmp/k3s-lab-age.agekey
SSH_KEY        := $(HOME)/.ssh/id_rsa
SSH_PUBKEY     := $(HOME)/.ssh/id_rsa.pub
GITHUB_OWNER   := tuckermclean
GITHUB_REPO    := k3s-lab

# ---------------------------------------------------------------------------
.PHONY: help
help:
	@echo "k3s-lab secret management & DR targets"
	@echo ""
	@echo "  Bootstrap / DR"
	@echo "    recover-age-key          Decrypt the age private key from git using ~/.ssh/id_rsa"
	@echo "    install-sops-age         Install age key as 'sops-age' Secret in flux-system"
	@echo "    bootstrap-age-key        Generate a NEW age keypair and back it up to ~/.ssh/id_rsa.pub"
	@echo "                             (only needed once; resets encryption — see warning)"
	@echo ""
	@echo "  OVH cluster (Terraform)"
	@echo "    init-ovh                 One-time setup: create secrets if needed, then terraform init"
	@echo "    plan-ovh                 Preview changes to the OVH cluster"
	@echo "    apply-ovh                Provision or update the OVH cluster"
	@echo "    destroy-ovh              Destroy the OVH cluster (stops billing)"
	@echo "    kubeconfig-ovh           Print path to the OVH kubeconfig"
	@echo ""
	@echo "  Longhorn S3 backup"
	@echo "    store-longhorn-backup-secret  Encrypt provided AWS keys into SOPS secrets (also derives backup-target-vars)"
	@echo ""
	@echo "  Authentik (run after Flux deploys Authentik)"
	@echo "    store-authentik-token      Encrypt and store Authentik API token: make store-authentik-token TOKEN=<value>"
	@echo "    apply-authentik            Apply OIDC apps/groups via Terraform (reads all secrets from SOPS)"
	@echo "    plan-authentik             Preview Terraform changes without applying"
	@echo "    dr-authentik               DR: nuke stale state and re-apply after DB restore"
	@echo ""
	@echo "  Flux bootstrap (run after install-sops-age)"
	@echo "    flux-bootstrap-ovh-lab   Bootstrap Flux on the OVH cluster"
	@echo "    flux-bootstrap-oci-lab   Bootstrap Flux on the OCI cluster"
	@echo "    (GitHub PAT read from SOPS automatically for both)"
	@echo ""
	@echo "  Secrets"
	@echo "    fill-secrets               Recover key, edit every secret.sops.yaml in sequence, clean up"
	@echo "    edit-secret FILE=<path>    Decrypt, open in \$$EDITOR, re-encrypt (key must be recovered first)"
	@echo "    decrypt-secret FILE=<path> Print decrypted content to stdout (pipe to less)"
	@echo "    rotate-ssh-key             Re-encrypt age key backup for a new ~/.ssh/id_rsa.pub"
	@echo ""
	@echo "  Verification"
	@echo "    verify-encryption          Check all *.sops.yaml files are actually encrypted"
	@echo "    verify-roundtrip           Decrypt each *.sops.yaml and verify it's valid YAML"

# ---------------------------------------------------------------------------
# Age key management
# ---------------------------------------------------------------------------

.PHONY: recover-age-key
recover-age-key: ## Decrypt age.agekey from git using your SSH key → /tmp/k3s-lab-age.agekey
	@echo "Recovering age private key from $(AGE_KEY_ENC) using $(SSH_KEY) ..." >&2
	@test -f "$(SSH_KEY)" || (echo "ERROR: SSH key not found at $(SSH_KEY)" >&2; exit 1)
	@test -f "$(AGE_KEY_ENC)" || (echo "ERROR: $(AGE_KEY_ENC) not found in repo" >&2; exit 1)
	@age -d -i "$(SSH_KEY)" -o "$(AGE_KEY_TMP)" "$(AGE_KEY_ENC)"
	@chmod 600 "$(AGE_KEY_TMP)"
	@echo "Age key recovered." >&2

.PHONY: install-sops-age
install-sops-age: ## Install the age private key as sops-age Secret in flux-system
	@test -f "$(AGE_KEY_TMP)" || (echo "ERROR: $(AGE_KEY_TMP) not found. Run 'make recover-age-key' first."; exit 1)
	kubectl create secret generic sops-age \
	  --namespace flux-system \
	  --from-file=age.agekey="$(AGE_KEY_TMP)" \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo "sops-age Secret applied to flux-system."

.PHONY: clean-age-key
clean-age-key: ## Securely delete the temporary plaintext age key
	@test -f "$(AGE_KEY_TMP)" && shred -u "$(AGE_KEY_TMP)" && echo "Deleted $(AGE_KEY_TMP)" \
	  || echo "$(AGE_KEY_TMP) not present, nothing to clean."

.PHONY: bootstrap-age-key
bootstrap-age-key: ## DANGER: Generate a new age keypair — only run on first setup or after a key compromise
	@echo "WARNING: This creates a NEW age keypair and re-encrypts the backup."
	@echo "If any *.sops.yaml files already exist, they will become unreadable."
	@echo "Press Ctrl-C to abort, or Enter to continue."
	@read _confirm
	age-keygen -o "$(AGE_KEY_TMP)"
	@chmod 600 "$(AGE_KEY_TMP)"
	@PUBKEY=$$(grep "^# public key:" "$(AGE_KEY_TMP)" | awk '{print $$NF}'); \
	  echo "New public key: $$PUBKEY"; \
	  sed -i "s|^    age: age1.*|    age: $$PUBKEY|" .sops.yaml; \
	  echo "Updated .sops.yaml with new recipient."
	age -R "$(SSH_PUBKEY)" -o "$(AGE_KEY_ENC)" "$(AGE_KEY_TMP)"
	@echo "Encrypted new age key to $(AGE_KEY_ENC)"
	@echo "Commit .sops.yaml and $(AGE_KEY_ENC), then re-encrypt all *.sops.yaml files."

# ---------------------------------------------------------------------------
# Flux bootstrap
# ---------------------------------------------------------------------------


define flux-github-token
$$(SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d "$(OVH_TF_DIR)/secrets.sops.yaml" | \
  python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['GITHUB_TOKEN'])")
endef

.PHONY: flux-bootstrap-ovh-lab
flux-bootstrap-ovh-lab: recover-age-key ## Bootstrap Flux on the OVH cluster
	@GITHUB_TOKEN=$(flux-github-token) \
	flux bootstrap github \
	  --owner="$(GITHUB_OWNER)" \
	  --repository="$(GITHUB_REPO)" \
	  --branch=main \
	  --path=./clusters/ovh-lab \
	  --personal

.PHONY: flux-bootstrap-oci-lab
flux-bootstrap-oci-lab: recover-age-key ## Bootstrap Flux on the OCI cluster
	@GITHUB_TOKEN=$(flux-github-token) \
	flux bootstrap github \
	  --owner="$(GITHUB_OWNER)" \
	  --repository="$(GITHUB_REPO)" \
	  --branch=main \
	  --path=./clusters/oci-lab \
	  --personal

# ---------------------------------------------------------------------------
# OVH Terraform
# ---------------------------------------------------------------------------

OVH_TF_DIR := bootstrap/terraform/ovh-k3s

.PHONY: init-ovh
init-ovh: recover-age-key ## One-time setup: create secrets if needed, then terraform init
	@if [ ! -f "$(OVH_TF_DIR)/secrets.sops.yaml" ]; then \
	  echo "No secrets.sops.yaml found — opening example in $$EDITOR to fill in credentials."; \
	  cp "$(OVH_TF_DIR)/secrets.yaml.example" "$(OVH_TF_DIR)/secrets.yaml"; \
	  $${EDITOR:-vi} "$(OVH_TF_DIR)/secrets.yaml"; \
	  cp "$(OVH_TF_DIR)/secrets.yaml" "$(OVH_TF_DIR)/secrets.sops.yaml"; \
	  SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -e -i "$(OVH_TF_DIR)/secrets.sops.yaml"; \
	  rm "$(OVH_TF_DIR)/secrets.yaml"; \
	  echo "Secrets encrypted. Commit with: git add $(OVH_TF_DIR)/secrets.sops.yaml && git commit"; \
	fi
	terraform -chdir="$(OVH_TF_DIR)" init

.PHONY: plan-ovh
plan-ovh: recover-age-key ## Preview OVH cluster changes
	SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" $(MAKE) -C $(OVH_TF_DIR) plan

.PHONY: apply-ovh
apply-ovh: recover-age-key ## Provision or update the OVH cluster
	SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" $(MAKE) -C $(OVH_TF_DIR) apply

.PHONY: destroy-ovh
destroy-ovh: recover-age-key ## Destroy the OVH cluster (stops billing)
	SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" $(MAKE) -C $(OVH_TF_DIR) destroy

.PHONY: kubeconfig-ovh
kubeconfig-ovh: recover-age-key ## Print absolute path to the OVH kubeconfig
	@echo "$(CURDIR)/$(OVH_TF_DIR)/kubeconfig"

# ---------------------------------------------------------------------------
# Longhorn S3 backup
# ---------------------------------------------------------------------------

LONGHORN_BACKUP_SECRET      := infrastructure/storage/longhorn/backup/secret.sops.yaml
LONGHORN_BACKUP_EXAMPLE     := infrastructure/storage/longhorn/backup/secret.example.yaml
LONGHORN_BACKUP_TARGET_VARS := infrastructure/storage/longhorn/backup/backup-target-vars.sops.yaml

.PHONY: store-longhorn-backup-secret
store-longhorn-backup-secret: recover-age-key ## Encrypt provided AWS keys into the Longhorn backup SOPS secret
	@echo "Opening secret template in $$EDITOR."
	@echo "Fill in AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION, and BACKUP_TARGET."
	@echo "AWS_DEFAULT_REGION must match the @region in the BACKUP_TARGET URL."
	@cp "$(LONGHORN_BACKUP_EXAMPLE)" /tmp/longhorn-backup-secret.yaml
	@$${EDITOR:-vi} /tmp/longhorn-backup-secret.yaml
	@cp /tmp/longhorn-backup-secret.yaml "$(LONGHORN_BACKUP_SECRET)"
	@SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -e -i "$(LONGHORN_BACKUP_SECRET)"
	@rm /tmp/longhorn-backup-secret.yaml
	@$(MAKE) _store-longhorn-backup-target-vars
	$(MAKE) clean-age-key
	@echo ""
	@echo "Secrets encrypted. Commit both:"
	@echo "  git add $(LONGHORN_BACKUP_SECRET) $(LONGHORN_BACKUP_TARGET_VARS) && git commit"

# Internal: derive the flux-system substituteFrom secret from the already-encrypted backup secret.
# Called automatically by store-longhorn-backup-secret — not intended to be run directly.
.PHONY: _store-longhorn-backup-target-vars
_store-longhorn-backup-target-vars:
	@test -f "$(LONGHORN_BACKUP_SECRET)" || \
	  (echo "ERROR: $(LONGHORN_BACKUP_SECRET) not found. Run store-longhorn-backup-secret first."; exit 1)
	@set -e; \
	BACKUP_TARGET=$$(SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d "$(LONGHORN_BACKUP_SECRET)" | \
	  python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['stringData']['BACKUP_TARGET'])"); \
	printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: longhorn-backup-target-vars\n  namespace: flux-system\nstringData:\n  BACKUP_TARGET: "%s"\n' "$$BACKUP_TARGET" \
	  > "$(LONGHORN_BACKUP_TARGET_VARS)"; \
	SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -e -i "$(LONGHORN_BACKUP_TARGET_VARS)"
	@echo "Derived backup-target-vars secret encrypted at $(LONGHORN_BACKUP_TARGET_VARS)"

# ---------------------------------------------------------------------------
# Authentik Terraform
# ---------------------------------------------------------------------------

AUTHENTIK_TF_DIR := bootstrap/terraform/authentik

.PHONY: store-authentik-token
store-authentik-token: recover-age-key ## Encrypt and store Authentik API token: make store-authentik-token TOKEN=<value>
	@test -n "$(TOKEN)" || \
	  (echo "Usage: make store-authentik-token TOKEN=<your-authentik-api-token>"; \
	   echo "Get a token from: Authentik admin → Directory → Tokens → Create token"; exit 1)
	@printf -- '---\ntoken: %s\n' '$(TOKEN)' > "$(AUTHENTIK_TF_DIR)/token.sops.yaml"
	@SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -e -i "$(AUTHENTIK_TF_DIR)/token.sops.yaml"
	$(MAKE) clean-age-key
	@echo "Token encrypted. Run: git add $(AUTHENTIK_TF_DIR)/token.sops.yaml && git commit"

.PHONY: apply-authentik
apply-authentik: recover-age-key ## Apply Authentik config via Terraform (all secrets read from SOPS — no tfvars needed)
	@test -f "$(AUTHENTIK_TF_DIR)/token.sops.yaml" || \
	  (echo "ERROR: $(AUTHENTIK_TF_DIR)/token.sops.yaml not found."; \
	   echo "After Authentik is running, create it with: make store-authentik-token TOKEN=<api-token>"; exit 1)
	@set -e; \
	export TF_VAR_authentik_token=$$(SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d "$(AUTHENTIK_TF_DIR)/token.sops.yaml" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['token'])"); \
	export TF_VAR_grafana_client_secret=$$(SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d infrastructure/monitoring/secret.sops.yaml | python3 -c "import sys,yaml; docs=list(yaml.safe_load_all(sys.stdin)); d=next(x for x in docs if x['metadata']['name']=='grafana-oidc-secret'); print(d['stringData']['GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET'])"); \
	export TF_VAR_weave_client_secret=$$(SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d infrastructure/weave-gitops/secret.sops.yaml | python3 -c "import sys,yaml; docs=list(yaml.safe_load_all(sys.stdin)); d=next(x for x in docs if x['metadata']['name']=='oidc-auth'); print(d['stringData']['clientSecret'])"); \
	export TF_VAR_nodecast_client_secret=$$(SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d apps/nodecast-tv/secret.sops.yaml | python3 -c "import sys,yaml; docs=list(yaml.safe_load_all(sys.stdin)); d=next(x for x in docs if x['metadata']['name']=='nodecast-tv-env'); print(d['stringData']['OIDC_CLIENT_SECRET'])"); \
	terraform -chdir="$(AUTHENTIK_TF_DIR)" init -upgrade -input=false; \
	terraform -chdir="$(AUTHENTIK_TF_DIR)" apply -input=false -auto-approve
	$(MAKE) clean-age-key

.PHONY: plan-authentik
plan-authentik: recover-age-key ## Preview Authentik Terraform changes without applying
	@test -f "$(AUTHENTIK_TF_DIR)/token.sops.yaml" || \
	  (echo "ERROR: $(AUTHENTIK_TF_DIR)/token.sops.yaml not found."; exit 1)
	@set -e; \
	export TF_VAR_authentik_token=$$(SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d "$(AUTHENTIK_TF_DIR)/token.sops.yaml" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['token'])"); \
	export TF_VAR_grafana_client_secret=$$(SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d infrastructure/monitoring/secret.sops.yaml | python3 -c "import sys,yaml; docs=list(yaml.safe_load_all(sys.stdin)); d=next(x for x in docs if x['metadata']['name']=='grafana-oidc-secret'); print(d['stringData']['GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET'])"); \
	export TF_VAR_weave_client_secret=$$(SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d infrastructure/weave-gitops/secret.sops.yaml | python3 -c "import sys,yaml; docs=list(yaml.safe_load_all(sys.stdin)); d=next(x for x in docs if x['metadata']['name']=='oidc-auth'); print(d['stringData']['clientSecret'])"); \
	export TF_VAR_nodecast_client_secret=$$(SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d apps/nodecast-tv/secret.sops.yaml | python3 -c "import sys,yaml; docs=list(yaml.safe_load_all(sys.stdin)); d=next(x for x in docs if x['metadata']['name']=='nodecast-tv-env'); print(d['stringData']['OIDC_CLIENT_SECRET'])"); \
	terraform -chdir="$(AUTHENTIK_TF_DIR)" init -upgrade -input=false; \
	terraform -chdir="$(AUTHENTIK_TF_DIR)" plan -input=false
	$(MAKE) clean-age-key

.PHONY: dr-authentik
dr-authentik: ## DR: nuke stale Terraform state and re-apply (use after DB restore)
	@echo "Removing stale Terraform state for Authentik..."
	rm -f "$(AUTHENTIK_TF_DIR)/terraform.tfstate" "$(AUTHENTIK_TF_DIR)/terraform.tfstate.backup"
	$(MAKE) apply-authentik
	@echo ""
	@echo "Done. OIDC client secrets are pinned in SOPS — no k8s Secret rotation needed."

# ---------------------------------------------------------------------------
# Secrets day-to-day
# ---------------------------------------------------------------------------

.PHONY: fill-secrets
fill-secrets: recover-age-key ## Recover key then open every *.sops.yaml in $EDITOR in sequence, then clean up
	@echo "Opening all secret files for editing. Fill in CHANGEME_* placeholders."
	@for f in $$(find . -name 'secret.sops.yaml' -not -path './.git/*' | sort); do \
	  echo ""; \
	  echo "=== $$f ==="; \
	  SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops "$$f"; \
	done
	$(MAKE) clean-age-key

.PHONY: edit-secret
edit-secret: ## Decrypt, open in $$EDITOR, re-encrypt: make edit-secret FILE=infrastructure/authentik/secret.sops.yaml
	@test -n "$(FILE)" || (echo "Usage: make edit-secret FILE=<path/to/secret.sops.yaml>"; exit 1)
	@test -f "$(AGE_KEY_TMP)" || (echo "ERROR: $(AGE_KEY_TMP) not found. Run 'make recover-age-key' first."; exit 1)
	SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops "$(FILE)"

.PHONY: decrypt-secret
decrypt-secret: ## Print decrypted secret to stdout: make decrypt-secret FILE=infrastructure/authentik/secret.sops.yaml
	@test -n "$(FILE)" || (echo "Usage: make decrypt-secret FILE=<path/to/secret.sops.yaml>"; exit 1)
	@test -f "$(AGE_KEY_TMP)" || (echo "ERROR: $(AGE_KEY_TMP) not found. Run 'make recover-age-key' first."; exit 1)
	SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d "$(FILE)"

.PHONY: rotate-ssh-key
rotate-ssh-key: ## Re-encrypt the age key backup for a new SSH key (run after rotating ~/.ssh/id_rsa)
	@echo "Re-encrypting age key backup for new SSH key at $(SSH_PUBKEY) ..."
	@test -f "$(AGE_KEY_TMP)" || (echo "ERROR: $(AGE_KEY_TMP) not found. Run 'make recover-age-key' (with your OLD key) first."; exit 1)
	age -R "$(SSH_PUBKEY)" -o "$(AGE_KEY_ENC)" "$(AGE_KEY_TMP)"
	@echo "Updated $(AGE_KEY_ENC). Commit this file."

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

.PHONY: verify-encryption
verify-encryption: ## Confirm all *.sops.yaml files contain ENC[] ciphertext (none slipped through unencrypted)
	@echo "Checking *.sops.yaml files for encryption..."
	@FAILED=0; \
	for f in $$(find . -name '*.sops.yaml' -not -path './.git/*' -not -name '.sops.yaml'); do \
	  if grep -q 'ENC\[' "$$f"; then \
	    echo "  ✓ $$f"; \
	  else \
	    echo "  ✗ NOT ENCRYPTED: $$f"; \
	    FAILED=1; \
	  fi; \
	done; \
	test $$FAILED -eq 0 || (echo "ERROR: unencrypted *.sops.yaml files detected"; exit 1)
	@echo "All *.sops.yaml files are encrypted."

.PHONY: verify-roundtrip
verify-roundtrip: ## Decrypt each *.sops.yaml and confirm the output is valid YAML
	@test -f "$(AGE_KEY_TMP)" || (echo "ERROR: $(AGE_KEY_TMP) not found. Run 'make recover-age-key' first."; exit 1)
	@echo "Verifying decrypt round-trip for all *.sops.yaml files..."
	@FAILED=0; \
	for f in $$(find . -name '*.sops.yaml' -not -path './.git/*' -not -name '.sops.yaml'); do \
	  if SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -d "$$f" | python3 -c "import sys,yaml; list(yaml.safe_load_all(sys.stdin))" 2>/dev/null; then \
	    echo "  ✓ $$f"; \
	  else \
	    echo "  ✗ FAILED: $$f"; \
	    FAILED=1; \
	  fi; \
	done; \
	test $$FAILED -eq 0 || (echo "ERROR: one or more round-trips failed"; exit 1)
	@echo "All round-trips passed."
