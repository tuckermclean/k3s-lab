# agent-os OVH → OCI Migration Runbook

Migrates the `agent-os` app — and, critically, its **persistent state** — from `ovh-lab` to
`oci-lab` without disrupting the live session currently running on OVH. Written to be run cold
by an operator with `kubectl`/Longhorn UI access to **both** clusters (or driven from a laptop
with both kubeconfigs available).

> **Scope.** This is app-and-data migration for one workload. It is not the broader OVH
> decommission (see `docs/superpowers/specs/2026-08-02-ovh-to-oci-migration.md`) and it is not
> generic Longhorn disaster recovery (see [`longhorn-recovery.md`](longhorn-recovery.md) §3.4,
> whose restore mechanics this procedure reuses).

---

## 1. Purpose & safety model

`agent-os` today runs **only** on OVH (`clusters/ovh-lab/agent-os-kustomization.yaml`). On OCI
it is currently excluded from `clusters/oci-lab/kustomization.yaml`'s `resources:` list. The
goal here is to copy its state to OCI and start it there, then leave OVH's copy running
untouched as a live fallback until the wider OVH decommission.

**Why "control-surface-first, live copy":**

- The app's entire state is a single 20Gi Longhorn RWO PVC, `agent-os-home` (namespace
  `agent-os`), mounted at `/home/node` — the whole home directory: `~/.claude` (memories +
  session transcripts), the `~/workspace/k3s-lab` checkout, and the Claude Code OAuth login.
  `/var/lib/docker` (the DinD sidecar's storage) is a **separate `emptyDir`**, not on the PVC —
  it's the only ephemeral, architecture-specific part and is not migrated (nor should it be).
- **We do not scale the OVH Deployment to 0.** Doing so would kill the live working session.
  Instead we take a live, crash-consistent Longhorn backup of the attached volume. Longhorn can
  back up a volume while it's in use; the trade-off is that the copy may miss the last few
  minutes of session-log writes made after the backup's snapshot point. Memories, the repo
  checkout, and the OAuth login are all safe — they're not being actively rewritten at
  microsecond granularity the way a session transcript tail might be.
- **Ordering hazard: restore before enable, always.** `apps/agent-os/pvc.yaml` is a plain PVC
  spec with no `dataSource`. If the OCI Flux `Kustomization` for `agent-os` is enabled before
  the restored PVC exists and is bound, Flux/Longhorn will happily create a **brand-new, empty**
  `agent-os-home` PVC and agent-os will start completely stateless — no memories, no repo, no
  login. There is no CSI `VolumeSnapshot`/`snapshot-controller` in this cluster to make that
  safe automatically, so the ordering is manual and must be followed exactly: the restored,
  data-bearing PVC must exist and be `Bound` **before** you add `agent-os-kustomization.yaml` to
  `clusters/oci-lab/kustomization.yaml`. That "enable" step is deliberately last in this
  runbook (Step 5).

---

## 2. Preconditions

Confirm all of these before starting:

- [ ] A multi-arch (amd64+arm64) image `ghcr.io/tuckermclean/agent-os:0.2.4` exists and is
      pushed to GHCR (OCI's nodes are arm64; the base `apps/agent-os/deployment.yaml` still
      pins `:0.2.2`, amd64-only, which is what the live OVH pod runs — that pin is
      intentionally left alone by this migration). `clusters/oci-lab/agent-os-kustomization.yaml`
      (staged by this same change) overrides the tag to `0.2.4` via Flux's `spec.images`
      transformer, scoped to OCI only.
- [ ] OVH and OCI Longhorn share the **same** backup target: `infrastructure/storage/longhorn/backup-target/backuptarget.yaml`
      points both clusters' `BackupTarget` CRs at the same
      `s3://<bucket>@us-west-2/longhorn` URL (from the `longhorn-backup-target-vars` SOPS
      secret). This means OCI's Longhorn can already see and restore from backups created on
      OVH — no cross-cluster copy step is needed.
- [ ] `agent-os-home` is covered by the `backup-daily` Longhorn `RecurringJob`
      (`infrastructure/storage/longhorn/backup/recurringjobs.yaml`, group `default`, which
      covers every unlabeled volume) — confirm at least one daily backup already exists as a
      sanity check that the pipeline works, even though Step 1 below takes a fresh one anyway.
- [ ] You have `kubectl` context (or the Longhorn UI URL) for **both** `ovh-lab` and `oci-lab`.

---

## 3. Step 1 — Take a fresh, live backup of `agent-os-home` on OVH

**Do not scale `agent-os` down.** The Deployment stays at `replicas: 1` throughout this step —
Longhorn supports backing up an attached, in-use volume.

**Via the Longhorn UI (simplest):** on OVH's Longhorn dashboard, find the `agent-os-home`
volume → "Create Backup". Wait for it to reach 100%/`Completed` in the Backup list, then note
the backup's name and `Created` timestamp.

**Via `kubectl`, from an OVH context:**

```bash
kubectl -n longhorn-system get volumes.longhorn.io agent-os-home
# confirm State=attached, Robustness=healthy before proceeding

kubectl -n longhorn-system get backuptarget.longhorn.io default -o jsonpath='{.status.available}'
# true — confirms the shared S3 target is reachable from OVH

# Trigger an on-demand backup by annotating/patching the Volume's backup field,
# or apply a one-off snapshot+backup via a Backup CR. Longhorn's Volume CRD
# doesn't expose a plain "back up now" spec field directly; the supported
# non-UI path is to create a Snapshot then a Backup that references it:
kubectl -n longhorn-system create -f - <<'EOF'
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  generateName: agent-os-home-migration-
  namespace: longhorn-system
spec:
  volume: agent-os-home
EOF
# note the generated Snapshot name, then:
kubectl -n longhorn-system get snapshots.longhorn.io -l longhornvolume=agent-os-home

kubectl -n longhorn-system create -f - <<'EOF'
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  generateName: agent-os-home-migration-
  namespace: longhorn-system
spec:
  snapshotName: "<snapshot-name-from-above>"
  labels:
    purpose: oci-migration
EOF
```

Wait for the backup to finish:

```bash
kubectl -n longhorn-system get backups.longhorn.io -l longhornvolume=agent-os-home
# wait for the new one's status.state == Completed

kubectl -n longhorn-system get backups.longhorn.io <backup-name> -o jsonpath='{.status.url}{"\n"}{.status.size}{"\n"}'
```

**Record the backup's `status.url`** (the `s3://` backup URL) and size — both are needed in
Step 2. Confirm `agent-os` is still `Running` on OVH and untouched throughout.

---

## 4. Step 2 — Restore the backup into a new Longhorn volume on OCI

Switch to an OCI `kubectl` context (or the OCI Longhorn UI).

**Via the Longhorn UI:** OCI's Longhorn dashboard → Backup (left nav) should already list
OVH's backups, since both clusters share the same backupstore. Find the
`agent-os-home-migration-...` backup from Step 1 → "Restore Latest Backup" → name the new
volume `agent-os-home` → confirm.

**Via `kubectl`, from an OCI context:**

```bash
kubectl -n longhorn-system get backuptarget.longhorn.io default -o jsonpath='{.status.available}'
# true

kubectl -n longhorn-system get backupvolumes.longhorn.io agent-os-home
# confirms OCI's Longhorn already sees OVH's agent-os-home backups via the shared backupstore

kubectl apply -f - <<'EOF'
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: agent-os-home
  namespace: longhorn-system
spec:
  size: "21474836480"   # 20Gi in bytes — use the exact status.size noted in Step 1 if it differs
  fromBackup: "<backup-url-noted-in-step-1>"
  numberOfReplicas: 2
  frontend: blockdev
EOF

kubectl -n longhorn-system get volumes.longhorn.io agent-os-home -o jsonpath='{.status.restoreRequired}{"\n"}'
# poll until this reports false — the restore is done
kubectl -n longhorn-system get volumes.longhorn.io agent-os-home -o wide
# State should settle to detached, Robustness healthy, once restoreRequired is false
```

---

## 5. Step 3 — Bind the restored volume: static PV + PVC

Longhorn's restored `Volume` object is not itself a Kubernetes PV — it needs a static PV and a
PVC bound to it before any pod (or Flux-managed app) can use it.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: agent-os-home
spec:
  capacity:
    storage: 20Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: agent-os-home
    volumeAttributes:
      numberOfReplicas: "2"
      staleReplicaTimeout: "30"
  claimRef:
    name: agent-os-home
    namespace: agent-os
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: agent-os-home
  namespace: agent-os
  labels:
    app.kubernetes.io/part-of: gitops
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: longhorn
  volumeName: agent-os-home
```

```bash
kubectl create namespace agent-os --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f static-pv.yaml    # the two documents above
kubectl -n agent-os get pvc agent-os-home
# STATUS should reach Bound, VOLUME agent-os-home
```

**Why this survives Flux adopting it later:** `apps/agent-os/pvc.yaml` (applied when the OCI
`Kustomization` is enabled in Step 5) is byte-for-byte the same name/namespace/size/storageClass
as what you just created here. When Flux/kustomize-controller applies it via server-side apply,
it patches the existing PVC object in place rather than deleting and recreating it — Kubernetes
treats a PVC apply as an update to the existing resource when name+namespace match, regardless
of whether Flux "remembers" creating it. The pre-bound PVC (and its `volumeName` pointing at the
restored Longhorn volume) is preserved; the restored data is not touched.

---

## 6. Step 4 — Verify the restore before going further

Run a throwaway pod that mounts the PVC and inspect it, without touching agent-os itself:

```bash
kubectl -n agent-os run restore-check --rm -it --restart=Never \
  --image=busybox:1.36 --overrides='
{
  "spec": {
    "containers": [{
      "name": "restore-check",
      "image": "busybox:1.36",
      "command": ["sh"],
      "stdin": true,
      "tty": true,
      "volumeMounts": [{"name": "home", "mountPath": "/home/node"}]
    }],
    "volumes": [{"name": "home", "persistentVolumeClaim": {"claimName": "agent-os-home"}}]
  }
}' -- sh
```

Inside the shell, confirm the expected data is present:

```sh
ls /home/node/.claude/projects/*/memory/           # memories survived
ls -la /home/node/workspace/k3s-lab/.git           # repo checkout survived
ls -la /home/node/.claude/.credentials.json /home/node/.config/claude* 2>/dev/null
                                                    # Claude Code OAuth login / credentials present
exit
```

Do not proceed to Step 5 unless all three are present. If the PVC is empty, the restore did not
complete correctly — go back to Step 2 and confirm `status.restoreRequired` was actually `false`
before the PV/PVC were created.

---

## 7. Step 5 — Enable agent-os on OCI

Only now, with the restored PVC verified `Bound` and populated:

1. Edit `clusters/oci-lab/kustomization.yaml`: move `agent-os-kustomization.yaml` from the
   "Excluded" comment block into the active `resources:` list (alongside the other
   `*-kustomization.yaml` entries).
2. Commit and push.
3. Watch Flux reconcile:

   ```bash
   flux -n flux-system get kustomization agent-os --context oci-lab
   kubectl -n agent-os get pods -w
   ```

Flux applies `apps/agent-os/pvc.yaml`, adopting the pre-bound PVC from Step 3 (see the
explanation there), and starts the Deployment. Because `clusters/oci-lab/agent-os-kustomization.yaml`
carries the `spec.images` override, the pod runs `ghcr.io/tuckermclean/agent-os:0.2.4` (the
multi-arch tag) rather than the base's `:0.2.2`.

---

## 8. Step 6 — Verify on OCI

```bash
kubectl -n agent-os get pods
# agent-os-... Running, both containers ready (agent-os + dind)

kubectl -n agent-os logs deploy/agent-os -c agent-os --tail=50
```

Confirm Claude Code inside the pod registers with Remote Control using the restored OAuth
login — reach it from your phone via Remote Control, not the browser.

> **Note:** the browser ingress `agent.dcxxiv.com` may fail authentik's forwardAuth check until
> authentik's own datastore (Postgres/CNPG) has been migrated/restored on OCI in the later
> datastore phase of the broader OVH→OCI migration — that's expected and tracked separately.
> Remote Control (phone) does **not** depend on that ingress path and is the primary
> verification method here.

---

## 9. Handoff & rollback

Once OCI's `agent-os` is verified working end-to-end, stop using the OVH instance day-to-day.
**OVH's `agent-os` Deployment stays running** (not scaled down) until the broader OVH
decommission — it remains a live, untouched fallback with its own intact PVC the whole time.

- **Rollback:** trivial — just keep using the OVH instance; nothing about its state was ever
  touched by this procedure. On OCI, delete the `agent-os` namespace's Deployment/PVC/PV (or
  just the whole OCI `Kustomization`) if abandoning the migration; the restored Longhorn
  `Volume` can be deleted separately if no longer needed.
- **Optional zero-loss finish:** for a byte-perfect final sync (catching the last few minutes
  of session-log writes missed by the live backup in Step 1), you could later quiesce OVH's
  `agent-os` (scale to 0), take one final backup, and re-restore into OCI. This is optional and
  itself ends the OVH session, so only do it once you're fully ready to cut over — it is not
  part of this runbook's critical path.
