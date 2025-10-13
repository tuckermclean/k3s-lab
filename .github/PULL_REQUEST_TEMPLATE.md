Title: docs: sync repository documentation with current structure and workflows

Summary
- Align docs with current repo structure and Flux workflows
- Add apps/skel/kustomization.yaml template
- Remove references to deprecated scripts

Scope
- Documentation only; no secrets or functional changes

Details
- README: tree, commands, NFS note, flux diff examples
- MIGRATION: mappings and steps updated; legacy references removed
- SECURITY: openhands-env Secret example; backup/recovery simplified; health checks fixed
- EFFICIENCY_REPORT: focus on actual repo (HelmRepository duplication, YAML standardization); removed speculative content
- Removed deprecated scripts documentation file
- apps/skel: added kustomization.yaml template and clarified steps
- .github/copilot-instructions: aligned with README and current paths

Review Notes
- Please confirm the HelmRepository consolidation recommendation is appropriate for your environment
- Verify NFS server references and cert-manager ClusterIssuer values match your setup

