# OVH Terraform State Migration (local → S3)

One-time procedure to move the `ovh-k3s` Terraform root from local state to the S3 backend.
Written to be followed cold on whichever machine currently holds the authoritative local state.

> **Related.** See [`dr.md`](dr.md) for cluster disaster recovery and
> [`bootstrap/BOOTSTRAP.md`](../../bootstrap/BOOTSTRAP.md) for how the clusters are provisioned.
> This file is only about the *one-time state backend cutover* for `bootstrap/terraform/ovh-k3s`.

---

## 1. Context

Before this migration, `bootstrap/terraform/ovh-k3s` used Terraform's default **local** state
(`terraform.tfstate`). That file is git-ignored, so it exists **only** on whichever machine last ran
`terraform apply` there — no redundancy, no locking, no shared source of truth.

The migration adds an S3 backend, defined in `versions.tf`:

| Setting | Value |
|---------|-------|
| Bucket | `k3s-lab-backups` |
| Key | `terraform/state/ovh-k3s` |
| Region | `us-west-2` |
| Locking | `use_lockfile = true` (S3-native lock, no DynamoDB table) |
| Encryption | `encrypt = true` |
| Terraform version | `>= 1.10.0` required |

AWS credentials come from `secrets.sops.yaml` — `tf.sh` decrypts it and exports the keys as env vars
before invoking `terraform`. This reuses the existing Longhorn-backup IAM identity, which is already
scoped to the `k3s-lab-backups` bucket; no new IAM setup is needed.

---

## 2. The ordering rule

> **Do not run a bare `terraform init` first.** `-migrate-state` must be the *first* `init` run
> against the new S3 backend. A bare `init` initializes an **empty** S3 state, and the next `plan`
> or `apply` will show the entire OVH cluster as new — meaning `apply` would try to destroy and
> recreate every resource in the cluster.
>
> If a post-migration `plan` shows **any** creates or destroys, STOP. Do not apply. Go to §5 (rollback).

---

## 3. Precondition

Run this on the machine holding the current local `bootstrap/terraform/ovh-k3s/terraform.tfstate`
(or `scp` a copy of it into that directory first — do not proceed without it).

```bash
terraform version   # confirm >= 1.10.0
```

---

## 4. Migrate

### Step 1 — Recover the age key
```bash
make recover-age-key
```
Decrypts `bootstrap/age.agekey.age` with `~/.ssh/id_rsa` → `/tmp/k3s-lab-age.agekey`, `chmod 600`.

### Step 2 — Baseline, then migrate
```bash
cd bootstrap/terraform/ovh-k3s
export SOPS_AGE_KEY_FILE=/tmp/k3s-lab-age.agekey

terraform state list > /tmp/pre-migrate.txt   # baseline BEFORE migrating — do this first
ls -la terraform.tfstate                      # confirm local state is actually present here

./tf.sh init -migrate-state                   # answer "yes" to copy state to S3
```
If Terraform does **not** prompt to copy existing state into the new backend, STOP — you are either
in the wrong directory or the local state is empty/missing. Do not answer "yes" to anything until
you understand why.

### Step 3 — Verify
| Check | Command | Expect |
|-------|---------|--------|
| State contents unchanged | `./tf.sh state list \| diff - /tmp/pre-migrate.txt` | no diff |
| Local backup exists | `ls -la terraform.tfstate.backup` | present (Terraform's pre-migration safety copy) |
| S3 object exists (optional) | `aws s3api head-object --bucket k3s-lab-backups --key terraform/state/ovh-k3s --region us-west-2` | 200 response |
| No drift | `./tf.sh plan` | **"No changes."** |

Do not consider the migration done until `plan` reports no changes. If it reports any creates or
destroys, treat it as a failed migration — see §5.

---

## 5. Rollback

If `plan` shows unexpected changes, or the S3 copy looks wrong, do **not** `apply`.

1. Temporarily comment out the `backend "s3"` block in `versions.tf`.
2. Restore the pre-migration state:
   ```bash
   cp terraform.tfstate.backup terraform.tfstate
   terraform init -migrate-state   # migrates back to local
   ```
   Alternatively, pull the S3 copy down instead of using the local backup:
   ```bash
   aws s3 cp s3://k3s-lab-backups/terraform/state/ovh-k3s terraform.tfstate.recovered --region us-west-2
   ```
3. Confirm `terraform plan` shows no changes before doing anything else.
4. If retrying the migration, `rm -rf .terraform` first for a clean re-init, then repeat §4 from
   Step 2.

---

## 6. Known trap

> **Note:** `make init-ovh` calls `terraform init` directly — it does not go through `tf.sh`, so it
> has no AWS credentials in its environment. Against the S3 backend it will fail unless ambient AWS
> creds happen to be present. Use `./tf.sh init ...` for the `ovh-k3s` root instead of `make init-ovh`
> until that target is fixed to route through `tf.sh`.
