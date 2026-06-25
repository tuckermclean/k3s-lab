## Summary

<!-- What does this PR do and why? -->

## Checklist

- [ ] Secrets are SOPS-encrypted (`make verify-encryption` passes; no plaintext Secret manifests)
- [ ] No `:latest` image tags
- [ ] `kustomize build clusters/ovh-lab` succeeds and yamllint passes
- [ ] Docs or comments updated if behavior or conventions changed
