# Expose agent-os dev-server ports on agent.dcxxiv.com — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make agent-os dev servers on ports 3000, 5173, and 8080 reachable at `https://agent.dcxxiv.com:<port>`, served over HTTPS with the existing cert and gated by Authentik.

**Architecture:** Three config edits in the GitOps repo. Add three Traefik TCP entrypoints (Helm values) so the nodes open the ports; add matching ports to the agent-os Service so traffic reaches the pod; add three IngressRoutes that terminate TLS with the existing `agent-os-tls` cert and apply the shared `authentik` forwardAuth middleware. No image rebuild.

**Tech Stack:** k3s, Flux (syncs from `main`), Traefik v41 Helm chart (DaemonSet + LoadBalancer), Traefik IngressRoute CRD, Authentik forwardAuth, SOPS (unrelated to this change).

## Global Constraints

- Flux reconciles from the **`main`** branch (`clusters/ovh-lab/flux-system/gotk-sync.yaml`). Changes on a feature branch do NOT go live until merged. Full end-to-end verification is post-merge.
- CI (`.github/workflows/validate.yaml`) must pass on the PR: `kustomize build clusters/ovh-lab | kubeconform -strict`, `yamllint -s .`, and the no-`:latest`-tags grep.
- Traefik entrypoint names must be alphanumeric: `dev3000`, `dev5173`, `dev8080`.
- Reuse the existing cert secret `agent-os-tls` (namespace `agent-os`) for TLS — do not mint new certs.
- Reuse the existing middleware `authentik` in namespace `authentik` (cross-namespace refs are allowed via `allowCrossNamespace: true`).
- Follow existing file patterns: the `bedrock` custom port in the Helm values, and the existing single IngressRoute in `apps/agent-os/ingressroute.yaml`.
- Do NOT modify `apps/agent-os/kustomization.yaml` — all new routes go into the already-referenced `ingressroute.yaml`, and Service ports into the already-referenced `service.yaml`.

---

### Task 1: Add three Traefik entrypoints

**Files:**
- Modify: `infrastructure/traefik/helmrelease.yaml` (the `spec.values.ports:` block, currently containing `web` and `bedrock`)

**Interfaces:**
- Produces: Traefik entrypoints named `dev3000`, `dev5173`, `dev8080`, each a TCP entrypoint exposed on the LoadBalancer at the same-numbered port. Task 3's IngressRoutes reference these names in `entryPoints:`.

- [ ] **Step 1: Add the three entrypoints under `ports:`**

Insert the following as siblings of `web` and `bedrock`, immediately after the `bedrock` block (indentation: entrypoint keys at 6 spaces, matching `web`/`bedrock`):

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

The resulting `ports:` block reads: `web`, `bedrock`, `dev3000`, `dev5173`, `dev8080`.

- [ ] **Step 2: Validate YAML parses and structure is intact**

Run:
```bash
kubectl apply --dry-run=client -f infrastructure/traefik/helmrelease.yaml
```
Expected: `helmrelease.helm.toolkit.fluxcd.io/traefik configured (dry run)` (or `unchanged`). Any YAML/indentation error prints a parse error and non-zero exit — if so, fix indentation and re-run.

- [ ] **Step 3: Commit**

```bash
git add infrastructure/traefik/helmrelease.yaml
git commit -m "traefik: add dev3000/dev5173/dev8080 entrypoints for agent-os dev servers"
```

---

### Task 2: Add dev-server ports to the agent-os Service

**Files:**
- Modify: `apps/agent-os/service.yaml` (the `spec.ports:` list, currently one entry `http`/3011)

**Interfaces:**
- Consumes: nothing.
- Produces: Service `agent-os` (namespace `agent-os`) exposes ports 3000, 5173, 8080 (targetPort identical), selecting the same pod. Task 3's IngressRoutes reference these port numbers in `services[].port`.

- [ ] **Step 1: Append the three ports to `spec.ports`**

After the existing `http`/3011 entry, add (list items at 4 spaces, matching the existing entry):

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

- [ ] **Step 2: Validate against the live cluster schema (non-mutating)**

Run:
```bash
kubectl apply --dry-run=server -f apps/agent-os/service.yaml
```
Expected: `service/agent-os configured (server dry run)`. This validates the core Service schema without changing anything. A duplicate-port or malformed error means fix and re-run.

- [ ] **Step 3: Commit**

```bash
git add apps/agent-os/service.yaml
git commit -m "agent-os: expose dev-server ports 3000/5173/8080 on the Service"
```

---

### Task 3: Add three IngressRoutes (TLS + Authentik) for the dev ports

**Files:**
- Modify: `apps/agent-os/ingressroute.yaml` (append three IngressRoute documents after the existing one)

**Interfaces:**
- Consumes: Traefik entrypoints `dev3000`/`dev5173`/`dev8080` (Task 1); Service `agent-os` ports 3000/5173/8080 (Task 2); existing secret `agent-os-tls`; existing middleware `authentik`/`authentik`.
- Produces: public HTTPS routes `agent.dcxxiv.com:3000/5173/8080`, each behind Authentik.

- [ ] **Step 1: Append three IngressRoute documents**

At the end of `apps/agent-os/ingressroute.yaml`, append the following (note the leading `---` separators; each route mirrors the existing one but swaps the entrypoint and service port):

```yaml
---
# Dev server 3000 — same host, dedicated entrypoint, same auth + cert.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: agent-os-dev3000
  namespace: agent-os
  labels:
    app.kubernetes.io/part-of: gitops
spec:
  entryPoints:
    - dev3000
  routes:
    - kind: Rule
      match: Host(`agent.dcxxiv.com`)
      middlewares:
        - name: authentik
          namespace: authentik
      services:
        - name: agent-os
          port: 3000
  tls:
    secretName: agent-os-tls
---
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
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: agent-os-dev8080
  namespace: agent-os
  labels:
    app.kubernetes.io/part-of: gitops
spec:
  entryPoints:
    - dev8080
  routes:
    - kind: Rule
      match: Host(`agent.dcxxiv.com`)
      middlewares:
        - name: authentik
          namespace: authentik
      services:
        - name: agent-os
          port: 8080
  tls:
    secretName: agent-os-tls
```

- [ ] **Step 2: Validate all IngressRoutes against the live CRD schema**

Run:
```bash
kubectl apply --dry-run=server -f apps/agent-os/ingressroute.yaml
```
Expected: four lines, one per document, each ending `(server dry run)` — the original `agent-os` route plus `agent-os-dev3000`, `agent-os-dev5173`, `agent-os-dev8080`. A CRD schema error means fix and re-run.

- [ ] **Step 3: Commit**

```bash
git add apps/agent-os/ingressroute.yaml
git commit -m "agent-os: route agent.dcxxiv.com dev ports to dev servers via Traefik + Authentik"
```

---

### Task 4: Open PR and verify post-merge

**Files:** none (repo operations + live checks).

**Interfaces:**
- Consumes: Tasks 1–3 committed on `feature/dark-rain`.

- [ ] **Step 1: Push the branch and open a PR to `main`**

```bash
git push -u origin feature/dark-rain
gh pr create --base main --title "Expose agent-os dev-server ports on agent.dcxxiv.com" \
  --body "Adds Traefik entrypoints dev3000/dev5173/dev8080, matching agent-os Service ports, and three IngressRoutes (HTTPS via agent-os-tls, behind Authentik). Design: docs/superpowers/specs/2026-07-05-agent-os-dev-server-ports-design.md"
```

- [ ] **Step 2: Confirm CI passes**

Run:
```bash
gh pr checks --watch
```
Expected: the "Validate Manifests" workflow passes (kubeconform strict, yamllint, no-`:latest`). If it fails, read the log, fix, commit, push, re-watch.

- [ ] **Step 3: Merge, then let Flux reconcile**

Merge the PR (via `gh pr merge` or the UI). Then wait for Flux to apply. Watch:
```bash
kubectl get kustomization -n flux-system traefik agent-os -w
```
Expected: both report `Ready=True` with a recent `Applied revision` matching the merged commit. (Ctrl-C once both are Ready.)

- [ ] **Step 4: Verify the Traefik entrypoints and ports are live**

Run:
```bash
kubectl -n traefik get svc traefik -o jsonpath='{range .spec.ports[*]}{.name}{" "}{.port}{"\n"}{end}'
```
Expected: the output includes `dev3000 3000`, `dev5173 5173`, `dev8080 8080` alongside the existing ports.

- [ ] **Step 5: Verify the IngressRoutes exist**

Run:
```bash
kubectl -n agent-os get ingressroute
```
Expected: `agent-os`, `agent-os-dev3000`, `agent-os-dev5173`, `agent-os-dev8080`.

- [ ] **Step 6: Functional check — start a dev server and browse it**

In the agent-os UI, start a Node dev server bound to port 3000. Then from a browser open `https://agent.dcxxiv.com:3000`.
Expected: the Authentik login challenge appears; after logging in, the dev server responds. (If a cloud-provider firewall blocks the port, the connection will time out rather than redirect — see the design doc's firewall caveat and open the port at OVH/Vultr/Hetzner.)

- [ ] **Step 7: Verify idle-port behavior**

With nothing listening on 8080 in the pod, run:
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://agent.dcxxiv.com:8080
```
Expected: `302` (Authentik redirect) or, if already authenticated, `502` from Traefik — proving the entrypoint is open and routed but no backend is up. A connection timeout instead means the port isn't reachable (firewall).

---

## Self-Review

**Spec coverage:**
- Ports 3000/5173/8080 exposed → Task 1 (entrypoints), Task 2 (Service), Task 3 (routes). ✓
- HTTPS reusing `agent-os-tls` → Task 3 `tls.secretName`. ✓
- Behind Authentik → Task 3 `middlewares: authentik/authentik`. ✓
- Follow `bedrock` pattern / existing IngressRoute pattern → Task 1 & 3. ✓
- Caveats (firewall, 8080 conflict, idle 502, public exposure) → surfaced in Task 4 verification steps 6–7; full detail already in the committed design doc. ✓
- `lsof` / status detection → explicitly out of scope per design. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/vague steps — every edit shows exact YAML and every check shows an exact command with expected output. ✓

**Type/name consistency:** Entrypoint names `dev3000`/`dev5173`/`dev8080` are identical across Task 1 (definition), Task 3 (`entryPoints:`), and Task 4 Step 4 (verification). Service port numbers 3000/5173/8080 match between Task 2 and the `services[].port` values in Task 3. IngressRoute names `agent-os-dev3000/5173/8080` match between Task 3 and Task 4 Step 5. ✓
