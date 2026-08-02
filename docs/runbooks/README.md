# Recovery Runbooks — Start Here

This is the **single entry point** for recovering the k3s-lab cluster from any failure,
from a single degraded volume to total cluster loss. It triages the problem, points you at
the one runbook that covers it, and — critically — encodes the **order** in which the HA
subsystems must come back, because several of them depend on each other.

> Don't read all of these top to bottom. Find your symptom in §1, go to that runbook, come
> back here only if you need the cross-component ordering in §3.

---

## 1. Triage — what broke?

| Symptom | Go to |
|---------|-------|
| **Whole cluster is gone / rebuilding from nothing** (lost provider, wiped nodes, DR drill) | [`dr.md`](dr.md) — full rebuild, then this table for each subsystem |
| One node down, rest healthy | [`dr.md` §3 "Single node loss"](dr.md#3-single-scenario-runbooks) → re-provision with terraform |
| **k3s API unreachable / etcd quorum lost** (`etcdserver: request timed out`, servers won't start) | [`etcd-recovery.md`](etcd-recovery.md) |
| **Longhorn volume** faulted, degraded, stuck attaching, or replica rebuild looping | [`longhorn-recovery.md`](longhorn-recovery.md) |
| **Redis-HA** down, split sentinel, or `juicefs` mounts failing with metadata errors | [`redis-recovery.md`](redis-recovery.md) — Redis DB2 **is** the JuiceFS metadata |
| **Postgres (CNPG)** — instance loss, promotion stuck, PITR / restore, backup broken | [`cnpg-recovery.md`](cnpg-recovery.md) |
| **MariaDB Galera** — split-brain, all pods down, `safe_to_bootstrap` deadlock, SST loop | [`galera-recovery.md`](galera-recovery.md) |
| WordPress DB data-level restore (mysqldump) | [`dr.md` §6.3](dr.md#2-total-cluster-loss--recovery-order) |
| SOPS / age key lost, SSH key rotation | [`dr.md` §3 "age key loss"](dr.md#3-single-scenario-runbooks) |
| Terraform state backend cutover (local → S3) | [`ovh-terraform-state-migration.md`](ovh-terraform-state-migration.md) |

If more than one row matches, recover in the **§3 order** — not in the order you noticed the
alarms.

---

## 2. Runbook index

Each per-component runbook is self-contained and goes deeper than this page. This index only
says what each one owns and when to reach for it.

| Runbook | Owns | Reach for it when |
|---------|------|-------------------|
| [`dr.md`](dr.md) | **Total-loss master procedure** + backup inventory (§1) + full recovery order (§2) + DR rehearsal log (§5) | Cluster is gone, or you need the authoritative "what is backed up, where" table |
| [`etcd-recovery.md`](etcd-recovery.md) | k3s embedded etcd: single-member loss, quorum-lost `--cluster-reset` restore, snapshot management | The control plane itself is broken (this is upstream of everything else) |
| [`longhorn-recovery.md`](longhorn-recovery.md) | Longhorn distributed storage: faulted/degraded volumes, replica rebuild, node loss, S3 backup restore, the multipath-blacklist trap | Block storage for stateful workloads is unhealthy |
| [`redis-recovery.md`](redis-recovery.md) | Redis-HA (sentinel + haproxy): DB1 = Authentik, **DB2 = JuiceFS metadata** (only offsite copy is the nightly `juicefs dump`) | Redis is unhealthy, or JuiceFS can't read its metadata |
| [`cnpg-recovery.md`](cnpg-recovery.md) | CloudNativePG Postgres: instance/replica loss, failover, Barman object-store restore, `bootstrap.recovery` / PITR | Postgres (`authentik`, `personliness`) needs repair or restore |
| [`galera-recovery.md`](galera-recovery.md) | MariaDB Galera 3-node multi-master: split-brain, all-down bootstrap, `safe_to_bootstrap` selection, SST/mariabackup | WordPress DB cluster lost quorum or won't bootstrap |

---

## 3. Recovery order — the dependency chain

The HA subsystems are **not** independent. Bringing them up out of order corrupts data or
wastes hours. This is the same order as [`dr.md` §2](dr.md#2-total-cluster-loss--recovery-order),
distilled to the dependency reasoning:

```
DNS  ─▶  Nodes (terraform)  ─▶  age key + SOPS  ─▶  Flux
                                                      │
                                                      ▼
                          etcd (control plane must be healthy first)
                                                      │
                                                      ▼
                    Redis-HA ─▶ JuiceFS metadata ─▶ Longhorn ─▶ Databases (CNPG, Galera) ─▶ Apps
```

**Why this order, and the traps at each edge:**

1. **etcd before anything Kubernetes-level.** If the control plane doesn't have quorum,
   nothing you do to workloads sticks. Fix etcd ([`etcd-recovery.md`](etcd-recovery.md)) first.
2. **Redis before JuiceFS.** Redis DB2 holds the JuiceFS metadata map. JuiceFS mounts fail
   (or worse, appear empty) if Redis isn't healthy first. If Redis data was lost, reload the
   newest `juicefs dump` from S3 **before** any JuiceFS-backed app starts —
   see [`redis-recovery.md`](redis-recovery.md) and [`dr.md` §5.2](dr.md#2-total-cluster-loss--recovery-order).
3. **JuiceFS before its consumer apps.** A JuiceFS filesystem is **not safe to mount from two
   places at once** — never let a stale pod and a recovered pod mount the same volume
   concurrently.
4. **Longhorn before stateful DBs that ride on it.** (Note: CNPG and Redis run on `local-path`,
   not Longhorn — check each component's storage class before assuming.)
5. **Databases last, and each has a bootstrap trap:**
   - **Galera**: only the node with `safe_to_bootstrap: 1` may bootstrap the cluster; picking
     wrong deadlocks all three. The HelmRelease has a 15m timeout so a fresh SST isn't killed
     mid-flight. See [`galera-recovery.md`](galera-recovery.md).
   - **CNPG**: `bootstrap.recovery` only runs at **cluster creation** — it is a no-op on an
     existing `Cluster` object, so a restore means delete-and-recreate, not edit. See
     [`cnpg-recovery.md`](cnpg-recovery.md). ⚠️ The in-tree `barmanObjectStore` backup/restore
     syntax is deprecated and removed in operator **1.31**; the operator is pinned off in
     `renovate.json` until Postgres migrates to the barman-cloud plugin.

---

## 4. Golden rules (cross-cutting)

- **Restore the age key first, always.** Nothing decrypts — no backup creds, no S3, no DB
  passwords — until `make recover-age-key && make install-sops-age` has run.
  ([`dr.md` §2 step 3](dr.md#2-total-cluster-loss--recovery-order).)
- **The only offsite copy of the JuiceFS filesystem map is the nightly `juicefs dump`**, because
  Redis-HA runs on local-path, not Longhorn. Protect that CronJob's output.
- **Never mount a JuiceFS volume from two pods at once** — it corrupts.
- **Prefer the scripts, not hand-fixing nodes.** Re-provisioning is `terraform apply` /
  `make apply-*`, not manual `kubectl`/ssh surgery, so recovery stays reproducible.
- **Backups you haven't restored are hopes, not backups.** CNPG restore and Longhorn S3 restore
  are not yet DR-rehearsed — log every drill in [`dr.md` §5](dr.md#5-dr-rehearsal-log).

---

## 5. After any recovery — verify

Run the post-recovery checklist in [`dr.md` §4](dr.md#4-post-recovery-verification):

```bash
flux get all -A                                      # everything Reconciled
make verify-encryption && make verify-roundtrip      # secrets are ciphertext and decrypt cleanly
kubectl get pods -A | grep -vE 'Running|Completed'   # nothing stuck
kubectl get certificate -A                           # TLS Ready
```

Then smoke-test the user-facing paths (Authentik login, a JuiceFS-backed app, the WordPress
site) and **record the drill** in the rehearsal log.
