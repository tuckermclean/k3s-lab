# OCI Warm DR Standby — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the OCI Always-Free ARM k3s cluster (`bootstrap/terraform/oci-k3s`) as a running warm-standby platform — Terraform-provisioned, Flux-bootstrapped, every non-stateful-data Kustomization reconciling under `*.oci.dcxxiv.com` hostnames, all user-facing apps scaled to `replicas: 0` — without restoring any real data and without touching anything the OVH `clusters/ovh-lab` production cluster depends on.

**Architecture:** Mirror `clusters/ovh-lab/*-kustomization.yaml` into `clusters/oci-lab/*-kustomization.yaml` (same shared `infrastructure/`/`apps/` `path:` targets, per the spec's locked Option B), carrying OCI-only variance as inline `patches:` in each Flux `Kustomization` CR — the same technique already used for OVH's Longhorn `backupTarget` patch. Extend `bootstrap/terraform/oci-k3s` with S3 remote state, a dedicated per-node Block Volume for Longhorn, and a `dns.tf` for the `oci.dcxxiv.com` subdomain, mirroring the already-proven `bootstrap/terraform/ovh-k3s` patterns.

**Tech Stack:** Terraform (`oracle/oci ~> 8.0`, `cloudflare/cloudflare ~> 4.0`, `hashicorp/random ~> 3.6`, `hashicorp/null ~> 3.2`), OCI `VM.Standard.A1.Flex` (ARM64/aarch64), k3s (embedded etcd), Flux CD (`kustomize.toolkit.fluxcd.io/v1`, `helm.toolkit.fluxcd.io/v2`), SOPS + age, Cloudflare DNS (DNS01), cert-manager.

## Global Constraints

- Boot volume: **35 GB** per node (`boot_volume_size_gbs` default). Data volume: **30 GB** per node (`data_volume_size_gbs`, new).
- Total Always Free block storage cap: **200 GB** (3×35 boot + 3×30 data = 195 GB, 5 GB slack).
- All OCI app/platform hostnames: **`*.oci.dcxxiv.com`** (distinct subdomain, not the production apex).
- Excluded from `clusters/oci-lab/` in Phase 1: **`juggler`**, **`juicefs`**, **`juicefs-s3-gateway`**, **`minecraft-bedrock`** (never wired anywhere, no change needed), **`agent-os`** (until PR #141 arm64 image lands).
- All user-facing app Deployments/HelmReleases: **`replicas: 0`** (no live traffic, no split-brain writes; platform/infra Kustomizations keep running normally).
- Every OCI node is **ARM64** — no `nodeSelector`/architecture patch needed anywhere (whole cluster is one arch).
- Zero edits to any file OVH's `clusters/ovh-lab` depends on. All OCI variance lives under `clusters/oci-lab/` and `bootstrap/terraform/oci-k3s/`.

---

## Scope notes (read before starting)

A few points that affect multiple tasks below, called out once instead of repeated per-task:

1. **Postgres/MariaDB/Longhorn come up empty in Phase 1.** The shared `infrastructure/database/postgres/cluster.yaml`, `infrastructure/database/mariadb/helmrelease.yaml`, and `infrastructure/storage/longhorn/helmrelease.yaml` have no OCI-specific storage patches needed — they're deployed unmodified and simply initialize fresh/empty (no `bootstrap.recovery` stanza exists yet anywhere in the repo; that's Phase 2's dependency on `feat/cnpg-bootstrap-recovery`). Real data restore is explicitly out of scope here.
2. **CNPG backup hazard specific to Phase 1 (not just Phase 2):** `infrastructure/database/postgres/cluster.yaml`'s `Cluster` has `backup.barmanObjectStore.destinationPath: s3://k3s-lab-backups/postgres/pg` — the **same path OVH's live cluster continuously archives WAL into**. This isn't just a restore-time risk: if OCI's *fresh* Phase 1 Postgres cluster reconciles that spec unpatched, it starts archiving its own WAL to that same barman prefix immediately, corrupting OVH's backup chain even though OCI never restores anything. Task 6 below patches this out for OCI (`/spec/backup` removed, `ScheduledBackup` deleted) — this is a decision beyond what the spec's §3 called out explicitly (which only warned about the *restore*-time case), flagged in the report back.
3. **Authentik gets its own empty DB.** OCI's Authentik HelmRelease (mirrored unmodified except hostname patches) points at `pg-rw.postgres.svc.cluster.local` / `redis-ha-haproxy.redis.svc.cluster.local` — these are **OCI's own** in-cluster Postgres/Redis (same service names, different cluster), so no cross-cluster reference exists. Authentik bootstraps a brand-new empty `authentik` database via CNPG's `Database` CR. This is sufficient to prove the platform reconciles; it is not a working SSO login until Phase 2/3 restores real data and Phase 3 registers OIDC redirect URIs for `oci.` hostnames.
4. **`longhorn-backup` and `longhorn-backup-target` are additionally excluded** (beyond the spec's explicit "juggler/juicefs*/agent-os" list). `longhorn-backup-target-kustomization.yaml` activates the **same** shared S3 `BackupTarget` OVH's Longhorn uses; `longhorn-backup-kustomization.yaml` layers `RecurringJob`s on top of it. Since OCI's Longhorn volumes are empty in Phase 1 and there's no working backup target to send to, both are left out — this avoids either touching OVH's live backup target or spamming failed backup `Job`s. This is a decision beyond the spec's literal text, flagged in the report back.
5. **`dcxxiv-home`'s hostnames don't fit the `<name>.dcxxiv.com` → `<name>.oci.dcxxiv.com` pattern** (its Ingress serves the bare apex `dcxxiv.com` / `www.dcxxiv.com`, not a subdomain). Task 8 maps it to `oci.dcxxiv.com` / `www.oci.dcxxiv.com` — i.e., OCI's own subdomain apex (created by this plan's `dns.tf`) plays the same role for the standby that the production apex plays for OVH. Flagged as a decision in the report back.
6. **`GITHUB_TOKEN` is added to `oci-k3s`'s own `secrets.sops.yaml`** alongside the `AWS_*`/`CLOUDFLARE_API_TOKEN` keys named in the task brief. `bootstrap/terraform/oci-k3s/flux.tf`'s `null_resource.flux_bootstrap` reads `GITHUB_TOKEN` from the process environment during `terraform apply` itself (not just from the top-level `make flux-bootstrap-oci-lab` target, which already reads a shared token from `ovh-k3s/secrets.sops.yaml`) — without it, `make apply-oci` / `tf.sh apply` fails at that resource. Flagged as a decision beyond the literal task brief.

---

## Task 1: OCI Terraform tooling & secrets parity

**Files:**
- Create: `bootstrap/terraform/oci-k3s/tf.sh`
- Create: `bootstrap/terraform/oci-k3s/secrets.yaml.example`
- Create: `bootstrap/terraform/oci-k3s/Makefile`
- Modify: `Makefile` (repo root)

- [ ] **Step 1: Copy the OVH `tf.sh` wrapper verbatim**

`tf.sh` is directory-relative and provider-agnostic (it just decrypts whatever's in the sibling `secrets.sops.yaml` and exports each key as an env var before exec'ing `terraform`), so it needs no oci-specific changes:

```bash
#!/usr/bin/env bash
# tf.sh — Terraform wrapper that decrypts secrets.sops.yaml before running.
# Prefer using top-level make targets (make plan-oci, make apply-oci, etc.)
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
  echo "  # fill in AWS creds + Cloudflare token + GitHub PAT" >&2
  echo "  cp $SCRIPT_DIR/secrets.yaml $SCRIPT_DIR/secrets.sops.yaml" >&2
  echo "  sops -e -i $SCRIPT_DIR/secrets.sops.yaml" >&2
  echo "  rm $SCRIPT_DIR/secrets.yaml" >&2
  echo "  git add $SCRIPT_DIR/secrets.sops.yaml && git commit" >&2
  exit 1
fi

# Use age key from env if set; fall back to the temp path from 'make recover-age-key'
: "${SOPS_AGE_KEY_FILE:=/tmp/k3s-lab-age.agekey}"
export SOPS_AGE_KEY_FILE

# Decrypt YAML and export each key as an env var
eval "$(sops -d "$SOPS_FILE" | python3 -c "
import yaml, sys, shlex
for k, v in yaml.safe_load(sys.stdin).items():
    print(f'export {k}={shlex.quote(str(v))}')
")"

exec terraform "$@"
```

Make it executable: `chmod +x bootstrap/terraform/oci-k3s/tf.sh`.

- [ ] **Step 2: Create the secrets template**

```yaml
# OCI k3s bootstrap secrets — copy to secrets.yaml, fill in, then encrypt:
#
#   cp secrets.yaml.example secrets.yaml
#   $EDITOR secrets.yaml
#   cp secrets.yaml secrets.sops.yaml && sops -e -i secrets.sops.yaml && rm secrets.yaml
#   git add secrets.sops.yaml && git commit -m "oci-k3s: add encrypted bootstrap secrets"
#
# Or from the repo root, use top-level make targets:
#   make init-oci && make apply-oci
# (make apply-oci runs make recover-age-key first, so the SOPS key is handled for you.)
#
# AWS credentials: used for the S3 remote state backend (versions.tf). These are
# NOT the same as Longhorn's or Postgres's S3 backup creds (those are separate,
# cluster-internal Kubernetes Secrets — infrastructure/storage/longhorn/backup/
# secret.sops.yaml and infrastructure/database/postgres/s3-backup-creds.sops.yaml —
# not this file).
AWS_ACCESS_KEY_ID: your_aws_access_key_id
AWS_SECRET_ACCESS_KEY: your_aws_secret_access_key

# Cloudflare API token (Zone:Read + DNS:Edit for dcxxiv.com) — for dns.tf's
# oci.dcxxiv.com subdomain A records.
CLOUDFLARE_API_TOKEN: your_cloudflare_api_token

# GitHub PAT (repo scope) — read directly from the environment by
# null_resource.flux_bootstrap in flux.tf during 'terraform apply' itself
# (separate from the top-level 'make flux-bootstrap-oci-lab' target, which
# reads a shared token from ovh-k3s/secrets.sops.yaml).
GITHUB_TOKEN: ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**Note for the operator (cannot be done by an agent):** the actual `secrets.sops.yaml` with real values must be created by hand — `cp secrets.yaml.example secrets.yaml`, fill in real AWS/Cloudflare/GitHub credentials, then `sops -e -i secrets.sops.yaml` using the repo's real age recipient (`.sops.yaml`), then `rm secrets.yaml` and commit. This plan does not (and cannot) produce a real encrypted secrets file — no credential material is available to it.

- [ ] **Step 3: Copy the OVH `Makefile` wrapper, unchanged**

```makefile
SHELL := /bin/bash

# All targets go through tf.sh which decrypts secrets.sops.yaml using the age key.
# Prefer top-level make targets from the repo root (make init-oci, make apply-oci, etc.)
# which handle age key recovery automatically.
#
# From this directory with the age key already recovered:
#   export SOPS_AGE_KEY_FILE=/tmp/k3s-lab-age.agekey
#   make init && make apply

.PHONY: init plan apply destroy kubeconfig

init:
	terraform init

plan:
	./tf.sh plan

apply:
	./tf.sh apply -auto-approve

destroy:
	./tf.sh destroy -auto-approve

kubeconfig:
	@./tf.sh output -raw kubeconfig_path
```

- [ ] **Step 4: Wire top-level `make plan-oci`/`apply-oci`/etc.**

In the repo-root `Makefile`, add an `OCI_TF_DIR` variable and matching targets right after the existing OVH Terraform section (after `kubeconfig-ovh`, before the "Longhorn S3 backup" section):

```makefile
# ---------------------------------------------------------------------------
# OCI Terraform
# ---------------------------------------------------------------------------

OCI_TF_DIR := bootstrap/terraform/oci-k3s

.PHONY: init-oci
init-oci: recover-age-key ## One-time setup: create secrets if needed, then terraform init
	@if [ ! -f "$(OCI_TF_DIR)/secrets.sops.yaml" ]; then \
	  echo "No secrets.sops.yaml found — opening example in $$EDITOR to fill in credentials."; \
	  cp "$(OCI_TF_DIR)/secrets.yaml.example" "$(OCI_TF_DIR)/secrets.yaml"; \
	  $${EDITOR:-vi} "$(OCI_TF_DIR)/secrets.yaml"; \
	  cp "$(OCI_TF_DIR)/secrets.yaml" "$(OCI_TF_DIR)/secrets.sops.yaml"; \
	  SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" sops -e -i "$(OCI_TF_DIR)/secrets.sops.yaml"; \
	  rm "$(OCI_TF_DIR)/secrets.yaml"; \
	  echo "Secrets encrypted. Commit with: git add $(OCI_TF_DIR)/secrets.sops.yaml && git commit"; \
	fi
	terraform -chdir="$(OCI_TF_DIR)" init

.PHONY: plan-oci
plan-oci: recover-age-key ## Preview OCI cluster changes
	SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" $(MAKE) -C $(OCI_TF_DIR) plan

.PHONY: apply-oci
apply-oci: recover-age-key ## Provision or update the OCI cluster
	SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" $(MAKE) -C $(OCI_TF_DIR) apply

.PHONY: destroy-oci
destroy-oci: recover-age-key ## Destroy the OCI cluster (frees the Always Free pool)
	SOPS_AGE_KEY_FILE="$(AGE_KEY_TMP)" $(MAKE) -C $(OCI_TF_DIR) destroy

.PHONY: kubeconfig-oci
kubeconfig-oci: recover-age-key ## Print absolute path to the OCI kubeconfig
	@echo "$(CURDIR)/$(OCI_TF_DIR)/kubeconfig"
```

Also update the `help:` target's echo block — right after the existing `"  OVH cluster (Terraform)"` block (after the `kubeconfig-ovh` line, before the blank `@echo ""` that precedes "S3 backup credentials") — add:

```makefile
	@echo "  OCI cluster (Terraform)"
	@echo "    init-oci                 One-time setup: create secrets if needed, then terraform init"
	@echo "    plan-oci                 Preview changes to the OCI cluster"
	@echo "    apply-oci                Provision or update the OCI cluster"
	@echo "    destroy-oci              Destroy the OCI cluster (frees the Always Free pool)"
	@echo "    kubeconfig-oci           Print path to the OCI kubeconfig"
	@echo ""
```

- [ ] **Step 5: VALIDATE**

```bash
bash -n bootstrap/terraform/oci-k3s/tf.sh
make -n init-oci
make -n plan-oci
make help | grep -A6 "OCI cluster"
```
Expected: `bash -n` prints nothing (syntax OK); `make -n` prints the would-run command list without executing anything (no secrets file is required for `-n`); `make help` shows the new OCI block.

- [ ] **Step 6: Commit**

```bash
git add bootstrap/terraform/oci-k3s/tf.sh bootstrap/terraform/oci-k3s/secrets.yaml.example bootstrap/terraform/oci-k3s/Makefile Makefile
git commit -m "oci-k3s: add tf.sh/secrets template and top-level make targets"
```

---

## Task 2: S3 remote state backend

**Files:**
- Modify: `bootstrap/terraform/oci-k3s/versions.tf`

- [ ] **Step 1: Add the S3 backend and bump the version floor**

```hcl
terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "k3s-lab-backups"
    key          = "terraform/state/oci-k3s"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
```

(The `cloudflare` provider requirement is added here because Task 4 introduces `dns.tf`; adding it now means `terraform init` only needs to run once for both changes.)

- [ ] **Step 2: VALIDATE**

Since this module has never been applied, there is no existing local state to migrate — this is a fresh `init`, not a `-migrate-state` run. From `bootstrap/terraform/oci-k3s/` (after Task 1's `secrets.sops.yaml` exists with real AWS creds and the operator has exported `SOPS_AGE_KEY_FILE`):

```bash
./tf.sh init
./tf.sh validate
```

Expected: `init` reports "Successfully configured the backend \"s3\"!" and downloads the `cloudflare` provider; `validate` reports "Success! The configuration is valid." If `terraform`/`tofu` isn't installed in the environment writing this plan, at minimum confirm the HCL parses: `terraform fmt -check bootstrap/terraform/oci-k3s/versions.tf` (or eyeball-diff against `bootstrap/terraform/ovh-k3s/versions.tf`, which has the identical backend/version shape).

- [ ] **Step 3: Commit**

```bash
git add bootstrap/terraform/oci-k3s/versions.tf
git commit -m "oci-k3s: add S3 remote state backend, bump terraform floor to 1.10"
```

---

## Task 3: Storage — dedicated per-node Block Volume for Longhorn

**Files:**
- Modify: `bootstrap/terraform/oci-k3s/variables.tf`
- Create: `bootstrap/terraform/oci-k3s/storage.tf`
- Modify: `bootstrap/terraform/oci-k3s/locals.tf`
- Modify: `bootstrap/terraform/oci-k3s/cloud-init.tf`
- Modify: `bootstrap/terraform/oci-k3s/cloud-init/server.yaml.tftpl`

- [ ] **Step 1: Shrink the boot volume default and add data-volume variables**

In `variables.tf`, change:

```hcl
variable "boot_volume_size_gbs" {
  type        = number
  description = "Boot volume size per node in GB. Always Free block storage total is 200 GB."
  default     = 50
}
```

to:

```hcl
variable "boot_volume_size_gbs" {
  type        = number
  description = "Boot volume size per node in GB. Always Free block storage total is 200 GB."
  default     = 35
}

variable "data_volume_size_gbs" {
  type        = number
  description = "Size in GB of the dedicated per-node Block Volume for Longhorn. Mounted at data_mount_point and bind-mounted over /var/lib/longhorn so Longhorn's I/O and capacity are separated from the boot volume — mirrors ovh-k3s's Cinder data-disk pattern. Set to 0 to disable (Longhorn then uses a subdir of the boot volume)."
  default     = 30
}

variable "data_mount_point" {
  type        = string
  description = "Host path where the data Block Volume is mounted. The Longhorn bind mount is anchored here."
  default     = "/mnt/data"
}
```

- [ ] **Step 2: Add a storage guardrail alongside the existing OCPU/memory ones**

In `locals.tf`, extend the existing `null_resource.free_tier_guardrail` with a third precondition (the resource and its other two preconditions are unchanged):

```hcl
resource "null_resource" "free_tier_guardrail" {
  lifecycle {
    precondition {
      condition     = local.total_ocpus <= var.free_tier_max_ocpus
      error_message = "Requested ${local.total_ocpus} OCPUs exceeds free_tier_max_ocpus (${var.free_tier_max_ocpus})."
    }
    precondition {
      condition     = local.total_memory <= var.free_tier_max_memory_gbs
      error_message = "Requested ${local.total_memory} GB exceeds free_tier_max_memory_gbs (${var.free_tier_max_memory_gbs})."
    }
    precondition {
      condition     = (var.server_count + var.agent_count) * (var.boot_volume_size_gbs + var.data_volume_size_gbs) <= 200
      error_message = "Total block storage (boot + data, all nodes) exceeds the 200 GB Always Free cap."
    }
  }
}
```

- [ ] **Step 3: Create the volume + attachment resources**

```hcl
# Per-node dedicated Block Volume for Longhorn — mirrors ovh-k3s's Cinder
# data-disk pattern (bootstrap/terraform/ovh-k3s/storage.tf). The boot volume
# stays small (var.boot_volume_size_gbs) and Longhorn gets its own disk
# instead of sharing the boot volume's I/O and capacity.
#
# Default: 3x 35 GB boot + 3x 30 GB data = 195 GB, under the 200 GB Always
# Free block storage cap (5 GB slack). Set data_volume_size_gbs = 0 to disable.
#
# Added as standalone volume + attachment resources so existing instances are
# NOT recreated (mirrors ovh-k3s/storage.tf's comment on the same point).
# cloud-init (cloud-init/server.yaml.tftpl) formats, mounts, and bind-mounts
# the volume over /var/lib/longhorn on first boot.

locals {
  data_volumes_enabled = var.data_volume_size_gbs > 0
}

resource "oci_core_volume" "server_data" {
  count               = local.data_volumes_enabled ? var.server_count : 0
  compartment_id      = var.compartment_ocid
  availability_domain = oci_core_instance.server[count.index].availability_domain
  display_name        = "k3s-server-${count.index + 1}-data"
  size_in_gbs         = var.data_volume_size_gbs
}

resource "oci_core_volume_attachment" "server_data" {
  count           = local.data_volumes_enabled ? var.server_count : 0
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.server[count.index].id
  volume_id       = oci_core_volume.server_data[count.index].id
  display_name    = "k3s-server-${count.index + 1}-data-attach"
}

resource "oci_core_volume" "agent_data" {
  count               = local.data_volumes_enabled ? var.agent_count : 0
  compartment_id      = var.compartment_ocid
  availability_domain = oci_core_instance.agent[count.index].availability_domain
  display_name        = "k3s-agent-${count.index + 1}-data"
  size_in_gbs         = var.data_volume_size_gbs
}

resource "oci_core_volume_attachment" "agent_data" {
  count           = local.data_volumes_enabled ? var.agent_count : 0
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.agent[count.index].id
  volume_id       = oci_core_volume.agent_data[count.index].id
  display_name    = "k3s-agent-${count.index + 1}-data-attach"
}
```

Save as `bootstrap/terraform/oci-k3s/storage.tf`. Unlike OVH's `storage.tf` (which splits `first`/`rest` because OVH's compute resources are split that way), OCI's `oci_core_instance.server`/`.agent` already use `count`, so a single indexed resource per group is enough — no first/rest split needed here.

- [ ] **Step 4: Pass the new variables into cloud-init**

In `cloud-init.tf`, add `data_volume_size_gbs` and `data_mount_point` to all three `templatefile()` calls:

```hcl
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

locals {
  cloudinit_server_first = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    role                 = "server-first"
    k3s_token            = random_password.k3s_token.result
    lb_ip                = local.lb_ip
    api_dns_name         = var.api_dns_name
    first_ip             = local.first_server_ip
    data_volume_size_gbs = var.data_volume_size_gbs
    data_mount_point     = var.data_mount_point
  })

  cloudinit_server_join = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    role                 = "server-join"
    k3s_token            = random_password.k3s_token.result
    lb_ip                = local.lb_ip
    api_dns_name         = var.api_dns_name
    first_ip             = local.first_server_ip
    data_volume_size_gbs = var.data_volume_size_gbs
    data_mount_point     = var.data_mount_point
  })

  cloudinit_agent = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    role                 = "agent"
    k3s_token            = random_password.k3s_token.result
    lb_ip                = local.lb_ip
    api_dns_name         = var.api_dns_name
    first_ip             = local.first_server_ip
    data_volume_size_gbs = var.data_volume_size_gbs
    data_mount_point     = var.data_mount_point
  })
}
```

- [ ] **Step 5: Add the data-disk setup step to cloud-init**

Replace `cloud-init/server.yaml.tftpl` in full with:

```
#cloud-config
# Rendered by Terraform (templatefile). role = ${role}
#
# Three OCI gotchas handled here:
#  1. The stock Ubuntu image ships restrictive iptables (REJECT in INPUT and
#     FORWARD) that silently breaks flannel/etcd/apiserver. We insert ACCEPT
#     rules at the top of both chains BEFORE installing k3s, then persist them.
#  2. The VCN security list (separate from the host firewall) is opened in
#     Terraform's network.tf, not here.
#  3. If a dedicated data Block Volume is attached (data_volume_size_gbs > 0,
#     see storage.tf), format/mount it at data_mount_point and bind-mount it
#     over /var/lib/longhorn before k3s/Longhorn ever touch that path.

write_files:
  - path: /etc/rancher/k3s/config.yaml
    permissions: "0600"
    content: |
      write-kubeconfig-mode: "0644"
      tls-san:
        - ${lb_ip}
%{ if api_dns_name != "" ~}
        - ${api_dns_name}
%{ endif ~}

runcmd:
%{ if data_volume_size_gbs > 0 ~}
  # ── Data disk: find the attached blank Block Volume, format, mount, bind ──
  - |
    set -e
    MOUNT="${data_mount_point}"
    echo "==> Waiting for the data Block Volume to attach..."
    DEV=""
    for i in $(seq 1 12); do
      for d in $(lsblk -nd --output NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}'); do
        findmnt "$d" &>/dev/null && continue
        lsblk -n "$d" 2>/dev/null | grep -q 'part' && continue
        blkid "$d" &>/dev/null && continue
        DEV="$d"
        break 2
      done
      sleep 5
    done
    if [ -n "$DEV" ]; then
      mkfs.ext4 -L data -m 1 "$DEV"
      mkdir -p "$MOUNT" "$MOUNT/longhorn"
      echo "LABEL=data $MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
      echo "$MOUNT/longhorn /var/lib/longhorn none bind,nofail,x-systemd.requires=local-fs.target 0 0" >> /etc/fstab
      mount "$MOUNT"
      mkdir -p /var/lib/longhorn
      mount --bind "$MOUNT/longhorn" /var/lib/longhorn
      echo "==> Data disk ready at $MOUNT; /var/lib/longhorn bind-mounted."
    else
      echo "WARNING: No blank data Block Volume found after 60s; Longhorn will use the boot volume." >&2
    fi
%{ endif ~}
  # --- open the host firewall before k3s starts ---
  - iptables -I INPUT 1 -p tcp --dport 6443 -j ACCEPT
  - iptables -I INPUT 1 -p tcp --dport 2379:2380 -j ACCEPT
  - iptables -I INPUT 1 -p tcp --dport 10250 -j ACCEPT
  - iptables -I INPUT 1 -p udp --dport 8472 -j ACCEPT
  - iptables -I INPUT 1 -s 10.0.0.0/16 -j ACCEPT
  - iptables -I INPUT 1 -s 10.42.0.0/16 -j ACCEPT
  - iptables -I INPUT 1 -s 10.43.0.0/16 -j ACCEPT
  - iptables -I FORWARD 1 -s 10.42.0.0/16 -j ACCEPT
  - iptables -I FORWARD 1 -d 10.42.0.0/16 -j ACCEPT
  - netfilter-persistent save
  # --- install k3s for this node's role ---
%{ if role == "server-first" ~}
  - curl -sfL https://get.k3s.io | sh -s - server --cluster-init --token "${k3s_token}"
%{ endif ~}
%{ if role == "server-join" ~}
  - curl -sfL https://get.k3s.io | sh -s - server --server "https://${first_ip}:6443" --token "${k3s_token}"
%{ endif ~}
%{ if role == "agent" ~}
  - curl -sfL https://get.k3s.io | K3S_URL="https://${lb_ip}:6443" K3S_TOKEN="${k3s_token}" sh -
%{ endif ~}
```

- [ ] **Step 6: VALIDATE**

```bash
./tf.sh validate   # from bootstrap/terraform/oci-k3s/, after Task 2's init
./tf.sh plan       # confirm: 3x oci_core_volume, 3x oci_core_volume_attachment,
                   # boot_volume_size_in_gbs now 35 on existing/planned instances
```

Expected: `plan` shows the 6 new resources (3 volumes + 3 attachments) and no unexpected changes to `oci_core_instance.server`/`.agent` beyond `boot_volume_size_in_gbs` (35 instead of 50) if this runs on a pre-existing apply — on a first-ever apply (the expected case here, module has never been applied) `plan` just shows the full resource set once. Also confirm the guardrail: `terraform plan -var='data_volume_size_gbs=200'` should fail the new precondition.

- [ ] **Step 7: Commit**

```bash
git add bootstrap/terraform/oci-k3s/variables.tf bootstrap/terraform/oci-k3s/storage.tf bootstrap/terraform/oci-k3s/locals.tf bootstrap/terraform/oci-k3s/cloud-init.tf bootstrap/terraform/oci-k3s/cloud-init/server.yaml.tftpl
git commit -m "oci-k3s: add dedicated per-node data volume for Longhorn, shrink boot volume"
```

---

## Task 4: Cloudflare DNS for `oci.dcxxiv.com`

**Files:**
- Modify: `bootstrap/terraform/oci-k3s/variables.tf`
- Modify: `bootstrap/terraform/oci-k3s/providers.tf`
- Create: `bootstrap/terraform/oci-k3s/dns.tf`

- [ ] **Step 1: Add `manage_dns`/`dns_zone` variables**

Append to `variables.tf`:

```hcl
# --- Cloudflare DNS ---

variable "manage_dns" {
  type        = bool
  description = "If true, create round-robin A records in Cloudflare for the oci.dcxxiv.com subdomain across all node public IPs. API token comes from CLOUDFLARE_API_TOKEN env var (exported by tf.sh from secrets.sops.yaml)."
  default     = true
}

variable "dns_zone" {
  type        = string
  description = "Cloudflare DNS zone. The oci.dcxxiv.com subdomain A records are created here; app hostname CNAMEs are unmanaged and resolve via those records."
  default     = "dcxxiv.com"
}
```

- [ ] **Step 2: Add the Cloudflare provider block**

Append to `providers.tf`:

```hcl
# API token read from CLOUDFLARE_API_TOKEN env var (exported by tf.sh from secrets.sops.yaml).
# Only contacts Cloudflare when manage_dns = true.
provider "cloudflare" {}
```

- [ ] **Step 3: Create `dns.tf`**

```hcl
# Cloudflare DNS — round-robin A records for the oci.dcxxiv.com subdomain,
# fronting the 3 OCI node public IPs. Every OCI app hostname is a CNAME to
# oci.dcxxiv.com in Cloudflare (unmanaged here, same pattern as ovh-k3s's
# apex CNAMEs — see ovh-k3s/dns.tf).
#
# This is a *subdomain* record (name = "oci"), not the apex — see
# docs/superpowers/specs/2026-08-01-oci-warm-dr-standby-design.md §2. The
# apex (dcxxiv.com) stays owned by ovh-k3s/dns.tf until promotion (Phase 3,
# not implemented here — this module has no manage_apex_dns variable yet).

data "cloudflare_zones" "this" {
  count = var.manage_dns ? 1 : 0
  filter {
    name = var.dns_zone
  }
}

resource "cloudflare_record" "oci_subdomain" {
  for_each = var.manage_dns ? toset(oci_core_instance.server[*].public_ip) : toset([])
  zone_id  = data.cloudflare_zones.this[0].zones[0].id
  name     = "oci"
  content  = each.value
  type     = "A"
  ttl      = 1
}
```

- [ ] **Step 4: VALIDATE**

```bash
./tf.sh validate
./tf.sh plan   # confirm: data.cloudflare_zones.this, 3x cloudflare_record.oci_subdomain (one per server public IP)
```

Expected: `validate` succeeds; `plan` shows the zone data source and one `cloudflare_record.oci_subdomain["<ip>"]` per server node (3, matching `server_count` default). Manually confirm afterward (post-apply, out of Terraform): `dig +short oci.dcxxiv.com` resolves to all 3 node public IPs.

- [ ] **Step 5: Commit**

```bash
git add bootstrap/terraform/oci-k3s/variables.tf bootstrap/terraform/oci-k3s/providers.tf bootstrap/terraform/oci-k3s/dns.tf
git commit -m "oci-k3s: add dns.tf for the oci.dcxxiv.com subdomain"
```

---

## Task 5: Platform infrastructure Kustomizations (no hostname/replica changes)

**Files:**
- Create: `clusters/oci-lab/traefik-config-kustomization.yaml`
- Create: `clusters/oci-lab/cert-manager-kustomization.yaml`
- Create: `clusters/oci-lab/cert-manager-http01-kustomization.yaml`
- Create: `clusters/oci-lab/cert-manager-config-kustomization.yaml`
- Create: `clusters/oci-lab/local-path-kustomization.yaml`
- Create: `clusters/oci-lab/longhorn-kustomization.yaml`
- Create: `clusters/oci-lab/cloudnative-pg-kustomization.yaml`
- Create: `clusters/oci-lab/postgres-kustomization.yaml`
- Create: `clusters/oci-lab/redis-kustomization.yaml`
- Create: `clusters/oci-lab/mariadb-kustomization.yaml`
- Create: `clusters/oci-lab/reloader-kustomization.yaml`

- [ ] **Step 1: Copy 9 files unchanged**

These have no hostnames and no OVH-only patches — copy verbatim, byte-for-byte, from `clusters/ovh-lab/`:

```bash
for f in traefik-config cert-manager cert-manager-http01 cert-manager-config \
         local-path cloudnative-pg redis mariadb reloader; do
  cp "clusters/ovh-lab/${f}-kustomization.yaml" "clusters/oci-lab/${f}-kustomization.yaml"
done
```

- [ ] **Step 2: Create `longhorn-kustomization.yaml` — same base, without OVH's backup-target patch**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: longhorn
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure/storage/longhorn
  prune: true
  wait: true
  timeout: 15m
  dependsOn:
    - name: cert-manager-config
  # No backupTarget patch here (unlike clusters/ovh-lab/longhorn-kustomization.yaml):
  # OCI's Longhorn volumes are empty in Phase 1 (see plan's Scope notes #4) and
  # must not touch OVH's live S3 backup target. Restore-time wiring is Phase 2.
```

- [ ] **Step 3: Create `postgres-kustomization.yaml` — disable the shared barman backup path**

`infrastructure/database/postgres/cluster.yaml`'s CNPG `Cluster` archives WAL to `s3://k3s-lab-backups/postgres/pg` — the same path OVH's live cluster continuously writes to (see plan's Scope notes #2). Patch it out for OCI:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: postgres
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure/database/postgres
  prune: true
  wait: true
  timeout: 15m
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  dependsOn:
    - name: cloudnative-pg
  # OCI-only: the shared Cluster spec archives WAL to s3://k3s-lab-backups/postgres/pg —
  # the same path OVH's live cluster continuously writes to. OCI's fresh, empty Phase 1
  # cluster must not also archive there (two independent PG timelines writing to the same
  # barman prefix corrupts the backup chain for both). Remove backup entirely for Phase 1;
  # real restore + a distinct OCI-only backup path are Phase 2 concerns.
  patches:
    - patch: |
        - op: remove
          path: /spec/backup
      target:
        kind: Cluster
        name: pg
        namespace: postgres
    - patch: |
        apiVersion: postgresql.cnpg.io/v1
        kind: ScheduledBackup
        metadata:
          name: pg-daily
          namespace: postgres
        $patch: delete
      target:
        kind: ScheduledBackup
        name: pg-daily
        namespace: postgres
```

- [ ] **Step 4: VALIDATE**

```bash
kustomize build clusters/oci-lab | kubeconform -strict -ignore-missing-schemas -summary
```

(This will still report the cluster as effectively empty/incomplete until `flux-system/` exists post-bootstrap and Task 10 wires the aggregator — expected at this point in the plan. For now, confirm each new file individually parses as valid YAML and valid Flux `Kustomization`/patch syntax: `kustomize build --load-restrictor=LoadRestrictionsNone clusters/oci-lab 2>&1 | head` should not error on YAML parsing for these 11 files specifically; a full `kubeconform` pass happens in Task 10 once the aggregator lists everything.)

Also diff-check the copies are truly byte-identical to their OVH source (sanity check for Step 1):

```bash
for f in traefik-config cert-manager cert-manager-http01 cert-manager-config \
         local-path cloudnative-pg redis mariadb reloader; do
  diff "clusters/ovh-lab/${f}-kustomization.yaml" "clusters/oci-lab/${f}-kustomization.yaml" && echo "OK: $f"
done
```

Expected: `OK: <name>` for all 9, no diff output.

- [ ] **Step 5: Commit**

```bash
git add clusters/oci-lab/traefik-config-kustomization.yaml clusters/oci-lab/cert-manager-kustomization.yaml \
        clusters/oci-lab/cert-manager-http01-kustomization.yaml clusters/oci-lab/cert-manager-config-kustomization.yaml \
        clusters/oci-lab/local-path-kustomization.yaml clusters/oci-lab/longhorn-kustomization.yaml \
        clusters/oci-lab/cloudnative-pg-kustomization.yaml clusters/oci-lab/postgres-kustomization.yaml \
        clusters/oci-lab/redis-kustomization.yaml clusters/oci-lab/mariadb-kustomization.yaml \
        clusters/oci-lab/reloader-kustomization.yaml
git commit -m "oci-lab: mirror platform infrastructure Kustomizations"
```

---

## Task 6: Hostname-patched platform Kustomizations (authentik, monitoring, weave-gitops, headlamp)

**Files:**
- Create: `clusters/oci-lab/authentik-kustomization.yaml`
- Create: `clusters/oci-lab/monitoring-kustomization.yaml`
- Create: `clusters/oci-lab/weave-gitops-kustomization.yaml`
- Create: `clusters/oci-lab/headlamp-kustomization.yaml`

- [ ] **Step 1: `authentik-kustomization.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: authentik
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: "./infrastructure/authentik"
  prune: true
  wait: true
  timeout: 15m
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  dependsOn:
    - name: cert-manager-config
    - name: longhorn
    - name: postgres
    - name: shared-redis
  # OCI runs its own, independent Authentik instance (own outpost, own empty
  # CNPG DB — see plan's Scope notes #3). Hostname rewritten to the oci.
  # subdomain; OIDC redirect-URI registration for oci. hostnames is Phase 3.
  patches:
    - patch: |
        apiVersion: helm.toolkit.fluxcd.io/v2
        kind: HelmRelease
        metadata:
          name: authentik
          namespace: authentik
        spec:
          values:
            global:
              host: https://auth.oci.dcxxiv.com
            server:
              ingress:
                enabled: true
                ingressClassName: traefik
                annotations:
                  cert-manager.io/cluster-issuer: letsencrypt-prod
                hosts:
                  - auth.oci.dcxxiv.com
                tls:
                  - secretName: authentik-tls
                    hosts:
                      - auth.oci.dcxxiv.com
                  - secretName: authentik-outpost-tls
                    hosts:
                      - auth.oci.dcxxiv.com
      target:
        kind: HelmRelease
        name: authentik
        namespace: authentik
```

- [ ] **Step 2: `monitoring-kustomization.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: monitoring
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: "./infrastructure/monitoring"
  prune: true
  wait: true
  timeout: 15m
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  dependsOn:
    - name: cert-manager-config
    - name: longhorn
  patches:
    - patch: |
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: grafana-tls
          namespace: monitoring
        spec:
          dnsNames:
            - grafana.oci.dcxxiv.com
      target:
        kind: Certificate
        name: grafana-tls
        namespace: monitoring
    - patch: |
        apiVersion: helm.toolkit.fluxcd.io/v2
        kind: HelmRelease
        metadata:
          name: kube-prometheus-stack
          namespace: monitoring
        spec:
          values:
            grafana:
              grafana.ini:
                server:
                  root_url: https://grafana.oci.dcxxiv.com
                auth:
                  signout_redirect_url: https://auth.oci.dcxxiv.com/application/o/grafana/end-session/
                auth.generic_oauth:
                  auth_url: https://auth.oci.dcxxiv.com/application/o/authorize/
                  token_url: https://auth.oci.dcxxiv.com/application/o/token/
                  api_url: https://auth.oci.dcxxiv.com/application/o/userinfo/
              ingress:
                hosts:
                  - grafana.oci.dcxxiv.com
                tls:
                  - secretName: grafana-tls
                    hosts:
                      - grafana.oci.dcxxiv.com
      target:
        kind: HelmRelease
        name: kube-prometheus-stack
        namespace: monitoring
```

(The `auth.generic_oauth`/`signout_redirect_url` rewrite points Grafana's OIDC flow at OCI's own Authentik — the one it can actually reach in-cluster. Login won't fully succeed until Phase 3 registers a matching OIDC client on OCI's Authentik for `grafana.oci.dcxxiv.com`; this doesn't block Flux reconciliation.)

- [ ] **Step 3: `weave-gitops-kustomization.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: weave-gitops
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: "./infrastructure/weave-gitops"
  prune: true
  wait: true
  timeout: 5m
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  dependsOn:
    - name: cert-manager-config
  patches:
    - patch: |
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: weave-gitops-tls
          namespace: weave-gitops
        spec:
          dnsNames:
            - flux.oci.dcxxiv.com
      target:
        kind: Certificate
        name: weave-gitops-tls
        namespace: weave-gitops
    - patch: |
        apiVersion: helm.toolkit.fluxcd.io/v2
        kind: HelmRelease
        metadata:
          name: weave-gitops
          namespace: weave-gitops
        spec:
          values:
            ingress:
              hosts:
                - host: flux.oci.dcxxiv.com
                  paths:
                    - path: /
                      pathType: Prefix
              tls:
                - secretName: weave-gitops-tls
                  hosts:
                    - flux.oci.dcxxiv.com
      target:
        kind: HelmRelease
        name: weave-gitops
        namespace: weave-gitops
```

- [ ] **Step 4: `headlamp-kustomization.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: headlamp
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: "./infrastructure/headlamp"
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
    - name: cert-manager-config
    - name: authentik
  patches:
    - patch: |
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: headlamp-tls
          namespace: headlamp
        spec:
          dnsNames:
            - headlamp.oci.dcxxiv.com
      target:
        kind: Certificate
        name: headlamp-tls
        namespace: headlamp
    - patch: |
        apiVersion: traefik.io/v1alpha1
        kind: IngressRoute
        metadata:
          name: headlamp
          namespace: headlamp
        spec:
          entryPoints:
            - websecure
          routes:
            - kind: Rule
              match: Host(`headlamp.oci.dcxxiv.com`)
              middlewares:
                - name: authentik
                  namespace: authentik
              services:
                - name: headlamp
                  port: 80
          tls:
            secretName: headlamp-tls
      target:
        kind: IngressRoute
        name: headlamp
        namespace: headlamp
```

- [ ] **Step 5: VALIDATE**

```bash
python3 -c "
import subprocess
for f in ['authentik','monitoring','weave-gitops','headlamp']:
    subprocess.run(['python3','-c','import sys,json'], check=True)
"
# Simpler: each file must at least be well-formed YAML with no tab characters
# and every 'patch: |' block indented consistently. Grep-based sanity check:
for f in authentik monitoring weave-gitops headlamp; do
  grep -c "target:" "clusters/oci-lab/${f}-kustomization.yaml"
done
```

Expected: each `grep -c "target:"` returns the same count as the number of `patch:` blocks in that file (authentik=1, monitoring=2, weave-gitops=2, headlamp=2) — confirms every patch has a matching target. Full schema validation happens in Task 10's `kustomize build | kubeconform` once the aggregator exists.

- [ ] **Step 6: Commit**

```bash
git add clusters/oci-lab/authentik-kustomization.yaml clusters/oci-lab/monitoring-kustomization.yaml \
        clusters/oci-lab/weave-gitops-kustomization.yaml clusters/oci-lab/headlamp-kustomization.yaml
git commit -m "oci-lab: mirror authentik/monitoring/weave-gitops/headlamp with oci. hostnames"
```

---

## Task 7: App Kustomizations — plain Ingress apps (dcxxiv-home, hero, personliness, nodecast-tv, wordpress)

**Files:**
- Create: `clusters/oci-lab/dcxxiv-home-kustomization.yaml`
- Create: `clusters/oci-lab/hero-kustomization.yaml`
- Create: `clusters/oci-lab/personliness-kustomization.yaml`
- Create: `clusters/oci-lab/nodecast-tv-kustomization.yaml`
- Create: `clusters/oci-lab/wordpress-kustomization.yaml`

- [ ] **Step 1: `dcxxiv-home-kustomization.yaml`**

Its Ingress serves the bare apex (`dcxxiv.com`/`www.dcxxiv.com`), not a `<name>.dcxxiv.com` subdomain — mapped to OCI's own subdomain apex (`oci.dcxxiv.com`/`www.oci.dcxxiv.com`, the same one `dns.tf` creates round-robin A records for) per the plan's Scope notes #5:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: dcxxiv-home
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/dcxxiv-home
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
    - name: cert-manager-config
  patches:
    - patch: |
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: dcxxiv-home
          namespace: dcxxiv-home
        spec:
          rules:
            - host: oci.dcxxiv.com
              http:
                paths:
                  - path: /
                    pathType: Prefix
                    backend:
                      service:
                        name: dcxxiv-home
                        port:
                          number: 80
            - host: www.oci.dcxxiv.com
              http:
                paths:
                  - path: /
                    pathType: Prefix
                    backend:
                      service:
                        name: dcxxiv-home
                        port:
                          number: 80
          tls:
            - hosts:
                - oci.dcxxiv.com
                - www.oci.dcxxiv.com
              secretName: dcxxiv-home-tls
      target:
        kind: Ingress
        name: dcxxiv-home
        namespace: dcxxiv-home
    - patch: |
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: dcxxiv-home
          namespace: dcxxiv-home
        spec:
          replicas: 0
      target:
        kind: Deployment
        name: dcxxiv-home
        namespace: dcxxiv-home
```

- [ ] **Step 2: `hero-kustomization.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hero
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/hero
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
    - name: cert-manager-config
  patches:
    - patch: |
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: hero
          namespace: hero
        spec:
          rules:
            - host: hero.oci.dcxxiv.com
              http:
                paths:
                  - path: /
                    pathType: Prefix
                    backend:
                      service:
                        name: hero
                        port:
                          number: 80
          tls:
            - hosts:
                - hero.oci.dcxxiv.com
              secretName: hero-tls
      target:
        kind: Ingress
        name: hero
        namespace: hero
    - patch: |
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: hero
          namespace: hero
        spec:
          replicas: 0
      target:
        kind: Deployment
        name: hero
        namespace: hero
```

- [ ] **Step 3: `personliness-kustomization.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: personliness
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/personliness
  prune: true
  wait: true
  timeout: 5m
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  dependsOn:
    - name: cert-manager-config
    - name: shared-redis
    - name: postgres
  patches:
    - patch: |
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: personliness
          namespace: personliness
        spec:
          rules:
            - host: personliness.oci.dcxxiv.com
              http:
                paths:
                  - path: /
                    pathType: Prefix
                    backend:
                      service:
                        name: personliness
                        port:
                          number: 80
          tls:
            - hosts:
                - personliness.oci.dcxxiv.com
              secretName: personliness-tls
      target:
        kind: Ingress
        name: personliness
        namespace: personliness
    - patch: |
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: personliness
          namespace: personliness
        spec:
          replicas: 0
      target:
        kind: Deployment
        name: personliness
        namespace: personliness
```

- [ ] **Step 4: `nodecast-tv-kustomization.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: nodecast-tv
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/nodecast-tv
  prune: true
  wait: true
  timeout: 5m
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  dependsOn:
    - name: cert-manager-config
    - name: longhorn
  patches:
    - patch: |
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: nodecast-tv
          namespace: nodecast-tv
          annotations:
            traefik.ingress.kubernetes.io/router.middlewares: nodecast-tv-compress@kubernetescrd
        spec:
          rules:
            - host: tv.oci.dcxxiv.com
              http:
                paths:
                  - path: /
                    pathType: Prefix
                    backend:
                      service:
                        name: nodecast-tv
                        port:
                          number: 3000
          tls:
            - hosts:
                - tv.oci.dcxxiv.com
              secretName: nodecast-tv-tls
      target:
        kind: Ingress
        name: nodecast-tv
        namespace: nodecast-tv
    - patch: |
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: nodecast-tv
          namespace: nodecast-tv
        spec:
          replicas: 0
      target:
        kind: Deployment
        name: nodecast-tv
        namespace: nodecast-tv
```

- [ ] **Step 5: `wordpress-kustomization.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: wordpress
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/wordpress
  prune: true
  wait: true
  timeout: 5m
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  dependsOn:
    - name: cert-manager-config
    - name: mariadb
  patches:
    - patch: |
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: wordpress
          namespace: wordpress
        spec:
          rules:
            - host: lol.oci.dcxxiv.com
              http:
                paths:
                  - path: /
                    pathType: Prefix
                    backend:
                      service:
                        name: wordpress
                        port:
                          number: 80
          tls:
            - hosts:
                - lol.oci.dcxxiv.com
              secretName: wordpress-tls
      target:
        kind: Ingress
        name: wordpress
        namespace: wordpress
    - patch: |
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: wordpress
          namespace: wordpress
        spec:
          replicas: 0
      target:
        kind: Deployment
        name: wordpress
        namespace: wordpress
```

- [ ] **Step 6: VALIDATE**

```bash
for f in dcxxiv-home hero personliness nodecast-tv wordpress; do
  echo "=== $f ==="
  grep -c "target:" "clusters/oci-lab/${f}-kustomization.yaml"   # expect 2 each
  grep "host:" "clusters/oci-lab/${f}-kustomization.yaml"        # expect only *.oci.dcxxiv.com (or oci.dcxxiv.com for dcxxiv-home)
  grep "replicas:" "clusters/oci-lab/${f}-kustomization.yaml"    # expect "replicas: 0"
done
```

Expected: 2 `target:` blocks per file, every `host:` line ends in `oci.dcxxiv.com`, `replicas: 0` present in every file.

- [ ] **Step 7: Commit**

```bash
git add clusters/oci-lab/dcxxiv-home-kustomization.yaml clusters/oci-lab/hero-kustomization.yaml \
        clusters/oci-lab/personliness-kustomization.yaml clusters/oci-lab/nodecast-tv-kustomization.yaml \
        clusters/oci-lab/wordpress-kustomization.yaml
git commit -m "oci-lab: mirror dcxxiv-home/hero/personliness/nodecast-tv/wordpress at replicas 0"
```

---

## Task 8: App Kustomizations — IngressRoute apps (deluge, orchestrator)

**Files:**
- Create: `clusters/oci-lab/deluge-kustomization.yaml`
- Create: `clusters/oci-lab/orchestrator-kustomization.yaml`

- [ ] **Step 1: `deluge-kustomization.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: deluge
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/deluge
  prune: true
  wait: true
  timeout: 5m
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  dependsOn:
    # letsencrypt-prod ClusterIssuer (DNS01/Cloudflare) for the TLS cert
    - name: cert-manager-config
    # longhorn StorageClass for the config PVC
    - name: longhorn
    # authentik/authentik forwardAuth Middleware referenced by the IngressRoute
    - name: authentik
  # No storage-juicefs dependency here (unlike clusters/ovh-lab/deluge-kustomization.yaml):
  # juicefs-kustomization.yaml is excluded from clusters/oci-lab/ entirely (see Global
  # Constraints / Task 10) — the shared media PVC simply doesn't mount on OCI in Phase 1.
  patches:
    - patch: |
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: deluge-cert
          namespace: media
        spec:
          dnsNames:
            - deluge.oci.dcxxiv.com
      target:
        kind: Certificate
        name: deluge-cert
        namespace: media
    - patch: |
        apiVersion: traefik.io/v1alpha1
        kind: IngressRoute
        metadata:
          name: deluge
          namespace: media
        spec:
          entryPoints:
            - websecure
          routes:
            - kind: Rule
              match: Host(`deluge.oci.dcxxiv.com`)
              middlewares:
                - name: authentik
                  namespace: authentik
              services:
                - name: deluge
                  port: 8112
          tls:
            secretName: deluge-tls
      target:
        kind: IngressRoute
        name: deluge
        namespace: media
    - patch: |
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: deluge
          namespace: media
        spec:
          replicas: 0
      target:
        kind: Deployment
        name: deluge
        namespace: media
```

- [ ] **Step 2: `orchestrator-kustomization.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: orchestrator
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/orchestrator
  prune: true
  wait: true
  timeout: 5m
  # ─────────────────────────────────────────────────────────────────────────
  # SINGLE SOURCE OF TRUTH for the orchestrator version. Bump ONLY this line.
  # Kept in sync with clusters/ovh-lab/orchestrator-kustomization.yaml.
  # ─────────────────────────────────────────────────────────────────────────
  postBuild:
    substitute:
      ORCH_VERSION: "0.1.29"
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  dependsOn:
    # letsencrypt-prod ClusterIssuer (DNS01/Cloudflare) for the TLS cert
    - name: cert-manager-config
    # longhorn StorageClass for the SQLite PVC
    - name: longhorn
    # authentik/authentik forwardAuth Middleware referenced by the IngressRoute
    - name: authentik
  patches:
    - patch: |
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: orchestrator-cert
          namespace: orchestrator
        spec:
          dnsNames:
            - orch.oci.dcxxiv.com
      target:
        kind: Certificate
        name: orchestrator-cert
        namespace: orchestrator
    - patch: |
        apiVersion: traefik.io/v1alpha1
        kind: IngressRoute
        metadata:
          name: orchestrator
          namespace: orchestrator
        spec:
          entryPoints:
            - websecure
          routes:
            - kind: Rule
              match: Host(`orch.oci.dcxxiv.com`) && (PathPrefix(`/api/webhook`) || PathPrefix(`/webhook`) || Path(`/healthz`) || Path(`/readyz`))
              priority: 20
              services:
                - name: orchestrator
                  port: 8080
            - kind: Rule
              match: Host(`orch.oci.dcxxiv.com`)
              priority: 10
              middlewares:
                - name: authentik
                  namespace: authentik
              services:
                - name: orchestrator
                  port: 8080
          tls:
            secretName: orchestrator-tls
      target:
        kind: IngressRoute
        name: orchestrator
        namespace: orchestrator
    - patch: |
        apiVersion: helm.toolkit.fluxcd.io/v2
        kind: HelmRelease
        metadata:
          name: orchestrator
          namespace: orchestrator
        spec:
          values:
            replicaCount: 0
      target:
        kind: HelmRelease
        name: orchestrator
        namespace: orchestrator
```

- [ ] **Step 3: VALIDATE**

```bash
for f in deluge orchestrator; do
  echo "=== $f ==="
  grep "Host(" "clusters/oci-lab/${f}-kustomization.yaml"     # expect only oci.dcxxiv.com hosts
  grep -E "replicas: 0|replicaCount: 0" "clusters/oci-lab/${f}-kustomization.yaml"
done
```

Expected: every `Host(...)` match string in both files targets `*.oci.dcxxiv.com`; each file contains its zero-scaling line (`replicas: 0` for deluge's Deployment, `replicaCount: 0` for orchestrator's HelmRelease values).

- [ ] **Step 4: Commit**

```bash
git add clusters/oci-lab/deluge-kustomization.yaml clusters/oci-lab/orchestrator-kustomization.yaml
git commit -m "oci-lab: mirror deluge/orchestrator IngressRoutes at replicas 0"
```

---

## Task 9: `clusters/oci-lab/kustomization.yaml` aggregator

**Files:**
- Modify: `clusters/oci-lab/kustomization.yaml`

- [ ] **Step 1: Replace the placeholder `resources: []` with the full mirrored set**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  # `flux bootstrap` (run by bootstrap/terraform/oci-k3s) populates flux-system/.
  - flux-system/

  # k3s built-in Traefik configuration
  - traefik-config-kustomization.yaml

  # Foundation: certs (DNS01/Cloudflare, defines letsencrypt-prod) + storage
  - cert-manager-kustomization.yaml
  - cert-manager-http01-kustomization.yaml
  - cert-manager-config-kustomization.yaml
  - local-path-kustomization.yaml
  - longhorn-kustomization.yaml
  - cloudnative-pg-kustomization.yaml
  - postgres-kustomization.yaml
  - redis-kustomization.yaml
  - mariadb-kustomization.yaml

  # Core infrastructure
  - authentik-kustomization.yaml
  - monitoring-kustomization.yaml
  - weave-gitops-kustomization.yaml

  # Infrastructure tools
  - headlamp-kustomization.yaml
  - reloader-kustomization.yaml

  # Applications — all patched to replicas: 0 (warm standby, no live traffic;
  # see per-file patches). Hostnames rewritten to *.oci.dcxxiv.com.
  - personliness-kustomization.yaml
  - hero-kustomization.yaml
  - dcxxiv-home-kustomization.yaml
  - wordpress-kustomization.yaml
  - orchestrator-kustomization.yaml
  - deluge-kustomization.yaml
  - nodecast-tv-kustomization.yaml

  # Excluded from Phase 1 (see docs/superpowers/specs/2026-08-01-oci-warm-dr-standby-design.md §8
  # and this plan's Global Constraints / Scope notes):
  #   juggler-kustomization.yaml                 — amd64-only, no arm64 image
  #   juicefs-kustomization.yaml                 — dual-mount hazard: standby must not attach
  #                                                 the shared JuiceFS S3 data read-write
  #   juicefs-s3-gateway-kustomization.yaml       — depends on juicefs above
  #   agent-os-kustomization.yaml                 — excluded until PR #141 (arm64 image) lands
  #                                                 and is confirmed running
  #   longhorn-backup-kustomization.yaml          — no working backup target on OCI in Phase 1
  #   longhorn-backup-target-kustomization.yaml   — activates OVH's live shared S3 backup target;
  #                                                 standby must not touch it
```

- [ ] **Step 2: VALIDATE**

Full-repo kustomize + kubeconform pass (this is the first point where every file from Tasks 5-8 is actually assembled together):

```bash
kustomize build clusters/oci-lab | kubeconform -strict -ignore-missing-schemas -summary
```

Expected: exits 0, summary shows the ~21 Flux `Kustomization` CRs plus the base `flux-system/` resources (once `flux bootstrap` has populated it — until then, temporarily comment out `- flux-system/` locally to test the rest, since that directory does not exist pre-bootstrap and `kustomize build` will otherwise fail with "no such file or directory" for that one line only; do not commit it commented out).

Also confirm every excluded name really has no file present and every included name really does:

```bash
comm -3 \
  <(grep -oE '^\s*- [a-z0-9-]+-kustomization\.yaml' clusters/oci-lab/kustomization.yaml | awk '{print $2}' | sort) \
  <(ls clusters/oci-lab/*-kustomization.yaml | xargs -n1 basename | sort)
```

Expected: no output (every listed file exists, every existing file is listed).

- [ ] **Step 3: Commit**

```bash
git add clusters/oci-lab/kustomization.yaml
git commit -m "oci-lab: wire the full Phase 1 mirrored Kustomization set"
```

---

## Task 10: Verification

**Files:** none (operational verification only — run after a real `terraform apply` + `flux bootstrap`, which requires real cloud credentials this plan cannot supply).

- [ ] **Step 1: Confirm every Kustomization reconciles**

```bash
export KUBECONFIG=$(make kubeconfig-oci)
flux get kustomizations -A --watch
```

Expected: every Kustomization from Task 9's list reaches `Ready: True` (no `False` / stuck `Reconciling` after each `interval` window). This is also the **first real test of the arm64 image audit** — watch specifically for `ImagePullBackOff`/`exec format error` on `mariadb-galera` (bitnamilegacy image, verified arm64-compatible per its HelmRelease comment — confirm in practice), `redis-ha`/`haproxy` (official multi-arch images), `kube-prometheus-stack` components, and `authentik`.

- [ ] **Step 2: Confirm cert-manager issues an `oci.` cert without touching OVH's certs**

```bash
kubectl get certificate -A | grep oci.dcxxiv.com
kubectl describe certificate grafana-tls -n monitoring | grep -A3 "Status:"
```

Expected: at least one `Certificate` (e.g. `grafana-tls` in `monitoring`) shows `Ready: True` with a cert issued via `letsencrypt-prod`'s Cloudflare DNS01 solver for an `*.oci.dcxxiv.com` name. Separately, on the OVH cluster (different `KUBECONFIG`), confirm no existing `*.dcxxiv.com` certs were touched: `kubectl --kubeconfig=$(make kubeconfig-ovh) get certificate -A` shows unchanged `Ready`/`Not After` values from before this work started.

- [ ] **Step 3: Confirm apps are at zero replicas and platform apps are up**

```bash
kubectl get deploy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas | \
  grep -E "dcxxiv-home|hero|personliness|nodecast-tv|wordpress|deluge"
kubectl -n orchestrator get helmrelease orchestrator -o jsonpath='{.status.history[0].configDigest}' # sanity: HelmRelease reconciled
kubectl -n orchestrator get deploy orchestrator -o jsonpath='{.spec.replicas}'
```

Expected: `REPLICAS` is `0` for all 6 plain-Deployment apps; the orchestrator Deployment (rendered from its HelmRelease's `values.replicaCount: 0`) also shows `0`. Platform Deployments (cert-manager, longhorn-manager, authentik, kube-prometheus-stack, headlamp, weave-gitops, traefik, cloudnative-pg-operator, redis-ha, mariadb-galera) are running normally (not scaled down).

- [ ] **Step 4: Record known Phase 1 exit state (not a code change — informational)**

Confirm and note for the next phase (do not attempt to fix in Phase 1):
- CNPG `bootstrap.recovery` stanza still doesn't exist anywhere (tracked on `feat/cnpg-bootstrap-recovery`, must be authored **fresh-cluster-only**, after the #144 revert, before Phase 2's restore work).
- Authentik OIDC redirect-URI automation for `oci.` hostnames doesn't exist yet (Phase 3).
- No real data has been restored anywhere (Phase 2).

No commit for this task (verification/observation only, run against a live applied cluster).

---

## Self-review against the spec

Coverage check against `docs/superpowers/specs/2026-08-01-oci-warm-dr-standby-design.md` §8 (Phase 1 scope) and the full spec:

- **§1 GitOps structure (Option B, inline patches):** Tasks 5-9 — every OCI variance lives in `clusters/oci-lab/*-kustomization.yaml` `patches:` blocks, zero edits to shared `infrastructure/`/`apps/` manifests. ✓
- **§2 DNS (distinct `*.oci.dcxxiv.com` subdomain, Cloudflare, no apex changes):** Task 4 (`dns.tf`) + Tasks 6-8 (every hostname patch uses the `oci.` subdomain). No `manage_apex_dns`/promotion-cutover code — that's explicitly Phase 3, not built here. ✓
- **§3 Stateful data (Postgres/MariaDB/Longhorn empty in Phase 1, JuiceFS excluded, no dual-mount):** Scope notes #1-2 + Task 5 (postgres backup-disable patch) + Task 9 (juicefs* excluded from the aggregator). Real restore/rehearsal cadence is explicitly Phase 2, not attempted here. ✓
- **§4 App coordination (distinct hostnames + `replicas: 0`):** Tasks 7-8. ✓
- **§5 Storage sizing (dedicated Block Volume, ~195/200 GB):** Task 3. ✓
- **§6 Bootstrap runbook steps 1-5, 9-10 (S3 state, apply, age key, mirrored kustomization set, cert-manager, apps at 0):** Tasks 1-4 (Terraform), Tasks 5-9 (GitOps), Task 10 (verification steps 1-3) cover these; steps 6-8 (CNPG restore, MariaDB restore, JuiceFS metadata load, Authentik OIDC Terraform) are Phase 2/3 and correctly not attempted here. Step 11 (record rehearsal in `dr.md`) is a Phase 2 rehearsal-log concern, not applicable to a Phase 1 platform-only stand-up (noted, not actioned).
- **§7 Prerequisites:** #1 (CNPG recovery stanza) and #6 (dns.tf/Authentik automation) are addressed to the extent Phase 1 owns them (`dns.tf` built; CNPG recovery correctly left to its own branch). #4 (never-applied module) and #5 (no S3 state) are directly resolved by Tasks 2-4. #2 (agent-os arm64) and #3 (stale JuiceFS example) are out of this plan's scope (agent-os is excluded per decision #6 in the spec; the stale example fix is an independent, unrelated cleanup not mentioned in the Phase 1 task brief — not added here to avoid scope creep beyond what was asked).
- **§8 Phase 1 itself:** every named component (Terraform apply readiness, age key install note, mirrored `clusters/oci-lab/*`, apps at `replicas: 0`, cert-manager DNS01, storage sizing, `dns.tf`) has a corresponding task above.
- **Decisions (locked) #1-6:** all directly implemented (Option B structure, Option A DNS, Option B storage, A+B app coordination, split refresh cadence — not applicable to Phase 1's empty-data scope — and agent-os exclusion).

**Placeholder scan:** no `TBD`/`TODO`/"similar to Task N" patterns; every YAML/HCL block above is complete, copy-pasteable content, not a description of what to write.

**Type/name consistency check:** `data_volume_size_gbs` (Task 3) is referenced identically in `variables.tf`, `storage.tf`, `locals.tf`'s guardrail, and `cloud-init.tf`'s three `templatefile()` calls — no `data_volume_size_gb` (OVH's singular-GB spelling, deliberately not reused) vs. `data_volume_size_gbs` mismatch anywhere. `data_mount_point` is likewise consistent across `variables.tf`, `cloud-init.tf`, and `server.yaml.tftpl`. Kustomization `dependsOn` names (`cert-manager-config`, `longhorn`, `postgres`, `shared-redis`, `mariadb`, `authentik`) match the `metadata.name` set in each corresponding Task 5/6 file exactly (e.g. `redis-kustomization.yaml`'s `metadata.name: shared-redis`, matching every `dependsOn: - name: shared-redis` reference in Tasks 7-8).

**Decisions/gaps to flag back to the requester (not silently assumed):**
1. `longhorn-backup`/`longhorn-backup-target` additionally excluded (spec's exclusion list only named juggler/juicefs*/agent-os).
2. CNPG backup patch (remove `/spec/backup`, delete `ScheduledBackup`) added to Phase 1 itself — the spec's §3 warning was written for the *restore*-time case; it applies equally to an unpatched fresh cluster, which Phase 1 would otherwise create.
3. `dcxxiv-home` mapped to `oci.dcxxiv.com`/`www.oci.dcxxiv.com` (no natural `<name>.oci.dcxxiv.com` reading exists for an apex-serving Ingress).
4. `GITHUB_TOKEN` added to `oci-k3s/secrets.sops.yaml` (needed by `flux.tf`'s own `null_resource`, beyond the two credential types named in the task brief).
5. Grafana's embedded OIDC URLs (`auth_url`/`token_url`/`api_url`/`signout_redirect_url`) repointed to OCI's own Authentik for consistency — functionally still won't complete a login until Phase 3 registers the OIDC client, but avoids an obviously-wrong cross-cluster URL sitting in the manifest.
6. A third `precondition` (total block storage ≤ 200 GB) added to the existing OCPU/memory guardrail in `locals.tf` — not explicitly requested, but directly enforces the Global Constraint and matches the existing guardrail pattern.
