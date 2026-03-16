# =============================================================================
# Security Group - allow all for development
# =============================================================================

resource "openstack_networking_secgroup_v2" "ironic_dev" {
  name        = "ironic-dev-allow-all"
  description = "Allow all traffic for Ironic development"
}

resource "openstack_networking_secgroup_rule_v2" "allow_all_ingress_v4" {
  security_group_id = openstack_networking_secgroup_v2.ironic_dev.id
  direction         = "ingress"
  ethertype         = "IPv4"
}

resource "openstack_networking_secgroup_rule_v2" "allow_all_ingress_v6" {
  security_group_id = openstack_networking_secgroup_v2.ironic_dev.id
  direction         = "ingress"
  ethertype         = "IPv6"
}

# =============================================================================
# Management Network (ironic-mgmt)
#   - DHCP enabled, router to external for internet access
#   - Connects all nodes: controller, spines, leafs, DevStack, BM nodes
#   - Controller runs DHCP/TFTP for POAP on this network
# =============================================================================

resource "openstack_networking_network_v2" "mgmt" {
  name           = "ironic-mgmt"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "mgmt" {
  name            = "ironic-mgmt-subnet"
  network_id      = openstack_networking_network_v2.mgmt.id
  cidr            = var.mgmt_subnet_cidr
  ip_version      = 4
  dns_nameservers = var.dns_nameservers
  enable_dhcp     = true
}

resource "openstack_networking_router_v2" "mgmt" {
  name                = "ironic-mgmt-router"
  external_network_id = data.openstack_networking_network_v2.external.id
}

resource "openstack_networking_router_interface_v2" "mgmt" {
  router_id = openstack_networking_router_v2.mgmt.id
  subnet_id = openstack_networking_subnet_v2.mgmt.id
}

# =============================================================================
# Inter-switch Point-to-Point Links (underlay)
#   - /30 subnets for OSPF adjacencies between spines and leafs
#   - No DHCP, static IPs
#   - All from 10.1.1.0/24, carved into /30s
#
#   spine-link:        10.1.1.0/30   spine01 (.1) <-> spine02 (.2)
#   leaf01-spine01:    10.1.1.4/30   leaf01 (.5)  <-> spine01 (.6)
#   leaf01-spine02:    10.1.1.8/30   leaf01 (.9)  <-> spine02 (.10)
#   leaf02-spine01:    10.1.1.12/30  leaf02 (.13) <-> spine01 (.14)
#   leaf02-spine02:    10.1.1.16/30  leaf02 (.17) <-> spine02 (.18)
# =============================================================================

locals {
  interswitch_links = {
    spine_link = {
      name = "spine-link"
      cidr = "10.1.1.0/30"
      ip_a = "10.1.1.1"  # spine01
      ip_b = "10.1.1.2"  # spine02
    }
    leaf01_spine01 = {
      name = "leaf01-spine01"
      cidr = "10.1.1.4/30"
      ip_a = "10.1.1.5"  # leaf01
      ip_b = "10.1.1.6"  # spine01
    }
    leaf01_spine02 = {
      name = "leaf01-spine02"
      cidr = "10.1.1.8/30"
      ip_a = "10.1.1.9"  # leaf01
      ip_b = "10.1.1.10" # spine02
    }
    leaf02_spine01 = {
      name = "leaf02-spine01"
      cidr = "10.1.1.12/30"
      ip_a = "10.1.1.13" # leaf02
      ip_b = "10.1.1.14" # spine01
    }
    leaf02_spine02 = {
      name = "leaf02-spine02"
      cidr = "10.1.1.16/30"
      ip_a = "10.1.1.17" # leaf02
      ip_b = "10.1.1.18" # spine02
    }
  }
}

resource "openstack_networking_network_v2" "interswitch" {
  for_each       = local.interswitch_links
  name           = each.value.name
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "interswitch" {
  for_each    = local.interswitch_links
  name        = "${each.value.name}-subnet"
  network_id  = openstack_networking_network_v2.interswitch[each.key].id
  cidr        = each.value.cidr
  ip_version  = 4
  no_gateway  = true
  enable_dhcp = false
}

# Inter-switch ports: "a" side
resource "openstack_networking_port_v2" "interswitch_a" {
  for_each       = local.interswitch_links
  name           = "${each.value.name}-a"
  network_id     = openstack_networking_network_v2.interswitch[each.key].id
  admin_state_up = true

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.interswitch[each.key].id
    ip_address = each.value.ip_a
  }

  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

# Inter-switch ports: "b" side
resource "openstack_networking_port_v2" "interswitch_b" {
  for_each       = local.interswitch_links
  name           = "${each.value.name}-b"
  network_id     = openstack_networking_network_v2.interswitch[each.key].id
  admin_state_up = true

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.interswitch[each.key].id
    ip_address = each.value.ip_b
  }

  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

# =============================================================================
# DevStack Trunk Network
#   - Uses Neutron trunk port feature: parent port + sub-ports per VLAN
#   - The hosting cloud handles 802.1Q tagging transparently
#   - DevStack sees a single NIC with all VLANs as tagged frames
#   - Connects DevStack to leaf01 (Ethernet1/3 configured as trunk)
# =============================================================================

resource "openstack_networking_network_v2" "devstack_trunk_parent" {
  name           = "devstack-trunk-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "devstack_trunk_parent" {
  name        = "devstack-trunk-subnet"
  network_id  = openstack_networking_network_v2.devstack_trunk_parent.id
  cidr        = "172.20.20.0/24"
  ip_version  = 4
  no_gateway  = true
  enable_dhcp = false
}

# Per-VLAN sub-port networks (one network per VLAN in the tenant range)
resource "openstack_networking_network_v2" "devstack_trunk_vlan" {
  count          = var.vlan_range_end - var.vlan_range_start + 1
  name           = "devstack-vlan${var.vlan_range_start + count.index}"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "devstack_trunk_vlan" {
  count       = var.vlan_range_end - var.vlan_range_start + 1
  name        = "devstack-vlan${var.vlan_range_start + count.index}-subnet"
  network_id  = openstack_networking_network_v2.devstack_trunk_vlan[count.index].id
  cidr        = "172.20.${var.vlan_range_start + count.index}.0/24"
  ip_version  = 4
  no_gateway  = true
  enable_dhcp = false
}

# DevStack trunk parent port
resource "openstack_networking_port_v2" "devstack_trunk_parent" {
  name           = "devstack-trunk"
  network_id     = openstack_networking_network_v2.devstack_trunk_parent.id
  admin_state_up = true

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.devstack_trunk_parent.id
  }

  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

# DevStack trunk sub-ports (one per VLAN)
resource "openstack_networking_port_v2" "devstack_trunk_subport" {
  count          = var.vlan_range_end - var.vlan_range_start + 1
  name           = "devstack-trunk-vlan${var.vlan_range_start + count.index}"
  network_id     = openstack_networking_network_v2.devstack_trunk_vlan[count.index].id
  admin_state_up = true

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.devstack_trunk_vlan[count.index].id
  }

  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

# Leaf01 side of the trunk (same networks, separate ports)
resource "openstack_networking_port_v2" "leaf01_trunk_parent" {
  name           = "leaf01-trunk"
  network_id     = openstack_networking_network_v2.devstack_trunk_parent.id
  admin_state_up = true

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.devstack_trunk_parent.id
  }

  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

resource "openstack_networking_port_v2" "leaf01_trunk_subport" {
  count          = var.vlan_range_end - var.vlan_range_start + 1
  name           = "leaf01-trunk-vlan${var.vlan_range_start + count.index}"
  network_id     = openstack_networking_network_v2.devstack_trunk_vlan[count.index].id
  admin_state_up = true

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.devstack_trunk_vlan[count.index].id
  }

  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

# Neutron trunk resources
resource "openstack_networking_trunk_v2" "devstack" {
  name           = "devstack-trunk"
  admin_state_up = true
  port_id        = openstack_networking_port_v2.devstack_trunk_parent.id

  dynamic "sub_port" {
    for_each = openstack_networking_port_v2.devstack_trunk_subport
    content {
      port_id           = sub_port.value.id
      segmentation_id   = var.vlan_range_start + sub_port.key
      segmentation_type = "vlan"
    }
  }
}

resource "openstack_networking_trunk_v2" "leaf01" {
  name           = "leaf01-trunk"
  admin_state_up = true
  port_id        = openstack_networking_port_v2.leaf01_trunk_parent.id

  dynamic "sub_port" {
    for_each = openstack_networking_port_v2.leaf01_trunk_subport
    content {
      port_id           = sub_port.value.id
      segmentation_id   = var.vlan_range_start + sub_port.key
      segmentation_type = "vlan"
    }
  }
}

# =============================================================================
# Per-node Bare Metal Networks (ironic-bm-{N})
#   - No DHCP, allowed_address_pairs
#   - Each is a point-to-point L2 link between a BM VM and a leaf access port
#   - Even nodes (0,2,...) -> leaf01, odd nodes (1,3,...) -> leaf02
# =============================================================================

resource "openstack_networking_network_v2" "bm" {
  count          = var.baremetal_node_count
  name           = "ironic-bm-${count.index}"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "bm" {
  count       = var.baremetal_node_count
  name        = "ironic-bm-${count.index}-subnet"
  network_id  = openstack_networking_network_v2.bm[count.index].id
  cidr        = "10.0.${100 + count.index}.0/24"
  ip_version  = 4
  no_gateway  = true
  enable_dhcp = false
}

# =============================================================================
# Ports - Management
# =============================================================================

resource "openstack_networking_port_v2" "controller_mgmt" {
  name           = "controller-mgmt"
  network_id     = openstack_networking_network_v2.mgmt.id
  admin_state_up = true
  security_group_ids = [openstack_networking_secgroup_v2.ironic_dev.id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt.id
    ip_address = var.controller_mgmt_ip
  }
}

resource "openstack_networking_port_v2" "devstack_mgmt" {
  name           = "devstack-mgmt"
  network_id     = openstack_networking_network_v2.mgmt.id
  admin_state_up = true
  security_group_ids = [openstack_networking_secgroup_v2.ironic_dev.id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt.id
    ip_address = var.devstack_mgmt_ip
  }
}

resource "openstack_networking_port_v2" "spine01_mgmt" {
  name           = "spine01-mgmt"
  network_id     = openstack_networking_network_v2.mgmt.id
  admin_state_up = true
  security_group_ids = [openstack_networking_secgroup_v2.ironic_dev.id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt.id
    ip_address = var.spine01_mgmt_ip
  }
}

resource "openstack_networking_port_v2" "spine02_mgmt" {
  name           = "spine02-mgmt"
  network_id     = openstack_networking_network_v2.mgmt.id
  admin_state_up = true
  security_group_ids = [openstack_networking_secgroup_v2.ironic_dev.id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt.id
    ip_address = var.spine02_mgmt_ip
  }
}

resource "openstack_networking_port_v2" "leaf01_mgmt" {
  name           = "leaf01-mgmt"
  network_id     = openstack_networking_network_v2.mgmt.id
  admin_state_up = true
  security_group_ids = [openstack_networking_secgroup_v2.ironic_dev.id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt.id
    ip_address = var.leaf01_mgmt_ip
  }
}

resource "openstack_networking_port_v2" "leaf02_mgmt" {
  name           = "leaf02-mgmt"
  network_id     = openstack_networking_network_v2.mgmt.id
  admin_state_up = true
  security_group_ids = [openstack_networking_secgroup_v2.ironic_dev.id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt.id
    ip_address = var.leaf02_mgmt_ip
  }
}

# =============================================================================
# Ports - Leaf switch access ports for bare metal nodes
# =============================================================================

resource "openstack_networking_port_v2" "leaf_bm" {
  count          = var.baremetal_node_count
  name           = "${count.index % 2 == 0 ? "leaf01" : "leaf02"}-bm-${count.index}"
  network_id     = openstack_networking_network_v2.bm[count.index].id
  admin_state_up = true

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.bm[count.index].id
  }

  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

resource "openstack_networking_port_v2" "bm_node" {
  count          = var.baremetal_node_count
  name           = "bm-node-${count.index}"
  network_id     = openstack_networking_network_v2.bm[count.index].id
  admin_state_up = true

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.bm[count.index].id
  }

  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

# =============================================================================
# Floating IP for DevStack VM
# =============================================================================

resource "openstack_networking_floatingip_v2" "devstack" {
  pool = var.external_network_name
}

resource "openstack_networking_floatingip_associate_v2" "devstack" {
  floating_ip = openstack_networking_floatingip_v2.devstack.address
  port_id     = openstack_networking_port_v2.devstack_mgmt.id
}

# Floating IP for controller (needed for SSH access and POAP file serving)
resource "openstack_networking_floatingip_v2" "controller" {
  pool = var.external_network_name
}

resource "openstack_networking_floatingip_associate_v2" "controller" {
  floating_ip = openstack_networking_floatingip_v2.controller.address
  port_id     = openstack_networking_port_v2.controller_mgmt.id
}
