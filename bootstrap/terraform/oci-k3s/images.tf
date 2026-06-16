# Newest Canonical Ubuntu 24.04 image published for the A1 (aarch64) shape.
# Filtering by shape guarantees an ARM image; no OCID is hardcoded.
data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}
