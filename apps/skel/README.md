# app skeleton templates

Copy this folder to `apps/<your-app>/` and replace the placeholder values (`<app-name>`, `<namespace>`, `<chart-name>`, `<helm-repo-name>`, `<host.example.com>`, etc.) before committing.

Guidelines and repo-specific conventions
- Do NOT commit plaintext secrets. Use `Secret` objects created out-of-band or reference in-cluster secrets.
- Label resources with `app.kubernetes.io/part-of: gitops` to match repo filters.
- Ingresses should use the `traefik` ingress class and rely on cert-manager ClusterIssuers in `infrastructure/cert-manager-config/clusterissuer.yaml`.
- If you need persistent storage, prefer the NFS provisioner configured in `infrastructure/nfs-provisioner/helmrelease.yaml` and set `storageClassName: nfs-provisioner` on PVCs.

Quick steps to add a new app
1. Copy `apps/skel/` -> `apps/<your-app>/`.
2. Replace placeholders in files.
3. Add the new app path to `clusters/ovh-lab/kustomization.yaml` or create a new kustomization under `clusters/ovh-lab/` to include the app.
4. Add a kustomization.yaml in your app folder to include the above resources and the namespace if applicable.
5. Create a new `clusters/ovh-lab/<your-app>-kustomization.yaml` pointing at `./apps/<your-app>` and add `dependsOn` as needed.

6. Locally preview with:

```bash
flux diff kustomization clusters/ovh-lab
```

5. Create a PR and merge to `main` — Flux will reconcile the new resources.

Examples to inspect in this repo
- `apps/jellyfin/` — HelmRelease + media-volume + ingress that show hostname affinity and NFS-backed volumes.
- `apps/minecraft-bedrock/` — plain Deployment + PVC + Service example.
