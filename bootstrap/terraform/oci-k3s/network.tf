resource "oci_core_vcn" "k3s" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [local.vcn_cidr]
  display_name   = "oci-k3s-vcn"
  dns_label      = "ocik3s"
}

resource "oci_core_internet_gateway" "k3s" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "oci-k3s-igw"
}

resource "oci_core_route_table" "k3s" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "oci-k3s-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.k3s.id
  }
}

resource "oci_core_security_list" "k3s" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k3s.id
  display_name   = "oci-k3s-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH for kubeconfig fetch / debugging.
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.api_allowed_cidr
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Kubernetes API directly on each node's public IP (no load balancer — see
  # cloud-init/server.yaml.tftpl and flux.tf for the Option-A rationale).
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.api_allowed_cidr
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # All node-to-node traffic inside the VCN: covers 6443, etcd 2379-2380,
  # flannel VXLAN 8472/udp, kubelet 10250, etc. in one rule.
  ingress_security_rules {
    protocol = "all"
    source   = local.vcn_cidr
  }

  # Optional HTTP/HTTPS for a future Traefik ingress.
  dynamic "ingress_security_rules" {
    for_each = var.enable_http_ingress ? [80, 443] : []
    content {
      protocol = "6" # TCP
      source   = "0.0.0.0/0"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.k3s.id
  cidr_block        = local.subnet_cidr
  display_name      = "oci-k3s-public"
  dns_label         = "pub"
  route_table_id    = oci_core_route_table.k3s.id
  security_list_ids = [oci_core_security_list.k3s.id]
}

# --- API endpoint: Option A — no load balancer ---
#
# The k3s API is reached directly on each server node's public IP (mirrors
# ovh-k3s: no LB, to keep cost/complexity down). etcd stays HA across all
# server nodes; if server-0 dies, repoint the kubeconfig at another server's
# public IP. See cloud-init/server.yaml.tftpl (node-external-ip/tls-san) and
# flux.tf (kubeconfig fetch + readiness poll) for how the public IP is wired
# up post-boot.
