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
#   - Connects: DevStack VM, Cisco 9k mgmt0, (optionally bare metal VMs)
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
# Trunk Network (ironic-trunk)
#   - No DHCP, port security disabled
#   - Carries all VLANs between Cisco 9k trunk port and DevStack OVS
# =============================================================================

resource "openstack_networking_network_v2" "trunk" {
  name                  = "ironic-trunk"
  admin_state_up        = true
  port_security_enabled = false
}

resource "openstack_networking_subnet_v2" "trunk" {
  name        = "ironic-trunk-subnet"
  network_id  = openstack_networking_network_v2.trunk.id
  cidr        = "10.0.99.0/24"
  ip_version  = 4
  no_gateway  = true
  enable_dhcp = false
}

# =============================================================================
# Per-node Bare Metal Networks (ironic-bm-{N})
#   - No DHCP, port security disabled
#   - Each is a point-to-point L2 link between a bare metal VM and a switch port
# =============================================================================

resource "openstack_networking_network_v2" "bm" {
  count                 = var.baremetal_node_count
  name                  = "ironic-bm-${count.index}"
  admin_state_up        = true
  port_security_enabled = false
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
# Ports - DevStack VM
# =============================================================================

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

resource "openstack_networking_port_v2" "devstack_trunk" {
  name               = "devstack-trunk"
  network_id         = openstack_networking_network_v2.trunk.id
  admin_state_up     = true
  port_security_enabled = false

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.trunk.id
  }
}

# =============================================================================
# Ports - Cisco 9k switch
#   NIC ordering matters: NIC 0 = mgmt0, NIC 1 = Ethernet1/1, NIC 2+ = Ethernet1/2+
# =============================================================================

resource "openstack_networking_port_v2" "switch_mgmt" {
  name           = "cisco9k-mgmt"
  network_id     = openstack_networking_network_v2.mgmt.id
  admin_state_up = true
  security_group_ids = [openstack_networking_secgroup_v2.ironic_dev.id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt.id
    ip_address = var.switch_mgmt_ip
  }
}

resource "openstack_networking_port_v2" "switch_trunk" {
  name               = "cisco9k-trunk"
  network_id         = openstack_networking_network_v2.trunk.id
  admin_state_up     = true
  port_security_enabled = false

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.trunk.id
  }
}

resource "openstack_networking_port_v2" "switch_bm" {
  count              = var.baremetal_node_count
  name               = "cisco9k-bm-${count.index}"
  network_id         = openstack_networking_network_v2.bm[count.index].id
  admin_state_up     = true
  port_security_enabled = false

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.bm[count.index].id
  }
}

# =============================================================================
# Ports - Bare metal VMs (one port each, on per-node network)
# =============================================================================

resource "openstack_networking_port_v2" "bm_node" {
  count              = var.baremetal_node_count
  name               = "bm-node-${count.index}"
  network_id         = openstack_networking_network_v2.bm[count.index].id
  admin_state_up     = true
  port_security_enabled = false

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.bm[count.index].id
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
