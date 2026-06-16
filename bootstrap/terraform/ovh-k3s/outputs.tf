output "api_endpoint" {
  description = "Kubernetes API endpoint (node-1's public IP)."
  value       = "https://${local.first_ip}:6443"
}

output "kubeconfig_path" {
  description = "Local path to the fetched kubeconfig."
  value       = "${path.module}/kubeconfig"
}

output "node_public_ips" {
  description = "Public IPs of all server nodes (SSH as the image's default user)."
  value       = concat([openstack_compute_instance_v2.first.access_ip_v4], openstack_compute_instance_v2.rest[*].access_ip_v4)
}

output "agent_public_ips" {
  description = "Public IPs of any agent nodes."
  value       = openstack_compute_instance_v2.agent[*].access_ip_v4
}
