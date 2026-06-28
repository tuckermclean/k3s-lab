# Bootstrap Reference

Provisioning and first-setup reference for the k3s-lab GitOps clusters (Flux + k3s + SOPS).

**For total-loss recovery sequencing, see `docs/runbooks/dr.md`** — this file covers
initial provisioning only, not step-by-step disaster recovery.

---

## Clusters

Two independent clusters, each with its own control plane and Flux instance:

| Cluster | Provider | Terraform module | Flux target |
|---------|----------|-----------------|-------------|
| ovh-lab | OVH US Public Cloud (Oregon) | `bootstrap/terraform/ovh-k3s/` | `clusters/ovh-lab/` |
| oci-lab | Oracle Cloud Always Free (ARM) | `bootstrap/terraform/oci-k3s/` | `clusters/oci-lab/` |

There is no home-server node in the current topology. Both clusters are fully
cloud-provisioned via Terraform. cloud-init is generated from templates in each
module's `cloud-init/` directory — there are no hand-maintained per-node files.

---

## 1. Provision Infrastructure

### OVH cluster (ovh-lab)

3-node HA cluster on OVH US (d2-8 flavor, 8 GB RAM each). 100 GB Cinder data disk
per node, bind-mounted over `/var/lib/longhorn` and `/var/lib/rancher/k3s/storage`.
k3s uses `flannel-backend=wireguard-native` (required — OVH blocks plain VXLAN).

See full details and gotchas: [`bootstrap/terraform/ovh-k3s/README.md`](terraform/ovh-k3s/README.md)

**One-time: create the encrypted secrets file** (if not already in git):

```bash
cd bootstrap/terraform/ovh-k3s
cp secrets.yaml.example secrets.yaml
$EDITOR secrets.yaml          # OpenStack creds + GitHub PAT (see comments in file)
cp secrets.yaml secrets.sops.yaml
sops -e -i secrets.sops.yaml
rm secrets.yaml
git add secrets.sops.yaml && git commit -m "chore(ovh-k3s): add encrypted bootstrap secrets"
git push
```

**Provision:**

```bash
make init-ovh    # terraform init (one-time)
make apply-ovh   # recover age key, decrypt secrets, terraform apply -auto-approve (~5 min)

export KUBECONFIG=$(make kubeconfig-ovh)
kubectl get nodes -o wide
```

**After first apply — activate data disk bind mounts (rolling reboot):**

Reboot one node at a time; Longhorn tolerates one node offline:

```bash
ssh ubuntu@<node-ip> sudo reboot
kubectl -n longhorn-system get nodes.longhorn.io   # wait for healthy before next node
```

On a fresh build from scratch, cloud-init handles this automatically at first boot.

---

### OCI cluster (oci-lab)

3-node HA cluster on Oracle Cloud Always Free ARM pool (VM.Standard.A1.Flex,
1 OCPU / 8 GB each). OCI Network Load Balancer with reserved static IP fronts
the Kubernetes API. No cost; `terraform destroy` reclaims the free-tier allocation.

See full details and gotchas: [`bootstrap/terraform/oci-k3s/README.md`](terraform/oci-k3s/README.md)

**Provision:**

```bash
cd bootstrap/terraform/oci-k3s
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # OCI API key, SSH key, github_owner, api_allowed_cidr

export GITHUB_TOKEN=ghp_xxxx
terraform init
terraform apply

export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl get nodes -o wide
flux get all
```

> The OCI module does not yet have top-level `make` targets like the OVH module.
> Run terraform directly from `bootstrap/terraform/oci-k3s/`.

---

## 2. Bootstrap Flux

After nodes are up and the kubeconfig is active, install the SOPS age key and
bootstrap Flux:

```bash
make recover-age-key          # decrypt age key from git using ~/.ssh/id_rsa
make verify-roundtrip         # confirm age key decrypts all *.sops.yaml before proceeding
make install-sops-age         # create sops-age Secret in flux-system namespace

export GITHUB_TOKEN=<your-PAT>
make flux-bootstrap-ovh-lab   # or: make flux-bootstrap-oci-lab

flux get kustomizations --watch   # watch Flux reconcile the cluster
```

`make flux-bootstrap-*` depends on `recover-age-key` — it runs automatically.

---

## 3. Secrets & Age-Key Model

### Root of trust

All Kubernetes secrets are **encrypted in git** as `*.sops.yaml` files using
[SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age).
Flux's kustomize-controller decrypts them at apply time using the `sops-age` Secret.

**The human root of trust is `~/.ssh/id_rsa`** (synced between desktop and laptop).
The age private key is encrypted to that SSH key and committed at
`bootstrap/age.agekey.age`. This means: **`git clone` + your SSH key = full secret
access.**

Every `*.sops.yaml` in the tree is a cluster secret. Run
`git ls-files '*.sops.yaml'` to see the current inventory — the list is the source
of truth and does not need to be duplicated here.

### Common operations

```bash
# Verify all *.sops.yaml are actually encrypted (CI gate)
make verify-encryption

# Verify the age key can decrypt all secrets end-to-end
make verify-roundtrip

# Edit a single secret
make edit-secret FILE=infrastructure/authentik/secret.sops.yaml

# Open every *.sops.yaml for bulk editing
make fill-secrets

# Print a secret to stdout (for inspection)
make decrypt-secret FILE=infrastructure/authentik/secret.sops.yaml
```

### Age key lifecycle

```bash
# Recover age key to /tmp (needed before editing secrets or running terraform)
make recover-age-key

# Install recovered key into the cluster as the sops-age Secret
make install-sops-age

# Securely delete the temporary plaintext key after you're done
make clean-age-key
```

`make apply-ovh`, `make flux-bootstrap-*`, and secret editing targets all call
`recover-age-key` automatically as a prerequisite.

### Rotating your SSH key

```bash
make recover-age-key          # with the OLD key while you still have it
# (replace ~/.ssh/id_rsa.pub with the new public key)
make rotate-ssh-key
git add bootstrap/age.agekey.age
git commit -m "chore: re-encrypt age key for new SSH key"
make clean-age-key
```

### Secrets outside Kubernetes (bootstrap chicken-and-egg)

Two secrets must exist in the cluster **before** Flux can reconcile, created by the
provisioning steps above:

| Secret | Created by |
|--------|-----------|
| `flux-system/flux-system` (GitHub deploy key) | `flux bootstrap` / `make flux-bootstrap-*` |
| `flux-system/sops-age` (age private key) | `make install-sops-age` |

### Authentik bootstrap (first time, after Flux deploys Authentik)

The `bootstrap/terraform/authentik/` module manages OIDC apps and groups. It reads
all secrets from SOPS — no `terraform.tfvars` file is needed or kept.

```bash
# 1. Let Flux deploy Authentik fully, get the initial admin token from logs:
kubectl logs -n authentik -l app.kubernetes.io/component=server \
  | grep -i "token\|password" | tail -5

# 2. Log in at https://auth.dcxxiv.com/if/flow/initial-setup/
#    Set admin password → Admin → Directory → Tokens → Create token (type: API)

# 3. Store the token encrypted in git
make store-authentik-token TOKEN=<paste-token-here>
git add bootstrap/terraform/authentik/token.sops.yaml
git commit -m "chore: add authentik api token"
git push

# 4. Apply OIDC apps, groups, and scope mappings
make apply-authentik
```

After a database restore, run `make dr-authentik` to nuke stale Terraform state and
re-apply — no secret rotation is needed.

---

## 4. Recovery from Total Loss

This file covers provisioning. If you are recovering from a full cluster loss
(nodes destroyed, Longhorn data lost, database corruption), follow the sequenced
runbook in **`docs/runbooks/dr.md`**.

Quick orientation:
- **Git + `~/.ssh/id_rsa`** is enough to recover all secrets and re-provision
  both clusters from scratch.
- Storage (Longhorn S3 backups, JuiceFS S3 data) is durable across cluster loss.
- Re-run the steps in this file in order (provision → flux-bootstrap → install-sops-age),
  then follow `docs/runbooks/dr.md` for volume and database restore sequencing.
