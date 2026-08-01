# Fetch the kubeconfig from server-0 over SSH and rewrite the endpoint to its
# public IP. (Option A: no load balancer, to keep cost/complexity down — the
# API endpoint is server-0's public IP. etcd stays HA across all server
# nodes; if server-0 dies, repoint the kubeconfig at another server's public IP.)
resource "null_resource" "kubeconfig" {
  depends_on = [
    oci_core_instance.server,
  ]

  triggers = {
    node_id = oci_core_instance.server[0].id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      host=${oci_core_instance.server[0].public_ip}
      key=${pathexpand(var.ssh_private_key_path)}
      ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $key"

      echo "Waiting for k3s on server-0 ($host)..."
      for i in $(seq 1 60); do
        if ssh $ssh_opts ubuntu@$host 'sudo test -f /etc/rancher/k3s/k3s.yaml' 2>/dev/null; then
          break
        fi
        sleep 20
      done

      ssh $ssh_opts ubuntu@$host 'sudo cat /etc/rancher/k3s/k3s.yaml' \
        | sed 's#https://127.0.0.1:6443#https://${oci_core_instance.server[0].public_ip}:6443#' \
        > ${path.module}/kubeconfig
      chmod 600 ${path.module}/kubeconfig
      echo "kubeconfig written to ${path.module}/kubeconfig"
    EOT
  }
}

# Bootstrap Flux against clusters/oci-lab. Requires GITHUB_TOKEN in the
# environment and the `flux` CLI installed on the machine running terraform.
resource "null_resource" "flux_bootstrap" {
  count      = var.bootstrap_flux ? 1 : 0
  depends_on = [null_resource.kubeconfig]

  triggers = {
    node_id = oci_core_instance.server[0].id
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

      # First-boot race: the kubeconfig fetch above only proves k3s.yaml
      # exists on disk, not that the apiserver is actually serving requests
      # over the node's public IP yet (it can still be initializing, or the
      # node can still be rebooting after cloud-init). Poll /livez through
      # the public endpoint for up to ~5 minutes before handing off to
      # flux bootstrap, so it doesn't fail on a transient connection
      # refused/reset right after boot.
      host=${oci_core_instance.server[0].public_ip}
      echo "Waiting for the k3s API to report healthy at https://$host:6443/livez..."
      ready=0
      for i in $(seq 1 30); do
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$host:6443/livez" || echo 000)
        case "$code" in
          200|401|403) ready=1; break ;;
        esac
        sleep 10
      done
      if [ "$ready" -ne 1 ]; then
        echo "ERROR: k3s API at https://$host:6443/livez did not report healthy within 5 minutes." >&2
        exit 1
      fi
      echo "k3s API is healthy."

      flux bootstrap github \
        --owner=${var.github_owner} \
        --repository=${var.github_repository} \
        --branch=${var.github_branch} \
        --path=./clusters/oci-lab \
        --personal
    EOT
  }
}
