# Redis-HA Recovery Runbook

Recovery procedure for the shared `redis-ha` cluster (`infrastructure/database/redis`). Written to
be followed cold — assume you are looking at a broken/degraded cluster and need to diagnose and fix
it, or rebuild it from nothing.

> **Scope.** This file is about *this specific cluster's* failure modes and recovery mechanics
> (Sentinel failover, replica rejoin, full loss). For the full whole-cluster disaster recovery
> sequence (and where Redis fits in the overall restore order), see
> [`dr.md`](./dr.md).

---

## 1. What this cluster is and who depends on it

`redis-ha` (Helm chart `dandydeveloper/redis-ha`, version `4.39.0`) runs in the `redis` namespace:

- **3 replicas** — a `redis-ha-server` StatefulSet with pods `redis-ha-server-0/1/2`, each pod
  running a `redis` container and a `sentinel` container side by side (co-located, not separate
  pods).
- **Sentinel quorum** monitors a master group named `mymaster` and handles automatic failover.
- **HAProxy** (`redis-ha-haproxy`, 3 replicas) fronts the cluster and always proxies to whichever
  pod Sentinel currently considers master. Consumers never talk to a redis pod directly — they use
  the stable endpoint:

  ```
  redis-ha-haproxy.redis.svc.cluster.local:6379
  ```

- **Storage: `local-path`, not Longhorn.** Each pod's data directory is a local-path PV pinned to
  the node it's scheduled on. There is no Longhorn snapshot/backup safety net here — losing a node
  loses that replica's on-disk data permanently (see §2 and §6).
- **Auth**: password in SOPS secret `redis-auth` (namespace `redis`), key `redis-password`.

### Consumers and their databases

| DB | Consumer | Nature of the data |
|----|----------|---------------------|
| **DB 1** | Authentik (`infrastructure/authentik/helmrelease.yaml`, `authentik.redis.db: 1`) | Session/cache data. Disposable — Authentik rebuilds its Redis-backed state on its own; a full loss here just logs everyone out and drops caches. |
| **DB 2** | JuiceFS metadata engine (`METAURL=redis://redis-ha-haproxy.redis.svc.cluster.local:6379/2`, referenced from `infrastructure/storage/juicefs/redis-meta-backup-cronjob.yaml`) | **The JuiceFS filesystem map** — every inode, chunk, and slice pointer for data sitting in the JuiceFS S3 bucket. **Not disposable.** |

---

## 2. CRITICAL: DB 2 is the JuiceFS filesystem map

> **If all 3 redis pods lose their local-path data (e.g. all 3 nodes lost, or the PVs are deleted),
> DB 2 is gone with them.** JuiceFS's actual file *contents* are safe in S3, but without the
> metadata engine there is no way to know which S3 objects correspond to which files, directories,
> or permissions. **JuiceFS mounts will fail / read as empty or corrupt until DB 2 is reloaded.**
>
> The only offsite copy of DB 2 is the nightly `juicefs dump` CronJob
> (`infrastructure/storage/juicefs/redis-meta-backup-cronjob.yaml`, runs 04:00 UTC), which writes to
> `s3://k3s-lab-backups/juicefs/meta-<ts>.json`. Restoring Redis and restoring JuiceFS are therefore
> **entangled**: a full Redis loss is not "done" until DB 2 has been reloaded from that dump. See §5
> (Procedure D) for the exact steps, and [`dr.md` §1/§5.2](./dr.md) for how this fits the
> whole-cluster recovery order.

If only DB 1 (Authentik) is affected, or the cluster degrades but DB 2 data survives (any of the 3
replicas kept its disk), **no metadata restore is needed** — Sentinel/replication already have you
covered. Confirm data actually is intact before assuming the worst (§4 verification step 5).

---

## 3. Failure modes and expected behavior

### (a) Master pod dies (process crash, pod eviction, single node reboot)
Sentinel quorum (2 of 3 sentinels must agree) detects the master is unreachable, elects a replica as
the new master, and reconfigures the remaining replica to follow it. HAProxy's health checks notice
the topology change and repoint to the new master automatically. **Usually no action required** —
just confirm the new topology (§5, Procedure A) and let the old pod rejoin as a replica once it
comes back (StatefulSet restarts it; it re-syncs from the new master automatically).

### (b) One replica down (not the master)
No failover needed — Sentinel quorum is unaffected (still 2 of 3 sentinels healthy) and the master
keeps serving. When the pod comes back (rescheduled, node recovers, etc.) it rejoins the replication
stream and resyncs from the master automatically. Confirm with `INFO replication` once it's back
(§5, Procedure B) — watch for `master_link_status:up` and `master_repl_offset` catching up.

### (c) Sentinel quorum lost / split-brain
If 2+ sentinel processes are down, or a network partition splits the 3 nodes such that no side sees
a majority, Sentinel cannot safely elect a new master — writes may stall or (in a partition) split
into two masters. The chart's own split-brain-fix sidecar container detects config inconsistency
between pods and will restart the offending redis process to force it to resync as a replica, but if
that doesn't resolve it (e.g. sustained network partition), manual intervention is needed —
determine which side has quorum (2 of 3 nodes reachable), and manually fail over onto that side if
necessary (§5, Procedure C). Do not manually write to a minority-side "master" — its data will be
thrown away when the partition heals.

### (d) Full loss — all 3 pods' local-path data gone
This happens if all 3 underlying nodes are lost/rebuilt, or someone deletes the PVCs/PVs. Flux will
recreate the StatefulSet and fresh, empty local-path PVs bind. The cluster comes up healthy but
**empty**:
- **DB 1 (Authentik)**: no action needed — Authentik repopulates sessions/cache on its own.
- **DB 2 (JuiceFS metadata)**: **must be restored from the latest S3 dump** before any JuiceFS mount
  will work correctly. See §5, Procedure D.

---

## 4. Quick diagnosis

Set your password once per shell:

```bash
export REDIS_PW=$(kubectl -n redis get secret redis-auth -o jsonpath='{.data.redis-password}' | base64 -d)
```

1. **Pods Ready?**
   ```bash
   kubectl -n redis get pods -l app=redis-ha
   kubectl -n redis get pods -l app=redis-ha-haproxy
   ```
   Expect 3/3 `redis-ha-server-{0,1,2}` Running (2 containers each: `redis`, `sentinel`) and 3
   `redis-ha-haproxy-*` Running.

2. **Who is master, right now?**
   ```bash
   kubectl -n redis exec -it redis-ha-haproxy-0 -- redis-cli -a "$REDIS_PW" --no-auth-warning \
     -h redis-ha-haproxy -p 6379 info replication | head -5
   ```
   Look at `role:master` (confirms HAProxy is routing to a master, as expected) and
   `connected_slaves:2`.

3. **What does Sentinel think?**
   ```bash
   kubectl -n redis exec -it redis-ha-server-0 -c sentinel -- redis-cli -a "$REDIS_PW" --no-auth-warning \
     -p 26379 sentinel masters
   ```
   Check `num-slaves:2`, `num-other-sentinels:2`, `quorum:2`, and `flags:master` (not `s_down` /
   `o_down`).

4. **Per-pod role** (to find which of the 3 StatefulSet pods is currently master):
   ```bash
   for i in 0 1 2; do
     echo "== redis-ha-server-$i =="
     kubectl -n redis exec redis-ha-server-$i -c redis -- redis-cli -a "$REDIS_PW" --no-auth-warning \
       -p 6379 info replication | grep -E '^role:|master_link_status'
   done
   ```

5. **Is DB 2 (JuiceFS metadata) actually populated?**
   ```bash
   kubectl -n redis exec -it redis-ha-haproxy-0 -- redis-cli -a "$REDIS_PW" --no-auth-warning \
     -h redis-ha-haproxy -p 6379 -n 2 dbsize
   ```
   A `dbsize` of `0` on a cluster that should hold live JuiceFS metadata is the signal to run
   Procedure D below. A nonzero count roughly matching your filesystem's expected object count means
   the metadata survived — do not restore over it.

---

## 5. Recovery procedures

### Procedure A — confirm/assist automatic master failover (case a)

Normally no action is needed. To confirm the new master and force HAProxy to re-check if it seems
stuck:

```bash
# Confirm Sentinel's view of the current master
kubectl -n redis exec -it redis-ha-server-0 -c sentinel -- redis-cli -a "$REDIS_PW" --no-auth-warning \
  -p 26379 sentinel get-master-addr-by-name mymaster

# Confirm HAProxy is routing to that same pod IP
kubectl -n redis exec -it redis-ha-haproxy-0 -- redis-cli -a "$REDIS_PW" --no-auth-warning \
  -h redis-ha-haproxy -p 6379 info replication | grep role
```
If HAProxy's target disagrees with Sentinel's `get-master-addr-by-name`, restart the haproxy pods to
force them to re-run their sentinel-polling init logic:
```bash
kubectl -n redis rollout restart deployment redis-ha-haproxy
```

### Procedure B — replica rejoin / resync (case b)

Usually automatic. If a replica pod comes back but doesn't resync on its own within a few minutes:

```bash
# Check its replication status
kubectl -n redis exec redis-ha-server-<N> -c redis -- redis-cli -a "$REDIS_PW" --no-auth-warning \
  -p 6379 info replication

# If it's stuck (not master_link_status:up), force it to re-replicate from the current master
MASTER_ADDR=$(kubectl -n redis exec redis-ha-server-0 -c sentinel -- redis-cli -a "$REDIS_PW" \
  --no-auth-warning -p 26379 sentinel get-master-addr-by-name mymaster)
kubectl -n redis exec redis-ha-server-<N> -c redis -- redis-cli -a "$REDIS_PW" --no-auth-warning \
  -p 6379 replicaof <master-ip-from-above> 6379
```

### Procedure C — Sentinel quorum lost / manual failover (case c)

1. Identify which side of a partition (if any) has 2 of 3 sentinels/nodes reachable — that side has
   quorum and is safe to promote onto.
2. From a sentinel on the quorum side, force a failover:
   ```bash
   kubectl -n redis exec -it redis-ha-server-<N> -c sentinel -- redis-cli -a "$REDIS_PW" \
     --no-auth-warning -p 26379 sentinel failover mymaster
   ```
3. Re-run the diagnosis in §4 to confirm a single master is agreed upon by all reachable sentinels
   before letting the partitioned side rejoin.
4. Once network connectivity is restored, the previously-partitioned pod(s) will resync as replicas
   from the new master (any writes they took while partitioned, if any, are discarded — this is why
   step 1 matters: never trust writes on a minority-side "master").

### Procedure D — full loss: rebuild + restore DB 2 (JuiceFS metadata) (case d)

1. **Let the cluster come back first.** Confirm all 3 `redis-ha-server-*` pods are Running and
   Sentinel quorum is healthy (§4, steps 1–3) before touching JuiceFS. A JuiceFS mount pointed at a
   half-up Redis will just fail differently, and you can end up loading the dump into a cluster
   that isn't stable yet.

2. **Confirm DB 2 really is empty** (§4, step 5). If any replica retained its disk, DB 2 already has
   live data via replication — skip straight to step 5 (verification) and do **not** overwrite it.

3. **Pull the newest metadata dump from S3:**
   ```bash
   aws s3 ls s3://k3s-lab-backups/juicefs/ | sort | tail -1
   aws s3 cp s3://k3s-lab-backups/juicefs/meta-<ts>.json /tmp/meta.json
   ```

4. **Load it into Redis DB 2** via the JuiceFS CLI (this is the inverse of the nightly `juicefs dump`
   that produced the file):
   ```bash
   juicefs load redis://redis-ha-haproxy.redis.svc.cluster.local:6379/2 /tmp/meta.json
   ```
   If your `juicefs` client build requires embedding the password in the URL (rather than an env
   var), use:
   ```bash
   juicefs load redis://:$REDIS_PW@redis-ha-haproxy.redis.svc.cluster.local:6379/2 /tmp/meta.json
   ```
   This can be run from any pod/host with the `juicefs` binary and network access to the cluster —
   e.g. `kubectl -n kube-system exec` into a juicefs-csi-driver pod, or a one-off debug pod using the
   same `juicedata/juicefs-csi-driver` image as the backup CronJob.

5. **DB 1 (Authentik) needs no restore action** — it's session/cache data and repopulates itself as
   users re-authenticate. If you want to confirm it's simply empty (not erroring):
   ```bash
   kubectl -n redis exec -it redis-ha-haproxy-0 -- redis-cli -a "$REDIS_PW" --no-auth-warning \
     -h redis-ha-haproxy -p 6379 -n 1 dbsize
   ```

---

## 6. Verification checklist

After any of the above:

```bash
# 1. All 3 redis pods Ready, all 3 haproxy pods Ready
kubectl -n redis get pods

# 2. Exactly one master, two replicas in sync
kubectl -n redis exec -it redis-ha-haproxy-0 -- redis-cli -a "$REDIS_PW" --no-auth-warning \
  -h redis-ha-haproxy -p 6379 info replication
# expect: role:master, connected_slaves:2, both slaves state=online

# 3. Sentinel quorum healthy
kubectl -n redis exec -it redis-ha-server-0 -c sentinel -- redis-cli -a "$REDIS_PW" --no-auth-warning \
  -p 26379 sentinel masters
# expect: num-slaves:2, num-other-sentinels:2, no s_down/o_down flags

# 4. HAProxy routing correctly (repeat Procedure A's check)

# 5. If DB 2 was restored: JuiceFS mounts actually read
kubectl -n kube-system get pods -l app=juicefs-csi-driver
# then, from any pod with the JuiceFS PVC mounted, confirm a known file/directory is visible and
# readable — a mount that comes up but lists nothing/errors means the metadata load didn't take.
```

Only consider the incident closed once all 5 checks pass (and, for a DB 2 restore, spot-check that
JuiceFS-backed apps can actually read their existing files, not just that the mount exists).

---

## 7. Prevention / notes for next time

- **The nightly `juicefs dump` (04:00 UTC) is the entire safety net for DB 2.** It's the only
  offsite copy of the JuiceFS filesystem map — verify the CronJob is succeeding
  (`kubectl -n kube-system get cronjob juicefs-meta-backup`) rather than discovering it's been
  silently failing during an actual recovery.
- **`local-path` means node loss = that replica's data is gone for good** — there is no Longhorn
  snapshot to fall back on for an individual redis pod. The 3-way Sentinel replication is what
  protects you day-to-day; it only becomes a real incident if you lose quorum (2+ of 3) at once.
- **`maxmemory-policy: noeviction`** is intentionally set (see `helmrelease.yaml`) specifically
  because this cluster holds JuiceFS metadata — under memory pressure, eviction of live keys would
  silently corrupt the filesystem map. `noeviction` instead makes Redis reject writes (loud and
  recoverable) rather than lose data. Don't change this policy without re-reading that comment.
- Prefer Procedure A/B (do nothing, or gently confirm) over forcing a manual failover — Sentinel's
  automatic election is well-tested; manual `sentinel failover` is a case-(c) tool for when quorum
  itself is broken, not a first response to a routine pod restart.
