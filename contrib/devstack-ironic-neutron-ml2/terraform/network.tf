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
#   - Connects: DevStack VM, Cisco 9k (mgmt0), bare metal VMs (BMC/Redfish)
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
# Underlay Network (ironic-underlay)
#   - No DHCP, static IPs assigned to ports
#   - Carries VXLAN-encapsulated trunk traffic (regular UDP packets) between
#     DevStack and Cisco 9k switch(es)
#   - allowed_address_pairs on all ports (the switch sends VXLAN packets with
#     its VTEP/loopback IP as source, which differs from the port's fixed IP)
# =============================================================================

resource "openstack_networking_network_v2" "underlay" {
  name           = "ironic-underlay"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "underlay" {
  name        = "ironic-underlay-subnet"
  network_id  = openstack_networking_network_v2.underlay.id
  cidr        = var.underlay_subnet_cidr
  ip_version  = 4
  no_gateway  = true
  enable_dhcp = false
}

# =============================================================================
# Per-node Bare Metal Networks (ironic-bm-{N})
#   - No DHCP (bare metal DHCP comes from DevStack's Neutron via the switch)
#   - Each is a point-to-point L2 link between a bare metal VM and a switch
#     access port
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
#   NIC 0: management (SSH, internet access)
#   NIC 1: underlay (VXLAN tunnel endpoint for OVS brbm)
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

resource "openstack_networking_port_v2" "devstack_underlay" {
  name           = "devstack-underlay"
  network_id     = openstack_networking_network_v2.underlay.id
  admin_state_up = true

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.underlay.id
    ip_address = var.devstack_underlay_ip
  }

  # OVS VXLAN packets arrive with the port's own IP as source, so
  # allowed_address_pairs is technically not required here. Include it
  # for consistency and future flexibility.
  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

# =============================================================================
# Ports - Cisco 9k switch
#   NIC ordering matters (NX-OS maps NICs in order):
#     NIC 0 = mgmt0
#     NIC 1 = Ethernet1/1 (underlay, routed L3 for VXLAN)
#     NIC 2 = Ethernet1/2 (bare metal node 0, access port)
#     NIC 3 = Ethernet1/3 (bare metal node 1, access port)
#     ...
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

resource "openstack_networking_port_v2" "switch_underlay" {
  name           = "cisco9k-underlay"
  network_id     = openstack_networking_network_v2.underlay.id
  admin_state_up = true

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.underlay.id
    ip_address = var.switch_underlay_ip
  }

  # The switch sends VXLAN packets with its VTEP loopback IP as source,
  # which is different from this port's fixed IP. allowed_address_pairs
  # permits any source IP from this port's MAC.
  allowed_address_pairs {
    ip_address = "0.0.0.0/0"
  }
}

resource "openstack_networking_port_v2" "switch_bm" {
  count          = var.baremetal_node_count
  name           = "cisco9k-bm-${count.index}"
  network_id     = openstack_networking_network_v2.bm[count.index].id
  admin_state_up = true

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.bm[count.index].id
  }

  # Switch sends frames with IPs assigned by DevStack's Neutron (not the
  # hosting cloud) on behalf of bare metal nodes.
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

  # Bare metal nodes get IPs from DevStack's Neutron via the switch,
  # not from the hosting cloud.
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
