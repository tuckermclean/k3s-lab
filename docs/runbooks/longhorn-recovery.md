# Longhorn Recovery Runbook

Authoritative recovery procedure for **Longhorn** (`longhorn-system` namespace) — the
distributed block storage backing every Longhorn-class PVC in `ovh-lab` (and, once storage is
mirrored, `oci-lab`). Written to be followed cold: assume you're staring at a `Volume` stuck in
a bad state, not that you remember the incident that caused it.

> **Scope.** This is about recovering *Longhorn itself* — degraded/faulted volumes, lost
> replicas, stuck attach/detach. Restoring a specific application's data from its own
> S3-native backup (Postgres/CNPG, MariaDB) is `dr.md` §6, not this doc. Longhorn's own backup
> target is a different, volume-level mechanism (§3.4 below).

---

## 1. Context

| Fact | Value | Where it's set |
|---|---|---|
| Chart | `longhorn` 1.11.3 (Rancher Longhorn HelmRepository) | `infrastructure/storage/longhorn/helmrelease.yaml` |
| Cluster-wide default replica count | `2` | `defaultSettings.defaultReplicaCount` and `persistence.defaultClassReplicaCount` in `helmrelease.yaml` |
| `longhorn` StorageClass | `numberOfReplicas: "2"` | `infrastructure/storage/longhorn/storageclass.yaml` |
| `longhorn-local-home` StorageClass | `numberOfReplicas: "1"`, `dataLocality: strict-local`, pinned to the `home-media` node | same file — a deliberately non-redundant class for one specific workload, not the general case |
| `allowVolumeExpansion` | **omitted** (defaults `false`) on both classes | Deliberate — see the incident note in `storageclass.yaml`: an interrupted `resize2fs` mid-expand corrupted all 4 stateful volumes simultaneously (block-level replication propagated the partial write to every replica instantly) with no backup target configured at the time to recover from |
| Data path | `/var/lib/longhorn` | `defaultSettings.defaultDataPath`, bind-mounted to the dedicated data disk in cloud-init (`storage.tf`/`server.yaml.tftpl`) — **not** the boot disk |
| Backup target | S3, via `BackupTarget` CR | `infrastructure/storage/longhorn/backup-target/backuptarget.yaml`, credentials from `longhorn-backup-secret` (`backup/secret.sops.yaml`), URL from `backup-target-vars.sops.yaml` |
| Backup schedule | `backup-daily` — 03:00 UTC, retain 7, group `default` (all volumes) | `infrastructure/storage/longhorn/backup/recurringjobs.yaml` |
| Local snapshot schedule | `snapshot-6h` — every 6h, retain 8, group `default` | same file |
| Detached-volume backups | Enabled (`allowRecurringJobWhileVolumeDetached: true`) | `helmrelease.yaml` — stopped apps still get backed up |

**Known issue: multipathd claiming Longhorn devices (fix pending merge, PR #137 /
`fix/longhorn-multipath-blacklist`).** Upgrading 1.10.1 → 1.11.3 surfaced a latent bug:
`multipathd` on the OVH Ubuntu nodes runs with no blacklist by default and grabs Longhorn's
iSCSI frontend block devices (vendor `IET`, product `VIRTUAL-DISK`) into multipath maps,
holding them open so kubelet can't mount the PVC (`already mounted or mount point busy`, exit
32). This left `media/deluge` and `wordpress/wordpress` stuck in `Init` for hours. Per the
[Longhorn KB](https://longhorn.io/kb/troubleshooting-volume-with-multipath/), the fix is a
multipath blacklist for those devices — cloud-init `write_files` for future nodes plus a
`configure-multipath.sh` script (run via a Terraform `null_resource`, mirroring the data-disk
pattern in `storage.tf`) to converge the running fleet, added in commit `f6c3771` on
`fix/longhorn-multipath-blacklist`. **As of this writing that branch is not merged to `main`**
— confirm with `git log --oneline -- bootstrap/terraform/ovh-k3s/multipath.tf` before assuming
the tooling in §3.5 is present; if it isn't merged yet, either merge it first or apply the
blacklist by hand (§3.5 includes the manual fallback). If you hit the exact symptom above on a
node, see §3.5.

---

## 2. Failure modes

| # | Failure mode | Signature | Action |
|---|---|---|---|
| (a) | **Replica faulted/degraded, healthy replicas remain** | `Volume` shows `Robustness: degraded`, one `Replica` shows `Failed`/`Stopped`, at least one other replica `Running`/healthy. | **Usually none.** Longhorn auto-rebuilds a new replica on a healthy node. Confirm it's happening (§3.1); only escalate if it stalls. |
| (b) | **Node lost** | Every replica that lived on that node goes `Failed` at once; other nodes' replicas of the same volumes are unaffected. | Same as (a) if spare capacity exists elsewhere — Longhorn rebuilds replicas on a surviving node automatically. If there's no room (only 3 nodes, `numberOfReplicas: 2`, and the lost node was hosting the only other copy's target), the volume runs at reduced redundancy until the node returns or is replaced — not itself an outage, but treat as urgent. |
| (c) | **Volume `Faulted`** (all replicas bad) | `Volume` shows `State: faulted` (or `detached`, unable to attach) and **every** `Replica` is `Failed`/`Error` — no healthy copy anywhere. Longhorn's block-level replication means a corrupting event (e.g. an interrupted resize, simultaneous disk failure) can take out every replica at once, exactly as happened in the incident noted in `storageclass.yaml`. | No local copy is recoverable — restore from the S3 backup target (§3.4). This is the entire reason the backup target exists. |
| (d) | **multipathd claiming Longhorn devices** | PVC stuck `Init`/`ContainerCreating`, kubelet logs `already mounted or mount point busy`, exit status 32; `multipath -ll` on the node shows a map for an `IET`/`VIRTUAL-DISK` device. | See §3.5 — apply/verify the blacklist, flush the stale map. |
| (e) | **Volume stuck `attaching`/stuck detached** | PVC/pod stuck pending; `Volume` sits in `attaching` or `detached` past a couple of minutes with no error, or a stale `VolumeAttachment` object references a pod/node that's already gone (e.g. after an ungraceful pod termination). | See §3.6. |

---

## 3. Recovery procedures

### 3.1 Check volume health

```bash
kubectl get volumes.longhorn.io -n longhorn-system
kubectl get volumes.longhorn.io -n longhorn-system -o wide   # State, Robustness, Node columns
kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=<volume-name>
```

Or the UI: `https://longhorn.dcxxiv.com` → Volume list, or a specific volume's detail page. Look
at `Robustness` (`healthy`/`degraded`/`faulted`) and the replica list underneath.

### 3.2 Replica faulted, rebuild not progressing (failure mode a)

Confirm a rebuild is actually in flight before assuming it's stuck — it can legitimately take
minutes on a large volume:

```bash
kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=<volume-name> -o wide
# look for a new Replica in `Running`/rebuilding state on a different node
```

If nothing is rebuilding after a reasonable wait, nudge it from the UI (Volume detail →
"Replica Rebuild" is otherwise automatic; check Settings → General → "Replica Replenishment
Wait Interval" hasn't been raised) or delete the failed `Replica` object to force Longhorn to
schedule a fresh one:

```bash
kubectl -n longhorn-system delete replica.longhorn.io <failed-replica-name>
```

### 3.3 Node lost, capacity check (failure mode b)

```bash
kubectl get nodes                                    # confirm which node is gone
kubectl -n longhorn-system get nodes.longhorn.io      # Longhorn's own Node CRs — Schedulable?
```

If a third schedulable node with free disk space exists, replicas rebuild there automatically —
same as §3.2. If the lost node's replacement hasn't rejoined yet (see `etcd-recovery.md` if it
was a server node), volumes stay at reduced redundancy until it does; nothing to force here
except restoring the node itself.

### 3.4 Volume faulted, all replicas bad — restore from S3 backup (failure mode c)

There is no local copy to salvage from at this point — go straight to the backup target.

**Check the backup target is reachable first:**

```bash
kubectl -n longhorn-system get backuptarget.longhorn.io default -o yaml
# status.available should be true; status.conditions should show no error
```

**Find the backup to restore:**

```bash
kubectl -n longhorn-system get backups.longhorn.io -l longhornvolume=<original-volume-name>
# note the backup's spec.snapshotName / status.url (the s3:// backup URL) and the size
```

**Restore into a new Volume, then bind a PV/PVC to it** (fastest path via the UI: Backup menu →
select the backup → "Restore Latest Backup" → give it a name → OK; this does steps below for
you). Via CLI:

```yaml
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: <restored-volume-name>
  namespace: longhorn-system
spec:
  size: "<size-in-bytes-from-the-backup>"
  fromBackup: "<backup-url-from-status.url-above>"
  numberOfReplicas: 2
  frontend: blockdev
```

```bash
kubectl apply -f restored-volume.yaml
kubectl -n longhorn-system get volumes.longhorn.io <restored-volume-name> -o jsonpath='{.status.restoreRequired}'
# wait for this to report false before attaching
```

Then create a PV/PVC pair whose PV `volumeHandle`/`csi.volumeHandle` matches the restored
Volume's name, using the original PVC's `storageClassName` (`longhorn` in almost every case
here), and point the app at that PVC. If the original PVC/PV still exist (just empty or
corrupted), delete them first — Longhorn won't bind a new backing volume to an existing bound
PVC.

### 3.5 multipathd claiming Longhorn devices (failure mode d)

Confirm the symptom before treating every stuck-mount as this:

```bash
ssh ubuntu@<affected-node-ip>
sudo multipath -ll | grep -A2 'IET,VIRTUAL-DISK'   # a map here is the smoking gun
```

**If `bootstrap/terraform/ovh-k3s/multipath.tf` exists on `main`** (i.e. PR #137/
`fix/longhorn-multipath-blacklist` has been merged — check with `git log`), the fix is codified
and you just need to converge the fleet:

```bash
cd bootstrap/terraform/ovh-k3s
terraform apply    # runs the configure_multipath_* null_resources against every node

# Or by hand on a single node, right now, without waiting on Terraform:
sudo bash bootstrap/terraform/ovh-k3s/scripts/configure-multipath.sh
```

**If that branch isn't merged yet**, apply the same fix by hand directly on the affected node
(this is exactly what the script above does):

```bash
ssh ubuntu@<affected-node-ip>
sudo mkdir -p /etc/multipath/conf.d
sudo tee /etc/multipath/conf.d/longhorn.conf > /dev/null <<'EOF'
blacklist {
    device {
        vendor "IET"
        product "VIRTUAL-DISK"
    }
}
EOF
sudo multipathd reconfigure || sudo systemctl restart multipathd
sudo multipath -f <stale-map-name>   # from the `multipath -ll` output above, if any map remains
```

Either way, once the blacklist is live and any stale map flushed, the stuck PVC's pod should
proceed past `Init` within a normal mount cycle — if it doesn't, delete the pod to force a
fresh mount attempt now that the device is free.

### 3.6 Volume stuck attaching/detached (failure mode e)

```bash
kubectl -n longhorn-system get volumes.longhorn.io <volume-name> -o yaml | grep -A5 state
kubectl get volumeattachments.storage.k8s.io | grep <pvc-name>
```

Check for a stale `VolumeAttachment` pointing at a node/pod that's already gone — this is the
same class of symptom as multipath (§3.5) but caused by an ungraceful termination (node killed,
kubelet restarted) rather than multipathd holding the device. If the referencing pod is truly
gone:

```bash
kubectl delete volumeattachment <name>   # only if the referencing pod/node no longer exists
```

Then restart the workload's pod to trigger a clean re-attach. If the volume itself is wedged in
`attaching` on the Longhorn side (not just the k8s `VolumeAttachment` object), detach and
reattach from the UI (Volume detail → Detach), or:

```bash
kubectl -n longhorn-system patch volumes.longhorn.io <volume-name> --type=merge \
  -p '{"spec":{"nodeID":""}}'   # force-detach; only once you're sure nothing still holds it
```

Always rule out §3.5's multipath signature first on OVH nodes — it produces the identical
"stuck, no error" symptom from the workload's point of view.

---

## 4. Verification

```bash
kubectl get volumes.longhorn.io -n longhorn-system -o wide
# every volume: State=attached (for in-use PVCs) or detached (for stopped apps),
# Robustness=healthy, Replicas actual == numberOfReplicas

kubectl -n longhorn-system get backuptarget.longhorn.io default -o jsonpath='{.status.available}'
# true

kubectl get pods -A | grep -vE 'Running|Completed'   # nothing stuck on the recovered PVC(s)
```

For a restored volume specifically, confirm the app itself reads back the expected data before
considering the recovery done — a volume can report `healthy` while still holding whatever was
in the backup, which may or may not be what you expected to restore.

---

## 5. Prevention

- **Keep `numberOfReplicas: 2` and the S3 backup target configured** — replica count survives
  a single bad replica (§2a) and a single lost node with spare capacity (§2b); the backup
  target is the only thing that survives all-replicas-bad (§2c), which block-level replication
  makes a real (not theoretical) risk — see the `resize2fs` incident noted in
  `storageclass.yaml`.
- **Never re-add `allowVolumeExpansion: true` casually.** It's intentionally omitted after the
  incident that corrupted all 4 stateful volumes at once. Follow the four-step procedure
  documented directly in `storageclass.yaml` if a resize is ever needed: enable expansion,
  resize one PVC at a time, wait for `healthy` before touching the next, then remove the flag
  again.
- **Merge PR #137 (`fix/longhorn-multipath-blacklist`)** and keep the multipath blacklist
  applied to every OVH node, including new ones added later — confirm `terraform apply` has
  converged the fleet (§3.5) after any node replacement, since `compute.tf` intentionally
  ignores `user_data` changes on already-running instances and won't pick the blacklist up on
  its own.
- **Rehearse a full backup-target restore (§3.4)** end to end at least once, the same way
  `dr.md`'s storage/database restores need rehearsing — log the result in `dr.md`'s rehearsal
  log (§5).
