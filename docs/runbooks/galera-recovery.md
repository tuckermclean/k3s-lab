# MariaDB Galera Recovery Runbook

Authoritative recovery procedure for the `mariadb-galera` StatefulSet (namespace `mariadb`) —
the WordPress database. Written to be followed cold: assume you're staring at a red cluster,
not that you remember the incident that put it there.

> **Scope.** This runbook is about *recovering a broken Galera cluster* (split-brain, all-down,
> the `safe_to_bootstrap: 0` deadlock). Restoring WordPress data from an S3 dump into an
> already-healthy cluster is [`dr.md`](dr.md) Step 6.3 / §3 "MariaDB restore" — the two
> procedures are complementary, not duplicates: get Galera healthy first (this doc), then
> restore data into it if needed (`dr.md`).

---

## 1. Context

3-node Galera cluster, one pod per Kubernetes node via **hard** pod anti-affinity
(`infrastructure/database/mariadb/helmrelease.yaml`, `affinity.podAntiAffinity
.requiredDuringSchedulingIgnoredDuringExecution`, `topologyKey: kubernetes.io/hostname`). A
node loss and a pod loss are the same event — there is no way to reschedule a Galera pod onto
a node that already runs one.

| Fact | Value | Why it matters |
|---|---|---|
| Replicas | 3 | Galera needs a quorum-forming odd node count |
| Quorum | 2 of 3 | Cluster stays `Primary` and serves writes as long as 2 nodes see each other |
| Chart | `mariadb-galera` 16.0.1 (Bitnami, via `oci://registry-1.docker.io/bitnamicharts`) | Pinned in the HelmRelease |
| Image | `bitnamilegacy/mariadb-galera:11.8.2-debian-12-r3` | `bitnami/mariadb-galera` tags moved to `bitnamilegacy` in 2025 |
| HelmRelease `timeout` | `15m` | See hardening below |
| `resources.requests.cpu` | `100m` per pod | See hardening below |
| `resources.requests.memory` | `256Mi` per pod, **no memory limit** | See prevention notes, §5 |
| Storage | `local-path`, 10Gi per pod | Host-path backed — a pod's data lives on **one specific node**, it does not follow the pod |
| `pdb.create` | `true` (chart default, not overridden) | A PodDisruptionBudget exists guarding against voluntary disruption (e.g. node drains) taking out quorum |

**Why the 15m timeout and 100m CPU request exist — the OCI standup remediation spiral.**
A fresh 3-node Galera bootstrap plus mariabackup SST across nodes takes several minutes on
constrained/ARM nodes. The chart's install originally ran with Flux's default 5-minute
`HelmRelease` timeout. That timeout fired **mid-bootstrap**, Flux's remediation kicked in and
uninstalled the release, which killed the bootstrapping node uncleanly — leaving it (and every
other node that had partially joined) with `safe_to_bootstrap: 0` in `grastate.dat`. The next
install attempt hit the same 5-minute wall before the *new* cluster could even elect a
bootstrap node, uninstalled again, and the deadlock reproduced itself on every retry: a
reinstall spiral that never converges on its own. The fix was mechanical, not a workaround:
give the HelmRelease real room (`timeout: 15m`, `install.remediation.retries: 3`,
`upgrade.remediation.retries: 3` with `remediateLastFailure: true`) so a slow-but-succeeding
bootstrap is never treated as a failure in the first place. The 100m CPU request (down from an
earlier 250m) exists so the third Galera pod actually fits the free-tier 3×1-OCPU OCI node
budget under the hard one-pod-per-node anti-affinity — see the commit that dropped it
(`fix(mariadb): drop Galera CPU request 250m->100m to fit free-tier nodes`).

This runbook exists because that same underlying failure mode — a node (or all three) not
shutting down cleanly and refusing to bootstrap afterward — is the thing you have to be able
to recover from *manually* when the automatic timeout/retry hardening above isn't enough (e.g.
the whole cluster lost power, not just a slow bootstrap).

---

## 2. Failure modes — how to tell them apart

Run this on all three pods first, it's the fastest triage signal:

```bash
for i in 0 1 2; do
  echo "--- mariadb-galera-$i ---"
  kubectl -n mariadb get pod mariadb-galera-$i -o jsonpath='{.status.phase}{"\n"}'
  kubectl -n mariadb exec mariadb-galera-$i -c mariadb-galera -- \
    mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SHOW STATUS LIKE 'wsrep_cluster_%'; SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>&1
done
```

| # | Failure mode | Signature | Action |
|---|---|---|---|
| (a) | **One node down** | 2 pods `Running`, both report `wsrep_cluster_size = 2`, `wsrep_cluster_status = Primary`. The down pod is `Pending`/`CrashLoopBackOff`/gone. | **None required.** Quorum holds, the cluster keeps serving writes. Let Kubernetes reschedule the pod (or fix the node); when it restarts, Galera auto-rejoins via IST/SST. Only escalate if it stays down long enough that you're worried about a *second* node loss dropping you below quorum. |
| (b) | **All nodes down / cluster cold** | All 3 pods `Pending`, `CrashLoopBackOff`, or the Deployment/cluster was never started (e.g. fresh node group). No `wsrep_cluster_size` to query — nothing is listening. | Go to §3: identify the most-advanced node, force-bootstrap it, let the other two rejoin. |
| (c) | **`safe_to_bootstrap: 0` deadlock** | All 3 pods `CrashLoopBackOff`. Each one's log shows something like `It may not be safe to bootstrap the cluster from this node. It was not the last one to leave the cluster and may not contain all the updates.` and each `grastate.dat` shows `safe_to_bootstrap: 0`. This is the exact failure the 15m timeout/retries in §1 exists to prevent, but it can still happen from a real power/OOM event that kills all 3 nodes uncleanly at once. | Go to §3 — same procedure as (b), but you *must* use the `forceSafeToBootstrap` override since no node will volunteer on its own. |
| (d) | **Split-brain (two primaries)** | More than one pod reports `wsrep_cluster_status = Primary` **simultaneously**, with `wsrep_cluster_size` less than 3 on each side (e.g. one node alone believes it's `Primary` while the other two form their own `Primary` component of size 2). Normally Galera's quorum algorithm prevents this outright — it only happens if something previously forced `pc.ignore_quorum`/`pc.ignore_sb`, or a partition healed in a way that left a stale node believing it's still primary. | Go to §3.6 — identify the *majority* component (the one two nodes agree on) as authoritative, and force the lone dissenting node to rejoin it as a fresh SST target rather than treating it as primary. |

---

## 3. Recovery procedures

### 3.1 Suspend Flux first

Do this before touching any pod. The HelmRelease's `install`/`upgrade` remediation
(`retries: 3`, `remediateLastFailure: true`) will fight a manual recovery — if Flux notices the
release as unhealthy mid-fix and re-triggers remediation, you get the exact uninstall-then-
`safe_to_bootstrap:0` spiral described in §1, but self-inflicted this time.

```bash
kubectl -n mariadb patch helmrelease mariadb-galera --type=merge -p '{"spec":{"suspend":true}}'
```

Resume it only after §4 verification passes (§3.7).

### 3.2 Identify the most-advanced node

You need the node with the highest committed `seqno` — that's the one you force-bootstrap
from. Two methods, in order of preference:

**Method A — read `grastate.dat` (fast, works when the node shut down semi-cleanly):**

```bash
for i in 0 1 2; do
  echo "--- mariadb-galera-$i ---"
  kubectl -n mariadb exec mariadb-galera-$i -c mariadb-galera -- \
    cat /bitnami/mariadb/data/grastate.dat
done
```

Look at the `seqno:` line on each. The highest non-negative value wins. A `seqno: -1` means
that node doesn't know its position and can't be trusted by this method alone — fall through
to Method B for it.

> If a pod is crash-looping too fast to `exec` into (container restarts before your command
> lands), catch it in the brief `Running` window right after a restart (`kubectl -n mariadb get
> pod -w`), or read the file straight off the node — `persistence.storageClass` is `local-path`
> (host-path backed, single node per PVC), so `grastate.dat` also exists directly under k3s's
> local-path directory on whichever node last hosted that pod (`kubectl -n mariadb get pod
> mariadb-galera-<N> -o wide` for the node, `kubectl -n mariadb get pvc` for the PVC name/UID).

**Method B — `--wsrep-recover` (authoritative, use when `grastate.dat` is inconclusive):**

```bash
kubectl -n mariadb exec mariadb-galera-0 -c mariadb-galera -- \
  bash -c 'mariadbd --wsrep-recover --user=mysql --datadir=/bitnami/mariadb/data 2>&1 | grep -i "wsrep.*recover"'
```

This starts `mariadbd` briefly, replays the InnoDB redo log, prints the recovered
`<uuid>:<seqno>` position, and exits. Run it on each candidate pod and compare `seqno` values
directly — this is more trustworthy than `grastate.dat` alone because it derives the position
from the actual committed transaction log, not just the last-shutdown bookkeeping.

### 3.3 Force-bootstrap the winning node

**Confirmed chart values** (Bitnami `mariadb-galera` chart, `bitnami/charts` repo — same
values structure at the `16.0.1` pin used here as at `main`; verified against the chart's
`values.yaml` and README directly, not assumed):

| Value | Purpose |
|---|---|
| `galera.bootstrap.bootstrapFromNode` | Ordinal of the pod to bootstrap from (default `0`) |
| `galera.bootstrap.forceBootstrap` | Force that node to attempt bootstrap even though the chart normally only does this once, at first install |
| `galera.bootstrap.forceSafeToBootstrap` | Force `safe_to_bootstrap: 1` in that node's `grastate.dat` — this is the override for failure mode (c) |
| `podManagementPolicy: Parallel` | Required alongside the above when the bootstrap node isn't ordinal 0 — see §3.5 |

These map internally to the container's `MARIADB_GALERA_CLUSTER_BOOTSTRAP` and
`MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP` env vars. Bitnami's own recovery docs (chart README)
give this as `helm install`/`helm upgrade --set ...` against a chart-managed release — which is
exactly what the suspended HelmRelease still is under the hood, so you can drive it directly:

```bash
# Example: pod ordinal 2 had the highest seqno, all 3 are safe_to_bootstrap: 0
helm upgrade mariadb-galera oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  -n mariadb --version 16.0.1 --reuse-values \
  --set galera.bootstrap.forceBootstrap=true \
  --set galera.bootstrap.bootstrapFromNode=2 \
  --set galera.bootstrap.forceSafeToBootstrap=true \
  --set podManagementPolicy=Parallel
```

Wait for `mariadb-galera-2` to come up as `Primary` with `wsrep_cluster_size=1` before moving
on — that confirms the bootstrap itself succeeded.

**Manual fallback (no chart/values changes at all) — use this when the winning node is
already ordinal 0**, the chart's default `bootstrapFromNode`. It's the more reliable path
precisely because it doesn't depend on `helm upgrade` succeeding against a possibly-unhealthy
release:

```bash
# Edit grastate.dat in place on the winning node (here, node 0)
kubectl -n mariadb exec mariadb-galera-0 -c mariadb-galera -- \
  sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /bitnami/mariadb/data/grastate.dat

# Force a clean restart so the entrypoint re-evaluates the (now-safe) state
kubectl -n mariadb delete pod mariadb-galera-0
```

If the winning node is *not* ordinal 0, either use the `helm upgrade` method above, or
temporarily edit the HelmRelease's `bootstrapFromNode` the same way — either is fine while
Flux is suspended, since you'll revert it in §3.7 regardless.

### 3.4 Bring the other two nodes back

Once the bootstrap node reports `wsrep_cluster_status: Primary` and `wsrep_cluster_size: 1`
(sanity-check with the query in §2), restart the remaining two pods normally — they have no
force flags set, so they'll rejoin the now-live cluster via SST (full state snapshot,
mariabackup) or IST (incremental, if their state is recent enough) automatically:

```bash
kubectl -n mariadb delete pod mariadb-galera-1 mariadb-galera-2
```

SST on constrained/ARM nodes is the same slow operation the 15m HelmRelease timeout exists
for — give it minutes, not seconds, before concluding it's stuck. Watch `wsrep_cluster_size`
climb to 2, then 3.

### 3.5 The StatefulSet `OrderedReady` gotcha

`podManagementPolicy` defaults to `OrderedReady` (not overridden anywhere in
`helmrelease.yaml`), which means the StatefulSet controller will **not even create** pod *N+1*
until pod *N* is `Running` and `Ready`. If a pod gets stuck `Pending` (unschedulable — e.g. it's
still carrying a stale resource request that no longer fits a node, or the hard anti-affinity
can't find it a free node) it silently blocks every pod after it from ever being (re)created
with the current spec, which looks identical to "SST is just slow" if you're not watching
`kubectl get events`.

```bash
kubectl -n mariadb get pods -o wide
kubectl -n mariadb describe pod mariadb-galera-<N>     # look for FailedScheduling in Events
kubectl -n mariadb delete pod mariadb-galera-<N>        # force it to be recreated against the current spec
```

Deleting the stuck pod forces the controller to recreate it fresh against whatever spec is
currently live (e.g. the corrected 100m CPU request) instead of leaving a pod stranded on an
older, incompatible spec.

### 3.6 Split-brain (failure mode d)

Confirm which side is the real majority — the two nodes that agree with each other are the
authoritative `Primary` component; the lone dissenter is the split:

```bash
for i in 0 1 2; do
  kubectl -n mariadb exec mariadb-galera-$i -c mariadb-galera -- \
    mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_cluster_status';"
done
```

Once you know which pod is the odd one out, force it to rejoin the majority as a fresh SST
target rather than let it keep claiming to be `Primary` on its own:

```bash
kubectl -n mariadb delete pod mariadb-galera-<dissenting-ordinal>
```

If it comes back still claiming `Primary` alone (rare — implies something explicitly disabled
quorum enforcement, e.g. `wsrep_provider_options='pc.ignore_quorum=true'` set during an earlier
incident and never reverted), wipe its PVC data so it has no choice but to SST from the
majority:

```bash
kubectl -n mariadb exec mariadb-galera-<dissenting-ordinal> -c mariadb-galera -- \
  bash -c 'rm -rf /bitnami/mariadb/data/*'
kubectl -n mariadb delete pod mariadb-galera-<dissenting-ordinal>
```

### 3.7 Resume Flux

Only after §4 passes. Remove any temporary `--set galera.bootstrap.*`/`podManagementPolicy`
overrides first if you drove recovery via `helm upgrade` directly (§3.3) — resuming the
HelmRelease will otherwise leave Flux fighting a values drift between what's live and what git
declares:

```bash
helm upgrade mariadb-galera oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  -n mariadb --version 16.0.1 --reuse-values \
  --set galera.bootstrap.forceBootstrap=false \
  --set galera.bootstrap.bootstrapFromNode=0 \
  --set galera.bootstrap.forceSafeToBootstrap=false \
  --set podManagementPolicy=OrderedReady

kubectl -n mariadb patch helmrelease mariadb-galera --type=merge -p '{"spec":{"suspend":false}}'
```

If you only ever edited `grastate.dat` directly (the manual fallback path) there's nothing to
revert — just resume.

---

## 4. Verification

```bash
kubectl -n mariadb get pods
# expect: mariadb-galera-0/1/2 all Running, 1/1 Ready

kubectl -n mariadb exec mariadb-galera-0 -c mariadb-galera -- \
  mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SHOW STATUS LIKE 'wsrep_%';"
# expect: wsrep_cluster_size = 3, wsrep_cluster_status = Primary,
#         wsrep_local_state_comment = Synced, wsrep_ready = ON
```

Repeat the `SHOW STATUS` check against all three pods — all three must agree on
`wsrep_cluster_size = 3` and `wsrep_cluster_status = Primary`. If any one disagrees, you still
have a split; go back to §3.6.

Then confirm the app itself is healthy: WordPress loads and can write (smoke-test per
`dr.md` §4), and the nightly `wordpress-db-backup` CronJob's next run succeeds
(`backup-cronjob.yaml`).

---

## 5. Prevention notes

- **Keep the 15m `HelmRelease` timeout and the 3-retry remediation.** They exist specifically
  so a slow-but-succeeding bootstrap/SST is never mistaken for a failure and force-uninstalled
  mid-flight — that mistake is what causes the §2(c) deadlock in the first place.
- **Keep the hard one-pod-per-node anti-affinity and the chart's default PDB
  (`pdb.create: true`).** Both exist to stop a single node/voluntary-disruption event from ever
  taking out more than 1 of 3 nodes at once, which is the difference between failure mode (a)
  (self-healing, no action) and (b)/(c) (manual recovery, this whole doc).
- **Do not add a CPU or memory *limit*.** The 100m CPU *request* is a scheduling reservation
  only, deliberately left uncapped so SST/mariabackup can burst freely — MariaDB OOMs badly
  under a tight memory cap specifically during SST, which is the worst possible moment to
  induce a second node failure while you're already down to 2-of-3 quorum recovering the first.
- **Rehearse this.** Like `dr.md`'s restore procedures, this runbook is not yet exercised
  end-to-end against a real dead cluster — log results in `dr.md`'s rehearsal log (§5) once it
  is.
