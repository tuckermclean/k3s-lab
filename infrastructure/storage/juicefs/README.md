# JuiceFS CSI (Community Edition) with AWS S3 via FluxCD

This stack installs the JuiceFS CSI driver (CE) and wires it to AWS S3 for data and a Longhorn-backed PVC (SQLite) for metadata. Everything is managed by Flux.

## What this provides
- JuiceFS CSI driver installed via Helm (Flux-managed)
- AWS S3 as object storage for file data
- SQLite metadata file stored on a Longhorn PVC mounted at `/var/lib/juicefs` in the CSI controller
- A StorageClass (`juicefs-sc`) for dynamic RWX volumes

## Where things live
- Data: S3 bucket `<S3_BUCKET_NAME>` in region `<AWS_REGION>`
- Metadata: PVC `juicefs-meta-pvc` in namespace `kube-system` (Longhorn SC `longhorn`)
- Secret: `kube-system/juicefs-secret` with JuiceFS CE config and AWS credentials

## How Flux wires it together
- `HelmRepository` points at `https://juicedata.github.io/charts`
- `HelmRelease` installs `juicefs-csi-driver` in `kube-system` and mounts the metadata PVC at `/var/lib/juicefs`
- `Secret` provides CE parameters (name, metaurl, storage=s3, bucket, access-key, secret-key, region)
- `StorageClass` (`juicefs-sc`) references that Secret for dynamic provisioning
- Example PVC (`default/juicefs-app-pvc`) shows RWX 100Gi claim using `juicefs-sc`

## Create more JuiceFS volumes
To create another JuiceFS-backed storage class/volume set:
1. Create a new Secret with a different `name`, `bucket` (or subdir via mount options), and credentials if needed.
2. Create another StorageClass that references the new Secret.
3. Bind PVCs to that StorageClass.

Alternatively, use `subdir` mount option (via ConfigMap or StorageClass/PV for legacy) to isolate application data within a single filesystem.

## Rotating credentials
- Edit the SOPS-encrypted secret: `make recover-age-key && make edit-secret FILE=infrastructure/storage/juicefs/secret.sops.yaml`
- Commit and push. Flux will reconcile and Kubernetes will update the Secret automatically.
- Safest approach: roll the CSI controller and application pods so Mount Pods pick up new credentials.

## Home-lab caveats
- If S3 is unavailable: IO may stall or fail depending on cache/state; ensure apps handle transient failures.
- If Longhorn is unavailable: SQLite metadata won’t be writable; mounts/operations will fail.
- This is suitable for lab/media and low-criticality workloads. For production, use HA metadata (e.g., TiKV/Redis), replication, and multi-AZ S3 strategies.

## Apply order (handled by Flux)
- Longhorn must be present first (PVC binds to `longhorn` class)
- Then the Secret & PVC & StorageClass
- Then the CSI driver (which mounts `/var/lib/juicefs`)

## Filling in credentials
The secret is stored encrypted in `secret.sops.yaml`. To set the real values:
```bash
make recover-age-key
make edit-secret FILE=infrastructure/storage/juicefs/secret.sops.yaml
make clean-age-key
```
Replace the `CHANGEME_*` placeholder values with actual S3 credentials.
