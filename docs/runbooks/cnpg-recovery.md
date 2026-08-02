# CloudNativePG Recovery Runbook

Authoritative recovery procedure for the `pg` CloudNativePG (CNPG) Postgres cluster
(namespace `postgres`). Written to be followed cold — assume you are starting from this
repo, `kubectl` access to the cluster, and the AWS S3 backup bucket, with no other context.

> This is a deep-dive on one datastore. [`docs/runbooks/dr.md`](dr.md) §2 Step 6.1 covers
> Postgres as one piece of a whole-cluster-loss sequence — read that first if you're
> recovering more than just Postgres. This file is the thing it points to.

---

## 1. Context

| Fact | Value |
|------|-------|
| Cluster object | `Cluster/pg` in namespace `postgres` (`infrastructure/database/postgres/cluster.yaml`) |
| Topology | 3 instances: 1 primary + 2 replicas, one per node (`enablePodAntiAffinity: required`, `topologyKey: kubernetes.io/hostname`) |
| Postgres image | `ghcr.io/cloudnative-pg/postgresql:16` |
| Storage | `local-path` — **node-local, not replicated at the block level.** There is no volume snapshot or Longhorn-style backup under these PVCs; streaming replication + the Barman WAL archive are the only recovery mechanisms if a PVC is lost. |
| Operator | `HelmRelease/cloudnative-pg` in `cnpg-system` (`infrastructure/database/cloudnative-pg/helmrelease.yaml`), chart `0.29.0` → **operator/appVersion `1.30.0`** (confirmed against the chart's `index.yaml`; see the version gotcha in §5) |
| Databases | `personliness` (owner role `personliness`) and `authentik` (owner role `authentik`), declared via CNPG `Database` CRDs |
| Replication mode | Operator-managed automatic failover — async streaming replication to both standbys by default (no `synchronous` stanza set in `cluster.yaml`) |
| Backups | WAL + base backups to `s3://k3s-lab-backups/postgres/pg` via `spec.backup.barmanObjectStore`, gzip compression, `retentionPolicy: "30d"` |
| Backup schedule | `ScheduledBackup/pg-daily`, cron `"0 0 3 * * *"` — CNPG uses a 6-field cron (`sec min hour dom month dow`), so this is **03:00:00 UTC daily** |

The operator handles primary/replica election and replica rebuilds on its own for pod- and
node-level failures. Manual action is mostly needed for planned maintenance (switchover) and
total loss (restore from Barman).

---

## 2. Failure modes

**(a) Primary pod/node failure.** The operator promotes the standby with the lowest
replication lag automatically — no action required in the common case. The `pg-rw` Service
endpoint repoints to the new primary on its own. Confirm it happened correctly with §3.1
below; don't assume, verify.

**(b) A replica is down or badly lagging.** The operator restarts it in place if its PVC is
still usable, or rebuilds it from the primary via `pg_basebackup`/streaming replication if
not. Usually self-heals; §3.3 covers forcing a rebuild if it doesn't.

**(c) Planned switchover** (e.g. draining a node for maintenance). Use `kubectl cnpg
promote` (§3.2) rather than killing the primary pod — it's a controlled handoff instead of
a failover.

**(d) Whole cluster lost** (all 3 PVCs gone / cluster deleted / disaster recovery from
nothing). Restore from the Barman S3 store into a **newly created** `Cluster` object — see
§3.4. This is the exact mechanic `docs/superpowers/specs/2026-08-02-ovh-to-oci-migration.md`
§4 ("Per-datastore data migration → Postgres / CNPG") relies on for standing up Postgres on
a fresh cluster, and it has a sharp edge:

> **`spec.bootstrap.recovery` is only evaluated when the `Cluster` object is first
> created.** Applying it to a `Cluster` that already exists is a no-op — CNPG will not
> retroactively restore live data into a running cluster. This was learned the hard way:
> PR #144 (`b824c56`) added `bootstrap.recovery` + `externalClusters` directly to this
> repo's live `cluster.yaml` and was reverted same-day as PR #146 (`73164b2`) because it did
> nothing against the already-running OVH `pg` cluster. **To actually restore, the `Cluster`
> object must not already exist** — delete it first (safe once you've confirmed there's
> nothing you still need from it) or give the restored cluster a different name, then create
> fresh with the recovery stanza.

**(e) PVC/storage loss on a single instance** (disk failure, node reprovisioned, PVC
deleted by hand). Because storage is `local-path`, there is no snapshot to restore that PVC
from — the operator's own rebuild-via-replication is the recovery path. If it doesn't
self-heal, force it per §3.3.

---

## 3. Recovery procedures

Install the plugin first if it isn't already present (client-side only, no cluster
permissions needed beyond your existing kubeconfig):

```bash
kubectl krew install cnpg
# or, without krew:
curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh \
  | sudo sh -s -- -b /usr/local/bin
```

### 3.1 Check cluster status (always start here)

```bash
kubectl cnpg status pg -n postgres
```

Read for: which pod is primary, `Instances status` showing all 3 as `OK`, the streaming
replication table (per-replica Write/Flush/Replay lag — should be small and stable, not
climbing), and the backup/WAL-archiving section (`Last Archived WAL` should be recent, no
`Last Failed WAL`). Add `-v` (repeatable) for Postgres config, HBA rules, and certificate
detail.

Raw-`kubectl` fallback if the plugin isn't available:

```bash
kubectl get cluster pg -n postgres -o wide
kubectl get pods -n postgres -l cnpg.io/cluster=pg -o wide
kubectl get cluster pg -n postgres -o jsonpath='{.status.currentPrimary}{"\n"}'
```

### 3.2 Manual switchover / promote (planned maintenance)

```bash
kubectl cnpg promote pg <instance> -n postgres
# <instance> is either the ordinal number (2) or the full pod name (pg-2)
kubectl cnpg promote pg 2 -n postgres
```

This is a controlled handoff — the current primary is demoted to standby and rejoins as a
replica. Prefer this over deleting the primary pod for anything planned.

Raw-`kubectl` fallback: there is no clean raw-kubectl equivalent (the plugin talks to the
operator's own switchover API). If the plugin truly isn't available, deleting the current
primary pod (`kubectl delete pod <primary-pod> -n postgres`) forces the same automatic
failover path as §2(a) — less controlled (you don't pick which replica wins, the operator
does, by lowest lag), but it works in a pinch.

### 3.3 Force a replica rebuild

If a replica's PVC is corrupted/unusable and the operator hasn't already replaced it:

```bash
kubectl cnpg destroy pg <instance-number> -n postgres
# example: kubectl cnpg destroy pg 2 -n postgres
```

This removes the instance's PVCs and pod; the operator creates a fresh pod + PVC pair and
rebuilds it via streaming replication from the current primary. Use `--keep-pvc` instead if
you want to detach (not delete) the PVC for inspection first.

Raw-`kubectl` fallback (PVC must be deleted *before* the pod, in the same command, so the
operator doesn't just recreate a StatefulSet-style pod against the stale PVC):

```bash
kubectl delete -n postgres pvc/pg-2 pod/pg-2
```

### 3.4 Full restore from the Barman S3 store (whole cluster lost)

1. **Confirm the target `Cluster` object does not already exist**, or delete it (and its
   PVCs, which are useless if you're restoring):
   ```bash
   kubectl delete cluster pg -n postgres
   kubectl delete pvc -n postgres -l cnpg.io/cluster=pg
   ```
2. **Apply a new `Cluster` manifest** with `spec.bootstrap.recovery` + `spec.externalClusters`
   pointing at the Barman store. Reuse the stanza already authored (and reverted) on the
   `feat/cnpg-bootstrap-recovery` branch (`b824c56`) rather than re-deriving it — the
   `externalClusters` block below is a **read-only recovery source reference**, so it's safe
   even if the source path is still being actively written to:
   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: pg
     namespace: postgres
   spec:
     instances: 3
     imageName: ghcr.io/cloudnative-pg/postgresql:16
     storage:
       size: 10Gi
       storageClass: local-path
     affinity:
       enablePodAntiAffinity: true
       topologyKey: kubernetes.io/hostname
       podAntiAffinityType: required
     bootstrap:
       recovery:
         source: pg-backup
         # Omit recoveryTarget to restore to the latest available backup/end of WAL.
         # For PITR instead, add e.g.:
         # recoveryTarget:
         #   targetTime: "2026-08-01 03:00:00+00"
     externalClusters:
       - name: pg-backup
         barmanObjectStore:
           destinationPath: s3://k3s-lab-backups/postgres/pg
           s3Credentials:
             accessKeyId: {name: s3-backup-creds, key: AWS_ACCESS_KEY_ID}
             secretAccessKey: {name: s3-backup-creds, key: AWS_SECRET_ACCESS_KEY}
             region: {name: s3-backup-creds, key: AWS_DEFAULT_REGION}
           wal:
             compression: gzip
     # This restored cluster's OWN go-forward backup target — see the gotcha below.
     backup:
       barmanObjectStore:
         destinationPath: s3://k3s-lab-backups/postgres/pg-restored
         s3Credentials:
           accessKeyId: {name: s3-backup-creds, key: AWS_ACCESS_KEY_ID}
           secretAccessKey: {name: s3-backup-creds, key: AWS_SECRET_ACCESS_KEY}
           region: {name: s3-backup-creds, key: AWS_DEFAULT_REGION}
         wal:
           compression: gzip
         data:
           compression: gzip
       retentionPolicy: "30d"
     managed:
       roles:
         - name: personliness
           login: true
           passwordSecret: {name: personliness-role-secret}
         - name: authentik
           login: true
           passwordSecret: {name: authentik-role-secret}
   ```
   > **Shared-WAL-path corruption gotcha.** `externalClusters[].barmanObjectStore` above is
   > only ever *read* — that's fine pointed at the live source path. But the restored
   > cluster's own `spec.backup.barmanObjectStore.destinationPath` (used for its future
   > backups) **must be a distinct path**, never the path it recovered from. Two independent
   > Postgres timelines archiving WAL to the same Barman prefix corrupts the backup chain for
   > both. This is exactly the hazard called out in `b824c56`'s own inline comment and in
   > `docs/superpowers/specs/2026-08-02-ovh-to-oci-migration.md` §4. Pick a new path (e.g.
   > `pg-restored`, or `pg-oci` if this is the OCI-standby-becomes-primary case from that
   > spec) and keep it permanently — there's no benefit to later "reclaiming" the old path.
3. **Apply it and watch the restore job**, then the instances join:
   ```bash
   kubectl apply -f cluster.yaml
   kubectl get pods -n postgres -l cnpg.io/cluster=pg -w
   ```
   The first pod runs a restore job (`pg-1-full-recovery` or similar) that pulls the base
   backup and replays WAL; instances 2 and 3 then join as streaming replicas once the
   primary is up.
4. **Re-apply the `Database` CRDs** (`personliness`, `authentik`) if not already reconciled
   by Flux — this is idempotent against data already present in the restored backup; CNPG
   reconciles existing databases rather than recreating them.
5. **Confirm role password secrets exist** (`personliness-role-secret`,
   `authentik-role-secret`) — these are SOPS-encrypted in Git and come back once the age key
   is restored (`docs/runbooks/dr.md` §2 Step 3), same as everything else in this repo.
6. **Update `ScheduledBackup/pg-daily`** if needed — it targets `cluster: {name: pg}` by
   name, so it picks the restored cluster up automatically; just confirm it's actually
   running against the new `destinationPath` (§4).
7. Apps don't need reconfiguring — same Service names (`pg-rw`/`pg-ro`/`pg-r`), same DB/role
   names, same as the note in `cluster.yaml` about `POSTGRES_HOST` being the only thing that
   changes at cutover.

---

## 4. Verification

```bash
kubectl cnpg status pg -n postgres
```
Confirm all of:
- **3/3 instances** listed and `OK`.
- **A primary is elected** and it's a pod you expect (`status.currentPrimary`).
- **Replication lag** on both replicas is small and not climbing (Write/Flush/Replay lag
  columns).
- **WAL archiving resumed** — `Last Archived WAL` timestamp is recent (within the last WAL
  switch/archive_timeout window), no `Last Failed WAL` entry.

```bash
kubectl get pods -n postgres -l cnpg.io/cluster=pg
kubectl get cluster pg -n postgres -o jsonpath='{.status.currentPrimary}{"\n"}'
kubectl get databases -n postgres
```
All pods `Running`/`Ready`; both `Database` objects `Ready`.

Prove the backup path actually works end-to-end after any restore, don't just trust the
config — trigger an on-demand backup and check it lands:
```bash
kubectl cnpg backup pg -n postgres
kubectl get backup -n postgres --watch
```

---

## 5. Prevention notes

- **`ScheduledBackup/pg-daily`** runs 03:00:00 UTC daily to
  `s3://k3s-lab-backups/postgres/pg`, gzip WAL + data, **30-day retention**
  (`retentionPolicy: "30d"`).
- **PITR is available**, not just latest-backup restore — add a `recoveryTarget` block
  (`targetTime`, `targetLSN`, `targetName`, or `targetXID`) inside `bootstrap.recovery` at
  restore time (§3.4 step 2) to roll forward to any point within the 30-day WAL retention
  window instead of the most recent backup.
- **`local-path` storage has no snapshot safety net.** Unlike Longhorn-backed volumes
  elsewhere in this repo, CNPG's PVCs are node-local with nothing to fall back to if a disk
  dies — the Barman backup chain above *is* the disaster-recovery mechanism for this
  cluster, not a supplement to one.
- **Operator version / in-tree backup deprecation — action needed before the next chart
  bump.** `infrastructure/database/cloudnative-pg/helmrelease.yaml` pins chart `0.29.0`
  (operator/appVersion `1.30.0`, confirmed against the chart repo's `index.yaml`), but its
  own inline comment is stale — it still says "chart 0.23.2 → operator 1.25.1" and warns not
  to bump past chart `0.23.x` because CNPG 1.26 deprecated the in-tree
  `spec.backup.barmanObjectStore` S3 syntax this cluster uses. That guardrail has already
  been silently crossed (current pin is 0.29.0, well past 0.23.x) but still works today only
  because CNPG's own deprecation timeline has slipped: in-tree Barman Cloud support is
  deprecated since 1.26 and, per the upstream 1.28.4 release notes, is now slated for
  **removal in 1.31.0**. The running operator (1.30.0) is one minor version away from that.
  **Before bumping the `cloudnative-pg` chart again**, migrate `backup.barmanObjectStore` /
  `externalClusters` (both here and in any restore manifest built from §3.4) to the Barman
  Cloud Plugin + `ObjectStore` CR — otherwise both `ScheduledBackup/pg-daily` and this
  runbook's §3.4 restore path stop working with no other warning than a future upgrade
  quietly breaking backups.
- **Not yet rehearsed for real.** `docs/runbooks/dr.md` §5 tracks DR rehearsal status
  cluster-wide and already flags Postgres restore as untested — log any real run of §3.4
  here or there once it happens.
