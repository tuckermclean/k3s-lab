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

  # Kubernetes API via the load balancer.
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

# --- HA API endpoint: Network Load Balancer with a reserved (static) public IP ---

resource "oci_core_public_ip" "api" {
  compartment_id = var.compartment_ocid
  lifetime       = "RESERVED"
  display_name   = "oci-k3s-api"
}

resource "oci_network_load_balancer_network_load_balancer" "api" {
  compartment_id = var.compartment_ocid
  display_name   = "oci-k3s-api"
  subnet_id      = oci_core_subnet.public.id
  is_private     = false

  reserved_ips {
    id = oci_core_public_ip.api.id
  }
}

resource "oci_network_load_balancer_backend_set" "api" {
  name                     = "k3s-api"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.api.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false

  health_checker {
    protocol = "TCP"
    port     = 6443
  }
}

resource "oci_network_load_balancer_listener" "api" {
  name                     = "k3s-api"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.api.id
  default_backend_set_name = oci_network_load_balancer_backend_set.api.name
  port                     = 6443
  protocol                 = "TCP"
}

resource "oci_network_load_balancer_backend" "api" {
  count                    = var.server_count
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.api.id
  backend_set_name         = oci_network_load_balancer_backend_set.api.name
  ip_address               = local.server_private_ips[count.index]
  port                     = 6443
}
