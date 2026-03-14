# =============================================================================
# Cisco Nexus 9000v Image
# =============================================================================

resource "openstack_images_image_v2" "cisco_9k" {
  name             = "cisco-nexus9300v"
  container_format = "bare"
  disk_format      = "qcow2"
  local_file_path  = var.cisco_9k_image_path
  visibility       = "private"

  properties = {
    hw_firmware_type = "uefi"
    hw_machine_type  = "q35"
  }
}

# =============================================================================
# DevStack VM
#   NIC 0 (eth0/ens3): ironic-mgmt (management, internet via floating IP)
#   NIC 1 (eth1/ens4): ironic-underlay (VXLAN tunnel endpoint)
# =============================================================================

resource "openstack_compute_instance_v2" "devstack" {
  name        = "devstack-ironic"
  image_id    = data.openstack_images_image_v2.devstack.id
  flavor_name = var.devstack_flavor
  key_pair    = var.key_pair_name

  # NIC 0: management
  network {
    port = openstack_networking_port_v2.devstack_mgmt.id
  }

  # NIC 1: underlay
  network {
    port = openstack_networking_port_v2.devstack_underlay.id
  }

  metadata = {
    role = "devstack"
  }
}

# =============================================================================
# Cisco Nexus 9000v Simulator
#   NIC ordering is critical - NX-OS maps NICs in order:
#     NIC 0 = mgmt0           (management, SSH, NGS access)
#     NIC 1 = Ethernet1/1     (underlay, routed L3 for VXLAN)
#     NIC 2 = Ethernet1/2     (bare metal node 0, access port)
#     NIC 3 = Ethernet1/3     (bare metal node 1, access port)
#     ...
#
#   The switch can run on any host -- it does not need to be co-located
#   with DevStack. All trunk traffic flows over VXLAN on the underlay.
# =============================================================================

resource "openstack_compute_instance_v2" "cisco_9k" {
  name        = "cisco-nexus9k"
  image_id    = openstack_images_image_v2.cisco_9k.id
  flavor_name = var.cisco_9k_flavor
  key_pair    = var.key_pair_name

  # NIC 0: mgmt0
  network {
    port = openstack_networking_port_v2.switch_mgmt.id
  }

  # NIC 1: Ethernet1/1 (underlay for VXLAN)
  network {
    port = openstack_networking_port_v2.switch_underlay.id
  }

  # NIC 2+: Ethernet1/2+ (one per bare metal node)
  dynamic "network" {
    for_each = openstack_networking_port_v2.switch_bm
    content {
      port = network.value.id
    }
  }

  metadata = {
    role = "switch-simulator"
  }
}

# =============================================================================
# Bare Metal Node VMs
#   Created by Terraform, managed by sushy-tools via the hosting cloud's Nova API.
#   Each has a single NIC on its per-node network (connected to a switch port).
#   Ironic will deploy to these via sushy-tools Redfish virtual media.
# =============================================================================

resource "openstack_compute_instance_v2" "bm_node" {
  count       = var.baremetal_node_count
  name        = "ironic-bm-node-${count.index}"
  image_id    = data.openstack_images_image_v2.devstack.id
  flavor_name = var.baremetal_flavor
  key_pair    = var.key_pair_name

  network {
    port = openstack_networking_port_v2.bm_node[count.index].id
  }

  metadata = {
    role       = "baremetal-node"
    node_index = tostring(count.index)
  }
}
