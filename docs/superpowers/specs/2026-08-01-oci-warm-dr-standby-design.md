# OCI Warm DR Standby — Design Spec

**Status:** APPROVED (decisions locked 2026-08-01)

**Purpose:** Design how to stand up the OCI Always-Free ARM cluster (`bootstrap/terraform/oci-k3s`) as a warm DR standby for the OVH `clusters/ovh-lab` production cluster — GitOps structure, DNS, stateful data seeding, active/standby coordination, storage sizing, and promotion — without touching anything OVH depends on.

Grounded by reading: `bootstrap/terraform/oci-k3s/*`, `bootstrap/terraform/ovh-k3s/*`,
`clusters/ovh-lab/*`, `clusters/oci-lab/kustomization.yaml`, ~15 `infrastructure/*` and
`apps/*` kustomizations, `docs/runbooks/dr.md`, `infrastructure/database/postgres/cluster.yaml`,
`infrastructure/database/cloudnative-pg`, `infrastructure/storage/{longhorn,juicefs}/*`,
`.sops.yaml`, `bootstrap/BOOTSTRAP.md`.

Baseline facts this design leans on:

- `clusters/ovh-lab/kustomization.yaml` aggregates ~30 **flat** `*-kustomization.yaml`
  files (Flux `Kustomization` CRs), each pointing `path:` directly at a shared
  `infrastructure/<x>` or `apps/<x>` directory. There are **no per-cluster kustomize
  overlay directories** anywhere in the repo today.
- Two precedents for per-cluster variance already exist in that flat model:
  - `patches:` inline in the Flux `Kustomization` CR — used today in
    `longhorn-kustomization.yaml` to activate the OVH-only S3 `backupTarget` without
    touching the shared HelmRelease base.
  - `postBuild.substitute` / `substituteFrom` — used today in
    `orchestrator-kustomization.yaml` (`ORCH_VERSION`) and
    `longhorn-backup-target-kustomization.yaml` (`BACKUP_TARGET` from a Secret).
- Exclusion is already solved by omission: `apps/minecraft-bedrock` and `apps/openhands`
  exist as directories but have **no** `*-kustomization.yaml` wiring them into
  `clusters/ovh-lab/kustomization.yaml` — they simply aren't reconciled. Mirroring that
  mechanism for `juggler`/`minecraft-bedrock` on OCI costs nothing new.
- `clusters/oci-lab/kustomization.yaml` is currently `resources: []`.
- `bootstrap/terraform/oci-k3s/` is complete and unapplied: 3× `VM.Standard.A1.Flex`
  (1 OCPU/8GB default), NLB + reserved static IP fronting :6443 only, `flux bootstrap
  github --path=./clusters/oci-lab` wired via `null_resource`, **local Terraform state**
  (OVH just moved to S3 remote state in `bbf2722`/`211a008` — OCI hasn't).
- Every `*.sops.yaml` in the repo is encrypted to the **same single age recipient**
  (`.sops.yaml` has one age key, no per-cluster split). This means once the age key is
  installed on OCI, **every existing secret decrypts as-is** — no secret authoring needed
  just to stand the cluster up (S3 backup creds, Cloudflare token, JuiceFS secret, etc.
  all just work).
- `infrastructure/database/postgres/cluster.yaml`'s CNPG `Cluster` has a `backup.barmanObjectStore`
  stanza (`s3://k3s-lab-backups/postgres/pg`) but **no `bootstrap.recovery` stanza at all** —
  confirmed by reading the full file. This is a hard blocker for both OCI seeding and
  OVH's own from-scratch DR (`dr.md` already flags it as "not yet DR-tested"). It is being
  authored on a separate branch, `feat/cnpg-bootstrap-recovery`, outside the scope of this
  spec's implementation — see "Prerequisites in flight" below.
- DNS is Cloudflare, managed by `bootstrap/terraform/ovh-k3s/dns.tf`: a **single apex**
  `cloudflare_record.apex` (round-robin `A` records, `@` → all 3 OVH node public IPs).
  Every app hostname (`auth.dcxxiv.com`, `lol.dcxxiv.com`, `agent.dcxxiv.com`, …) is a
  CNAME to the apex in Cloudflare (not managed by this repo) — **there is no ingress load
  balancer**; Traefik (k3s built-in) + DNS round-robin does the job. cert-manager uses
  Cloudflare DNS01 (`letsencrypt-prod`/`-staging` ClusterIssuers in
  `infrastructure/cert-manager-config`) — DNS01 doesn't require the record to point at the
  issuing cluster, so two clusters issuing certs for *different* hostnames never conflict.
- Authentik (`infrastructure/authentik/helmrelease.yaml`) hardcodes `global.host:
  https://auth.dcxxiv.com` and runs an embedded `forward_auth` outpost; it's backed by the
  shared CNPG `pg` cluster (own `authentik` DB) and shared Redis DB1. OIDC redirect URIs
  are inherently per-hostname.
- Ingress objects are a mix of plain `Ingress` (`networking.k8s.io/v1`) and Traefik
  `IngressRoute` CRDs, each with a hardcoded `host`/`Host()` — no existing hostname
  templating variable anywhere in the repo.

---

## 1. GitOps structure for two clusters

**Options**

| # | Approach | Fit |
|---|---|---|
| A | New `clusters/oci-lab/overlays/<x>/kustomization.yaml` dirs wrapping each shared base with `patchesStrategicMerge`/`replacements` | Standard Kustomize convention, but **introduces a directory pattern that doesn't exist anywhere in this repo today** — every existing cluster reconciles shared paths directly. |
| B | Mirror `clusters/ovh-lab/*-kustomization.yaml` as `clusters/oci-lab/*-kustomization.yaml`, same `path:` targets, carrying OCI-specific `patches:` (nodeSelector/tolerations, storageClassName, resource sizing, hostnames) inline in the Flux `Kustomization` CR — same technique already used for the OVH-only Longhorn `backupTarget` patch. | **Zero changes to shared `infrastructure/`/`apps/` manifests or to OVH's cluster.** Exactly the established pattern, just applied more times. |
| C | `postBuild.substitute` everywhere: template shared manifests with `${CLUSTER_DOMAIN}`, `${STORAGE_CLASS}`, `${NODE_ARCH}` placeholders once, each cluster's `Kustomization` supplies its own values (already proven for `ORCH_VERSION`). | DRY over time, but requires **editing every shared manifest that has a hostname/storageClass** (~20+ files) up front — a repo-wide refactor that touches OVH's live manifests for a value that doesn't change on OVH's side. |

**Decision: B**, with C adopted narrowly later if it proves worth it — see "Decisions (locked)" below.

Rationale: B requires zero edits to any file OVH depends on — the entire OCI variance
surface lives in new files under `clusters/oci-lab/`. It's more boilerplate per-app than C,
but that boilerplate is isolated, reviewable, and reversible (delete `clusters/oci-lab/`
and OVH is untouched). C is the more scalable long-term answer once a third cluster or
frequent hostname churn makes the maintenance cost of N inline patches exceed the cost of
one templating refactor — call that out as an explicit future refactor, not a Phase 1 blocker.

`clusters/oci-lab/kustomization.yaml` becomes a copy of `clusters/ovh-lab/kustomization.yaml`
minus `juggler-kustomization.yaml` (amd64-only), minus `agent-os-kustomization.yaml` (excluded
until the multi-arch image lands, see "Decisions (locked)" #6), and never including a
`minecraft-bedrock-kustomization.yaml` (matches how it's already excluded from OVH — no chart
inclusion needed at all today; box64 runtime validation is a separate, later exercise if it's
ever wired in anywhere).

Concrete per-kind patch strategy inside `clusters/oci-lab/*-kustomization.yaml`:
- **HelmRelease values** (longhorn, redis-ha, mariadb-galera, authentik, monitoring, …):
  strategic-merge `patches:` targeting `kind: HelmRelease` for storageClass swaps, resource
  sizing, and (Traefik/Longhorn manager) `tolerations`/`nodeSelector`.
- **Ingress / Certificate / IngressRoute hostnames**: one small JSON6902 or strategic-merge
  patch per resource, targeting by `kind`+`name`, rewriting `host`/`Host()`/`dnsNames` from
  `<name>.dcxxiv.com` to `<name>.oci.dcxxiv.com` (see §2).
- **ARM64 scheduling**: since *all* OCI nodes are ARM (unlike OVH which is uniformly amd64),
  no `nodeSelector: kubernetes.io/arch` is actually required — the whole cluster is one
  architecture. Only needed if a future mixed-arch node pool is added.

---

## 2. DNS / hostname strategy

**Options**

| # | Approach | Fit |
|---|---|---|
| A | Distinct namespace for standby: `*.oci.dcxxiv.com` (own Cloudflare records, own DNS01 certs) during normal operation; **manual** Terraform-driven DNS cutover of the apex at promotion. | Reuses the existing `cloudflare_record.apex` mechanism (see `ovh-k3s/dns.tf`) almost unchanged; zero collision risk with OVH's live certs/records at any time. |
| B | Cloudflare Load Balancing (health-checked failover pool, automatic). | Requires a **paid** Cloudflare plan feature not currently used anywhere in this repo; adds a health-check surface and a second DNS product to operate for a home-lab DR scenario that's explicitly human-supervised, not auto-failover. |

**Decision: A.**

- Add `bootstrap/terraform/oci-k3s/dns.tf`, structurally identical to `ovh-k3s/dns.tf`, but
  targeting a **subdomain zone record** (`oci` name, not `@`) — i.e. round-robin `A`
  records for `oci.dcxxiv.com` → the 3 OCI node public IPs, `manage_dns = true` by default.
  Every OCI app hostname becomes `<name>.oci.dcxxiv.com` (CNAME to `oci.dcxxiv.com`, managed
  in Cloudflare same as today, out of Terraform).
- **cert-manager DNS01**: no conflict — OVH's `letsencrypt-prod` issues for `*.dcxxiv.com`
  names, OCI's issues for `*.oci.dcxxiv.com` names. Both ClusterIssuers can run
  simultaneously without ACME rate-limit or ownership collisions, because DNS01 validates
  ownership of the *name being issued*, not of the cluster serving it.
- **Authentik**: OCI runs its **own** Authentik instance (own outpost, own restored
  `authentik` DB via CNPG recovery, own Redis DB1) at `auth.oci.dcxxiv.com`. This is a
  second, independent Authentik — sessions/JWTs from OVH's instance are not portable, and
  that's fine because standby apps aren't being used by real users. The consequence:
  **OIDC redirect URIs are per-instance** — every app that has an Authentik OAuth2/OIDC
  provider configured in `bootstrap/terraform/authentik/` needs a second set of provider/
  redirect-URI entries pointed at the `oci.dcxxiv.com` hostnames. Cleanest way: parameterize
  that Terraform (module or `-var-file`) so it can target either Authentik instance's API,
  and run it once against OCI's Authentik after CNPG restore brings its DB up — ownership
  model deferred, see below.
- **Promotion cutover**: flip which Terraform module "owns" the apex. Add a
  `manage_apex_dns` bool to both `ovh-k3s` and `oci-k3s` (default `true` on OVH, `false` on
  OCI). Promotion sets OVH's to `false` (or the module is gone/destroyed) and OCI's to
  `true`, then `terraform apply` on OCI re-points `dcxxiv.com`'s apex `A` records at the OCI
  node IPs. Certs for the bare `dcxxiv.com` names then need fresh issuance on OCI's
  `letsencrypt-prod` (one-time `Certificate` resource change from `oci.dcxxiv.com` →
  `dcxxiv.com` hostnames, or simply let existing Ingress/Certificate objects be patched back
  to bare hostnames as part of the promotion runbook — see §6). Whether OCI keeps the
  `oci.` subdomain permanently post-promotion is deferred — see "Explicitly deferred" below.

---

## 3. Stateful data seeding

General principle: standby data must come from the **shared S3 backups**, never from a
live connection to OVH's databases/volumes, and nothing on OCI may write to a path OVH is
still actively writing.

### Postgres / CNPG — hard prerequisite, in flight on a separate branch
`infrastructure/database/postgres/cluster.yaml` has zero `bootstrap.recovery` today. This
must be authored **once**, benefiting both OVH self-recovery (`dr.md` Step 6.1) and OCI
seeding. It is being built on branch `feat/cnpg-bootstrap-recovery`, not as part of this
spec's implementation — Phase 2 below depends on that branch merging first.

```yaml
spec:
  bootstrap:
    recovery:
      source: pg-backup
  externalClusters:
    - name: pg-backup
      barmanObjectStore:
        destinationPath: s3://k3s-lab-backups/postgres/pg
        s3Credentials: {...same as backup.barmanObjectStore...}
```

**Warning (both clusters writing the same barman path):** `bootstrap.recovery` creates a
**brand-new, independent** CNPG `Cluster` object from the backup — it is not a streaming
replica of OVH. OCI's restored cluster must **not** also configure
`backup.barmanObjectStore.destinationPath: s3://k3s-lab-backups/postgres/pg` (the same
path OVH's live cluster is continuously archiving WAL into) — two independent PG timelines
archiving WAL to the same barman prefix will corrupt that backup chain for both. OCI's own
CNPG `Cluster` (if it backs up at all while in standby) must target a distinct path, e.g.
`s3://k3s-lab-backups/postgres/pg-oci-standby/`, or have backup disabled entirely until
promotion.

### Longhorn
Point OCI's `longhorn-kustomization.yaml` equivalent at the **same** S3 backup target
(read access is enough to see/restore backups). The risk called out in the prompt is real:
if Flux reconciles an app's Kustomization before its volume is restored, it creates an
**empty** PVC that then shadows the real data. Mitigation: for every stateful app PVC,
restore via the CSI **VolumeSnapshot** path (`VolumeSnapshotContent` sourced from the
Longhorn backup → `VolumeSnapshot` → PVC with `dataSource:` pointing at it) *before*
enabling that app's Flux `Kustomization` on OCI — not via ad hoc Longhorn-UI restores that
Flux can't see or gate on.

### JuiceFS — do not dual-mount
Metadata dump → load into **OCI's own** Redis (its own `redis-ha` HelmRelease/PVCs, not
shared with OVH). This is safe and cheap to do repeatedly. **Critical, per the prompt's own
framing:** the standby must not mount the shared JuiceFS S3 data read-write while OVH is
active — two independent metadata engines (OVH's Redis vs. OCI's Redis) both tracking
block references/GC against the *same* underlying S3 data bucket will corrupt it (stale
metadata engine's GC will delete blocks the other engine still considers live). Concretely:
**don't include `juicefs-kustomization.yaml` / `juicefs-s3-gateway-kustomization.yaml` in
`clusters/oci-lab/kustomization.yaml` at all** during standby — the CSI driver simply isn't
installed, so no PVC can accidentally mount it. Metadata stays loaded-and-idle in OCI's own
Redis, ready to attach the CSI only as a promotion step.

### MariaDB
Restore latest `.sql.gz` dump from S3 into OCI's own `mariadb-galera` (own instance, same
as `dr.md` Step 6.3), respecting the same Galera/InnoDB caveats already documented in
`mariadb-galera/backup-cronjob.yaml`.

### Continuous refresh vs. promotion-only restore

**Decision: split by risk/cost, not one blanket answer.**

- **JuiceFS metadata**: refresh **continuously** (e.g., a nightly CronJob mirroring the
  existing dump job in reverse — `juicefs load` the newest S3 dump into OCI's Redis DB2).
  It's unmounted, so there's no live-service disruption and essentially no corruption risk;
  this is nearly free RPO reduction.
- **Postgres, MariaDB, Longhorn**: restore **at promotion time**, plus a **scheduled
  rehearsal restore** (**monthly**, as the working default — see "Explicitly deferred" for
  the case to tune this) that populates `dr.md`'s currently-empty rehearsal log and validates
  the backup chain — but run it into the standby's *own* non-serving objects (OCI apps are
  scaled to 0 per §4, so nothing is disrupted by tearing down and re-restoring these on a
  schedule). This is what makes it meaningfully "warm" (bounded staleness, proven restorable)
  without taking on the operational cost of a continuously-running secondary Postgres/Galera
  cluster.

---

## 4. Active/standby app coordination

**Options**

| # | Approach | Fit |
|---|---|---|
| A | Distinct hostnames only (`*.oci.dcxxiv.com`) | Isolates traffic, but running apps still *could* accept writes if anyone reaches the hostname — no real safety net. |
| B | Scale most Deployments to 0 replicas by default on OCI (patch in each app's oci-lab Kustomization) | No compute cost, no accidental writes even if DNS/hostname isolation is somehow bypassed; infra (Traefik, cert-manager, Authentik outpost, monitoring) still runs to prove the platform reconciles. |
| C | A single "promotion flag" (`postBuild.substitute` variable gating `replicas: ${REPLICA_COUNT}` across all app manifests) | Most elegant, single flip at promotion — but requires templating every app Deployment's replica count now, for a value that's static 99% of the time. |

**Decision: A + B combined**, C deferred as a future refactor (same trade-off as §1).

Distinct hostnames give operational/DNS isolation; scale-to-zero is the actual safety
mechanism against split-brain writes. Promotion is a deliberate, rare, human-triggered
event — flipping `replicas: 0 → normal` via a real git commit (removing/adjusting the
patches in `clusters/oci-lab/*`) is appropriate and leaves an audit trail, rather than
needing a live feature-flag mechanism.

---

## 5. Storage sizing (200 GB Always Free block cap)

Current defaults: `boot_volume_size_gbs = 50` × 3 nodes = 150 GB, no separate data volume
(unlike OVH, which bind-mounts a dedicated 100 GB Cinder disk over `/var/lib/longhorn`).

**Options**

| # | Approach | Numbers | Fit |
|---|---|---|---|
| A (MVP) | Keep boot volume as-is, point Longhorn's `defaultDataPath` at a subdir of the boot volume — zero Terraform changes. | 3× 50 GB boot (150 GB total), no dedicated data volume. | Fastest to stand up; couples OS and data I/O/capacity — diverges from OVH's own separation-of-concerns pattern; risk of Longhorn filling the disk and starving the OS. |
| B (chosen) | Shrink boot volumes, add a dedicated per-node Block Volume for Longhorn (mirrors OVH's bind-mount pattern), new `oci_core_volume` + `oci_core_volume_attachment` resources + cloud-init mount step. | 3× 30 GB boot (90 GB) + 3× ~35 GB data volume (105 GB) = 195 GB, 5 GB slack under the 200 GB cap. | Matches OVH's own architecture; modest Terraform addition (`prepare-data-disk.sh`-style script already exists as a template in `ovh-k3s` to copy from). |

**Decision: B.** The actual dataset (Postgres 10Gi, Redis 3×2Gi, MariaDB 10Gi, plus
app PVCs) is well under 50 GB today even generously estimated, so 105 GB of dedicated
Longhorn capacity across 3 nodes (with `numberOfReplicas: 2`) is comfortable headroom, and
keeping data off the boot volume avoids an OS-disk-pressure failure mode.

---

## 6. Bootstrap & promotion runbooks

### Bootstrap (stand up the standby — non-disruptive to OVH)

1. Add an S3 backend to `bootstrap/terraform/oci-k3s` (same bucket, different `key`, e.g.
   `terraform/state/oci-k3s`) before first `apply`, mirroring OVH's own migration
   (`bbf2722`/`211a008`), to avoid local-state loss risk on a module that has never been
   applied. Recommended, not optional, given the module's history.
2. `terraform apply` in `bootstrap/terraform/oci-k3s` (real ARM capacity risk exists per
   its own README — "Out of host capacity" retries may be needed).
3. `make recover-age-key && make install-sops-age` against OCI's kubeconfig — same age key,
   same recipient, every existing SOPS secret decrypts unchanged.
4. Populate `clusters/oci-lab/kustomization.yaml` per §1 (mirrored `*-kustomization.yaml`
   set minus `juggler`, minus `agent-os` (until PR #141 lands), minus `juicefs*`, minus
   `minecraft-bedrock` (already excluded)). `flux bootstrap github --path=./clusters/oci-lab`
   runs automatically (already wired in `flux.tf`).
5. Watch `flux get kustomizations -A --watch`. This is also the **first real test** of the
   "arm64 image audit" assumption — confirm every chart/image actually pulls and runs on
   A1 ARM nodes.
6. Author + apply the CNPG `bootstrap.recovery` stanza (§3, prerequisite, tracked on
   `feat/cnpg-bootstrap-recovery`); restore Postgres.
7. Restore MariaDB from latest S3 dump; load JuiceFS metadata dump into OCI's own Redis
   (unmounted — no CSI Kustomization deployed yet).
8. Bring up Authentik against the restored DB; run the parameterized Authentik Terraform to
   register OIDC clients/redirect URIs for `*.oci.dcxxiv.com`.
9. Confirm cert-manager issues `*.oci.dcxxiv.com` certs via Cloudflare DNS01 without
   touching OVH's `*.dcxxiv.com` certs.
10. Apps reconcile at `replicas: 0` under `oci.dcxxiv.com` hostnames (§4).
11. Record the run in `dr.md`'s rehearsal log (currently empty).

### Promotion (OVH confirmed dead)

1. **Confirm OVH is truly gone**, not a transient blip — false-positive promotion risks
   real split-brain once JuiceFS/Longhorn CSI gets attached on OCI while OVH is still alive.
2. DNS: set `manage_apex_dns = false` on OVH's Terraform (or accept it's gone), `= true` on
   OCI's; `terraform apply` on OCI re-points the Cloudflare apex `A` records.
3. Data: run the promotion-time (not rehearsal) restore for Postgres/MariaDB/Longhorn if
   the last scheduled rehearsal isn't fresh enough; load the latest JuiceFS metadata dump
   one final time.
4. **Attach JuiceFS CSI on OCI now** (add `juicefs-kustomization.yaml` /
   `juicefs-s3-gateway-kustomization.yaml` to `clusters/oci-lab/kustomization.yaml`) — safe
   only because OVH is confirmed dead and no longer mounting the same S3 bucket.
5. Un-pause: remove the `replicas: 0` patches (or bump replicas) across app Kustomizations;
   flip hostnames on Ingress/Certificate/IngressRoute objects from `*.oci.dcxxiv.com` back
   to bare `*.dcxxiv.com` (or accept `oci.` as permanent and just repoint the apex — see
   "Explicitly deferred").
6. Re-run `make dr-authentik`-equivalent against OCI's Authentik for the bare-domain OIDC
   clients.
7. Verify per `dr.md` §4 (`flux get all -A`, `verify-encryption`, `verify-roundtrip`, smoke
   test auth/JuiceFS-backed app/WordPress, `kubectl get certificate -A`).

---

## 7. Prerequisites / dependencies blocking this

1. **CNPG `bootstrap.recovery` stanza — missing entirely.** Blocks both OCI seeding and
   OVH's own from-scratch DR. Must be authored and tested before any Postgres restore
   (on either cluster) can be trusted. In flight on branch `feat/cnpg-bootstrap-recovery`,
   outside this spec's own implementation — Phase 2 depends on it merging.
2. **`agent-os` multi-arch image** — in progress on branch `feat/agent-os-arm64-selfupdate`
   (PR #141). Decided: OCI's `agent-os-kustomization.yaml` is excluded entirely until that
   PR merges and arm64 builds are confirmed running, then it's added the same way every
   other app is (see "Decisions (locked)" #6).
3. **Stale JuiceFS `metaurl` example** — `infrastructure/storage/juicefs/secret.example.yaml`
   references `juicefs-redis-master.kube-system...`; the real Redis is `redis-ha-haproxy`
   in the `redis` namespace (per `authentik/helmrelease.yaml`'s working reference and
   `redis-meta-backup-cronjob.yaml`'s use of `juicefs-secret`/`metaurl`). Not a functional
   blocker (the real `secret.sops.yaml` is presumably correct), but the example file should
   be fixed so a future "seed OCI's juicefs-secret" step isn't copied from a stale example.
4. **`bootstrap/terraform/oci-k3s` has never been applied.** First `apply` is the first
   real-world test of the module (ARM capacity availability, cloud-init correctness,
   `flux bootstrap` null_resource behavior) — treat Phase 1 partly as "finish validating
   this module," not just "run it."
5. **No S3 remote state for `oci-k3s`** (OVH just migrated to it). Not a hard blocker, but
   doing this before first apply avoids a state-loss redo — recommended as Bootstrap step 1
   above.
6. **No `dns.tf` / Authentik-redirect-URI automation for OCI yet** — both need to be
   authored (§2), not just toggled.

---

## 8. Decomposition into phases

**Phase 1 — Stand up OCI cluster + platform layer on distinct hostnames (no real data).**
Terraform apply, age key, Flux bootstrap, mirrored `clusters/oci-lab/*` (minus stateful-data
kustomizations that need restore gating), apps at `replicas: 0` under `*.oci.dcxxiv.com`,
cert-manager DNS01 working. Goal: prove the ARM64 platform reconciles end-to-end. Storage
sizing (§5) and DNS `dns.tf` (§2) land here.

**Phase 2 — Stateful data restore rehearsal.** Depends on the CNPG `bootstrap.recovery`
stanza landing via `feat/cnpg-bootstrap-recovery` (shared prerequisite — benefits OVH DR
too). Wire Longhorn VolumeSnapshot-based restores, MariaDB restore, JuiceFS metadata load
(continuous). Run and log the first rehearsal in `dr.md`. JuiceFS CSI/gateway stay
uninstalled throughout this phase.

**Phase 3 — Promotion tooling.** `manage_apex_dns` variables on both Terraform modules,
parameterized Authentik OIDC Terraform, the promotion runbook (§6) turned into `make`
targets analogous to `make dr-authentik`, and a rehearsed (not just written) promotion —
ideally practiced against a disposable/renamed test domain before ever needed for real.

This ordering keeps Phase 1 achievable and low-risk (no live data touched, nothing OVH
depends on is edited), Phase 2 isolated to the genuinely hard/dangerous part called out in
the prompt, and Phase 3 scoped to the one-time, rare, high-stakes event.

---

## Decisions (locked)

1. **GitOps structure (§1): Option B — inline `patches:` in per-cluster Flux Kustomizations.**
   Matches the repo's existing pattern (already used for OVH's Longhorn `backupTarget`
   patch); the `postBuild.substitute` templating refactor (Option C) is deferred until a
   third cluster or hostname churn makes N inline patches costlier than one refactor.
2. **DNS (§2): Option A — distinct `*.oci.dcxxiv.com` subdomain**, via a new
   `bootstrap/terraform/oci-k3s/dns.tf`, with a manual, Terraform-driven apex cutover at
   promotion (`manage_apex_dns` flag). Reuses the existing `cloudflare_record.apex`
   mechanism with zero collision risk against OVH's live certs/records.
3. **Storage (§5): Option B — dedicated per-node Block Volume** for Longhorn (~30 GB boot
   ×3 + ~35 GB data ×3 = 195 GB, under the 200 GB Always Free cap). Mirrors OVH's own
   boot/data separation and avoids an OS-disk-pressure failure mode.
4. **App coordination (§4): A + B — distinct hostnames and `replicas: 0` patches.**
   Hostnames give DNS/cert isolation; scale-to-zero is the actual safety mechanism against
   split-brain writes.
5. **Data refresh cadence (§3): split by risk.** JuiceFS metadata refreshes continuously
   (nightly load into OCI's own Redis — unmounted, so no corruption risk). Postgres,
   MariaDB, and Longhorn restore at promotion time plus a monthly rehearsal by default;
   the exact cadence is revisitable once rehearsals establish real operational cost (see
   "Explicitly deferred").
6. **`agent-os` on OCI (§7): excluded** from `clusters/oci-lab/kustomization.yaml` until
   the multi-arch image lands on `feat/agent-os-arm64-selfupdate` (PR #141) and is confirmed
   building/running on arm64, then added the same way every other app is — no `replicas: 0`
   workaround in the interim.

## Explicitly deferred (revisit at Phase 2/3)

- **Permanent `oci.` subdomain vs. hostname-flip at promotion (§2).** Whether OCI keeps
  `oci.dcxxiv.com` permanently post-promotion, or every app's Ingress/Certificate/
  IngressRoute is rewritten back to bare `*.dcxxiv.com` hostnames. Affects how much of the
  promotion runbook is "flip DNS" vs. "flip DNS + rewrite every hostname."
- **Authentik OIDC redirect-URI automation ownership (§2).** Leaning toward one
  parameterized Terraform config/module that can target either Authentik instance's API,
  over two fully separate `bootstrap/terraform/authentik-oci/` states, but not committed —
  decide when Phase 2/3 actually builds this automation.
- **Exact rehearsal cadence beyond the monthly default (§3).** Monthly is the working
  assumption for Postgres/MariaDB/Longhorn restore-and-verify; quarterly (lower effort) or
  weekly (if scriptable enough to be "free") remain open once the first rehearsals establish
  real operational cost.

## Prerequisites in flight

- The CNPG `bootstrap.recovery` stanza (§3, §7) — a hard prerequisite for both OCI seeding
  and OVH's own from-scratch DR — is being authored on a separate branch,
  `feat/cnpg-bootstrap-recovery`, not as part of this spec's implementation. Phase 2 above
  depends on that branch merging first.
- Adding S3 remote state to `bootstrap/terraform/oci-k3s` before its first `apply` is
  recommended, mirroring OVH's own recent migration (`bbf2722`, `211a008`), to avoid
  local-state loss risk on a module that has never been applied.
