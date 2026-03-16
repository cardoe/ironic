# =============================================================================
# Access Information
# =============================================================================

output "devstack_floating_ip" {
  description = "Floating IP to SSH into the DevStack VM"
  value       = openstack_networking_floatingip_v2.devstack.address
}

output "controller_floating_ip" {
  description = "Floating IP to SSH into the controller node"
  value       = openstack_networking_floatingip_v2.controller.address
}

# =============================================================================
# Management Network IPs
# =============================================================================

output "mgmt_ips" {
  description = "Management network IPs for all nodes"
  value = {
    controller = var.controller_mgmt_ip
    devstack   = var.devstack_mgmt_ip
    spine01    = var.spine01_mgmt_ip
    spine02    = var.spine02_mgmt_ip
    leaf01     = var.leaf01_mgmt_ip
    leaf02     = var.leaf02_mgmt_ip
  }
}

# =============================================================================
# Switch Instance IDs (for console access during POAP)
# =============================================================================

output "switch_instance_ids" {
  description = "Nova instance UUIDs for all switch VMs"
  value = {
    spine01 = openstack_compute_instance_v2.spine01.id
    spine02 = openstack_compute_instance_v2.spine02.id
    leaf01  = openstack_compute_instance_v2.leaf01.id
    leaf02  = openstack_compute_instance_v2.leaf02.id
  }
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
      leaf_switch = i % 2 == 0 ? "leaf01" : "leaf02"
      leaf_ip     = i % 2 == 0 ? var.leaf01_mgmt_ip : var.leaf02_mgmt_ip
      # NIC offset: leaf01 has trunk at NIC3 so BM starts at Ethernet1/4;
      # leaf02 has no trunk so BM starts at Ethernet1/3
      switch_port = i % 2 == 0 ? "Ethernet1/${4 + floor(i / 2)}" : "Ethernet1/${3 + floor(i / 2)}"
    }
  ]
}

# =============================================================================
# Network IDs (for reference / debugging)
# =============================================================================

output "network_ids" {
  description = "Network IDs for all created networks"
  value = {
    mgmt        = openstack_networking_network_v2.mgmt.id
    interswitch = { for k, v in openstack_networking_network_v2.interswitch : k => v.id }
    trunk       = openstack_networking_network_v2.devstack_trunk_parent.id
    bm          = [for n in openstack_networking_network_v2.bm : n.id]
  }
}

# =============================================================================
# Topology Summary
# =============================================================================

output "topology" {
  description = "Spine-leaf topology summary"
  value       = <<-EOT

    Spine-Leaf Topology:

      spine01 (${var.spine01_mgmt_ip}) ---- spine-link ---- spine02 (${var.spine02_mgmt_ip})
        |  \                                                /  |
        |   leaf01-spine01                    leaf01-spine02   |
        |         \                            /               |
        |          leaf01 (${var.leaf01_mgmt_ip})              |
        |            |                                         |
        |          trunk -> DevStack (${var.devstack_mgmt_ip}) |
        |                                                      |
        |   leaf02-spine01                    leaf02-spine02    |
        |         \                            /               |
        |          leaf02 (${var.leaf02_mgmt_ip})              |
        |                                                      |
      BM even nodes (0,2,...) -> leaf01                        |
      BM odd nodes  (1,3,...) -> leaf02 -----------------------+

      Controller (${var.controller_mgmt_ip}) - DHCP/TFTP/DNS for POAP
  EOT
}

# =============================================================================
# Connection Instructions
# =============================================================================

output "instructions" {
  description = "Next steps after terraform apply"
  value       = <<-EOT

    Infrastructure created. Next steps:

    1. SSH to the controller and set up POAP services (DNS, DHCP, TFTP):
       ssh ubuntu@${openstack_networking_floatingip_v2.controller.address}
       sudo bash /opt/poap/setup-controller.sh

    2. Wait for the Cisco 9k switches to boot and auto-provision via POAP (~10 min):
       openstack console log show spine01 | tail -20
       openstack console log show leaf01 | tail -20

    3. Verify switch provisioning (SSH from controller):
       ssh admin@${var.spine01_mgmt_ip}   # check OSPF, BGP
       ssh admin@${var.leaf01_mgmt_ip}    # check NVE, VLAN trunk

    4. SSH to the DevStack VM and run the setup:
       ssh ubuntu@${openstack_networking_floatingip_v2.devstack.address}
       bash scripts/02-setup-devstack.sh

    5. After stack.sh completes, enroll bare metal nodes:
       bash scripts/03-enroll-nodes.sh

    6. Verify the deployment:
       bash scripts/04-verify.sh
  EOT
}
