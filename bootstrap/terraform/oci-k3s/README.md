# oci-k3s — HA k3s on Oracle Cloud Always Free

Terraform module that provisions a **standalone, HA k3s cluster** on Oracle Cloud's
Always Free ARM pool and bootstraps Flux against [`clusters/oci-lab/`](../../../clusters/oci-lab).

It is intentionally separate from the home `k3s-lab` cluster — its own control plane,
its own kubeconfig, no WireGuard mesh. Built as the free-tier mirror of the paid
`ovh-k3s` module — same structure (S3 remote state, Cloudflare DNS, per-node data
disk, `tf.sh`/`secrets.sops.yaml`), different provider.

## What it builds

- **3 control-plane servers** (`VM.Standard.A1.Flex`, **1 OCPU / 8 GB each** = 3 OCPU /
  24 GB total, 1 OCPU left in reserve), embedded etcd HA. A1.Flex requires integer
  OCPUs, so this is the clean split of the free pool.
- A **VCN** (`10.0.0.0/16`), public subnet (`10.0.1.0/24`), internet gateway, and a
  security list that opens the cluster ports.
- A **30 GB per-node Block Volume** (`data_volume_size_gbs`), mounted at
  `/mnt/data` with bind mounts over `/var/lib/longhorn` and
  `/var/lib/rancher/k3s/storage` — existing StorageClasses gain the capacity
  without any manifest changes.
- **Flux** bootstrapped into this repo at `clusters/oci-lab/`.

There is **no load balancer** (Option A — matches `ovh-k3s`, keeps things simple and
free-tier-friendly): the API endpoint is server-0's public IP. etcd stays HA across
all three servers; if server-0 dies, repoint the kubeconfig at another server's
public IP (`terraform output server_public_ips`).

Servers get **static private IPs** (`10.0.1.11/12/13`) so join targets are known before
boot — no IP lookup needed for the intra-VCN join. The node's *public* IP (OCI NATs
it — it's never present on the interface) is fetched from the OCI metadata service at
boot and used only for k3s's external advertisement (`node-external-ip`) and API cert
SANs (`tls-san`); see `cloud-init/server.yaml.tftpl`. cloud-init also opens the stock
image's restrictive iptables before installing k3s.

## Prerequisites

- `terraform` (>= 1.10) or `tofu`, `flux` CLI, `kubectl`, `ssh`, `sed`, `sops`, `age`
  on the machine you run this from.
- An OCI account with the Always Free ARM pool available in your home region.
- An **OCI API signing key**: OCI Console → Identity → Users → *your user* → API Keys →
  Add API Key. Download the private key, note the fingerprint, tenancy/user OCIDs.
  These go into `terraform.tfvars` (see below) — they are plain Terraform variables,
  not secrets managed by SOPS.
- AWS credentials for the S3 remote state backend, a Cloudflare API token, and a
  GitHub PAT — these go into `secrets.sops.yaml` (see "Bootstrap from scratch" below).

## Bootstrap from scratch

Everything you need to recover the cluster lives in this repo + your `~/.ssh/id_rsa`.

### 1. One-time: create the encrypted secrets file

```bash
cd bootstrap/terraform/oci-k3s
cp secrets.yaml.example secrets.yaml
$EDITOR secrets.yaml   # fill in AWS creds (S3 backend) + Cloudflare token + GitHub PAT

cp secrets.yaml secrets.sops.yaml
sops -e -i secrets.sops.yaml
rm secrets.yaml
git add secrets.sops.yaml && git commit -m "oci-k3s: add encrypted bootstrap secrets"
git push
```

The age private key is stored encrypted in the repo at `bootstrap/age.agekey.age` and
recovered automatically from `~/.ssh/id_rsa` — no separate key file to manage.

### 2. One-time: set tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # OCI API key creds, SSH keys, github_owner, api_allowed_cidr
                           # set server_count = 3 for the HA quorum
```

`terraform.tfvars` is gitignored — OCI API key material and SSH keys never enter Git.

### 3. Deploy

All operations go through top-level make targets from the repo root:

```bash
make init-oci   # terraform init (one-time)
make apply-oci  # recovers age key, decrypts secrets, runs terraform apply -auto-approve
```

`make apply-oci` takes a few minutes. When done:

```bash
export KUBECONFIG=$(make kubeconfig-oci)
kubectl get nodes -o wide
```

### 4. Activate data disk bind mounts (rolling reboot)

After apply, `prepare-data-disk.sh` has set up the fstab entries on each node but the
bind mounts for `/var/lib/longhorn` and `/var/lib/rancher/k3s/storage` need a reboot
to go live. Reboot **one node at a time** — Longhorn (2 replicas) tolerates one node
offline:

```bash
# On each node, one at a time:
ssh ubuntu@<node-ip> sudo reboot

# Wait for the node to come back and Longhorn to go healthy:
kubectl -n longhorn-system get nodes.longhorn.io
```

## Day-to-day

From the repo root:

```bash
make plan-oci     # terraform plan (shows what would change)
make apply-oci    # terraform apply -auto-approve
make destroy-oci  # terraform destroy -auto-approve — frees the Always Free pool
```

Age key recovery and SOPS decryption happen automatically.

## Notes & gotchas

- **"Out of host capacity"** on `apply` is common — the A1 pool is heavily
  oversubscribed. Retry, try a different availability domain (`availability_domain`
  var), or a different home region. The 1 spare OCPU sometimes helps.
- **`api_allowed_cidr`** defaults to `0.0.0.0/0` (API open to the internet). Set it to
  your `IP/32`.
- **Topology is variable-driven.** Change `server_count` / `agent_count` /
  `ocpus_per_node` / `memory_gbs_per_node`; a guardrail fails the plan if you exceed the
  free pool (4 OCPU / 24 GB / 200 GB block storage), tunable via `free_tier_max_*`.
- **`server_count` must stay odd** (etcd quorum) — enforced by a `variable` validation
  block, same as `ovh-k3s`'s `node_count`.
- **cloud-init template changes**: check `terraform plan` before applying against a
  live cluster — confirm whether a `cloud-init/server.yaml.tftpl` edit would force a
  node replacement before running `apply`.
- **Data disk bind mounts** require a rolling node reboot after first apply (see above).
- **Flux bootstrap** uses `null_resource` + `local-exec` running `flux bootstrap github`,
  gated behind a `/livez` readiness poll against the public API endpoint (handles the
  first-boot race where the kubeconfig exists on disk before the apiserver is actually
  serving requests over the public IP).
- **State** is remote (S3, see `versions.tf`) — same bucket as `ovh-k3s`, different key
  (`terraform/state/oci-k3s`).

## DNS

`dns.tf` manages round-robin `A` records for **`oci.dcxxiv.com`** (not the production
apex — that stays owned by `ovh-k3s/dns.tf`), pointing at every server node's public
IP. Gate with `manage_dns` (default `true`); set `dns_zone` to change the zone. App
hostnames for this cluster are unmanaged CNAMEs to `oci.dcxxiv.com`. For a stable API
hostname in the k3s API cert SANs, set `api_dns_name = "oci.dcxxiv.com"` in
`terraform.tfvars`.

`oci.dcxxiv.com` stays a permanent secondary hostname even after cutover — it is never
removed. A separate `manage_apex_dns` flag (default `false`) gates a second resource,
`cloudflare_record.apex` (`name = "@"`), that points the bare `dcxxiv.com` apex at these
same nodes. It's off by default; flip it to `true` only at the deliberate OVH→OCI
cutover step (alongside setting `manage_dns = false` on `ovh-k3s`), then `terraform
apply`. See the comment block in `dns.tf` for the full sequencing.

## Free-tier billing tripwire

`budget.tf` creates a $1/month tenancy-wide OCI budget (`oci_budget_budget.free_tier_guard`)
with two alert rules: one fires on **ACTUAL** spend crossing ~$0.01 (1% of the $1 budget),
the other on a **FORECAST** to exceed the full $1. Expected spend on the Always Free pool
is $0, so either alert firing means something changed. It can be brought up independently
of the rest of the cluster with a targeted apply:

```bash
terraform -chdir=bootstrap/terraform/oci-k3s apply \
  -target=oci_budget_budget.free_tier_guard \
  -target=oci_budget_alert_rule.actual_first_cent \
  -target=oci_budget_alert_rule.forecast_over_budget
```

Caveats:

- **Latency.** OCI cost data is not real-time — alerts typically land within about a day
  of the triggering spend, not instantly.
- **IAM policy.** Creating budgets requires a policy granting
  `Allow group <admins> to manage usage-budgets in tenancy`.
- **No subscription confirmation.** OCI budget alerts email `recipients` directly; there's
  no opt-in/confirmation step like an SNS subscription.

## Teardown

From the repo root:

```bash
make destroy-oci
```

This removes the OCI resources. The `clusters/oci-lab/flux-system/` files committed by
`flux bootstrap` remain in Git — delete them by hand if you're retiring the cluster.
