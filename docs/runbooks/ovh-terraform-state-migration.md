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

> **Checkout the branch/commit that introduces the S3 backend first.** The `backend "s3"` block
> lives in `versions.tf`, added by the commit that migrates this root to S3 (currently
> `feat/ovh-k3s-s3-remote-state`). Before that lands on `main`, `main`'s `versions.tf` still pins
> the `cloudflare` provider to `~> 5.0`, which conflicts with the `4.52.7` version locked in state —
> `init`/`plan` fail with a provider-version error, and there is no backend block to migrate to
> anyway. Run:
> ```bash
> git checkout <branch-or-commit-with-the-s3-backend> && git pull
> ```
> before starting §4. Once this work merges to `main`, running from `main` is fine again.

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
`tf.sh` already defaults `SOPS_AGE_KEY_FILE` to `/tmp/k3s-lab-age.agekey` (where `make
recover-age-key` writes it), so no `export` is needed when invoking `./tf.sh`.
```bash
cd bootstrap/terraform/ovh-k3s

# Baseline BEFORE migrating. `terraform state list` cannot be used here: once the `backend "s3"`
# block is present but not yet initialized, Terraform errors with "Backend initialization
# required". Parse the local state file directly instead — needs no backend init.
python3 -c "
import json
d=json.load(open('terraform.tfstate'))
out=[( (r.get('module','')+'.') if r.get('module') else '')+r['type']+'.'+r['name']
      for r in d.get('resources',[])]
print('\n'.join(sorted(out)))
" > /tmp/pre-migrate.txt
wc -l /tmp/pre-migrate.txt   # sanity: > 0
ls -la terraform.tfstate     # confirm local state is actually present here

./tf.sh init -migrate-state  # answer "yes" to copy state to S3
```
If Terraform does **not** prompt to copy existing state into the new backend, STOP — you are either
in the wrong directory or the local state is empty/missing. Do not answer "yes" to anything until
you understand why.

### Step 3 — Verify
| Check | Command | Expect |
|-------|---------|--------|
| State contents look sane | `./tf.sh state list \| sort \| diff - /tmp/pre-migrate.txt` | differences expected, see below |
| Local backup exists | `ls -la terraform.tfstate.backup` | present (Terraform's pre-migration safety copy) |
| S3 object exists (optional) | `aws s3api head-object --bucket k3s-lab-backups --key terraform/state/ovh-k3s --region us-west-2` (needs AWS creds in env — see note) | 200 response |
| No drift | `./tf.sh plan` | **"No changes."** |

> The `diff` above will show **cosmetic** differences only, not a real mismatch. The raw-file
> parse used for `/tmp/pre-migrate.txt` lists each resource once (e.g. `cloudflare_record.apex`),
> while `state list` expands `count`/`for_each` instances into addressed form (e.g.
> `cloudflare_record.apex["..."]`, `openstack_compute_instance_v2.rest[0]`). Same resources,
> different address formatting — do not treat this diff as authoritative.
>
> The **authoritative** success check is `./tf.sh plan` reporting **"No changes."** Do not consider
> the migration done until `plan` confirms it, regardless of what the `diff` shows. If `plan`
> reports any creates or destroys, treat it as a failed migration — see §5.
>
> The optional `aws s3api head-object` row runs `aws` directly (not through `tf.sh`), so it needs
> AWS credentials in the environment. Decrypt them from SOPS first:
> ```bash
> export SOPS_AGE_KEY_FILE=/tmp/k3s-lab-age.agekey   # raw sops call needs this; tf.sh sets it itself
> export AWS_ACCESS_KEY_ID=$(sops -d secrets.sops.yaml | python3 -c "import sys,yaml;print(yaml.safe_load(sys.stdin)['AWS_ACCESS_KEY_ID'])")
> export AWS_SECRET_ACCESS_KEY=$(sops -d secrets.sops.yaml | python3 -c "import sys,yaml;print(yaml.safe_load(sys.stdin)['AWS_SECRET_ACCESS_KEY'])")
> ```

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
