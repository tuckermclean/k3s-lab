# k3s-lab Makefile
# Automates the bootstrap, secret management, and DR steps for the cluster.
#
# Prerequisites (already installed on Arch): age, sops, kubectl, flux
#
# Quick-start for a fresh cluster (DR path):
#   make recover-age-key          # decrypt age key from git using your SSH key
#   make install-sops-age         # push age key into flux-system as sops-age Secret
#   make flux-bootstrap-k3s-lab   # or flux-bootstrap-ovh-lab / flux-bootstrap-oci-lab
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
	@echo "  Flux bootstrap (run after install-sops-age + creating GitHub deploy key)"
	@echo "    flux-bootstrap-k3s-lab   Bootstrap Flux on the home cluster"
	@echo "    flux-bootstrap-ovh-lab   Bootstrap Flux on the OVH cluster"
	@echo "    flux-bootstrap-oci-lab   Bootstrap Flux on the OCI cluster"
	@echo ""
	@echo "  Secrets"
	@echo "    edit-secret FILE=<path>    Decrypt, open in \$$EDITOR, re-encrypt"
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
	@echo "Recovering age private key from $(AGE_KEY_ENC) using $(SSH_KEY) ..."
	@test -f "$(SSH_KEY)" || (echo "ERROR: SSH key not found at $(SSH_KEY)"; exit 1)
	@test -f "$(AGE_KEY_ENC)" || (echo "ERROR: $(AGE_KEY_ENC) not found in repo"; exit 1)
	age -d -i "$(SSH_KEY)" -o "$(AGE_KEY_TMP)" "$(AGE_KEY_ENC)"
	@chmod 600 "$(AGE_KEY_TMP)"
	@echo "Age key written to $(AGE_KEY_TMP)"
	@echo "Run 'make install-sops-age' to push it into the cluster, then 'make clean-age-key' when done."

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

# Common check: GITHUB_TOKEN must be set before flux bootstrap
define check-github-token
	@test -n "$(GITHUB_TOKEN)" || (echo "ERROR: export GITHUB_TOKEN=<your-PAT> first"; exit 1)
endef

.PHONY: flux-bootstrap-k3s-lab
flux-bootstrap-k3s-lab: ## Bootstrap Flux on the home (k3s-lab) cluster
	$(call check-github-token)
	flux bootstrap github \
	  --owner="$(GITHUB_OWNER)" \
	  --repository="$(GITHUB_REPO)" \
	  --branch=main \
	  --path=./clusters/k3s-lab \
	  --personal

.PHONY: flux-bootstrap-ovh-lab
flux-bootstrap-ovh-lab: ## Bootstrap Flux on the OVH cluster
	$(call check-github-token)
	flux bootstrap github \
	  --owner="$(GITHUB_OWNER)" \
	  --repository="$(GITHUB_REPO)" \
	  --branch=main \
	  --path=./clusters/ovh-lab \
	  --personal

.PHONY: flux-bootstrap-oci-lab
flux-bootstrap-oci-lab: ## Bootstrap Flux on the OCI cluster
	$(call check-github-token)
	flux bootstrap github \
	  --owner="$(GITHUB_OWNER)" \
	  --repository="$(GITHUB_REPO)" \
	  --branch=main \
	  --path=./clusters/oci-lab \
	  --personal

# ---------------------------------------------------------------------------
# Secrets day-to-day
# ---------------------------------------------------------------------------

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
