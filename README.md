# k3s-lab

GitOps-managed k3s cluster across three cloud providers. Everything declarative, everything in this repo except secrets.

## Nodes

| Node | Role | Provider | Location |
|------|------|----------|----------|
| k3s04 | server / control-plane | OVH VPS | Hillsboro, OR |
| k3s02 | agent | Vultr VPS | Seattle, WA |
| k3s03 | agent | Hetzner VPS | Hillsboro, OR |

k3s02 has the `node-role=storage-ingress:NoSchedule` taint. Add a toleration explicitly if you need to schedule something there.

## OCI Lab Cluster (separate)

A second, standalone HA cluster on Oracle Cloud's Always Free ARM pool, fully
Terraform-provisioned. It is **not** part of the home mesh above — own control plane, own
kubeconfig, reconciled by Flux from `clusters/oci-lab/`.

| Node | Role | Provider | Shape |
|------|------|----------|-------|
| k3s-server-1 | server / etcd | OCI Ampere A1 | 1 OCPU / 8 GB |
| k3s-server-2 | server / etcd | OCI Ampere A1 | 1 OCPU / 8 GB |
| k3s-server-3 | server / etcd | OCI Ampere A1 | 1 OCPU / 8 GB |

3-server embedded-etcd HA behind an OCI Network Load Balancer (reserved static IP) on the
API port. Provision and bootstrap with `bootstrap/terraform/oci-k3s/` — see that
directory's `README.md`.

## Stack

**GitOps:** Flux v2, watching `clusters/k3s-lab/`

**Ingress:** Traefik, deployed as DaemonSet + LoadBalancer. Uses IngressRoute CRDs throughout — there are no standard Ingress objects in this cluster. Do not add them.

**TLS:** cert-manager with Vultr DNS01 challenge. ClusterIssuer is `letsencrypt-prod`. Certs are issued for `*.dcxxiv.com`.

**Storage:**
- Longhorn — replicated block storage, 2 replicas, default StorageClass. Use this for anything that needs a PVC and doesn't need to be shared across pods.
- JuiceFS — S3-backed shared filesystem. Use for ReadWriteMany workloads or media-style shared access.

**Auth:** authentik at `auth.dcxxiv.com`. Every app sits behind forward auth. See the auth section below.

**Monitoring:** Prometheus + Grafana

**GitOps UI:** Weave GitOps

**DNS:** CoreDNS custom ConfigMap for internal rewrites. This is why `auth.dcxxiv.com` resolves correctly inside the cluster even though it's a public domain — without the rewrite, the outpost callback loop breaks.

## Repo Layout

```
apps/                        # one dir per app
infrastructure/
  authentik/
  cert-manager/
  cert-manager-config/
  cert-manager-webhook-vultr/
  monitoring/
  storage/longhorn/
  storage/juicefs/
  traefik/
clusters/k3s-lab/
  kustomization.yaml
  flux-system/
bootstrap/
  BOOTSTRAP.md
  cloud-init/
  scripts/
```

The entry point for Flux is `clusters/k3s-lab/kustomization.yaml`. Every Flux Kustomization that should be active needs to be referenced there (or transitively via something that is).

## Active Apps

- openhands
- minecraft-bedrock
- personliness

Removed apps (jellyfin, jellyseerr, sonarr, radarr, lidarr, deluge, prowlarr, flaresolverr, dashy) are preserved in the `media-apps` branch, not deleted, in case they come back.

## Adding an App

1. Create `apps/<name>/` with at minimum: `namespace.yaml`, `kustomization.yaml`, and your workload manifests.
2. Create `clusters/k3s-lab/<name>-kustomization.yaml` — this is a Flux `Kustomization` resource pointing at `apps/<name>/`.
3. Add that file to the resources list in `clusters/k3s-lab/kustomization.yaml`.
4. Add a `Middleware` resource in the app's namespace for authentik forward auth (see below).
5. Reference the middleware in the app's `IngressRoute`.

See `apps/openhands/` as the reference implementation.

## Auth Pattern

Every app needs a `Middleware` in its own namespace:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik
  namespace: <app-namespace>
spec:
  forwardAuth:
    address: http://ak-outpost-<outpost-name>.authentik:9000/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
      - X-authentik-jwt
      - X-authentik-meta-jwks
      - X-authentik-meta-outpost
      - X-authentik-meta-provider
      - X-authentik-meta-app
      - X-authentik-meta-version
```

The IngressRoute references it:

```yaml
routes:
  - match: Host(`myapp.dcxxiv.com`)
    kind: Rule
    middlewares:
      - name: authentik
    services:
      - name: myapp
        port: 80
```

The outpost in authentik must be configured with:
- `authentik_host_browser: https://auth.dcxxiv.com/`
- Domain-level forward auth mode

This matters because without `authentik_host_browser` set correctly, the browser gets redirected to the internal outpost address after login, which does not work.

## Secrets

Secrets are encrypted in Git using [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age).
Each secret lives as a `secret.sops.yaml` file alongside the app that uses it.
Flux's kustomize-controller decrypts them at apply time using the `sops-age` Secret in `flux-system`.

**The human root of trust is `~/.ssh/id_rsa`** (already synced between machines). The age private key is
encrypted to that SSH key and committed at `bootstrap/age.agekey.age` — so the repo is self-contained.

To edit an existing secret:
```bash
make recover-age-key
make edit-secret FILE=infrastructure/authentik/secret.sops.yaml
make clean-age-key
```

## Bootstrapping / DR

**OVH cluster (Terraform-managed — this is the primary HA cluster):**

```bash
make init-ovh                              # download providers (one-time after clone)
make apply-ovh                             # provision 3-node cluster (~5 min)
export KUBECONFIG=$(make kubeconfig-ovh)   # aim kubectl at the new cluster
make install-sops-age                      # push age key into flux-system
make flux-bootstrap-ovh-lab               # bootstrap Flux (GitHub PAT read from SOPS)
```

All credentials come from `bootstrap/terraform/ovh-k3s/secrets.sops.yaml` (encrypted in git).
The only thing you need outside the repo is `~/.ssh/id_rsa`.

**Home / OCI clusters:** See `bootstrap/BOOTSTRAP.md` for node provisioning details.
Once nodes exist: `make install-sops-age && make flux-bootstrap-k3s-lab` (or `oci-lab`).

Run `make help` from the repo root to see all available targets.

## Useful Commands

```bash
# See everything Flux is managing and its sync status
flux get all

# Watch Flux logs in real time
flux logs --follow

# Force a reconciliation if you don't want to wait for the interval
flux reconcile kustomization <name> -n flux-system

# Preview what Flux would apply without applying it
flux diff kustomization <name> -n flux-system

# Find all resources tagged as part of this GitOps setup
kubectl get all -l app.kubernetes.io/part-of=gitops

# Recent Flux events
flux events

# Inspect a failing kustomization
kubectl describe kustomization <name> -n flux-system
```
