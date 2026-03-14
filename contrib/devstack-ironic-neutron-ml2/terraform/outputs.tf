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

output "switch_local_mgmt_ip" {
  description = "Cisco 9k switch IP on the local management bridge inside DevStack"
  value       = var.switch_local_mgmt_ip
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
    mgmt = openstack_networking_network_v2.mgmt.id
    bm   = [for n in openstack_networking_network_v2.bm : n.id]
  }
}

# =============================================================================
# Connection Instructions
# =============================================================================

output "instructions" {
  description = "Next steps after terraform apply"
  value       = <<-EOT

    Infrastructure created. Next steps:

    1. SCP the Cisco 9k QCOW2 image to the DevStack VM:
       scp ${var.cisco_9k_image_path} ubuntu@${openstack_networking_floatingip_v2.devstack.address}:/tmp/nexus9300v.qcow2

    2. SSH to the DevStack VM and run the setup:
       ssh ubuntu@${openstack_networking_floatingip_v2.devstack.address}
       bash scripts/02-setup-devstack.sh

    3. After stack.sh completes, enroll bare metal nodes:
       bash scripts/03-enroll-nodes.sh

    4. Verify the deployment:
       bash scripts/04-verify.sh
  EOT
}
