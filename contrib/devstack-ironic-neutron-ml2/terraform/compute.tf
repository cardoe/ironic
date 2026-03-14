# =============================================================================
# DevStack VM
#   NIC 0 (eth0/ens3): ironic-mgmt (management, internet via floating IP)
#   NIC 1..N (eth1+/ens4+): ironic-bm-{0..N} (bridged to local Cisco 9k)
#
#   The Cisco 9k runs locally inside this VM (nested virtualization).
#   Each BM NIC is bridged to the corresponding 9k access port tap.
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

  # NIC 1..N: per-node bare metal links
  dynamic "network" {
    for_each = openstack_networking_port_v2.devstack_bm
    content {
      port = network.value.id
    }
  }

  metadata = {
    role = "devstack"
  }
}

# =============================================================================
# Bare Metal Node VMs
#   Created by Terraform, managed by sushy-tools via the hosting cloud's Nova API.
#   Each has a single NIC on its per-node network (connected via DevStack to
#   the local Cisco 9k's access port).
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
