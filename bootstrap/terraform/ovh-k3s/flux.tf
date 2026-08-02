# Fetch the kubeconfig from node-1 over SSH and point it at node-1's public IP.
# (No load balancer here, to keep cost down: the API endpoint is node-1. etcd
# stays HA across the 3 nodes; if node-1 dies, repoint the kubeconfig.)
resource "null_resource" "kubeconfig" {
  depends_on = [
    openstack_compute_instance_v2.first,
    openstack_compute_instance_v2.rest,
  ]

  triggers = {
    node_ip = local.first_ip
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      host=${local.first_ip}
      key=${pathexpand(var.ssh_private_key_path)}
      ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $key"

      echo "Waiting for k3s on node-1 ($host)..."
      for i in $(seq 1 60); do
        if ssh $ssh_opts ${var.ssh_user}@$host 'sudo test -f /etc/rancher/k3s/k3s.yaml' 2>/dev/null; then
          break
        fi
        sleep 20
      done

      ssh $ssh_opts ${var.ssh_user}@$host 'sudo cat /etc/rancher/k3s/k3s.yaml' \
        | sed 's#https://127.0.0.1:6443#https://${local.first_ip}:6443#' \
        > ${path.module}/kubeconfig
      chmod 600 ${path.module}/kubeconfig
      echo "kubeconfig written to ${path.module}/kubeconfig"
    EOT
  }
}

# Bootstrap Flux against clusters/ovh-lab. Requires GITHUB_TOKEN in the
# environment and the `flux` CLI installed on the machine running terraform.
resource "null_resource" "flux_bootstrap" {
  count      = var.bootstrap_flux ? 1 : 0
  depends_on = [null_resource.kubeconfig]

  triggers = {
    node_ip = local.first_ip
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if [ -z "$${GITHUB_TOKEN:-}" ]; then
        echo "GITHUB_TOKEN is not set; export a PAT with repo scope before applying." >&2
        exit 1
      fi
      export KUBECONFIG=${abspath(path.module)}/kubeconfig
      flux bootstrap github \
        --owner=${var.github_owner} \
        --repository=${var.github_repository} \
        --branch=${var.github_branch} \
        --path=./clusters/ovh-lab \
        --personal

      # flux bootstrap only wires up the Git sync — it does NOT install the
      # sops-age decryption key, so every Kustomization that uses a
      # sops-encrypted secret.sops.yaml fails to reconcile until this Secret
      # exists in flux-system. tf.sh (this run's caller) exports
      # SOPS_AGE_KEY_FILE, falling back to /tmp/k3s-lab-age.agekey (the path
      # `make recover-age-key` writes to), so the same key material used to
      # decrypt secrets.sops.yaml above is reused here. This mirrors the
      # root Makefile's manual `install-sops-age` target so a fresh OVH
      # standup doesn't need that step run by hand. (Matches the same fix on
      # oci-k3s/flux.tf, kept consistent across both clusters.)
      kubectl --kubeconfig ${abspath(path.module)}/kubeconfig create secret generic sops-age \
        --namespace flux-system \
        --from-file=age.agekey="$${SOPS_AGE_KEY_FILE:-/tmp/k3s-lab-age.agekey}" \
        --dry-run=client -o yaml \
        | kubectl --kubeconfig ${abspath(path.module)}/kubeconfig apply -f -
    EOT
  }
}
