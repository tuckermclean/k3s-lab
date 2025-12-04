Web Shell (ephemeral shells in Kubernetes)

Overview
--------
Minimal web app that authenticates via Authentik forward-auth (Traefik middleware) and provisions per-user ephemeral shell pods in namespace web-shell-sessions. A lightweight Go backend talks to the Kubernetes API to create/delete pods and bridges a WebSocket to kubernetes exec. The UI is a single page using xterm.js.

Auth
----
Requests must be protected by Authentik forwardAuth (see middleware.yaml). The app expects the following headers:
- X-authentik-username (preferred) or X-User as fallback
- X-authentik-email (optional)

Kubernetes security
-------------------
- ServiceAccount web-shell in namespace web-shell
- Role and RoleBinding limited to namespace web-shell-sessions allowing pods create/get/list/watch/delete and pods/exec
- Pods run as non-root (uid/gid 1000), no privilege escalation, no volumes, no inbound ports

Session behavior
----------------
- One pod per user; reuse if running; otherwise create a new one
- Idle timeout and max session duration enforced server-side; on disconnect/timeout the pod is deleted
- Resource requests/limits configurable via ConfigMap

Ingress
-------
Traefik IngressRoute protects host shell.home.dcxxiv.com with authentik middleware. TLS via cert-manager.

Build image
-----------
Dockerfile builds a static Go binary and serves static/index.html. Publish as ghcr.io/<org>/web-shell:<tag> and update deployment image.

