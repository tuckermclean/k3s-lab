# ovh-k3s — cheap HA k3s on OVH US Public Cloud (Oregon)

Terraform module that provisions a standalone k3s cluster on OVH **US** Public
Cloud (OpenStack) and bootstraps Flux against [`clusters/ovh-lab/`](../../../clusters/ovh-lab).
Built as the paid fallback to the free-tier `oci-k3s` module — same structure,
different provider. Default region **`US-WEST-OR-1`** (Oregon).

> **OVH US is a separate cloud from OVH EU** (us.ovhcloud.com, its own login,
> OpenStack endpoint, flavor catalog, and pricing in USD). Use the US manager and
> the US OpenStack RC file. EU flavor names (s1-*, b2-*) may not exist here —
> **verify with `openstack flavor list`.**

## What it builds

- **3 server nodes** (`node_count`, embedded etcd HA). Flavor `d2-8` (8 GB RAM).
  Billed hourly.
- A **100 GB Cinder data disk** per node, mounted at `/mnt/data` with bind mounts
  over `/var/lib/longhorn` and `/var/lib/rancher/k3s/storage` — existing
  StorageClasses gain the capacity without any manifest changes.
- A **keypair** and **security group** (SSH + API from `api_allowed_cidr`, all
  intra-cluster traffic between nodes).
- k3s with **`flannel-backend=wireguard-native`** — required on OVH because its
  anti-spoofing blocks plain VXLAN between nodes.
- **Flux** bootstrapped at `clusters/ovh-lab/`.

There is **no load balancer** (to keep cost down): the API endpoint is node-1's
public IP. etcd stays HA across all three nodes; if node-1 dies the cluster keeps
running and you repoint the kubeconfig at another node.

## Cost

Pricing is USD and region-specific in OVH US. Confirm current rates in the
us.ovhcloud.com manager before applying. `terraform destroy` (or `make destroy`)
stops billing.

## Bootstrap from scratch

Everything you need to recover the cluster lives in this repo + your age key.

### 1. One-time: create the encrypted secrets file

```bash
cd bootstrap/terraform/ovh-k3s
cp secrets.env.example secrets.env
$EDITOR secrets.env   # fill in OpenStack creds + GitHub PAT (see comments)

sops --encrypt --input-type dotenv --output-type dotenv secrets.env > secrets.sops.env
rm secrets.env
git add secrets.sops.env && git commit -m "chore(ovh-k3s): add encrypted bootstrap secrets"
git push
```

The OpenStack credentials come from the OVH US manager:
**Public Cloud → Users & Roles → (your user) → Download OpenStack RC v3**.
The password is the OpenStack user password, not your OVH account password.

Your age key must be in `~/.config/sops/age/keys.txt` (or `$SOPS_AGE_KEY_FILE`).
The public key is committed in `.sops.yaml` at the repo root.

### 2. Deploy

```bash
make init   # terraform init (one-time)
make apply  # decrypts secrets, runs terraform apply -auto-approve
```

`make apply` takes ~5 minutes. When done:

```bash
export KUBECONFIG=$(make kubeconfig)
kubectl get nodes -o wide
```

### 3. Activate data disk bind mounts (rolling reboot)

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

```bash
make plan     # terraform plan (shows what would change)
make apply    # terraform apply -auto-approve
make destroy  # terraform destroy -auto-approve — STOPS BILLING
```

All Make targets go through `tf.sh`, which decrypts `secrets.sops.env` and injects
the env vars before calling Terraform. Never need to manually source an OpenRC file.

## Teardown

```bash
make destroy
```

## Notes & gotchas

- **Flavor / image / region names must match what your project actually offers.**
  If `plan`/`apply` complains, run `openstack flavor list`, `openstack image list`,
  and adjust `flavor_name` / `image_name` / `region` in `terraform.tfvars`.
- **Single node?** Set `node_count = 1` and `flannel_backend = "vxlan"`.
- **`api_allowed_cidr`** defaults to `0.0.0.0/0`. Set to your `IP/32` to lock down.
- **cloud-init changes** never recreate running nodes (`lifecycle { ignore_changes = [user_data] }`).
  Template changes take effect only on the next full cluster rebuild.
- **Data disk bind mounts** require a rolling node reboot after first apply (see above).
  On a fresh rebuild from scratch, the cloud-init does the bind mounts at first boot
  automatically.

## Storage incident 2026-06-20

All four stateful Longhorn volumes were corrupted when `resize2fs` was interrupted
mid-run during a PVC expansion. Longhorn block-level replication propagated the
partial write to both replicas simultaneously — no clean copy remained.

**Safeguards now in place:**
- `allowVolumeExpansion` removed from both Longhorn StorageClasses (defaults to
  false). To expand a volume: temporarily patch the StorageClass, expand ONE volume,
  verify Longhorn health, remove the field. Never expand multiple volumes at once.
- Longhorn backup target stub added to `infrastructure/storage/longhorn/helmrelease.yaml`.
  **Configure a real S3 backup target before storing data you care about.**
