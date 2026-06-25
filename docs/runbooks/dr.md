# Disaster Recovery Runbook

Authoritative recovery procedure for the OVH `clusters/ovh-lab` cluster. Written to be
followed cold — assume the cluster is gone and you are starting from this repo + your
SSH key + the AWS backup buckets.

> **Provisioning vs. recovery.** How the clusters are *built* lives in
> [`bootstrap/BOOTSTRAP.md`](../../bootstrap/BOOTSTRAP.md) and the terraform module READMEs.
> This file is only about *recovering* from loss. Recovery reuses the provisioning steps.

---

## 1. What is backed up, and where

| Asset | Mechanism | Location / schedule |
|-------|-----------|---------------------|
| **SOPS secrets** | Committed to Git, SOPS+age encrypted | every `*.sops.yaml` in this repo |
| **age private key** (root of trust) | Encrypted to your SSH key, committed | `bootstrap/age.agekey.age` → `make recover-age-key` |
| **Longhorn volumes** | `RecurringJob backup-daily` → S3 | `s3://<bucket>@us-west-2/longhorn`, daily 03:00 UTC, retain 7 (+ `snapshot-6h` local, retain 8) |
| **Postgres (CNPG)** | Barman object store + `ScheduledBackup pg-daily` | `s3://k3s-lab-backups/postgres/pg`, daily 03:00 UTC, WAL+data gzip, 30d retention |
| **MariaDB (WordPress)** | Nightly `mysqldump` CronJob → S3 | `s3://k3s-lab-backups/mysql/wordpress/<ts>.sql.gz`, daily 03:00 UTC |
| **JuiceFS metadata** | `juicefs dump` CronJob → S3 | `s3://k3s-lab-backups/juicefs/meta-<ts>.json`, daily 04:00 UTC |

**Critical fact:** JuiceFS metadata lives in **Redis-HA, database 2** (`infrastructure/database/redis`).
Redis-HA is 3-node HA but runs on **local-path, not Longhorn** — so the nightly `juicefs dump` to
S3 is the *only offsite copy of the filesystem map*. Without it, JuiceFS data on S3 is unreadable.

Backup credentials are themselves SOPS secrets (`s3-backup-creds` per namespace,
`longhorn-backup-secret`, `juicefs-meta-backup-creds`) — they come back with the repo once the age
key is restored. Buckets are in AWS S3, region `us-west-2`.

---

## 2. Total cluster loss — recovery order

Order matters. Each step depends on the previous one.

### Step 1 — DNS
Confirm your domains still resolve to (or can be repointed at) the node public IPs. cert-manager
re-issues TLS automatically via the Cloudflare DNS01 ClusterIssuer once it is running, so no cert
backup is needed — just working DNS.

### Step 2 — Provision nodes
```bash
make apply-ovh        # OVH 3-node HA cluster (spans OVH / Vultr / Hetzner VPS via WireGuard)
```
See [`bootstrap/terraform/ovh-k3s/README.md`](../../bootstrap/terraform/ovh-k3s/README.md). The OCI
cluster is separate — `bootstrap/terraform/oci-k3s/`.

### Step 3 — Restore the root of trust
Nothing decrypts until the age key is in the cluster.
```bash
make recover-age-key      # decrypt bootstrap/age.agekey.age with your ~/.ssh/id_rsa → /tmp
make install-sops-age     # install it as the sops-age Secret in flux-system
```

### Step 4 — Bootstrap Flux
```bash
make flux-bootstrap-ovh-lab
```
Flux reconciles the whole repo. Watch it: `flux get kustomizations -A --watch`. Most workloads come
up on their own from here; the stateful pieces below need restore actions.

### Step 5 — Storage (Redis → JuiceFS → Longhorn, in that order)
1. **Redis-HA must be healthy first** — it holds the JuiceFS metadata. Confirm the `redis`
   StatefulSet/pods are Ready before touching JuiceFS.
2. **Restore JuiceFS metadata** *only if Redis data was lost* (fresh local-path volumes start empty).
   Load the most recent dump back into Redis DB 2 — the inverse of the backup's `juicefs dump`:
   ```bash
   # pull newest dump
   aws s3 ls s3://k3s-lab-backups/juicefs/ | sort | tail -1
   aws s3 cp s3://k3s-lab-backups/juicefs/meta-<ts>.json /tmp/meta.json
   # load into the metadata engine (METAURL = redis://...:6379/2 from the juicefs-secret)
   juicefs load "$METAURL" /tmp/meta.json
   ```
   If Redis came back with its data intact (HA survived), skip this — the metadata is already live.
3. **Longhorn volumes** — restore from S3. In the Longhorn UI (or via CRDs), the BackupTarget
   reconnects automatically (`backupTargetURL` comes from the SOPS-encrypted `backup-target-vars`).
   For each volume, restore the latest backup and let the PVC bind. New PVCs created by Flux that
   should carry restored data must be restored from backup, not left empty.

### Step 6 — Databases
1. **Postgres (CNPG)** — recover from the Barman object store. CNPG bootstraps a fresh cluster from
   `s3://k3s-lab-backups/postgres/pg` via a `bootstrap.recovery` stanza referencing the backup (see
   the `barmanObjectStore` block in `infrastructure/database/postgres/cluster.yaml`). This restores
   the `authentik` and `personliness` databases. **Not yet DR-tested — verify the recovery stanza
   before relying on it.**
2. **Re-apply Authentik config** after its database is back:
   ```bash
   make dr-authentik     # nukes stale Terraform state and re-applies Authentik
   ```
3. **MariaDB (WordPress)** — restore the latest dump:
   ```bash
   aws s3 ls s3://k3s-lab-backups/mysql/wordpress/ | sort | tail -1
   aws s3 cp s3://k3s-lab-backups/mysql/wordpress/<ts>.sql.gz - | gunzip \
     | mysql --host=mariadb-galera --user=root --password=<root-pw> wordpress
   ```
   Note the Galera caveats baked into `mariadb/backup-cronjob.yaml` (DEFINER clauses, MyISAM→InnoDB,
   PRIMARY KEY requirement) if importing into a fresh Galera cluster.

### Step 7 — Apps & verify
Remaining apps reconcile from Git automatically. Run the verification checklist (§4).

---

## 3. Single-scenario runbooks

**Single node loss / replacement.** Re-run `make apply-ovh` to re-provision the node. Longhorn
rebuilds replicas onto it; CNPG recreates its replica (one instance per node via required
pod-anti-affinity). No restore-from-S3 needed as long as a quorum survived.

**Longhorn volume restore (single volume).** Longhorn UI → Backup → select volume → Restore. The
BackupTarget is already wired via `longhorn-backup-secret`. Create a PVC from the restored volume.

**Postgres restore / PITR.** Use CNPG's `bootstrap.recovery` against `s3://k3s-lab-backups/postgres/pg`.
Follow with `make dr-authentik` so Authentik's Terraform-managed objects match the restored DB.

**MariaDB restore.** See Step 6.3 — pull the newest `.sql.gz` from S3 and import.

**JuiceFS metadata recovery.** See Step 5.2 — `juicefs load` the newest S3 dump into Redis DB 2.
Redis must be up first; JuiceFS mounts fail without readable metadata.

**age key loss / SSH key rotation.**
```bash
make rotate-ssh-key      # after rotating ~/.ssh/id_rsa — re-encrypts the age key backup to the new key
make bootstrap-age-key   # DANGER: only on first setup or key compromise — generates a NEW keypair,
                         # after which every *.sops.yaml must be re-encrypted
```

---

## 4. Post-recovery verification

```bash
flux get all -A                 # everything Reconciled, no failures
make verify-encryption          # all *.sops.yaml are ciphertext (none slipped through plaintext)
make verify-roundtrip           # every secret decrypts to valid YAML
kubectl get pods -A | grep -vE 'Running|Completed'   # nothing stuck
```
Then smoke-test the user-facing apps (auth login via Authentik, a JuiceFS-backed app, the WordPress
site) and confirm TLS certs are `Ready` (`kubectl get certificate -A`).

---

## 5. DR rehearsal log

Recovery steps 5–6 (storage + database restore) are **not routinely exercised**. Rehearse them and
record results here so the procedure is trusted before you need it for real.

| Date | Scope tested | Result | Notes |
|------|--------------|--------|-------|
| _—_ | _—_ | _—_ | _not yet rehearsed_ |
