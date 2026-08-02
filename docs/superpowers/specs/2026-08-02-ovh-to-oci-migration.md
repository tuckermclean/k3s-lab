# OVH → OCI Primary Migration & OVH Decommission — Design Spec

**Status:** DRAFT (not reviewed, not approved — sequel to
`2026-08-01-oci-warm-dr-standby-design.md`)

**Purpose:** Design how to flip the OCI Always-Free ARM cluster (`clusters/oci-lab`,
`bootstrap/terraform/oci-k3s`) from warm DR standby to PRIMARY, and fully decommission the
OVH cluster (`clusters/ovh-lab`, `bootstrap/terraform/ovh-k3s`) — driven by cost (the OVH
bill). OCI is currently a warm standby: platform reconciled, CNPG/Galera/Redis running for
real, apps patched to `replicas: 0` / `replicaCount: 0`, hostnames on `*.oci.dcxxiv.com`.
This spec covers resource/storage right-sizing for the free tier, the per-datastore data
migration, apps-on sequencing, DNS/OIDC cutover, the still-missing Galera recovery runbook,
codifying known manual gaps, and OVH teardown.

Grounded by reading: `docs/superpowers/specs/2026-08-01-oci-warm-dr-standby-design.md`,
`docs/runbooks/dr.md`, all of `clusters/oci-lab/*` and `clusters/ovh-lab/*`,
`infrastructure/database/postgres/cluster.yaml` (+ `git log`/`git show` on
`b824c56`/`73ce88b`/#144/#146 and the still-open `feat/cnpg-bootstrap-recovery` branch),
`infrastructure/database/mariadb/*`, `infrastructure/database/redis/helmrelease.yaml`,
`infrastructure/database/cloudnative-pg/helmrelease.yaml`, `infrastructure/storage/{longhorn,
juicefs}/*`, `bootstrap/terraform/oci-k3s/*` (`storage.tf`, `scripts/prepare-data-disk.sh`,
`dns.tf`, `budget.tf`, `variables.tf`, `terraform.tfvars.example`, `flux.tf`),
`bootstrap/terraform/ovh-k3s/dns.tf`, `bootstrap/terraform/authentik/*.tf`, the root
`Makefile`, `docs/runbooks/` (naming convention).

Baseline facts this design leans on (all re-verified against the current repo state, not
carried over unchecked from the prior spec):

- **OCI's datastores are already live, OCI's apps are not.** `clusters/oci-lab/postgres-
  kustomization.yaml`, `mariadb-kustomization.yaml`, and `redis-kustomization.yaml` carry no
  scale-down patches — CNPG `pg` (3 instances), `mariadb-galera` (3 pods), and `redis-ha`
  (3 pods) are running for real today. Only the *app* Kustomizations
  (`personliness`, `hero`, `dcxxiv-home`, `wordpress`, `orchestrator`, `nodecast-tv`) carry
  `replicas: 0` / `replicaCount: 0` patches. `deluge-kustomization.yaml` doesn't exist in
  `clusters/oci-lab/` at all (JuiceFS dependency).
- **OCI's CNPG `pg` Cluster already exists — empty, not restored.** This matters:
  `bootstrap.recovery` is honored by CNPG **only at initial Cluster object creation** (this
  is explicitly called out in `b824c56`'s own commit message and preserved verbatim on the
  still-open `feat/cnpg-bootstrap-recovery` branch, which was merged as PR #144 and reverted
  the same day in PR #146 — `git log --oneline -- infrastructure/database/postgres/
  cluster.yaml` shows `e55553c → dc82e0d → b824c56 → 73ce88b`, and `git diff origin/main
  origin/feat/cnpg-bootstrap-recovery -- infrastructure/database/postgres/cluster.yaml`
  shows the branch still carries the exact reverted diff, unmodified, today). Since OCI's
  `pg` Cluster was already created (empty) during standby standup, simply patching in
  `bootstrap.recovery` now is a **no-op** — CNPG will not retroactively restore an existing
  cluster. The Cluster object must be deleted (safe: it's empty, nothing depends on it while
  apps are at `replicas: 0`) and allowed to recreate with the stanza present. See §4.
- **`infrastructure/database/postgres/cluster.yaml`'s DB names are `personliness` and
  `authentik`** (confirmed directly in the `Database` CRs and in `managed.roles`, and cross-
  checked against `docs/runbooks/dr.md` step 6.1, which names the same two DBs).
- **The mysqldump Galera-compatibility rewrite is documented but not implemented.**
  `infrastructure/database/mariadb/backup-cronjob.yaml` says "Note for PR4 cutover: rewrite
  mysqldump output with sed to: strip DEFINER clauses / MyISAM→InnoDB / ensure PRIMARY KEY,"
  but the actual pipeline is `mysqldump | gzip | aws s3 cp` — no sed pass exists today. This
  is a real gap, not just a caveat to "respect" at restore time. See §4 and §8.
- **Galera hardening is done.** `infrastructure/database/mariadb/helmrelease.yaml`: `timeout:
  15m` (line 28, to survive slow ARM SST), `resources.requests.cpu: "100m"` (line 98, sized
  to fit the 3rd Galera pod under free-tier budget), and a hard
  `requiredDuringSchedulingIgnoredDuringExecution` pod anti-affinity, one pod per node (lines
  84–90). Nothing left to do here except write the recovery runbook (§7).
- **`kube-prometheus-stack` and Longhorn carry no explicit resource requests in this repo.**
  `infrastructure/monitoring/helmrelease.yaml` sets `prometheus.prometheusSpec.replicas: 2`
  and `alertmanager.alertmanagerSpec.replicas: 3` but no `resources:` block anywhere in the
  file — everything is chart defaults. `infrastructure/storage/longhorn/helmrelease.yaml`
  likewise sets no `resources:` and no `defaultSettings.guaranteedInstanceManagerCPU`/
  `guaranteedEngineManagerCPU`/`guaranteedReplicaManagerCPU` override (Longhorn's own
  mechanism for reserving a percentage of node CPU for instance-manager pods) — it's running
  on whatever the chart 1.11.3 default is. These are the two real unknowns; CNPG (3×250m =
  750m), MariaDB (3×100m = 300m), and Redis-ha (3×(50+25+25m) = 300m) are already lean and
  already grounded in explicit numbers in their manifests.
- **Storage sizing hasn't been touched since the standby design.** `bootstrap/terraform/
  oci-k3s/variables.tf`: `data_volume_size_gbs` still defaults to `0` (`storage.tf`'s
  `local.data_volumes_enabled` is false everywhere, so `oci_core_volume`/`prepare-data-disk.sh`
  have never run for real), `boot_volume_size_gbs` still defaults to `50`. The `terraform.tfvars
  .example` comment (`# data_volume_size_gbs = 30 ... 3x35 boot + 3x30 data = 195 GB, under the
  200 GB cap`) documents the original stay-inside-free-tier plan, but `boot_volume_size_gbs`
  was never actually shrunk from 50 — and shrinking it now would mean recreating 3 already-
  live, already-Flux-bootstrapped nodes (boot volume size is fixed at instance launch in OCI).
  See §3.
- **`bootstrap/terraform/oci-k3s/dns.tf` and `budget.tf` exist now** (they didn't at standby-
  design time) — but not quite as the prior spec sketched. The variable is `manage_dns` (a
  plain bool, present on **both** `ovh-k3s` and `oci-k3s`), not a hypothetical
  `manage_apex_dns`. OCI's `cloudflare_record.oci` resource hardcodes `name = "oci"` (the
  subdomain) — it is not parameterized to become the apex `@` record. `budget.tf` matches
  the prompt exactly: `oci_budget_budget.free_tier_guard`, `amount = 1` (whole dollars,
  OCI's minimum), an `ACTUAL` alert at 1% (fires on literally the first cent) and a
  `FORECAST` alert at 100%, both emailing `me@tuckermclean.com`. See §3 and §6.
- **`bootstrap/terraform/authentik/*.tf` is a single, unparameterized module already
  targeting bare `dcxxiv.com` hostnames** (`grafana.tf`, `nodecast.tf`, `weave.tf`,
  `headlamp.tf`, `agent-os.tf`, `deluge.tf`, `juggler.tf`, `orchestrator.tf` — every
  `external_host`/`allowed_redirect_uris`/`meta_launch_url` is `https://<app>.dcxxiv.com`,
  never `.oci.`). `provider "authentik" { url = var.authentik_url }` defaults to
  `https://auth.dcxxiv.com`. There is no second OCI-specific Authentik Terraform config —
  the "parameterize Authentik ownership" question the prior spec deferred turns out to have
  a simpler answer for *this* migration: see §6.
- **`make install-sops-age` is confirmed not wired into any OCI apply/bootstrap chain.**
  Root `Makefile`: `apply-oci` and `flux-bootstrap-oci-lab` (lines 139–146, 190–216) call
  `recover-age-key` but never `install-sops-age` — it's a documented, separate manual step
  (`Makefile` lines 88–95). See §8.
- **JuiceFS's stale example is still unfixed.** `infrastructure/storage/juicefs/
  secret.example.yaml` still shows `metaurl: redis://juicefs-redis-master.kube-system...`;
  the real service is `redis-ha-haproxy.redis` (per `redis-meta-backup-cronjob.yaml`'s
  `juicefs-secret`/`metaurl` usage and `authentik/helmrelease.yaml`'s working Redis
  reference). Flagged in the prior spec's §7 item 3 as non-blocking; still true today. See §8.

---

## 1. Cutover strategy

**Options**

| # | Approach | Downtime | Rollback |
|---|---|---|---|
| A | Big-bang: stop OVH writes, final data sync (Postgres/MariaDB/Longhorn restore + final JuiceFS metadata load), DNS flip. Minimal dual-run. | One maintenance window, length = however long the Postgres/MariaDB/Longhorn restores + JuiceFS unmount/mount sequencing actually take (unmeasured until Phase B rehearsal — see §10). | DNS flip back is instant (`manage_dns` toggle + `terraform apply`), but only if OVH is still *up* and its data hasn't diverged — see fallback window below. |
| B | Gradual/per-app cutover — move each app to OCI independently over days/weeks. | Spread out, but doesn't actually reduce the hard risk: `personliness` and `authentik` share one CNPG cluster restored in one action; `wordpress` (and `deluge`, once JuiceFS is back) share one Galera cluster restored in one action; JuiceFS is a single filesystem mount, not a per-app switch. The *only* apps with no datastore dependency are `hero` and `dcxxiv-home` — moving those "gradually" ahead of the rest is really just a low-risk rehearsal wave, not a genuinely gradual migration of the hard part. | Per-app rollback is easy for the two stateless apps, meaningless for the rest (their state already moved with the whole datastore). |
| C | Keep OVH running as a warm fallback for N days post-cutover before teardown (this is additive to A or B, not an alternative execution mechanic). | Same as whichever of A/B is chosen for the actual cutover. | Much safer: OVH stays intact (not destroyed, just not receiving writes/DNS traffic) for N days, so a bad surprise on OCI can fall back to a known-good OVH instead of a Longhorn/Barman/mysqldump restore-from-backup under pressure. |

**Recommendation: A (big-bang cutover mechanics) combined with C (an explicit N-day OVH
fallback window before teardown)**, with the stateless-app wave from B (`hero`,
`dcxxiv-home` first) folded in as a low-risk rehearsal step within the same maintenance
window, not a separate calendar phase.

Rationale: the expensive, risky part of this migration is entirely at the datastore layer
(CNPG, Galera, JuiceFS metadata+mount), and none of those are divisible per-app — Option B's
"gradual" framing doesn't reduce that risk, it just extends the window during which OVH and
OCI both partially exist, with no corresponding safety benefit. A single, well-rehearsed
maintenance window (A) is both simpler to reason about and shorter in wall-clock risk
exposure. But because the cost driver here is "stop the recurring OVH bill," not "OVH must
be gone today," there's no reason to destroy OVH's Terraform state in the same breath as the
DNS flip — the asymmetry between rolling back DNS (trivial, instant) and rolling back
*data* (not trivial once OCI starts taking real writes) is exactly what C's fallback window
buys cheaply: a few more days of OVH's bill in exchange for a real rollback path if OCI
surfaces a problem only visible under production traffic. Exact N is an open decision (see
end of document) — it should be informed by how confident Phase B's rehearsals leave you,
not fixed in advance.

---

## 2. Free-tier resource right-size

**Current known CPU *requests* on OCI today** (3× 1-OCPU ARM nodes ≈ 3000m allocatable
before k3s/OS overhead, realistically closer to ~2.6–2.8 vCPU usable):

| Component | Requests today | Source |
|---|---|---|
| CNPG `pg` (3 instances) | 3 × 250m cpu / 256Mi mem = 750m / 768Mi | `infrastructure/database/postgres/cluster.yaml` |
| MariaDB Galera (3 pods) | 3 × 100m cpu / 256Mi mem = 300m / 768Mi | `infrastructure/database/mariadb/helmrelease.yaml` |
| Redis-ha (redis+sentinel+haproxy, 3 pods each) | 3 × (50+25+25)m = 300m | `infrastructure/database/redis/helmrelease.yaml` |
| kube-prometheus-stack (prometheus×2, alertmanager×3, grafana×1, kube-state-metrics, node-exporter×3, operator) | **unset — chart defaults** | `infrastructure/monitoring/helmrelease.yaml` (no `resources:` block at all) |
| Longhorn (manager DaemonSet×3, instance-manager per node, csi sidecars) | **unset — chart defaults / `guaranteedInstanceManagerCPU` not overridden** | `infrastructure/storage/longhorn/helmrelease.yaml` |

The two biggest unknowns — and therefore the two highest-value places to spend right-sizing
effort — are kube-prometheus-stack and Longhorn, precisely because nothing in the repo pins
them today. A concrete first step before writing any patch is an actual measurement pass
(`kubectl top pods -A` / `kubectl describe` on the running standby, since it's already live)
rather than guessing chart defaults.

**Concrete levers, once measured:**
- `clusters/oci-lab/monitoring-kustomization.yaml` already carries a `patches:` block
  (Certificate + HelmRelease hostnames) — extend it with explicit `values.prometheus
  .prometheusSpec.resources.requests` / `alertmanager.alertmanagerSpec.resources.requests`,
  and consider dropping `prometheus.prometheusSpec.replicas` 2→1 and `alertmanager
  .alertmanagerSpec.replicas` 3→1 specifically for `oci-lab` (HA monitoring redundancy is a
  much lower priority than fitting the actual application workload on 3 free-tier nodes).
- `clusters/oci-lab/longhorn-kustomization.yaml` (currently just a `dependsOn`, no
  `patches:`) gets a patch setting `defaultSettings.guaranteedInstanceManagerCPU` (or the
  split `guaranteedEngineManagerCPU`/`guaranteedReplicaManagerCPU` settings, depending on
  what chart 1.11.3 actually exposes — confirm against the live `Setting` CRs before
  writing the patch) to a lower percentage appropriate for a 1-OCPU node.

**Approach: per-cluster Kustomize patch (`clusters/oci-lab/*`), not a shared Helm values
change.**

This matches the convention already locked in by the prior spec's §1 (Option B — inline
`patches:` in per-cluster Flux `Kustomization` CRs) and is already the pattern used in
`clusters/oci-lab/monitoring-kustomization.yaml` and `authentik-kustomization.yaml` today.
Editing the shared `infrastructure/monitoring/helmrelease.yaml` or `infrastructure/storage/
longhorn/helmrelease.yaml` directly would also shrink OVH's requests/replica counts for a
problem that is specifically about OCI's free-tier node size — OVH has no such constraint,
and there's no reason to risk perturbing its currently-working monitoring/storage stack to
solve OCI's fit problem. Keep the constraint isolated to `clusters/oci-lab/`.

---

## 3. Storage right-size

**Recommendation: set `data_volume_size_gbs = 25` (or `30`) in OCI's terraform vars,
*without* shrinking `boot_volume_size_gbs` from its current `50`.**

Math: 3 × 50 GB boot (150 GB) + 3 × 25–30 GB data (75–90 GB) = 225–240 GB total, against the
200 GB Always Free block-storage cap — 25–40 GB over, incurring a small OCI PAYG charge
(this is exactly the scenario `budget.tf`'s `oci_budget_budget.free_tier_guard` ($1/month
tripwire) exists to catch and notify on, not prevent — expect the `actual_first_cent` alert
to fire once this lands, and treat that as confirmation it worked, not a bug). This clears
the ~21 GB/node peak Longhorn usage measured on OVH with real headroom.

The alternative — shrinking boot volumes to ~30–35 GB (matching the aspirational math
already sitting in `terraform.tfvars.example`'s commented-out example: "3x35 boot + 3x30 data
= 195 GB, under the 200 GB cap") to stay fully inside the free tier — was the original
green-field plan, but OCI's boot volume size is fixed at instance launch; shrinking it now
means destroying and recreating all 3 already-live, already-Flux-bootstrapped nodes right
before a primary cutover. That's a materially riskier operation than accepting an
estimated-~$1/month PAYG charge, for a project whose entire premise is reducing hosting
cost. Recommend accepting the small spend.

**This is the first real exercise of `storage.tf` / `scripts/prepare-data-disk.sh` on OCI —
flag as untested.** `local.data_volumes_enabled = var.data_volume_size_gbs > 0` has evaluated
false in every apply so far, so `oci_core_volume`, `oci_core_volume_attachment`, and the
`null_resource.prepare_data_disk_{server,agent}` provisioners have never actually run against
OCI. `prepare-data-disk.sh`'s device-discovery logic (`/dev/oracleoci/oraclevdb` symlink,
falling back to a size-matched `lsblk` scan) and its bind-mount/rsync/fstab logic for
`/var/lib/longhorn` and `/var/lib/rancher/k3s/storage` is a direct port of the OVH pattern
but has zero OCI-specific mileage. Recommend rehearsing this in Phase A (§10) — apply it,
watch the `null_resource` provisioner output closely, and follow the script's own printed
guidance to reboot nodes one at a time (Longhorn's `defaultReplicaCount: 2` tolerates one
node down) rather than doing it live for the first time during the cutover window itself.

**Online-resize path if 25–30 GB proves insufficient:** OCI block volumes support online
resize (`oci_core_volume.size_in_gbs` bump via `terraform apply`, no downtime to the
attachment), but the in-guest side — `growpart`/`resize2fs` on the ext4 filesystem
`prepare-data-disk.sh` created — is **not scripted today**. That script only formats
if-blank; it has no resize path. Note this as a gap to close (a small follow-up to
`prepare-data-disk.sh`, or a documented manual `growpart`/`resize2fs` runbook step) if/when
a resize is actually needed, rather than something already handled.

---

## 4. Per-datastore data migration

General constraint carried over from the standby design: nothing on OCI may disrupt or
corrupt what OVH is still actively writing to, until OVH is confirmed stopped.

### Postgres / CNPG

OCI's `pg` Cluster (namespace `postgres`) **already exists, already empty**, created
directly by `clusters/oci-lab/postgres-kustomization.yaml` during standby standup (the
`/spec/backup` removal + `ScheduledBackup pg-daily` deletion patches are already applied;
`instances: 3` is unmodified from the shared base). This is the critical wrinkle:
`bootstrap.recovery` (the stanza built on `feat/cnpg-bootstrap-recovery`, merged as #144 and
reverted same-day as #146 specifically because it's a no-op against an *existing* running
cluster — see baseline facts above) **will not retroactively restore an already-created
Cluster**. To actually use it on OCI:

1. Delete OCI's existing `pg` Cluster object (and its PVCs) — safe, it's empty and nothing
   depends on it while apps sit at `replicas: 0`.
2. Add a patch to `clusters/oci-lab/postgres-kustomization.yaml` that reintroduces
   `spec.bootstrap.recovery.source: pg-backup` and the `spec.externalClusters` entry from
   `feat/cnpg-bootstrap-recovery` (the stanza is already authored on that branch — reuse it
   verbatim rather than re-deriving it):
   ```yaml
   spec:
     bootstrap:
       recovery:
         source: pg-backup
     externalClusters:
       - name: pg-backup
         barmanObjectStore:
           destinationPath: s3://k3s-lab-backups/postgres/pg
           s3Credentials: { ...same as backup.barmanObjectStore... }
           wal:
             compression: gzip
   ```
   `externalClusters` here is a **read-only recovery source reference** — it doesn't write
   anything, so it's safe for this to point at OVH's live path even while OVH keeps
   archiving WAL there (this is exactly what `b824c56`'s own inline comment says: "OVH keeps
   archiving WAL to `s3://k3s-lab-backups/postgres/pg` as before").
3. Flux recreates the `pg` Cluster fresh, and CNPG restores the `personliness` and
   `authentik` databases from the Barman object store.
4. **Shared-WAL-path hazard — do not re-add `backup.barmanObjectStore` pointed at the same
   path.** Once restored, if OCI's `pg` Cluster is configured to *archive* (not just read
   from) `s3://k3s-lab-backups/postgres/pg`, two independent PG timelines writing WAL to the
   same barman prefix corrupts the backup chain for both — this is the same warning the
   standby design already banked (`clusters/oci-lab/postgres-kustomization.yaml`'s existing
   comment says almost exactly this). Give OCI's own backup a **distinct, permanent** path —
   e.g. `s3://k3s-lab-backups/postgres/pg-oci` — from the moment of cutover onward, even
   after OVH is decommissioned. There's no benefit to later "reclaiming" OVH's old path once
   it's gone; that would just be a second migration of the backup target for no reason.
   Update `docs/runbooks/dr.md`'s Postgres backup location once this lands.

### MariaDB / Galera

Restore the latest `.sql.gz` from `s3://k3s-lab-backups/mysql/wordpress/` into OCI's
already-running `mariadb-galera` (mirrors `dr.md` Step 6.3). **Before this restore is
trustworthy, close the gap flagged in the baseline facts**: `infrastructure/database/mariadb/
backup-cronjob.yaml` documents but does not implement the DEFINER-strip / MyISAM→InnoDB /
PRIMARY-KEY-enforcement rewrite. Recommend fixing this **at the source** — add the sed pass
to the CronJob's dump pipeline itself, so every future dump (not just the one used for this
migration) is Galera-clean at rest. This also benefits OVH's own from-scratch DR path
(`dr.md` §2 Step 6.3), which has the identical caveat. Do this in Phase A (§10), before Phase
B's MariaDB restore rehearsal — restoring the *current*, un-rewritten dump format into
Galera will just reproduce the failure mode the comment already predicts.

### Longhorn volumes

Restore each app's PV via the CSI VolumeSnapshot path (`VolumeSnapshotContent` sourced from
the Longhorn S3 backup target → `VolumeSnapshot` → PVC with `dataSource:`), gated so the
restore completes *before* that app's Flux Kustomization/replica count is turned on —
otherwise Flux creates an empty PVC that shadows the real data, same risk called out in the
standby design's §3.

### JuiceFS — do not dual-mount

Per the standby design's own decision, JuiceFS metadata has been refreshing continuously
(nightly `juicefs load` into OCI's own `redis-ha` DB2) throughout the standby period, so it
should already be close to current — do one final load immediately before cutover to close
any remaining gap. The CSI driver itself is still **not installed** on OCI
(`juicefs-kustomization.yaml` / `juicefs-s3-gateway-kustomization.yaml` are deliberately
absent from `clusters/oci-lab/kustomization.yaml`, and `deluge-kustomization.yaml` doesn't
exist there either).

**Critical sequencing — this must be scripted, not judgment-called at cutover time:**
1. Stop OVH's JuiceFS mount first. On OVH, the only pod mounting the `juicefs` StorageClass
   is `deluge` (`apps/deluge/media-volume.yaml`'s `juicefs-media-bucket` PVC,
   `storageClassName: juicefs`). Scale `deluge`'s Deployment to 0 on OVH and confirm no
   JuiceFS CSI mount remains active (e.g. no mount namespace holding the bucket open) before
   proceeding.
2. Only once that's confirmed, add `juicefs-kustomization.yaml` and
   `juicefs-s3-gateway-kustomization.yaml` to `clusters/oci-lab/kustomization.yaml` (mirroring
   OVH's Flux Kustomization name `storage-juicefs`, path `./infrastructure/storage/juicefs`),
   and re-add `deluge-kustomization.yaml` to `clusters/oci-lab/` (it doesn't exist there
   today — it's excluded specifically because of this JuiceFS dependency).
3. Two independent metadata engines (OVH's Redis vs. OCI's Redis) both tracking block
   references/GC against the same underlying S3 data bucket is the corruption mode being
   guarded against here — the same one the standby design flagged. There is no reason to
   relax this now; it just moves from "standby forever" to "one deliberate one-way flip at
   cutover."

---

## 5. Apps on

Remove the `replicas: 0` / `replicaCount: 0` patches, sequenced strictly behind their
datastore being restored and verified — do not flip an app on before its data dependency is
confirmed:

1. `personliness-kustomization.yaml`, `authentik` (no explicit replica patch — Authentik
   HelmRelease values already point at the restored CNPG `pg`/`authentik` DB) — after CNPG
   restore (§4) verified.
2. `wordpress-kustomization.yaml` — after MariaDB restore (§4) verified.
3. `nodecast-tv-kustomization.yaml`, `hero-kustomization.yaml`, `dcxxiv-home-kustomization
   .yaml` — no datastore dependency; these are the lowest-risk wave and can go first as a
   confidence-building rehearsal step inside the same cutover window (see §1).
4. `orchestrator-kustomization.yaml` — depends on a Longhorn PVC (SQLite); after the
   Longhorn restore (§4) for that PVC is verified.
5. `deluge` (new Kustomization) — only after the JuiceFS unmount/mount sequencing (§4) is
   confirmed complete. This is necessarily last.

---

## 6. DNS cutover

**Correction to the prior spec's sketch:** the actual variable that exists in both
`bootstrap/terraform/oci-k3s/variables.tf` and `bootstrap/terraform/ovh-k3s/variables.tf` is
`manage_dns` (a plain bool, default `true` on both) — there is no `manage_apex_dns` anywhere
in the repo. More importantly, `oci-k3s/dns.tf`'s `cloudflare_record.oci` resource hardcodes
`name = "oci"` — it manages the `oci.dcxxiv.com` subdomain, not the apex. It is **not**
parameterized to become the apex `@` record. `ovh-k3s/dns.tf`'s `cloudflare_record.apex`
does `name = "@"` across `for_each = toset(local.all_node_ips)`.

To flip the bare-domain apex from OVH to OCI:
1. Add a new resource to `bootstrap/terraform/oci-k3s/dns.tf` — either a second
   `cloudflare_record.apex` block (`name = "@"`, same `for_each` pattern as OVH's, pointed at
   `oci_core_instance.server[*].public_ip`), or generalize the existing resource's `name`
   behind a new variable. Either way, this is new Terraform authoring — nothing in the repo
   does this today.
2. Set `manage_dns = false` on `ovh-k3s` (or accept its apex records are about to be
   destroyed along with the module in §9), enable the new apex resource on `oci-k3s`, and
   `terraform apply` on OCI. `dcxxiv.com`'s apex `A` records now point at the OCI node public
   IPs.
3. **Per-app hostnames flip from `*.oci.dcxxiv.com` back to bare `*.dcxxiv.com`** by deleting
   (not editing) the hostname-rewrite `patches:` blocks in each `clusters/oci-lab/*-
   kustomization.yaml` file that carries one — confirmed present in `personliness`, `hero`,
   `dcxxiv-home`, `wordpress`, `nodecast-tv`, `orchestrator`, `monitoring`, and `authentik`.
   Since OVH's own Kustomizations carry **no** hostname patches at all (base manifests like
   `apps/wordpress/ingress.yaml` already hardcode bare `lol.dcxxiv.com`), deleting these
   patch blocks is sufficient — no new bare-hostname patches need to be authored, the base
   manifests already have them.
4. cert-manager's `letsencrypt-prod` ClusterIssuer (DNS01/Cloudflare) issues fresh
   Certificates for the now-bare hostnames automatically once the Ingress/Certificate/
   IngressRoute objects reconcile with bare `dnsNames`/`Host()` — no manual cert action
   needed, same non-conflict property (DNS01 validates the *name*, not the serving cluster)
   the standby design already relied on.

**Authentik OIDC — simpler than the prior spec anticipated.** `bootstrap/terraform/
authentik/*.tf` is a single, already-existing, unparameterized module whose
`external_host`/`allowed_redirect_uris`/`meta_launch_url` values are **already bare
`dcxxiv.com`** (never `.oci.` — see baseline facts), and `provider "authentik" { url =
var.authentik_url }` defaults to `https://auth.dcxxiv.com`. This means once DNS (step 2
above) makes `auth.dcxxiv.com` resolve to OCI, the existing `make dr-authentik` target
(`Makefile` — removes stale local Terraform state, then `apply-authentik`) is the exact
right tool: it registers the same OAuth2/proxy-provider clients this migration needs against
OCI's now-restored Authentik DB, with zero new Terraform authoring. No second
"OCI Authentik" module needs to be built — the prior spec's deferred question ("one
parameterized config vs. two separate states") resolves itself here because the redirect
URIs were never OCI-specific to begin with.

---

## 7. Galera hardening runbook

The hardening work itself is **done**: `infrastructure/database/mariadb/helmrelease.yaml`
already has the 15-minute HelmRelease `timeout` (line 28, to survive slow ARM SST), the
100m CPU `resources.requests` (line 98, sized for free-tier fit), and the hard
one-pod-per-node `podAntiAffinity` (lines 84–90). What's missing is the recovery runbook.

`docs/runbooks/` currently holds `dr.md` and `ovh-terraform-state-migration.md` — flat,
lowercase-hyphenated filenames directly under `docs/runbooks/`. Following that convention,
add **`docs/runbooks/galera-recovery.md`** covering:
- **Split-brain / `safe_to_bootstrap: 0` deadlock** — the failure mode
  `mariadb-galera/helmrelease.yaml`'s own comment already alludes to ("remediation's
  uninstall then kills a node uncleanly -> `safe_to_bootstrap:0` deadlock -> reinstall
  spiral"). Standard Galera recovery: identify the node with the highest `seqno` in
  `grastate.dat` across the 3 pods, manually set `safe_to_bootstrap: 1` on that one, restart
  it first to re-form the cluster, then bring the other two up to rejoin via SST/IST.
- **All-pods-down recovery** — cold-start bootstrap of a fresh Galera cluster from the
  bitnami `mariadb-galera` chart (chart version pinned at `16.0.1` per the HelmRelease);
  confirm the exact chart value names for forcing a bootstrap node against that chart's
  `values.yaml` when the runbook is written, rather than assuming a name here.
- Cross-reference `docs/runbooks/dr.md` Step 6.3 (MariaDB restore) so the two runbooks don't
  duplicate/contradict the mysqldump-restore procedure.

---

## 8. Codify standup gaps

**`make install-sops-age` gap — confirmed real.** Neither `apply-oci` nor
`flux-bootstrap-oci-lab` (root `Makefile`) calls `install-sops-age`; it's a separate,
documented-but-manual step. Recommend either (a) wiring `flux-bootstrap-oci-lab` to run
`install-sops-age` automatically once the OCI kubeconfig exists (it already depends on
`recover-age-key`, so the age key material is present at that point in the chain), or (b) if
automating it is judged too fragile (kubeconfig/context switching between OVH and OCI in the
same Makefile target), at minimum promote it from "documented step" to an explicit,
numbered, un-skippable step in the cutover runbook this spec's Phase C produces — not a step
that only lives in tribal knowledge from the standby-design exercise.

**Other one-off manual gaps found with direct evidence in the repo, that should be made
permanent/codified rather than left as tribal knowledge:**
- `infrastructure/storage/juicefs/secret.example.yaml`'s stale `metaurl`
  (`juicefs-redis-master.kube-system` instead of the real `redis-ha-haproxy.redis`) — still
  unfixed since the standby spec flagged it. Fix now, before this migration's JuiceFS work
  gives someone a reason to copy from the example again.
- The mysqldump DEFINER/MyISAM/PK rewrite (§4) — documented as a TODO comment
  ("Note for PR4 cutover") rather than implemented. Fix at the source in the CronJob itself.
- The DNS `manage_apex_dns`-vs-`manage_dns` naming/parameterization gap (§6) — `oci-k3s/
  dns.tf` needs new authoring to support becoming the apex owner; this isn't a pre-existing
  automated path today and should land as reviewable Terraform, not a one-off `terraform
  console` edit at cutover time.
- **Not a gap, already resolved:** the standby design's open item "no S3 remote state for
  `oci-k3s`" is done — `bootstrap/terraform/oci-k3s/versions.tf` already has a `backend "s3"`
  block. Noted here only so it isn't mistakenly re-flagged as outstanding work.

---

## 9. OVH decommission

Only after OCI-as-primary is verified stable and the fallback window (open decision) has
elapsed, run `terraform destroy` against `bootstrap/terraform/ovh-k3s` — the existing
`make destroy-ovh` target already wraps this (`SOPS_AGE_KEY_FILE=... $(MAKE) -C
$(OVH_TF_DIR) destroy`, root `Makefile`).

**Pre-teardown verification checklist:**
- `flux get all -A` clean on OCI — no failing Kustomizations/HelmReleases, per `dr.md` §4.
- All apps (`personliness`, `hero`, `dcxxiv-home`, `wordpress`, `orchestrator`,
  `nodecast-tv`, `deluge`) reachable at bare `*.dcxxiv.com` hostnames with `kubectl get
  certificate -A` showing `Ready`.
- Authentik login smoke test, a JuiceFS-backed app smoke test (read + write, confirming
  single-mount integrity), and the WordPress site — same trio `dr.md` §4 already prescribes,
  reused here.
- Spot-check row/content counts on the restored `personliness` and `authentik` databases
  against last-known OVH values.
- Confirm OCI's *own* backup chain is live and green before OVH — its former backup
  source of truth — disappears: CNPG `ScheduledBackup` writing to the new distinct
  `pg-oci` path (§4), the MariaDB `wordpress-db-backup` CronJob, the Longhorn
  `RecurringJob backup-daily`, and the `juicefs-meta-backup` CronJob all need at least one
  successful run against OCI's own state before OVH goes away.
- Confirm zero live traffic to OVH for the duration of the fallback window (Cloudflare
  analytics / Traefik access logs on OVH show nothing after the DNS flip).
- Fallback window (N days, open decision) elapsed with no rollback triggered.

Then `make destroy-ovh`, and confirm outside the repo (OVH billing console) that the bill
actually stops — that confirmation isn't something this repo can verify for you.

---

## 10. Prerequisites & phase decomposition

**Phase A — Right-size + storage sizing + Galera runbook + fix known gaps (safe, no data
movement, can happen anytime).**
- §2: measure current kube-prometheus-stack/Longhorn resource usage, author
  `clusters/oci-lab/monitoring-kustomization.yaml` and `longhorn-kustomization.yaml` patches.
- §3: rehearse `data_volume_size_gbs` bump + `storage.tf`/`prepare-data-disk.sh` apply
  (first real exercise of that code path).
- §7: write `docs/runbooks/galera-recovery.md`.
- §8: fix the JuiceFS `secret.example.yaml` stale `metaurl`, fix the mysqldump sed-rewrite
  gap at the source, decide and wire up the `install-sops-age` automation (or formalize it
  as a numbered runbook step).
- §6 (partial): author the new apex-DNS Terraform for `oci-k3s` (don't apply it yet).

**Phase B — Data restore rehearsal (practice restoring each datastore into OCI without
affecting OVH, verify integrity).**
- §4 Postgres: delete OCI's existing empty `pg` Cluster, add the `bootstrap.recovery`
  stanza (reused from `feat/cnpg-bootstrap-recovery`) with a *distinct* `pg-oci` backup
  path, verify the `personliness`/`authentik` DBs restore correctly.
- §4 MariaDB: restore the now-Galera-clean dump (post Phase A fix) into OCI's Galera,
  verify.
- §4 Longhorn: rehearse the VolumeSnapshot restore path for at least one representative app
  PVC.
- §4 JuiceFS: script and dry-run the OVH-unmount-before-OCI-mount sequence end to end
  (against non-serving OCI, since apps are still at `replicas: 0` throughout this phase).
- Log results in `docs/runbooks/dr.md`'s rehearsal log (currently empty).

**Phase C — Cutover (apps on, DNS flip, per the chosen strategy in §1).**
- §5: apps on, sequenced behind their verified datastore restore.
- §6: apply the apex DNS Terraform, delete the `*.oci.dcxxiv.com` hostname patches,
  `make dr-authentik`.

**Phase D — Decommission (fallback window, then OVH teardown).**
- §9: pre-teardown verification checklist, wait out the fallback window, `make destroy-ovh`.

**Hard prerequisites/blockers, called out explicitly:**
- The CNPG recovery stanza must be authored **and its delete-then-recreate mechanics
  tested** in Phase B — this is not simply "add a patch," it requires deleting OCI's
  already-existing empty `pg` Cluster first, which must happen in rehearsal, not cutover
  night.
- The JuiceFS unmount-before-mount sequencing must be scripted and rehearsed before cutover
  night — there is no safe way to improvise this live given the dual-mount corruption risk.
- The mysqldump sed-rewrite gap should be fixed in Phase A, before Phase B's MariaDB restore
  rehearsal even runs — restoring the current unrewritten dump format will just reproduce
  the failure the backup-cronjob's own comment predicts.

---

## OPEN DECISIONS (need the human)

- Which cutover strategy (§1) to actually use — this spec recommends big-bang mechanics
  (A) plus an OVH fallback window (C), but that's a recommendation, not a decision.
- Length of the OVH fallback window post-cutover, in days (§1, §9).
- Downtime tolerance — is a maintenance-window outage acceptable, and how long (§1) — this
  can only be bounded once Phase B's rehearsals measure actual restore durations.
- Whether `*.oci.dcxxiv.com` should become a permanent secondary subdomain, or disappear
  entirely once bare `*.dcxxiv.com` points at OCI (§6).
- Rehearsal cadence for the data-restore dry run (§10 Phase B) — once vs. multiple times
  before committing to cutover night.
