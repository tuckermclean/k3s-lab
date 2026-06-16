output "api_endpoint" {
  description = "Kubernetes API endpoint (load-balanced)."
  value       = "https://${local.lb_ip}:6443"
}

output "lb_public_ip" {
  description = "Reserved public IP of the API load balancer. Point any API DNS record here."
  value       = local.lb_ip
}

output "kubeconfig_path" {
  description = "Local path to the fetched kubeconfig."
  value       = "${path.module}/kubeconfig"
}

output "server_public_ips" {
  description = "Public IPs of the control-plane servers (SSH as ubuntu)."
  value       = oci_core_instance.server[*].public_ip
}

output "server_private_ips" {
  description = "Static private IPs of the control-plane servers."
  value       = oci_core_instance.server[*].private_ip
}

output "agent_public_ips" {
  description = "Public IPs of any agent nodes."
  value       = oci_core_instance.agent[*].public_ip
}
