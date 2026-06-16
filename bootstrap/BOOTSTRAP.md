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

### Why Some Secrets Cannot Be Regenerated

| Namespace | Secret | Contents | Risk if lost |
|-----------|--------|----------|--------------|
| authentik | `authentik-secret` | `secretKey` | All sessions/OIDC invalidated |
| authentik | `authentik-db-secret` | `postgres-password` | Must update DB too |
| cert-manager | `vultr-credentials` | Vultr API key | cert-manager DNS01 stops working |
| flux-system | `flux-system` | GitHub deploy key | Flux loses repo access |
| kube-system | `juicefs-secret` | S3 access key, secret key, bucket, metaurl | All JuiceFS PVCs fail to mount |
| monitoring | `grafana-oidc-secret` | Grafana → authentik OIDC credentials | Grafana SSO broken |
| monitoring | `grafana-admin-secret` | Grafana admin password | No local admin fallback |
| weave-gitops | `oidc-auth` | Weave GitOps → authentik OIDC credentials | Weave GitOps SSO broken |
| weave-gitops | `cluster-user-auth` | Weave GitOps local admin password | No local admin fallback |
| personliness | `personliness-secret` | App secrets | App non-functional |
| (node) | `/etc/wireguard/*.conf` | WireGuard private keys | Must renegotiate with all peers |
| (node) | `/var/lib/rancher/k3s/server/node-token` | k3s join token | Must re-join all agents |

The bulk backup below captures all of these in one shot. This list exists so you know what you're missing if a restore is partial or a single secret needs rotating.

### Backup Procedure

**There is no automated backup.** Run this manually after any secret rotation and at least monthly. Verify the output file exists and is non-zero before closing the terminal.

**Kubernetes secrets:**
```bash
kubectl get secrets -A -o yaml \
  | gpg --symmetric --cipher-algo AES256 \
  -o ~/secrets-backup-$(date +%Y%m%d).yaml.gpg
```
Store in Bitwarden (file attachment) or an encrypted offline location. Never store unencrypted.

**Node WireGuard keys** — dump from each node and store encrypted:
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

### Restore Procedure

**Kubernetes secrets:**
```bash
# Apply BEFORE letting Flux reconcile, so HelmReleases find their Secrets
gpg -d ~/secrets-backup-YYYYMMDD.yaml.gpg | kubectl apply -f -
```

**WireGuard keys:** Write back to `/etc/wireguard/*.conf` on each node, then:
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
- [ ] Export Kubernetes secrets backup
- [ ] Render cloud-init with `envsubst`
- [ ] Destroy and recreate the VPS with rendered user-data
- [ ] Verify node joins: `kubectl get nodes`
- [ ] Verify WireGuard: `wg show all` — check AllowedIPs include pod CIDRs
- [ ] Verify Flux reconciles cleanly
- [ ] Verify pod-to-pod routing: `kubectl exec -n kube-system <coredns> -- ping 10.42.0.1`
