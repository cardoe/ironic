# =============================================================================
# Access Information
# =============================================================================

output "devstack_floating_ip" {
  description = "Floating IP to SSH into the DevStack VM"
  value       = openstack_networking_floatingip_v2.devstack.address
}

output "devstack_mgmt_ip" {
  description = "DevStack VM IP on the management network"
  value       = var.devstack_mgmt_ip
}

output "switch_mgmt_ip" {
  description = "Cisco 9k switch IP on the management network"
  value       = var.switch_mgmt_ip
}

# =============================================================================
# Underlay / VXLAN Information
# =============================================================================

output "devstack_underlay_ip" {
  description = "DevStack VM IP on the underlay network (VXLAN source)"
  value       = var.devstack_underlay_ip
}

output "switch_underlay_ip" {
  description = "Cisco 9k IP on the underlay network (Ethernet1/1)"
  value       = var.switch_underlay_ip
}

output "switch_vtep_ip" {
  description = "Cisco 9k VTEP IP (loopback0, NVE source-interface)"
  value       = var.switch_vtep_ip
}

output "switch_underlay_mac" {
  description = "MAC address of the switch underlay port (for static ARP if needed)"
  value       = openstack_networking_port_v2.switch_underlay.mac_address
}

# =============================================================================
# Bare Metal Node Information (needed for Ironic enrollment)
# =============================================================================

output "baremetal_nodes" {
  description = "Bare metal node details for Ironic enrollment"
  value = [
    for i, instance in openstack_compute_instance_v2.bm_node : {
      index       = i
      name        = instance.name
      uuid        = instance.id
      mac_address = openstack_networking_port_v2.bm_node[i].mac_address
      switch_port = "Ethernet1/${i + 2}"
    }
  ]
}

# =============================================================================
# Network IDs (for reference / debugging)
# =============================================================================

output "network_ids" {
  description = "Network IDs for all created networks"
  value = {
    mgmt     = openstack_networking_network_v2.mgmt.id
    underlay = openstack_networking_network_v2.underlay.id
    bm       = [for n in openstack_networking_network_v2.bm : n.id]
  }
}

# =============================================================================
# Cisco 9k Instance Info
# =============================================================================

output "cisco_9k_instance_id" {
  description = "Nova instance UUID of the Cisco 9k switch simulator"
  value       = openstack_compute_instance_v2.cisco_9k.id
}

# =============================================================================
# Connection Instructions
# =============================================================================

output "instructions" {
  description = "Next steps after terraform apply"
  value       = <<-EOT

    Infrastructure created. Next steps:

    1. Wait for the Cisco 9k switch to boot (~5-10 minutes):
       openstack console log show cisco-nexus9k | tail -20

    2. Configure the switch (requires console access for initial POAP skip):
       openstack console url show --serial cisco-nexus9k
       # Then run: bash scripts/01-configure-switch.sh

    3. SSH to the DevStack VM and run the setup:
       ssh ubuntu@${openstack_networking_floatingip_v2.devstack.address}
       bash scripts/02-setup-devstack.sh

    4. After stack.sh completes, enroll bare metal nodes:
       bash scripts/03-enroll-nodes.sh

    5. Verify the deployment:
       bash scripts/04-verify.sh
  EOT
}
