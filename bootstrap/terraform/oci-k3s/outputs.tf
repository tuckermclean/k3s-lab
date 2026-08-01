output "api_endpoint" {
  description = "Kubernetes API endpoint (server-0's public IP — no load balancer, Option A)."
  value       = "https://${oci_core_instance.server[0].public_ip}:6443"
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

output "oci_dns" {
  description = "Cloudflare oci.<dns_zone> A records managed by Terraform. Empty unless manage_dns=true."
  value       = [for k, r in cloudflare_record.oci : "oci.${var.dns_zone} -> ${r.content}"]
}
