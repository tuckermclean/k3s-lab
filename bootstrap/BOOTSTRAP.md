# Bootstrap & Disaster Recovery

This document captures the full plan for reproducible node provisioning, secrets backup, and volume backup/restore. None of the implementation files exist yet — this is the reference for when the work is done.

---

## Node Provisioning

### Problem

The WireGuard misconfiguration on k3s03 (missing pod CIDRs in `AllowedIPs`) took down DNS for the entire cluster. The root cause was manual node setup with no source of truth — there was no way to know what the correct config was without checking the running nodes.

### Approach

**Ubuntu 24.04 LTS + cloud-init**, not Talos or Flatcar.

- Vultr and Hetzner both support cloud-init natively — no tooling change needed
- k3s runs fine on standard Ubuntu
- SSH still available for debugging
- "Immutability" is enforced by policy: never make manual changes; all config lives in cloud-init YAML in this repo

### Node Roles

| Node | Provider | Method |
|------|----------|--------|
| k3s01 | Home (physical) | `bootstrap/scripts/bootstrap-k3s01.sh` |
| k3s02 | Vultr VPS | `bootstrap/cloud-init/k3s02-vultr.yaml` + `envsubst` → Vultr user-data |
| k3s03 | Hetzner VPS | `bootstrap/cloud-init/k3s03-hetzner.yaml` + `envsubst` → Hetzner user-data |

> The separate Oracle Cloud HA cluster is provisioned end-to-end (nodes + Flux) by the
> Terraform module in `bootstrap/terraform/oci-k3s/`, not by the manual flow above. See
> that directory's `README.md`.

### What Cloud-Init Must Configure

**Packages:** `wireguard-tools`, `nfs-common`, `open-iscsi`

**WireGuard** — write `/etc/wireguard/*.conf`, enable systemd units. AllowedIPs **must** include pod CIDRs:

| Node | Interface | Peer | AllowedIPs |
|------|-----------|------|------------|
| k3s02 | wg-home | k3s01 | `192.168.77.1/32, 192.168.79.1/32, 10.42.0.0/24, 10.42.1.0/24` |
| k3s03 | wg-home | k3s01 | `192.168.78.1/32, 192.168.77.1/32, 10.42.0.0/24, 10.42.3.0/24` |
| k3s03 | wg-vultr | k3s02 | `192.168.79.2/32, 10.42.3.0/24` |

**k3s installation flags:**
```
--flannel-backend=wireguard-native   # eliminates VXLAN/WireGuard inconsistency across nodes
--node-ip=<wg-ip>                    # bind k3s to WireGuard interface
--flannel-iface=wg-home              # flannel uses WireGuard directly
--token=${K3S_TOKEN}
--server=https://192.168.77.1:6443   # agent nodes only; k3s01 runs k3s server
```

The `--flannel-backend=wireguard-native` flag is a **breaking change** from the current setup where k3s02/k3s03 use VXLAN (`flannel.1`). Apply it during a full reprovision of the cloud nodes.

### Secret Handling in Cloud-Init

Cloud-init files in this repo use `${PLACEHOLDER}` for secrets. Before reprovisioning, render locally:

```bash
WG_HOME_PRIVATE_KEY=$(cat ~/.secrets/k3s02-wg-home.key) \
WG_HETZNER_PRIVATE_KEY=$(cat ~/.secrets/k3s02-wg-hetzner.key) \
K3S_TOKEN=$(cat ~/.secrets/k3s-token) \
envsubst < bootstrap/cloud-init/k3s02-vultr.yaml > /tmp/k3s02-userdata.yaml
```

Paste `/tmp/k3s02-userdata.yaml` into the Vultr/Hetzner user-data field when creating the server. Delete the rendered file after.

---

## Secrets Backup & Restore

### How secrets are stored (SOPS + age)

Kubernetes Secrets are **encrypted in Git** using [SOPS](https://github.com/getsops/sops) +
[age](https://github.com/FiloSottile/age). Each secret lives as a `secret.sops.yaml` file alongside the
app that uses it. Flux's kustomize-controller decrypts them at apply time using the `sops-age` Secret in
`flux-system`.

**The human root of trust is `~/.ssh/id_rsa`** (synced between desktop and laptop).
The age private key is encrypted to that SSH key and committed at `bootstrap/age.agekey.age`.
This means: **`git clone` + your SSH key = recover the entire cluster.**

### Kubernetes secrets in Git

| Location | Secret | Contents |
|---|---|---|
| `infrastructure/authentik/secret.sops.yaml` | `authentik-secret` | secretKey (sessions/OIDC) |
| `infrastructure/authentik/secret.sops.yaml` | `authentik-db-secret` | postgres-password |
| `infrastructure/cert-manager-config/secret.sops.yaml` | `cloudflare-credentials` | Cloudflare API token |
| `infrastructure/storage/juicefs/secret.sops.yaml` | `juicefs-secret` | S3 access/secret key, metaurl |
| `infrastructure/monitoring/secret.sops.yaml` | `grafana-admin-secret` | Grafana admin password |
| `infrastructure/monitoring/secret.sops.yaml` | `grafana-oidc-secret` | Grafana ↔ authentik OIDC |
| `infrastructure/weave-gitops/secret.sops.yaml` | `cluster-user-auth` | Weave local admin (bcrypt) |
| `infrastructure/weave-gitops/secret.sops.yaml` | `oidc-auth` | Weave GitOps ↔ authentik OIDC |
| `apps/personliness/secret.sops.yaml` | `personliness-secret` | App secrets |
| `apps/openhands/secret.sops.yaml` | `openhands-env` | LLM API key |

### Secrets NOT in Git (bootstrap chicken-and-egg)

These two must be created manually on every fresh cluster **before** Flux can reconcile:

| Secret | How to create |
|---|---|
| `flux-system/flux-system` (GitHub deploy key) | Created automatically by `flux bootstrap`; re-run bootstrap |
| `flux-system/sops-age` (age private key) | See restore procedure below |

Node-level secrets (WireGuard, k3s join token) are outside Kubernetes — see below.

### DR restore procedure

```bash
# 1. Recover the age private key from the repo using your SSH key
make recover-age-key

# 2. Install it into the fresh cluster
make install-sops-age

# 3. Bootstrap Flux (also creates the flux-system deploy key)
export GITHUB_TOKEN=<your-PAT>
make flux-bootstrap-k3s-lab   # or ovh-lab / oci-lab

# Flux will now reconcile all secrets from the encrypted git files automatically.
# Watch progress:
flux get kustomizations --watch

# 4. Clean up the temporary plaintext age key
make clean-age-key
```

**Before running Flux**, verify the age key decrypts all secrets:
```bash
make verify-roundtrip
```

### Editing a secret

```bash
make recover-age-key
make edit-secret FILE=infrastructure/authentik/secret.sops.yaml
make clean-age-key
git add infrastructure/authentik/secret.sops.yaml
git commit -m "chore: rotate authentik secretKey"
git push
```

### If you rotate your SSH key

The age key backup is encrypted to your `id_rsa.pub`. After generating a new SSH keypair:
```bash
make recover-age-key          # with the OLD key while you still have it
# (replace ~/.ssh/id_rsa.pub with the new public key)
make rotate-ssh-key
git add bootstrap/age.agekey.age
git commit -m "chore: re-encrypt age key for new SSH key"
make clean-age-key
```

### Node-level secrets (outside Kubernetes)

These are handled by cloud-init / Terraform and are not in Kubernetes secrets:

**Node WireGuard keys** — dump from each node and store encrypted offline:
```bash
# k3s01
sudo cat /etc/wireguard/wg-vultr.conf
sudo cat /etc/wireguard/wg-hetzner.conf

# k3s02
sudo cat /etc/wireguard/wg-home.conf
sudo cat /etc/wireguard/wg-hetzner.conf

# k3s03
sudo cat /etc/wireguard/wg-home.conf
sudo cat /etc/wireguard/wg-vultr.conf
```

**k3s server token:**
```bash
sudo cat /var/lib/rancher/k3s/server/node-token   # on k3s01 only
```

**Restore:** Write back to `/etc/wireguard/*.conf` on each node, then:
```bash
systemctl restart wg-quick@wg-home
systemctl restart wg-quick@wg-hetzner   # or wg-vultr, depending on node
```

---

## Volume Backup & Restore

### Storage Landscape

| Class | What | Risk |
|-------|------|------|
| **longhorn** (2 replicas) | authentik postgresql, *arr configs (dynamic), jellyfin-config (100Gi), openhands-config (100Gi), minecraft bedrock (20Gi), juicefs-meta-pvc, personliness postgres | Replicated across nodes; survives single node loss |
| **local-path** on k3s01 | authentik postgresql-config-pvc + redis-config-pvc, radarr/sonarr/lidarr/prowlarr/jellyseerr/deluge *-config-pvc, jellyfin local-config | **Single node — no replication. k3s01 disk failure = data loss.** |
| **nfs-provisioner** | media-root-pvc (actual media files) | On openmediavault NAS |
| **juicefs** | juicefs-media-bucket (4096Gi) | S3-backed (durable) |

**Most critical data (hard or impossible to regenerate):**
- authentik postgresql — all OAuth clients, users, flows, permissions
- Minecraft bedrock world
- *arr configs — quality profiles, indexer auth, custom formats, history
- Jellyfin config — libraries, user preferences, plugin config

### Longhorn Backup Configuration (TODO)

Add to `infrastructure/storage/longhorn/helmrelease.yaml`:
```yaml
values:
  defaultSettings:
    backupTarget: nfs://openmediavault.home.dcxxiv.com:/export/Backup/longhorn
```

NFS is preferred over S3 here — no AWS cost, openmediavault is already on the network.

Add `infrastructure/storage/longhorn/recurringjob.yaml`:
```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  cron: "0 2 * * *"
  task: backup
  retain: 28
  concurrency: 1
```
Then label critical volumes to attach to this job (via Longhorn UI or volume annotations).

### Local-Path PV Backup (TODO)

These PVs live in `/var/lib/rancher/k3s/storage/` on k3s01. Add to `bootstrap/scripts/bootstrap-k3s01.sh` a systemd timer or cron entry:

```bash
# /etc/cron.d/k3s-local-path-backup
0 3 * * * root rsync -av --delete \
  /var/lib/rancher/k3s/storage/ \
  openmediavault.home.dcxxiv.com:/export/Backup/k3s01-local-path/
```

### Restore Procedures

**Longhorn volume:**
1. Longhorn UI → Backup → select snapshot → Restore to new PVC
2. Update the app's PVC reference (or rename the PVC and recreate the PV binding)
3. Restart the deployment

**Local-path PV:**
1. Rsync back from openmediavault:
   ```bash
   rsync -av openmediavault.home.dcxxiv.com:/export/Backup/k3s01-local-path/ \
     /var/lib/rancher/k3s/storage/
   ```
2. Ensure PV/PVC still exists with correct `volumeName` binding
3. Restart the deployment

**JuiceFS:** Data is in S3 (survives cluster loss). Metadata is in Redis on Longhorn — restore Redis from Longhorn backup, then remount JuiceFS; data is already in S3.

**openmediavault media:** Out of scope — managed by openmediavault's own backup.

---

## Maintenance Window Checklist (Reprovisioning a Cloud Node)

Before destroying k3s02 or k3s03:

- [ ] Confirm Longhorn replicas for all volumes have replica on k3s01 (check Longhorn UI)
- [ ] Drain the node: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`
- [ ] Export current WireGuard configs from the node
- [ ] Verify secrets are encrypted in git (`make verify-encryption`) and age key backup is current
- [ ] Render cloud-init with `envsubst`
- [ ] Destroy and recreate the VPS with rendered user-data
- [ ] Verify node joins: `kubectl get nodes`
- [ ] Verify WireGuard: `wg show all` — check AllowedIPs include pod CIDRs
- [ ] Verify Flux reconciles cleanly
- [ ] Verify pod-to-pod routing: `kubectl exec -n kube-system <coredns> -- ping 10.42.0.1`
