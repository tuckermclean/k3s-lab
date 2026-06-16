# --- OCI API-key authentication (see README.md for how to generate these) ---

variable "tenancy_ocid" {
  type        = string
  description = "OCID of your OCI tenancy."
}

variable "user_ocid" {
  type        = string
  description = "OCID of the user the API key belongs to."
}

variable "fingerprint" {
  type        = string
  description = "Fingerprint of the uploaded API signing key."
}

variable "api_private_key_path" {
  type        = string
  description = "Path to the PEM private key matching the uploaded API key."
}

variable "region" {
  type        = string
  description = "OCI region identifier, e.g. us-ashburn-1."
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment to create all resources in. Use the tenancy (root) OCID if unsure."
}

# --- Topology / sizing (variable-driven so you can rebalance the free-tier pool) ---

variable "server_count" {
  type        = number
  description = "Number of k3s control-plane servers (embedded etcd). Use an odd number for HA quorum."
  default     = 3

  validation {
    condition     = var.server_count >= 1 && var.server_count % 2 == 1
    error_message = "server_count must be an odd number (1, 3, ...) for a healthy etcd quorum."
  }
}

variable "agent_count" {
  type        = number
  description = "Number of k3s agent (worker-only) nodes. Default 0 for an all-server HA cluster."
  default     = 0
}

variable "ocpus_per_node" {
  type        = number
  description = "OCPUs per node. VM.Standard.A1.Flex requires an integer >= 1."
  default     = 1

  validation {
    condition     = floor(var.ocpus_per_node) == var.ocpus_per_node && var.ocpus_per_node >= 1
    error_message = "ocpus_per_node must be a whole number >= 1 (A1.Flex does not allow fractional OCPUs)."
  }
}

variable "memory_gbs_per_node" {
  type        = number
  description = "Memory (GB) per node."
  default     = 8
}

variable "boot_volume_size_gbs" {
  type        = number
  description = "Boot volume size per node in GB. Always Free block storage total is 200 GB."
  default     = 50
}

# --- Access / networking ---

variable "ssh_public_key" {
  type        = string
  description = "SSH public key contents installed on every node for the 'ubuntu' user."
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the matching SSH private key, used to fetch the kubeconfig from server-0."
}

variable "api_allowed_cidr" {
  type        = string
  description = "CIDR allowed to reach the Kubernetes API (port 6443) through the load balancer. Set to your IP/32; 0.0.0.0/0 exposes the API to the internet."
  default     = "0.0.0.0/0"
}

variable "enable_http_ingress" {
  type        = bool
  description = "Open 80/443 on the security list for a future Traefik ingress. No ingress is deployed in this phase."
  default     = false
}

variable "api_dns_name" {
  type        = string
  description = "Optional hostname to add to the API server cert SAN (you create the A record pointing at the reserved LB IP). Leave empty to use the IP only."
  default     = ""
}

variable "availability_domain" {
  type        = string
  description = "Availability domain to launch in. Leave empty to auto-pick the first AD in the region."
  default     = ""
}

# --- Flux GitOps bootstrap ---

variable "bootstrap_flux" {
  type        = bool
  description = "Run 'flux bootstrap github' against clusters/oci-lab after the cluster is up. Requires GITHUB_TOKEN in the environment and the flux CLI installed."
  default     = true
}

variable "github_owner" {
  type        = string
  description = "GitHub user/org that owns the GitOps repository."
  default     = ""
}

variable "github_repository" {
  type        = string
  description = "GitOps repository name."
  default     = "k3s-lab"
}

variable "github_branch" {
  type        = string
  description = "Branch Flux watches."
  default     = "main"
}

# --- Cross-cutting validation against the Always Free pool (4 OCPU / 24 GB) ---

variable "free_tier_max_ocpus" {
  type        = number
  description = "Guardrail: maximum total OCPUs to allocate. Always Free A1 pool is 4."
  default     = 4
}

variable "free_tier_max_memory_gbs" {
  type        = number
  description = "Guardrail: maximum total memory (GB) to allocate. Always Free A1 pool is 24."
  default     = 24
}
