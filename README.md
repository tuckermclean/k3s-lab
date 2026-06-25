# k3s-lab

GitOps-managed k3s cluster across three cloud providers. Everything declarative, everything in this repo, secrets included (encrypted).

## Nodes

| Node | Role | Provider | Location |
|------|------|----------|----------|
| k3s04 | server / control-plane | OVH VPS | Hillsboro, OR |
| k3s02 | agent | Vultr VPS | Seattle, WA |
| k3s03 | agent | Hetzner VPS | Hillsboro, OR |

k3s02 carries the `node-role=storage-ingress:NoSchedule` taint. Add a toleration explicitly if you need to schedule there.

## OCI Lab Cluster (separate)

Standalone HA cluster on Oracle Cloud Always Free ARM. Not part of the home mesh — own control plane, own kubeconfig, reconciled by Flux from `clusters/oci-lab/`.

| Node | Role | Provider | Shape |
|------|------|----------|-------|
| k3s-server-1 | server / etcd | OCI Ampere A1 | 1 OCPU / 8 GB |
| k3s-server-2 | server / etcd | OCI Ampere A1 | 1 OCPU / 8 GB |
| k3s-server-3 | server / etcd | OCI Ampere A1 | 1 OCPU / 8 GB |

3-server embedded-etcd HA behind an OCI Network Load Balancer. Provision with `bootstrap/terraform/oci-k3s/`.

## Stack

**GitOps:** Flux v2, watching `clusters/ovh-lab/`

**Ingress:** Traefik, deployed as DaemonSet + LoadBalancer. Uses IngressRoute CRDs throughout — there are no standard Ingress objects in this cluster. Do not add them.

**TLS:** cert-manager with Cloudflare DNS01 challenge (`cloudflare-credentials` secret). ClusterIssuers: `letsencrypt-prod`, `letsencrypt-staging`, `local-selfsigned`.

**Storage:**
- Longhorn — replicated block storage, 2 replicas, default StorageClass. Use for anything that needs a PVC and doesn't require cross-pod sharing.
- JuiceFS — S3-backed shared filesystem. Use for ReadWriteMany or media-style shared access.

**Databases:** CloudNativePG (postgres), mariadb, redis — all running in-cluster. See `infrastructure/database/`.

**Auth:** authentik at `auth.dcxxiv.com`. Every app sits behind forward auth. See the Auth Pattern section below.

**Networking:** CoreDNS custom ConfigMap for internal rewrites. This is why `auth.dcxxiv.com` resolves correctly inside the cluster — without the rewrite, the authentik outpost callback loop breaks.

**Monitoring:** Prometheus + Grafana

**GitOps UI:** Weave GitOps, Headlamp

## Repo Layout

```
apps/                        # one dir per app; skel/ is the template
infrastructure/              # platform-level components
clusters/ovh-lab/
  kustomization.yaml         # Flux entry point — the live set of active resources
  flux-system/
bootstrap/
  BOOTSTRAP.md
  cloud-init/
  scripts/
```

The authoritative list of active apps and infrastructure components is whatever `clusters/ovh-lab/kustomization.yaml` references. That file is the single source of truth; this README does not duplicate it.

## Adding an App

Use `apps/skel/` as the starting template. The conventions are:

1. Copy `apps/skel/` to `apps/<name>/`. Fill in `namespace.yaml`, `kustomization.yaml`, and your workload manifests. Delete template files you don't need.
2. Encrypt secrets with SOPS (see Secrets section). Commit them as `*.sops.yaml` files alongside the app.
3. Use Longhorn as the default StorageClass for PVCs. Use JuiceFS (`storageClassName: juicefs`) for ReadWriteMany.
4. Write an `IngressRoute` CRD (not a standard Ingress). Reference the authentik middleware:
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
5. Add a `Middleware` resource in the app's namespace pointing at the authentik outpost (see Auth Pattern below).
6. Create `clusters/ovh-lab/<name>-kustomization.yaml` — a Flux `Kustomization` pointing at `apps/<name>/`.
7. Add that file to the resources list in `clusters/ovh-lab/kustomization.yaml`.

See `apps/personliness/` or `apps/orchestrator/` as reference implementations.

## Auth Pattern

Add a `Middleware` in the app's namespace:

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

The outpost in authentik must have `authentik_host_browser: https://auth.dcxxiv.com/` set. Without it, post-login redirects point at the internal outpost address and break.

## Secrets

Kubernetes Secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) and committed to Git as `*.sops.yaml` files. Flux's kustomize-controller decrypts them at apply time via the `sops-age` Secret in `flux-system`. Secrets live in the repo — they are not kept out of it.

**Root of trust:** `~/.ssh/id_rsa` (synced between machines). The age private key is encrypted to that SSH key and committed at `bootstrap/age.agekey.age`.

To edit an existing secret:

```bash
make recover-age-key
make edit-secret FILE=infrastructure/authentik/secret.sops.yaml
make clean-age-key
```

To create a new secret from a template: `make fill-secrets`. Run `make help` to see all targets.

## Bootstrapping / DR

See `docs/runbooks/dr.md` for the authoritative recovery sequence.

Quick reference:

```bash
make recover-age-key            # decrypt age key from bootstrap/age.agekey.age
make install-sops-age           # push age key into flux-system
make flux-bootstrap-ovh-lab    # bootstrap Flux (reads GitHub PAT from SOPS)
```

All credentials come from `bootstrap/terraform/ovh-k3s/secrets.sops.yaml`. The only thing you need outside the repo is `~/.ssh/id_rsa`.

## Useful Commands

```bash
# See everything Flux is managing and its sync status
flux get all

# Watch Flux logs in real time
flux logs --follow

# Force a reconciliation without waiting for the interval
flux reconcile kustomization <name> -n flux-system

# Preview what Flux would apply without applying it
flux diff kustomization <name> -n flux-system

# Recent Flux events
flux events

# Inspect a failing kustomization
kubectl describe kustomization <name> -n flux-system
```
