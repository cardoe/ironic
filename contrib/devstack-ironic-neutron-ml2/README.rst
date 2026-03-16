===============================================
Ironic + Neutron ML2 DevStack (Spine-Leaf)
===============================================

A development environment for testing Ironic with Neutron ML2 networking,
deployed on a hosting OpenStack cloud. Uses a spine-leaf network fabric with
Cisco Nexus 9000v switches, OSPF underlay, BGP EVPN, and VXLAN overlay.

Architecture
============

::

    ┌─────────────────────────────────────────────────────────────┐
    │                    Hosting OpenStack Cloud                   │
    │                                                             │
    │  ┌──────────┐    spine-link     ┌──────────┐               │
    │  │ spine01  │◄────────────────►│ spine02  │               │
    │  │  (RR)    │                   │  (RR)    │               │
    │  └─┬──┬─────┘                   └─────┬──┬─┘               │
    │    │  │                               │  │                 │
    │    │  └─────────┐         ┌───────────┘  │                 │
    │    │            │         │              │                 │
    │  ┌─┴────────┐ ┌─┴─────────┴─┐ ┌─────────┴─┐               │
    │  │ leaf01   │ │             │ │  leaf02   │               │
    │  │ (VTEP)   │ │             │ │  (VTEP)   │               │
    │  └─┬──┬─────┘ │             │ └────┬──┬───┘               │
    │    │  │       │  VXLAN/EVPN │      │  │                   │
    │    │  │       │   Fabric    │      │  │                   │
    │    │  trunk   │             │      │  │                   │
    │    │  │       └─────────────┘      │  │                   │
    │  ┌─┴──┴─────┐                   ┌──┴──┴────┐              │
    │  │ DevStack │                   │ BM node  │              │
    │  │   VM     │   ┌──────────┐    │ (odd)    │              │
    │  │          │   │ BM node  │    └──────────┘              │
    │  └──────────┘   │ (even)   │                              │
    │                 └──────────┘   ┌──────────┐              │
    │  ┌──────────┐                   │Controller│              │
    │  │          │◄── mgmt net ────►│DHCP/TFTP │              │
    │  │ All VMs  │                   │  (POAP)  │              │
    │  └──────────┘                   └──────────┘              │
    └─────────────────────────────────────────────────────────────┘

Components
----------

**Spine switches** (spine01, spine02):
  OSPF underlay routers and BGP route reflectors. They do not participate
  in VXLAN encapsulation. Each spine peers with both leafs and the other spine.

**Leaf switches** (leaf01, leaf02):
  VXLAN tunnel endpoints (VTEPs) with NVE interfaces. Leaf01 has a trunk port
  to DevStack carrying all tenant VLANs. Leaf02 handles odd-indexed BM nodes.
  Leafs exchange MAC/IP reachability via BGP EVPN through the spine RRs.

**DevStack VM**:
  Runs OpenStack services (Ironic, Neutron, Nova, etc.). Connected to leaf01
  via a Neutron trunk port that carries 802.1Q-tagged tenant VLAN traffic.
  OVS ``brbm`` bridges the trunk NIC directly.

**Bare metal node VMs**:
  Pre-created Nova instances on the hosting cloud that simulate bare metal
  hardware. Managed by Ironic via sushy-tools (Redfish emulator with the
  Nova driver). Even-indexed nodes connect to leaf01, odd-indexed to leaf02.

**Controller node**:
  Provides DHCP (with POAP options 66/67), TFTP, and DNS on the management
  network for automated switch provisioning.

Network Design
==============

Management Network (ironic-mgmt)
---------------------------------

- CIDR: ``192.168.32.0/24`` (configurable)
- DHCP enabled, router to external network for internet access
- Connects all nodes: controller, spines, leafs, DevStack, BM nodes
- Controller runs DHCP with POAP options for switch auto-provisioning

Inter-switch Underlay
---------------------

Point-to-point /30 subnets for OSPF adjacencies::

    spine-link:       10.1.1.0/30    spine01 (.1)  <-> spine02 (.2)
    leaf01-spine01:   10.1.1.4/30    leaf01  (.5)  <-> spine01 (.6)
    leaf01-spine02:   10.1.1.8/30    leaf01  (.9)  <-> spine02 (.10)
    leaf02-spine01:   10.1.1.12/30   leaf02  (.13) <-> spine01 (.14)
    leaf02-spine02:   10.1.1.16/30   leaf02  (.17) <-> spine02 (.18)

OSPF area 0.0.0.0 on all point-to-point links. Loopback0 IPs used as
router-IDs and BGP update sources:

- spine01: ``10.1.0.1``
- spine02: ``10.1.0.2``
- leaf01: ``10.1.0.3``
- leaf02: ``10.1.0.4``

BGP EVPN
--------

iBGP AS 65001 with L2VPN EVPN address-family:

- Spines are route reflectors
- Leafs are route reflector clients
- VXLAN NVE on leafs with ``host-reachability protocol bgp``
- VNI = VLAN + 10000 (e.g., VLAN 100 -> VNI 10100)

DevStack Trunk Port
-------------------

DevStack connects to leaf01 via a Neutron trunk port:

- Parent port on a dedicated trunk network (``172.20.20.0/24``)
- One sub-port per VLAN in the tenant range (100-150 by default)
- The hosting cloud handles 802.1Q tagging transparently
- DevStack sees tagged frames on its second NIC (eth1)
- ``eth1`` is added to OVS ``brbm`` bridge

BM nodes on leaf02 reach DevStack through the VXLAN/EVPN fabric
(leaf02 -> spine -> leaf01 -> trunk -> DevStack).

Bare Metal Networks
-------------------

Each BM node has a dedicated point-to-point L2 network to its leaf switch
access port. No DHCP, ``allowed_address_pairs`` set to ``0.0.0.0/0``.

- Even-indexed nodes (0, 2, ...) connect to leaf01 (Ethernet1/4+)
- Odd-indexed nodes (1, 3, ...) connect to leaf02 (Ethernet1/3+)

Prerequisites
=============

1. A hosting OpenStack cloud with:

   - Ability to create instances, networks, ports, trunks, floating IPs
   - Neutron trunk port support (``openstack_networking_trunk_v2``)
   - Sufficient quota for 7+ instances + networks

2. Cisco Nexus 9000v QCOW2 image (download from software.cisco.com)

3. Ubuntu 24.04 image in the hosting cloud's Glance

4. Terraform >= 1.0 with the OpenStack provider

5. SSH key pair registered in the hosting cloud

Deployment
==========

Step 0: Terraform
-----------------

::

    cd terraform/
    cp terraform.tfvars.example terraform.tfvars
    # Edit terraform.tfvars with your values

    terraform init
    terraform plan
    terraform apply

This creates all VMs, networks, ports, and trunk resources.

Step 1: Controller Setup
------------------------

SSH to the controller and set up POAP services::

    ssh ubuntu@$(terraform output -raw controller_floating_ip)
    sudo bash scripts/00-setup-controller.sh

This installs and configures DHCP (with POAP options) and TFTP, and
generates NX-OS configuration files for all four switches.

**Important**: Update ``/var/lib/tftpboot/serial_to_hostname`` with the
actual serial numbers from your Cisco 9000v images::

    openstack console log show spine01 | grep -i serial
    # Repeat for spine02, leaf01, leaf02

Step 2: Switch Provisioning
----------------------------

Switches should auto-provision via POAP when they boot. Monitor progress::

    openstack console log show spine01 | tail -20
    openstack console log show leaf01 | tail -20

**Alternative (manual)**: If POAP doesn't work, use the manual script::

    bash scripts/01-configure-switch.sh all

This requires initial console access to set mgmt0 IP, admin password,
and enable SSH on each switch first.

Step 3: DevStack Setup
----------------------

SSH to the DevStack VM and run the setup script::

    ssh ubuntu@$(terraform output -raw devstack_floating_ip)

    # Set hosting cloud credentials
    export HOSTING_CLOUD_AUTH_URL="https://your-cloud:5000/v3"
    export HOSTING_CLOUD_PROJECT="your-project"
    export HOSTING_CLOUD_USERNAME="your-user"
    export HOSTING_CLOUD_PASSWORD="your-password"

    bash scripts/02-setup-devstack.sh

This clones DevStack, generates ``local.conf``, runs ``stack.sh``, adds
the trunk interface to OVS ``brbm``, configures sushy-tools for the Nova
driver, and sets up networking-generic-switch for both leaf switches.

Step 4: Enroll Nodes
--------------------

From your workstation (where terraform runs)::

    terraform output -json baremetal_nodes > /tmp/nodes.json
    scp /tmp/nodes.json ubuntu@$(terraform output -raw devstack_floating_ip):/tmp/

On the DevStack VM::

    bash scripts/03-enroll-nodes.sh /tmp/nodes.json

Step 5: Verify
--------------

::

    bash scripts/04-verify.sh

Test a deployment::

    export OS_CLOUD=devstack-admin-demo
    openstack server create --flavor baremetal \
        --nic net-id=$(openstack network list | awk '/private/ {print $2}') \
        --image $(openstack image list | grep -- '-disk' | awk '{print $2}') \
        --key-name default testing

Maintenance
===========

::

    bash scripts/05-maintenance.sh status     # Check all services
    bash scripts/05-maintenance.sh restart    # Restart DevStack services
    bash scripts/05-maintenance.sh logs       # Tail service logs
    bash scripts/05-maintenance.sh reconnect  # Re-add trunk to brbm after reboot
    bash scripts/05-maintenance.sh redeploy   # Reset all nodes to available

File Layout
===========

::

    contrib/devstack-ironic-neutron-ml2/
    ├── README.rst
    ├── terraform/
    │   ├── main.tf                    # Provider config, data sources
    │   ├── variables.tf               # All configurable variables
    │   ├── network.tf                 # Networks, ports, trunks, floating IPs
    │   ├── compute.tf                 # VMs (controller, DevStack, switches, BM)
    │   ├── outputs.tf                 # IPs, node info, topology diagram
    │   └── terraform.tfvars.example   # Example variable values
    ├── poap/
    │   ├── poap_script.py             # POAP Python script (downloaded by switches)
    │   └── generate_switch_configs.sh # Generates NX-OS configs for all switches
    └── scripts/
        ├── 00-setup-controller.sh     # Controller: DHCP + TFTP for POAP
        ├── 01-configure-switch.sh     # Manual switch config (alternative to POAP)
        ├── 02-setup-devstack.sh       # DevStack + Ironic + ML2 setup
        ├── 03-enroll-nodes.sh         # Enroll BM nodes in Ironic
        ├── 04-verify.sh               # Verify deployment
        └── 05-maintenance.sh          # Status, restart, logs, reconnect
