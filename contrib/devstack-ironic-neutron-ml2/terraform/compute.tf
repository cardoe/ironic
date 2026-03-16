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
# Controller Node
#   Provides DNS, DHCP (with POAP options), and TFTP for switch auto-provisioning.
#   NIC 0: ironic-mgmt
# =============================================================================

resource "openstack_compute_instance_v2" "controller" {
  name        = "controller"
  image_id    = data.openstack_images_image_v2.devstack.id
  flavor_name = var.controller_flavor != "" ? var.controller_flavor : var.baremetal_flavor
  key_pair    = var.key_pair_name

  network {
    port = openstack_networking_port_v2.controller_mgmt.id
  }

  metadata = {
    role = "controller"
  }
}

# =============================================================================
# DevStack VM
#   NIC 0 (eth0): ironic-mgmt (management, internet via floating IP)
#   NIC 1 (eth1): trunk to leaf01 (parent port + VLAN sub-ports)
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

  # NIC 1: trunk to leaf01 (uses Neutron trunk port)
  network {
    port = openstack_networking_port_v2.devstack_trunk_parent.id
  }

  metadata = {
    role = "devstack"
  }

  depends_on = [openstack_networking_trunk_v2.devstack]
}

# =============================================================================
# Spine01
#   NIC ordering (NX-OS maps in order):
#     NIC 0 = mgmt0
#     NIC 1 = Ethernet1/1  spine-link       -> spine02
#     NIC 2 = Ethernet1/2  leaf01-spine01    -> leaf01
#     NIC 3 = Ethernet1/3  leaf02-spine01    -> leaf02
# =============================================================================

resource "openstack_compute_instance_v2" "spine01" {
  name        = "spine01"
  image_id    = openstack_images_image_v2.cisco_9k.id
  flavor_name = var.cisco_9k_flavor
  key_pair    = var.key_pair_name

  # NIC 0: mgmt0
  network {
    port = openstack_networking_port_v2.spine01_mgmt.id
  }

  # NIC 1: Ethernet1/1 -> spine02 (spine-link)
  network {
    port = openstack_networking_port_v2.interswitch_a["spine_link"].id
  }

  # NIC 2: Ethernet1/2 -> leaf01
  network {
    port = openstack_networking_port_v2.interswitch_b["leaf01_spine01"].id
  }

  # NIC 3: Ethernet1/3 -> leaf02
  network {
    port = openstack_networking_port_v2.interswitch_b["leaf02_spine01"].id
  }

  metadata = {
    role = "spine"
  }
}

# =============================================================================
# Spine02
#   NIC ordering:
#     NIC 0 = mgmt0
#     NIC 1 = Ethernet1/1  spine-link       -> spine01
#     NIC 2 = Ethernet1/2  leaf01-spine02    -> leaf01
#     NIC 3 = Ethernet1/3  leaf02-spine02    -> leaf02
# =============================================================================

resource "openstack_compute_instance_v2" "spine02" {
  name        = "spine02"
  image_id    = openstack_images_image_v2.cisco_9k.id
  flavor_name = var.cisco_9k_flavor
  key_pair    = var.key_pair_name

  # NIC 0: mgmt0
  network {
    port = openstack_networking_port_v2.spine02_mgmt.id
  }

  # NIC 1: Ethernet1/1 -> spine01 (spine-link)
  network {
    port = openstack_networking_port_v2.interswitch_b["spine_link"].id
  }

  # NIC 2: Ethernet1/2 -> leaf01
  network {
    port = openstack_networking_port_v2.interswitch_b["leaf01_spine02"].id
  }

  # NIC 3: Ethernet1/3 -> leaf02
  network {
    port = openstack_networking_port_v2.interswitch_b["leaf02_spine02"].id
  }

  metadata = {
    role = "spine"
  }
}

# =============================================================================
# Leaf01
#   NIC ordering:
#     NIC 0 = mgmt0
#     NIC 1 = Ethernet1/1  leaf01-spine01    -> spine01
#     NIC 2 = Ethernet1/2  leaf01-spine02    -> spine02
#     NIC 3 = Ethernet1/3  trunk to DevStack (Neutron trunk port)
#     NIC 4 = Ethernet1/4  BM node 0 (access)
#     NIC 5 = Ethernet1/5  BM node 2 (access), if exists
#     ...
# =============================================================================

resource "openstack_compute_instance_v2" "leaf01" {
  name        = "leaf01"
  image_id    = openstack_images_image_v2.cisco_9k.id
  flavor_name = var.cisco_9k_flavor
  key_pair    = var.key_pair_name

  # NIC 0: mgmt0
  network {
    port = openstack_networking_port_v2.leaf01_mgmt.id
  }

  # NIC 1: Ethernet1/1 -> spine01
  network {
    port = openstack_networking_port_v2.interswitch_a["leaf01_spine01"].id
  }

  # NIC 2: Ethernet1/2 -> spine02
  network {
    port = openstack_networking_port_v2.interswitch_a["leaf01_spine02"].id
  }

  # NIC 3: Ethernet1/3 -> DevStack (trunk)
  network {
    port = openstack_networking_port_v2.leaf01_trunk_parent.id
  }

  # NIC 4+: Ethernet1/4+ -> BM nodes (even-indexed: 0, 2, ...)
  dynamic "network" {
    for_each = [for i in range(var.baremetal_node_count) : i if i % 2 == 0]
    content {
      port = openstack_networking_port_v2.leaf_bm[network.value].id
    }
  }

  metadata = {
    role = "leaf"
  }

  depends_on = [openstack_networking_trunk_v2.leaf01]
}

# =============================================================================
# Leaf02
#   NIC ordering:
#     NIC 0 = mgmt0
#     NIC 1 = Ethernet1/1  leaf02-spine01    -> spine01
#     NIC 2 = Ethernet1/2  leaf02-spine02    -> spine02
#     NIC 3 = Ethernet1/3  (reserved for future trunk)
#     NIC 4 = Ethernet1/4  BM node 1 (access)
#     NIC 5 = Ethernet1/5  BM node 3 (access), if exists
#     ...
#
#   Note: leaf02 does not have a DevStack trunk in this topology.
#   BM traffic on leaf02 reaches DevStack via the VXLAN/EVPN fabric.
# =============================================================================

resource "openstack_compute_instance_v2" "leaf02" {
  name        = "leaf02"
  image_id    = openstack_images_image_v2.cisco_9k.id
  flavor_name = var.cisco_9k_flavor
  key_pair    = var.key_pair_name

  # NIC 0: mgmt0
  network {
    port = openstack_networking_port_v2.leaf02_mgmt.id
  }

  # NIC 1: Ethernet1/1 -> spine01
  network {
    port = openstack_networking_port_v2.interswitch_a["leaf02_spine01"].id
  }

  # NIC 2: Ethernet1/2 -> spine02
  network {
    port = openstack_networking_port_v2.interswitch_a["leaf02_spine02"].id
  }

  # NIC 3+: Ethernet1/3+ -> BM nodes (odd-indexed: 1, 3, ...)
  dynamic "network" {
    for_each = [for i in range(var.baremetal_node_count) : i if i % 2 == 1]
    content {
      port = openstack_networking_port_v2.leaf_bm[network.value].id
    }
  }

  metadata = {
    role = "leaf"
  }
}

# =============================================================================
# Bare Metal Node VMs
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
