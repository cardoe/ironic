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
#   - Connects: DevStack VM, bare metal VMs (for BMC/Redfish via sushy-tools)
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
# Per-node Bare Metal Networks (ironic-bm-{N})
#   - No DHCP (bare metal DHCP comes from DevStack's Neutron via the switch)
#   - Port security ON with allowed_address_pairs (0.0.0.0/0)
#   - Each is a point-to-point L2 link between a bare metal VM and the
#     DevStack VM (which bridges it to the local Cisco 9k's access port)
#   - Traffic is UNTAGGED (switch access ports strip VLAN tags), so
#     allowed_address_pairs is sufficient
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
# Ports - DevStack VM
#   NIC 0: management (SSH, internet)
#   NIC 1..N: per-node bare metal links (bridged to local Cisco 9k access ports)
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

resource "openstack_networking_port_v2" "devstack_bm" {
  count          = var.baremetal_node_count
  name           = "devstack-bm-${count.index}"
  network_id     = openstack_networking_network_v2.bm[count.index].id
  admin_state_up = true

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.bm[count.index].id
  }

  # Allow any IP from this port's MAC. DevStack bridges this NIC to the
  # local Cisco 9k's access port, so traffic from the switch (with
  # DevStack-assigned IPs) flows through here.
  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

# =============================================================================
# Ports - Bare metal VMs (one port each, on per-node network)
# =============================================================================

resource "openstack_networking_port_v2" "bm_node" {
  count          = var.baremetal_node_count
  name           = "bm-node-${count.index}"
  network_id     = openstack_networking_network_v2.bm[count.index].id
  admin_state_up = true

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.bm[count.index].id
  }

  # Allow any IP from this port's MAC. Bare metal nodes get IPs from
  # DevStack's Neutron via the switch, not from the hosting cloud.
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
