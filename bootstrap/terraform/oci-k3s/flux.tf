# Fetch the kubeconfig from server-0 over SSH and rewrite the endpoint to the
# load balancer so the cluster keeps working if server-0 dies.
resource "null_resource" "kubeconfig" {
  depends_on = [
    oci_core_instance.server,
    oci_network_load_balancer_backend.api,
  ]

  triggers = {
    lb_ip   = local.lb_ip
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
        | sed 's#https://127.0.0.1:6443#https://${local.lb_ip}:6443#' \
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
      flux bootstrap github \
        --owner=${var.github_owner} \
        --repository=${var.github_repository} \
        --branch=${var.github_branch} \
        --path=./clusters/oci-lab \
        --personal
    EOT
  }
}
