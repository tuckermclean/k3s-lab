# Expose agent-os dev-server ports on `agent.dcxxiv.com`

**Date:** 2026-07-05
**Branch:** `feature/dark-rain`
**Status:** Approved design

## Problem

The agent-os web UI (`saadnvd1/agent-os`, deployed at `agent.dcxxiv.com`) has a
"dev servers" feature that starts Node dev servers inside the pod on ports like
3000 (default), 5173 (Vite), or 8080. Those ports listen only inside the pod.
The Traefik `IngressRoute` routes `agent.dcxxiv.com` (443) to the app on port
3011 only, so a started dev server has no reachable URL — today it requires
`kubectl port-forward`.

Goal: make selected dev-server ports reachable at `https://agent.dcxxiv.com:<port>`.

## Decisions

- **Ports exposed:** 3000, 5173, 8080 (fixed set; an arbitrary range is
  impractical because each exposed port needs its own Traefik entrypoint).
- **TLS:** HTTPS, terminating at Traefik, reusing the existing
  `agent.dcxxiv.com` certificate (secret `agent-os-tls`) via SNI on each new
  entrypoint.
- **Auth:** behind the shared Authentik `forwardAuth` middleware, identical to
  the main app.

## Approach

Follow the existing custom-port pattern already used in the Traefik Helm values
(the `bedrock` UDP entrypoint on 19132). For each dev port:

1. Add a Traefik **entrypoint** — opens the port on the LoadBalancer / nodes.
2. Add a **Service** port on the agent-os pod for that port.
3. Add an **IngressRoute** bound to that entrypoint, TLS + Authentik, routing to
   the Service port.

### Data flow

```
browser  ->  https://agent.dcxxiv.com:5173
         ->  Traefik entrypoint "dev5173"
         ->  TLS terminate (agent-os cert, SNI = agent.dcxxiv.com)
         ->  Authentik forwardAuth middleware
         ->  IngressRoute  ->  Service port "dev-5173"  ->  pod:5173
```

## Components / files changed

All changes on `feature/dark-rain`. No image rebuild required.

### 1. `infrastructure/traefik/helmrelease.yaml`

Add three TCP entrypoints under `spec.values.ports:` (alongside `web`,
`websecure`, `bedrock`). Entrypoint names must be alphanumeric:

```yaml
dev3000:
  port: 3000
  exposedPort: 3000
  expose:
    default: true
dev5173:
  port: 5173
  exposedPort: 5173
  expose:
    default: true
dev8080:
  port: 8080
  exposedPort: 8080
  expose:
    default: true
```

This is a Flux `HelmRelease`; Flux reconciles the values and Traefik (a
DaemonSet) rolls to open the new ports via klipper hostPorts on each node.

### 2. `apps/agent-os/service.yaml`

Add three named ports to the existing `agent-os` Service, targeting the pod:

```yaml
- name: dev-3000
  port: 3000
  targetPort: 3000
- name: dev-5173
  port: 5173
  targetPort: 5173
- name: dev-8080
  port: 8080
  targetPort: 8080
```

Kubernetes Services route to any port on the pod IP regardless of the
container's declared `ports:` list (which stays 3011-only). The endpoint is the
pod, gated by the pod's existing readiness probe on 3011 — so the Service always
has the pod as a backend; if nothing is listening on a dev port, connections to
it fail (see 502 caveat).

### 3. `apps/agent-os/ingressroute.yaml`

Add three IngressRoutes (one per entrypoint), each mirroring the existing route
but bound to the dev entrypoint and its Service port. Example for 5173:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: agent-os-dev5173
  namespace: agent-os
  labels:
    app.kubernetes.io/part-of: gitops
spec:
  entryPoints:
    - dev5173
  routes:
    - kind: Rule
      match: Host(`agent.dcxxiv.com`)
      middlewares:
        - name: authentik
          namespace: authentik
      services:
        - name: agent-os
          port: 5173
  tls:
    secretName: agent-os-tls
```

Cross-namespace middleware/service refs are permitted
(`allowCrossNamespace: true` is set in `infrastructure/traefik-config`).

## Caveats (documented, not blockers)

- **Cloud provider firewalls.** The Traefik `externalIPs` are public VPS
  addresses (OVH / Vultr / Hetzner). Ports 3000/5173/8080 may need to be allowed
  inbound at each provider's firewall; the Kubernetes change alone is not
  sufficient if the VPS firewall drops them.
- **Port 8080 host conflict.** 8080 is commonly used. If any process on a node
  already binds 8080, the klipper hostPort will conflict and Traefik won't open
  it there. Swap to a less common port if this happens.
- **Vite HMR over Authentik.** HMR uses websockets; Traefik proxies ws
  automatically, and the session cookie is same-host so it should ride along. If
  forwardAuth interferes with the HMR socket, exempt the ws path or the dev port
  from auth.
- **502 when idle.** If no dev server is listening on a port, that URL returns
  502 from Traefik. Expected behavior.
- **Public exposure.** These ports are internet-reachable on public IPs;
  Authentik is the only gate. Do not run dev servers with secrets/debug
  endpoints assuming they're private.

Out of scope: adding `lsof` to the image (affects dev-server *status* detection,
not port exposure) — track separately if desired.

## Testing

After Flux reconciles the `HelmRelease` and the app manifests:

1. `kubectl get svc -n traefik traefik -o yaml` — confirm ports 3000/5173/8080
   present.
2. `kubectl get ingressroute -n agent-os` — confirm the three new routes.
3. In agent-os, start a Node dev server bound to 3000.
4. Browse `https://agent.dcxxiv.com:3000` — expect the Authentik challenge, then
   the dev server after login.
5. Confirm an idle port (e.g. 8080 with nothing running) returns 502, not a
   connection refused / timeout (proves the entrypoint is open and routed).
