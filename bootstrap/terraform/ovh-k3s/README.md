# ovh-k3s — cheap HA k3s on OVH US Public Cloud (Oregon)

Terraform module that provisions a standalone k3s cluster on OVH **US** Public
Cloud (OpenStack) and bootstraps Flux against [`clusters/ovh-lab/`](../../../clusters/ovh-lab).
Built as the paid fallback to the free-tier `oci-k3s` module — same structure,
different provider. Default region **`US-WEST-OR-1`** (Oregon, same metro as the
home OVH node).

> **OVH US is a separate cloud from OVH EU** (us.ovhcloud.com, its own login,
> OpenStack endpoint, flavor catalog, and pricing in USD). Use the US manager and
> the US OpenStack RC file. EU flavor names (s1-*, b2-*) may not exist here —
> **verify with `openstack flavor list`.**

## What it builds

- **3 server nodes** (`node_count`, embedded etcd HA). Flavor is `var.flavor_name`
  (default `d2-4`, a best-guess — confirm against your region's catalog). Billed hourly.
- A **keypair** and **security group** (SSH + API from `api_allowed_cidr`, all
  intra-cluster traffic between nodes).
- k3s with **`flannel-backend=wireguard-native`** — required on OVH because its
  anti-spoofing blocks plain VXLAN between nodes.
- **Flux** bootstrapped at `clusters/ovh-lab/` (separate from the home cluster).

There is **no load balancer** (to keep cost down): the API endpoint is node-1's
public IP. etcd stays HA across all three nodes; if node-1 dies the cluster
keeps running and you repoint the kubeconfig at another node.

## Cost

Pricing is USD and region-specific in OVH US. Confirm current rates in the
us.ovhcloud.com manager before applying; pick the cheapest flavor with >=4 GB RAM
for three nodes with headroom. `terraform destroy` stops billing.

## Prerequisites

- `terraform` (>= 1.5), `flux` CLI, `kubectl`, `ssh`, and the `openstack` CLI
  (handy for listing flavors/images) on the machine you run from.
- An OVH **US** Public Cloud project (us.ovhcloud.com).
- **OpenStack credentials**: us.ovhcloud.com manager → Public Cloud →
  **Users & Roles** → create/select a user → **Download OpenStack RC v3**. Then
  `source openrc.sh` (sets the `OS_*` env vars terraform reads). Or use a
  `clouds.yaml` entry and set `os_cloud`.
- A **GitHub PAT** with `repo` scope for the Flux bootstrap.

## Usage

```bash
cd bootstrap/terraform/ovh-k3s
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars            # region, SSH keys, github_owner

source ~/Downloads/openrc.sh        # OVH OpenStack RC (prompts for the password)
export GITHUB_TOKEN=ghp_xxxx

terraform init
terraform plan                      # confirm 3 instances, secgroup, keypair
terraform apply

export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl get nodes -o wide
```

## Notes & gotchas (untested against a live OVH account)

- **Flavor / image / region names must match what your project actually offers.**
  If `plan`/`apply` complains, run `openstack flavor list`, `openstack image list`,
  and check the region. Adjust `flavor_name` / `image_name` / `region`.
- **Single node?** Set `node_count = 1` and `flannel_backend = "vxlan"` (no
  inter-node networking, so the wireguard requirement goes away).
- **`api_allowed_cidr`** defaults to `0.0.0.0/0` (SSH + API open to the internet),
  matching the OCI setup. Set to your `IP/32` to lock down.
- **Flux bootstrap** needs `GITHUB_TOKEN` exported, else it errors after the nodes
  come up.

## Teardown

```bash
terraform destroy
```
