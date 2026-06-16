# --- OpenStack auth ---
# Credentials are read from your environment (source the OVH OpenRC file) or
# from a clouds.yaml entry named by os_cloud. Nothing secret lives in this repo.

variable "region" {
  type        = string
  description = "OVH US Public Cloud region: US-WEST-OR-1 (Oregon) or US-EAST-VA-1 (Virginia). OVH US is a separate cloud from OVH EU with its own OpenStack RC."
  default     = "US-WEST-OR-1"
}

variable "os_cloud" {
  type        = string
  description = "Optional clouds.yaml cloud name. Leave empty to use OS_* environment variables (sourced OpenRC)."
  default     = ""
}

# --- Topology / sizing ---

variable "node_count" {
  type        = number
  description = "Number of k3s server nodes (embedded etcd). Odd number for HA quorum."
  default     = 3

  validation {
    condition     = var.node_count >= 1 && var.node_count % 2 == 1
    error_message = "node_count must be an odd number (1, 3, ...) for a healthy etcd quorum."
  }
}

variable "agent_count" {
  type        = number
  description = "Number of agent (worker-only) nodes. Default 0."
  default     = 0
}

variable "flavor_name" {
  type        = string
  description = "OVH US flavor. The US catalog differs from EU and varies by region. VERIFY with `openstack flavor list` after sourcing the US OpenRC and set this to the cheapest one with >=4GB RAM. The default is a best-guess and may not exist in your region."
  default     = "d2-4"
}

variable "image_name" {
  type        = string
  description = "Glance image name. Must match exactly; run `openstack image list` if unsure."
  default     = "Ubuntu 24.04"
}

variable "flannel_backend" {
  type        = string
  description = "k3s flannel backend. wireguard-native is required for multi-node on OVH (anti-spoofing breaks vxlan). Use vxlan only for a single node."
  default     = "wireguard-native"
}

# --- Access ---

variable "ssh_user" {
  type        = string
  description = "Default SSH user of the image (ubuntu for OVH Ubuntu images)."
  default     = "ubuntu"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key contents installed on every node."
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the matching SSH private key, used to fetch the kubeconfig from node-1."
}

variable "api_allowed_cidr" {
  type        = string
  description = "CIDR allowed to reach SSH (22) and the Kubernetes API (6443). Default 0.0.0.0/0 (open). Intra-cluster traffic is always allowed."
  default     = "0.0.0.0/0"
}

variable "enable_http_ingress" {
  type        = bool
  description = "Open 80/443 for a future Traefik ingress. No ingress is deployed in this phase."
  default     = false
}

# --- Flux GitOps bootstrap ---

variable "bootstrap_flux" {
  type        = bool
  description = "Run 'flux bootstrap github' against clusters/ovh-lab after the cluster is up. Requires GITHUB_TOKEN in the environment and the flux CLI installed."
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
