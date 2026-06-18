# k3s-lab — AI Assistant Context

Flux v2 GitOps repo for a k3s cluster. Path watched by Flux: `clusters/k3s-lab/`.

## Architecture

- `apps/` — one dir per application (namespace, kustomization, manifests)
- `infrastructure/` — cluster infrastructure (Traefik, cert-manager, Longhorn, JuiceFS, authentik, monitoring)
- `clusters/k3s-lab/` — Flux Kustomization resources wiring the repo to the cluster

## Conventions

- **Ingress:** Traefik `IngressRoute` CRDs throughout. Never use standard `Ingress` objects.
- **TLS:** cert-manager, ClusterIssuer `letsencrypt-prod` (Vultr DNS01). Each app needs a `Certificate` resource — IngressRoute does not support cert-manager annotations.
- **Storage:** Longhorn is the default StorageClass. Use JuiceFS for ReadWriteMany / shared access.
- **Secrets:** Never in Git. Create in-cluster; reference via `envFrom.secretRef` or `secretKeyRef`.
- **Labels:** Tag resources with `app.kubernetes.io/part-of: gitops`.

## Authentication

Every app is protected by authentik forward auth. Each app namespace needs a `Middleware`:

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

The IngressRoute references `name: authentik`. No bypass routes needed. The outpost must be configured in authentik as **domain-level forward auth** with `authentik_host_browser: https://auth.dcxxiv.com/` and the app's provider assigned to it. See `apps/openhands/` for the reference implementation.

## Node Notes

- k3s02 has taint `node-role=storage-ingress:NoSchedule` — add an explicit toleration for workloads that must schedule there.
- k3s04 is the current control plane (OVH VPS). It does not have a cloud-init file in `bootstrap/` yet.

## Removed Apps

jellyfin, jellyseerr, sonarr, radarr, lidarr, deluge, prowlarr, flaresolverr, dashy are in the `media-apps` branch, not in main.

## Workflow

- Never push directly to main. Feature branch → PR.
- Preview changes: `flux diff kustomization <name> -n flux-system`
- Force reconcile: `flux reconcile kustomization <name> -n flux-system`
- Adding an app: `apps/<name>/` + `clusters/k3s-lab/<name>-kustomization.yaml` + entry in `clusters/k3s-lab/kustomization.yaml` + Middleware for auth.
