# oci-k3s — HA k3s on Oracle Cloud Always Free

Terraform module that provisions a **standalone, HA k3s cluster** on Oracle Cloud's
Always Free ARM pool and bootstraps Flux against [`clusters/oci-lab/`](../../../clusters/oci-lab).

It is intentionally separate from the home `k3s-lab` cluster — its own control plane,
its own kubeconfig, no WireGuard mesh.

## What it builds

- **3 control-plane servers** (`VM.Standard.A1.Flex`, **1 OCPU / 8 GB each** = 3 OCPU /
  24 GB total, 1 OCPU left in reserve), embedded etcd HA. A1.Flex requires integer
  OCPUs, so this is the clean split of the free pool.
- A **VCN** (`10.0.0.0/16`), public subnet (`10.0.1.0/24`), internet gateway, and a
  security list that opens the cluster ports.
- An **OCI Network Load Balancer** with a **reserved static public IP** fronting the
  Kubernetes API (6443) — the HA endpoint, durable across LB recreates.
- **Flux** bootstrapped into this repo at `clusters/oci-lab/`.

Servers get **static private IPs** (`10.0.1.11/12/13`) so join targets are known before
boot — no IP lookup needed. cloud-init opens the stock image's restrictive iptables
before installing k3s.

## Prerequisites

- `terraform` (>= 1.5) or `tofu`, `flux` CLI, `kubectl`, `ssh`, `sed` on the machine you
  run this from.
- An OCI account with the Always Free ARM pool available in your home region.
- An **OCI API signing key**: OCI Console → Identity → Users → *your user* → API Keys →
  Add API Key. Download the private key, note the fingerprint, tenancy/user OCIDs.
- A **GitHub PAT** with `repo` scope for the Flux bootstrap.

## Usage

```bash
cd bootstrap/terraform/oci-k3s
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars            # OCI creds, SSH keys, github_owner, api_allowed_cidr

export GITHUB_TOKEN=ghp_xxxx        # used only by the flux bootstrap step

terraform init
terraform plan                      # confirm 3 A1.Flex nodes, VCN, NLB
terraform apply
```

After apply:

```bash
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl get nodes -o wide           # 3 nodes, all control-plane,etcd,master
flux get all                        # flux-system reconciling from clusters/oci-lab
```

## Notes & gotchas

- **"Out of host capacity"** on `apply` is common — the A1 pool is heavily
  oversubscribed. Retry, try a different availability domain (`availability_domain`
  var), or a different home region. The 1 spare OCPU sometimes helps.
- **`api_allowed_cidr`** defaults to `0.0.0.0/0` (API open to the internet). Set it to
  your `IP/32`.
- **Topology is variable-driven.** Change `server_count` / `agent_count` /
  `ocpus_per_node` / `memory_gbs_per_node`; a guardrail fails the plan if you exceed the
  free pool (4 OCPU / 24 GB), tunable via `free_tier_max_*`.
- **Flux bootstrap** uses `null_resource` + `local-exec` running the same
  `flux bootstrap github` command documented in the repo README. For fully idempotent
  IaC you can switch to the official `flux`/`github`/`tls` Terraform providers later.
- **State** is local by default. For a shared/durable setup, add an OCI Object Storage
  (S3-compatible) backend.

## DNS

- In-cluster DNS (CoreDNS) and VCN internal DNS (`*.oraclevcn.com`) are automatic.
- Public DNS for app ingress is **not** created here — it belongs with a future
  Traefik/cert-manager addition under `clusters/oci-lab/`. For a stable API hostname,
  set `api_dns_name` and point an A record at `terraform output -raw lb_public_ip`.

## Teardown

```bash
terraform destroy
```

This removes the OCI resources. The `clusters/oci-lab/flux-system/` files committed by
`flux bootstrap` remain in Git — delete them by hand if you're retiring the cluster.
