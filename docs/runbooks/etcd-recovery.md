# etcd Recovery Runbook

Authoritative recovery procedure for k3s's **embedded etcd** — the datastore backing the
Kubernetes control plane on both `ovh-lab` (`k3s-ovh-1/2/3`) and `oci-lab`
(`k3s-server-1/2/3`). Both clusters use the identical topology: 3 server nodes, each running
`k3s server` with its own etcd member, no external etcd and no load balancer in front of the
API server. Written to be followed cold — assume you're looking at `kubectl get nodes` timing
out, not that you remember what killed the cluster.

> **Scope.** This is about recovering *etcd itself* — cluster membership and the API server's
> ability to come back up. It is not about restoring application data (Longhorn volumes,
> Postgres, MariaDB) — that's [`dr.md`](dr.md). A full node/cluster rebuild still needs
> `dr.md`'s provisioning steps; this doc is the etcd-specific piece that rebuild depends on,
> and the thing to reach for when the nodes are still there but etcd/the API server isn't.

---

## 1. Context

| Fact | Value | Where it's set |
|---|---|---|
| Topology | 3 server nodes, each a control-plane + etcd member (no agents by default) | `node_count`/`server_count` = 3, validated odd, in `bootstrap/terraform/{ovh-k3s,oci-k3s}/variables.tf` |
| Quorum | 2 of 3 | Standard Raft majority for a 3-member etcd cluster |
| First node | `--cluster-init` | `bootstrap/terraform/ovh-k3s/cloud-init/server.yaml.tftpl` role `server-first`; oci-k3s mirrors this in its own `cloud-init/server.yaml.tftpl` |
| Joining nodes | `--server https://<first-node-ip>:6443` | role `server-join` in the same templates |
| Data dir | `/var/lib/rancher/k3s/server/db` | k3s default; **not** on the separate data-disk bind mount (that's only `/var/lib/longhorn` and `/var/lib/rancher/k3s/storage` — see `storage.tf`/cloud-init) |
| Snapshot location | `/var/lib/rancher/k3s/server/db/snapshots` on **each server node's own root disk** | k3s default `--etcd-snapshot-dir` |
| Snapshot schedule | Every 12h (`0 */12 * * *`), retain 5 | k3s **default** — no `--etcd-snapshot-schedule-cron`/`--etcd-snapshot-retention` overrides exist anywhere in this repo's cloud-init or `config.yaml`, so the built-in default is what's actually running |
| Offsite snapshot copy | **None configured** | No `--etcd-s3*` flags anywhere in the repo (`grep -r etcd bootstrap/` turns up nothing beyond the flags above) |

**Critical gap:** k3s *is* already taking local etcd snapshots automatically (the 12h/retain-5
default), but every snapshot lives only on the same node's root disk that hosts the etcd member
it's a snapshot of. If that node is destroyed (not just rebooted), its snapshots go with it. See
§5 for the fix.

**Why total loss isn't really an etcd-restore problem.** Every workload's desired state
(Deployments, HelmReleases, Kustomizations, Secrets via SOPS) lives in this Git repo and gets
re-derived by Flux on a fresh cluster — that's `dr.md`. What etcd uniquely holds is *live,
non-git* state: current pod placement, PVC-to-volume bindings, in-flight object status. Losing
all 3 nodes at once means rebuilding fresh (`dr.md` §2, `--cluster-init` again) rather than
restoring a snapshot, because there won't be one to restore (per the gap above). Snapshot
restore matters for the case where the nodes/disks partially survive — that's §3.3 below.

---

## 2. Failure modes

| # | Failure mode | Signature | Quorum |
|---|---|---|---|
| (a) | **One server node lost** (crashed, rebooting, or permanently gone) | `kubectl get nodes` shows 1 node `NotReady`/gone; the other 2 are `Ready`. `kubectl get pods -A` still works — API server is reachable via the surviving nodes. | Holds (2/3) |
| (b) | **Quorum lost** (2 or more of 3 servers down) | `kubectl` against any surviving node hangs or errors (`etcdserver: request timed out`, `no leader`). This is the serious case. | Lost |
| (c) | **Full control-plane loss** (all 3 nodes/disks destroyed) | No node in the fleet is reachable at all. | N/A — nothing to recover *from*; rebuild |

---

## 3. Recovery procedures

### 3.1 Triage first

```bash
kubectl get nodes -o wide                 # who's Ready, who isn't
kubectl get pods -n kube-system -o wide | grep -i etcd 2>/dev/null   # k3s doesn't run etcd as a
                                           # separate static pod — this is just a sanity check;
                                           # absence of output is normal
```

If `kubectl` works at all (even slowly), quorum holds — go to §3.2. If it doesn't respond from
any node, assume quorum lost and go to §3.3.

### 3.2 (a) One server node lost — quorum holds

No emergency action needed; the cluster keeps serving. Two outcomes:

**The node comes back on its own** (reboot, transient network blip): k3s restarts, the etcd
member rejoins with its existing data directory, and it catches up automatically. Just confirm:

```bash
kubectl get nodes    # wait for it to flip back to Ready
```

**The node is permanently gone** (destroyed instance, dead disk): remove it cleanly and replace
it.

```bash
# 1. If the node is still reachable, stop k3s on it first so it can't rejoin mid-cleanup.
ssh ubuntu@<dead-node-ip> sudo systemctl stop k3s || true   # skip if truly unreachable

# 2. Remove it from Kubernetes. With quorum intact, k3s's own controller removes the
#    corresponding etcd member as part of this — no separate etcdctl step needed.
kubectl delete node k3s-ovh-2        # or k3s-server-2 on oci-lab

# 3. Verify the etcd member count actually dropped before adding a replacement — a partial
#    or racy Node deletion can leave a stale member behind and confuse quorum math later.
kubectl get nodes                    # should show 2 remaining, both Ready
```

Provision the replacement the normal way — re-run `make apply-ovh` (or `apply-oci`). Terraform
recreates the missing `k3s-ovh-2` instance; its cloud-init role is `server-join`
(`--server https://<first_ip>:6443`), so it joins the existing 2-member cluster and etcd grows
back to 3 on its own. No `--cluster-reset` needed for this case — quorum was never lost.

```bash
kubectl get nodes    # confirm 3/3 Ready again
```

### 3.3 (b) Quorum lost — restore from snapshot

This is the flow that matters. With 2+ of 3 servers down, no node can reach a Raft majority, so
the API server on the survivor (if any) is unusable for writes and often for reads too.

**Step 1 — stop k3s everywhere it's still running.** Don't let any surviving node keep
retrying quorum while you work.

```bash
ssh ubuntu@<node-ip> sudo systemctl stop k3s   # on every server node you can still reach
```

**Step 2 — pick the node to reset from and find its newest snapshot.** Prefer the node with
the most recent successful snapshot; if you're not sure, check the timestamps across whichever
nodes survived (remember: snapshots don't leave the node they were taken on, per the gap in
§1).

```bash
ssh ubuntu@<node-ip>
sudo k3s etcd-snapshot ls
# NAME                                          SIZE     TIME
# etcd-snapshot-k3s-ovh-1-1234567890-...   ...      2026-08-02T00:00:14Z
```

**Step 3 — reset that one node's etcd to a single-member cluster, restoring the snapshot.**

```bash
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-name>
```

This overwrites all data in that node's etcd datastore with the snapshot's contents and resets
cluster membership to just this node. It exits after the reset completes — it does not stay
running as the server.

```bash
sudo systemctl start k3s     # start it normally now
kubectl get nodes            # should show this one node Ready; the others still NotReady/gone
```

**Step 4 — bring the other two back as fresh joins, not old members.** Their old etcd data
directories reference a membership that no longer exists post-reset, so they must not reuse it.

*If the node itself still exists* (was just stopped, not destroyed):

```bash
ssh ubuntu@<other-node-ip>
sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s/server/db
sudo systemctl start k3s      # cloud-init already set its role to server-join, pointed at
                               # the first node's IP — it rejoins as a new member automatically
```

*If the node was destroyed*, re-provision it with Terraform instead (`make apply-ovh`/
`apply-oci`) — same effect, since a fresh instance has no `db` directory to begin with and its
`server-join` cloud-init role joins it the same way.

**Step 5 — repeat step 4 for the third node**, one at a time. Don't bring both back
simultaneously — let the reset node fully absorb the first rejoin before adding the second, so
you're not fighting quorum math on a 2-member interim cluster.

> **No snapshot exists / restore-path omitted.** `--cluster-reset` alone (no
> `--cluster-reset-restore-path`) is still valid — it resets membership to that single node
> using *whatever etcd data is already on its disk*, without rolling back to an older
> snapshot. Use this if the reset node's own data is intact and you just need to drop the
> dead members, not roll back state.

### 3.4 (c) Full control-plane loss

If all 3 nodes/disks are gone, there is nothing local to reset or restore (see the gap in §1 —
no offsite etcd snapshot copy exists today). Follow `dr.md` §2 "Total cluster loss": provision
fresh nodes (fresh `--cluster-init`, a brand-new etcd), restore the root of trust, bootstrap
Flux, and let Git/S3-backed application data (Longhorn, CNPG, MariaDB — `dr.md` §5–6) rebuild
the actual workloads. There's no etcd snapshot to restore into that flow because nothing
survived to hold one.

---

## 4. Command cheat-sheet

```bash
# Snapshot management (run on any server node, as root/sudo)
k3s etcd-snapshot save                       # on-demand snapshot, saved to the default dir
k3s etcd-snapshot ls                         # list local snapshots with timestamps/size
k3s etcd-snapshot delete <name>              # remove a specific snapshot

# Default snapshot directory
/var/lib/rancher/k3s/server/db/snapshots

# Quorum-lost restore (stop k3s on all servers first)
k3s server --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-name>

# Rejoin the other servers after the reset node is back up
systemctl stop k3s
rm -rf /var/lib/rancher/k3s/server/db
systemctl start k3s
```

---

## 5. Verification

```bash
kubectl get nodes                 # all 3 Ready
kubectl get pods -A | grep -vE 'Running|Completed'   # nothing stuck
flux get kustomizations -A        # Flux reconciling again now the API server is stable
ssh ubuntu@<any-server-ip> sudo k3s etcd-snapshot ls  # scheduled snapshots resuming on schedule
```

Then run the app-level smoke test from `dr.md` §4 if this recovery followed data loss of any
kind.

---

## 6. Prevention

- **Ship etcd snapshots offsite.** Today they're local-disk-only (§1 gap) — the same failure
  that destroys a node's etcd member also destroys its only copy of that member's snapshots.
  Add `--etcd-s3`, `--etcd-s3-bucket`, `--etcd-s3-region`, `--etcd-s3-access-key`/
  `--etcd-s3-secret-key` (or `--etcd-s3-config-secret`) to the server nodes' `config.yaml` in
  cloud-init, pointed at the same `s3://k3s-lab-backups` bucket the rest of `dr.md`'s backups
  use. This is the single highest-value follow-up from writing this runbook.
- **Consider a tighter snapshot cadence than the 12h default** if the acceptable data-loss
  window (RPO) for cluster metadata is smaller — set `--etcd-snapshot-schedule-cron` and
  `--etcd-snapshot-retention` explicitly once S3 shipping exists, so retention is deliberate
  rather than whatever the default happens to be.
- **Rehearse §3.3.** Like `dr.md`'s storage/database restores, this procedure has not been
  exercised against a real quorum-loss event. Log results in `dr.md`'s rehearsal log (§5) once
  it is.
