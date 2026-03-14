=====================================================================
DevStack: Ironic + Neutron ML2 with sushy-tools Nova Driver and
Cisco Nexus 9000v on a Hosting OpenStack Cloud
=====================================================================

This guide sets up a development environment for working on Ironic and
Neutron ML2 drivers. The key design: a **hosting OpenStack cloud** provides
all the compute and networking, while **DevStack** runs inside a VM on that
cloud. sushy-tools uses the **Nova driver** to manage sibling VMs (on the
same hosting cloud) as virtual bare metal nodes. A **Cisco Nexus 9000v**
switch simulator (also a Nova instance) sits between the bare metal VMs
and DevStack, providing realistic VLAN switching for ML2 driver testing.

Trunk traffic (VLAN-tagged) between the switch and DevStack flows over
**VXLAN tunnels** on a dedicated underlay network. This avoids needing
``port_security_enabled=false`` on the hosting cloud and allows the switch
to run on **any host** -- not necessarily co-located with DevStack.
Multiple switches can be deployed for port channel / vPC testing.

.. contents:: Table of Contents
   :local:
   :depth: 3

Architecture
============

Two layers: the hosting cloud provides infrastructure; DevStack runs
inside it and manages "bare metal" that is actually VMs on the same cloud.

::

  Hosting OpenStack Cloud
  =======================

  Network: ironic-mgmt (DHCP, router to external)
  ------------------------------------------------
  172.24.5.10           172.24.5.20
  DevStack VM --------> Cisco 9k sim (mgmt0)
  (floating IP)         (SSH config, NGS access)


  Network: ironic-underlay (no DHCP, allowed_address_pairs)
  ---------------------------------------------------------
  10.0.99.10            10.0.99.20 (Ethernet1/1, routed L3)
  DevStack VM --------> Cisco 9k sim (VXLAN VTEP: 10.0.99.120)
  (OVS VXLAN ports)     (NVE1, loopback0)

  VXLAN tunnels carry trunk traffic: VLAN <-> VNI mapping
    VLAN 100 <-> VNI 10100
    VLAN 101 <-> VNI 10101
    ...


  Network: ironic-bm-0 (no DHCP, allowed_address_pairs)
  ------------------------------------------------------
  BM Node 0 ----------> Cisco 9k sim (Ethernet1/2 access)

  Network: ironic-bm-1 (no DHCP, allowed_address_pairs)
  ------------------------------------------------------
  BM Node 1 ----------> Cisco 9k sim (Ethernet1/3 access)

  Network: ironic-bm-2 (no DHCP, allowed_address_pairs)
  ------------------------------------------------------
  BM Node 2 ----------> Cisco 9k sim (Ethernet1/4 access)


  Data Flow (during Ironic provisioning)
  =======================================

  1. Ironic tells sushy-tools to boot BM Node 0 via virtual media
  2. sushy-tools calls hosting cloud Nova API to rebuild instance
  3. NGS configures Cisco 9k: Ethernet1/2 -> provisioning VLAN 100
  4. IPA traffic: BM Node 0 eth0 -> ironic-bm-0 -> 9k Ethernet1/2
     -> VLAN 100 -> NVE (VNI 10100) -> VXLAN over underlay
     -> DevStack OVS brbm (VLAN 100) -> Neutron DHCP / Ironic
  5. IPA phones home, Ironic deploys the OS
  6. NGS switches Ethernet1/2 to tenant VLAN

Key design decisions:

* **VXLAN overlay** replaces the physical trunk. Trunk traffic (VLAN-tagged
  frames between the switch and DevStack) is encapsulated in VXLAN (regular
  UDP packets) that pass ``allowed_address_pairs`` on the hosting cloud. No
  ``port_security_enabled=false`` is needed anywhere.

* **Per-node networks** provide L2 connectivity between each bare metal VM
  and a switch access port. Traffic is untagged (switch access ports strip
  VLAN tags). ``allowed_address_pairs`` with ``0.0.0.0/0`` permits
  DevStack-assigned IPs through. The bare metal VM sees a regular ``eth0``.

* **Switch runs anywhere.** Because the trunk is VXLAN, the Cisco 9k does
  not need to be co-located with DevStack. It can run on a different host.
  Multiple switches can be deployed for port channel / vPC testing -- each
  switch gets its own underlay IP and VTEP, and DevStack creates VXLAN
  tunnels to each.

* **DHCP is disabled** on bare metal networks so the hosting cloud's
  Neutron doesn't interfere. All bare metal DHCP comes from DevStack's
  Neutron via the switch.

* **The Cisco 9k runs as a Nova instance** with: mgmt NIC, underlay NIC
  (Ethernet1/1, routed L3 for VXLAN), and one access port NIC per bare
  metal node.

* **Bare metal VMs are pre-created** by Terraform, then managed by
  sushy-tools via the hosting cloud's Nova API. Ironic enrolls them
  using their Nova instance UUIDs as Redfish system IDs.

Prerequisites
=============

Hosting Cloud Requirements
--------------------------

* Tenant networks with the ability to create many
* ``allowed_address_pairs`` with ``ip_address=0.0.0.0/0`` on ports
  (most clouds support this)
* **UEFI boot support** for Nova instances (OVMF firmware) -- needed for
  the Cisco 9k simulator. Verify that your cloud supports the
  ``hw_firmware_type=uefi`` image property.
* **Serial console or VNC access** for initial Cisco 9k switch setup
  (POAP skip). Serial console (nova-serialproxy) is preferred.
* Sufficient quota: ~5 instances, ~6 networks, ~15 ports, 1 floating IP
* An Ubuntu 24.04 image in Glance
* Appropriate flavors (see below)

Verify Hosting Cloud Compatibility
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Run these checks before starting::

    # Verify allowed_address_pairs works
    openstack network create test-aap
    openstack port create --network test-aap \
        --allowed-address ip-address=0.0.0.0/0 test-aap-port
    openstack port delete test-aap-port
    openstack network delete test-aap

    # UEFI images are supported (upload a small test)
    openstack image create --disk-format qcow2 --container-format bare \
        --property hw_firmware_type=uefi --property hw_machine_type=q35 \
        --file /dev/null test-uefi
    openstack image delete test-uefi

    # Check quotas
    openstack quota show

    # Check serial console availability
    # (create a small test instance first, then:)
    openstack console url show --serial <test-instance>

Flavor Sizing
-------------

============== ====== ====== ======
VM             vCPUs  RAM    Disk
============== ====== ====== ======
DevStack       8+     32 GB  100 GB
Cisco 9k       2      8 GB   10 GB
Bare metal (x3) 1-2   2-4 GB 10 GB
============== ====== ====== ======

Local Requirements
------------------

* **Terraform** >= 1.0 with the OpenStack provider
* **OpenStack CLI** (``python-openstackclient``) configured with
  ``clouds.yaml`` for the hosting cloud
* **Cisco Nexus 9000v QCOW2 image** -- download from
  https://software.cisco.com (search "Nexus 9000v" or "NX-OSv 9000",
  requires a Cisco account)
* **SSH key pair** registered in the hosting cloud

Setup
=====

Step 1: Configure Terraform Variables
--------------------------------------

::

    cd contrib/devstack-ironic-neutron-ml2/terraform
    cp terraform.tfvars.example terraform.tfvars
    # Edit terraform.tfvars with your cloud details

Step 2: Create Infrastructure
-------------------------------

::

    terraform init
    terraform plan
    terraform apply

This creates:

* 1 management network (``ironic-mgmt``) with router and floating IP
* 1 underlay network (``ironic-underlay``, ``allowed_address_pairs``)
* N bare metal networks (``ironic-bm-{0..N}``, ``allowed_address_pairs``)
* DevStack VM (Ubuntu 24.04) with mgmt + underlay NICs
* Cisco Nexus 9000v VM (uploaded to Glance with UEFI properties)
  with mgmt + underlay + N bare metal NICs
* N bare metal VMs
* All ports with ``allowed_address_pairs``

Step 3: Configure the Cisco 9k Switch
---------------------------------------

The switch needs initial console-based setup (POAP skip, admin password,
SSH enable) before SSH-based configuration can proceed.

**Initial console setup** (one-time, manual):

::

    # Get serial console URL from the hosting cloud
    openstack console url show --serial cisco-nexus9k

    # Connect and wait ~5-10 minutes for "Abort Power On Auto Provisioning"
    # Then run these commands:
    #   skip
    #   (wait for login prompt)
    #   admin
    #   (blank password)
    #   configure
    #   username admin password system_s3cret! role network-admin
    #   int mgmt0
    #   ip address 172.24.5.20/24
    #   exit
    #   feature ssh
    #   exit
    #   copy run start

**SSH-based configuration** (automated):

This script enables VXLAN/NVE on the switch, configures the underlay
interface (Ethernet1/1), VTEP loopback, VLAN-to-VNI mappings, and
access ports::

    # From a machine that can reach 172.24.5.20 (e.g., the DevStack VM)
    bash scripts/01-configure-switch.sh

Step 4: Set Up DevStack
------------------------

SSH to the DevStack VM and run the setup script::

    ssh ubuntu@$(terraform output -raw devstack_floating_ip)

    # Set hosting cloud credentials for sushy-tools Nova driver
    export HOSTING_CLOUD_AUTH_URL="https://your-cloud:5000/v3"
    export HOSTING_CLOUD_PROJECT="your-project"
    export HOSTING_CLOUD_USERNAME="your-user"
    export HOSTING_CLOUD_PASSWORD="your-password"

    # Set VXLAN underlay details (from terraform output)
    export SWITCH_VTEP_IP="10.0.99.120"
    export DEVSTACK_UNDERLAY_IP="10.0.99.10"

    bash scripts/02-setup-devstack.sh

This script:

1. Creates the ``stack`` user and clones DevStack
2. Writes hosting cloud credentials to ``clouds.yaml`` (for sushy-tools)
3. Configures the underlay interface with a static IP
4. Generates ``local.conf`` with:

   - Ironic in hardware mode (``IRONIC_IS_HARDWARE=True``) -- no local VMs
   - Redfish driver (will be reconfigured for Nova driver post-stack)
   - Neutron ML2 with networking-generic-switch
   - VLAN tenant networking (range 100:150)

5. Runs ``stack.sh``
6. Post-stack: creates per-VLAN VXLAN tunnel ports on OVS ``brbm``
   (one port per VLAN, each mapped to a VNI tunneled to the switch VTEP),
   reconfigures sushy-tools for the Nova driver, configures NGS with
   the switch details

Step 5: Enroll Bare Metal Nodes
--------------------------------

Export node information from Terraform and enroll in Ironic::

    # On your local machine (where terraform runs)
    terraform output -json baremetal_nodes > /tmp/nodes.json
    scp /tmp/nodes.json ubuntu@$(terraform output -raw devstack_floating_ip):/tmp/

    # On the DevStack VM
    bash scripts/03-enroll-nodes.sh /tmp/nodes.json

This creates Ironic nodes with:

* Redfish BMC URL pointing at local sushy-tools
* System ID = Nova instance UUID (sushy-tools Nova driver maps these)
* Port with ``local_link_connection`` pointing at the correct switch port
* ``network_interface=neutron`` for ML2 integration

Step 6: Verify
---------------

::

    bash scripts/04-verify.sh

Step 7: Test a Deployment
--------------------------

::

    export OS_CLOUD=devstack-admin-demo

    net_id=$(openstack network list | awk '/private/ {print $2}')
    image=$(openstack image list | grep -- '-disk' | awk '{ print $2 }')

    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa 2>/dev/null || true
    openstack keypair create --public-key ~/.ssh/id_rsa.pub default 2>/dev/null || true

    openstack server create --flavor baremetal --nic net-id=$net_id \
        --image $image --key-name default testing

    watch openstack server list --long

Maintenance
===========

::

    # Check status of all components
    bash scripts/05-maintenance.sh status

    # Restart all DevStack services
    bash scripts/05-maintenance.sh restart

    # Re-create VXLAN tunnel ports after a VM reboot
    bash scripts/05-maintenance.sh reconnect

    # Undeploy all instances and reset nodes
    bash scripts/05-maintenance.sh redeploy

    # Tail logs
    bash scripts/05-maintenance.sh logs

Tear Down
---------

::

    # On the DevStack VM
    cd /opt/stack/devstack && ./unstack.sh

    # On your local machine
    cd terraform && terraform destroy

Troubleshooting
===============

sushy-tools Not Discovering Bare Metal VMs
-------------------------------------------

* Verify hosting cloud credentials: ``openstack --os-cloud hosting-cloud server list``
* Check sushy-tools config: ``cat /etc/ironic/redfish/emulator.conf``
* Check sushy-tools logs: ``journalctl -u devstack@redfish-emulator``
* Verify clouds.yaml is readable: ``cat /etc/openstack/clouds.yaml``

.. note::
   sushy-tools with the Nova driver lists ALL instances in the configured
   cloud/project as Redfish Systems. The DevStack VM and Cisco 9k VM will
   also appear. This is harmless -- Ironic only manages explicitly enrolled
   nodes.

VXLAN Tunnels Not Working
--------------------------

* Verify underlay connectivity: ``ping <switch_vtep_ip>`` from DevStack
* If ping fails, the switch may not be responding to ARP for its VTEP
  loopback IP. Add a static ARP entry::

      # Get the switch underlay MAC from terraform output
      SWITCH_MAC=$(terraform output -raw switch_underlay_mac)
      ssh ubuntu@<devstack-ip> sudo ip neigh replace 10.0.99.120 \
          lladdr $SWITCH_MAC dev <underlay-if> nud permanent

* Verify VXLAN ports on brbm: ``sudo ovs-vsctl list-ports brbm | grep vxlan``
* Check NVE status on switch: ``show nve peers``, ``show nve vni``
* Check OVS VXLAN port config: ``sudo ovs-vsctl list interface vxlan_100``

VLAN Traffic Not Flowing Through the Switch
---------------------------------------------

* Verify VXLAN tunnels are up (see above)
* Check switch access port configuration: ``show interface status``
* Check VLAN-to-VNI mapping: ``show vlan``, ``show vxlan``
* Check OVS flows: ``sudo ovs-ofctl dump-flows brbm``

Switch Console Access
----------------------

If the hosting cloud has serial console proxy (nova-serialproxy)::

    openstack console url show --serial cisco-nexus9k

If only VNC is available::

    openstack console url show cisco-nexus9k

Default switch credentials: ``admin`` / ``system_s3cret!``

Bare Metal Node Won't Boot
---------------------------

* Check Ironic node state: ``openstack baremetal node show <uuid>``
* Check sushy-tools can control it:
  ``curl http://localhost:9132/redfish/v1/Systems/<nova-uuid>``
* Verify the correct Nova instance UUID is used as the Redfish system ID
* Check Ironic conductor logs: ``journalctl -u devstack@ir-cond``

Known Limitations and TODOs
===========================

* **NIC ordering on the Cisco 9k.** Nova does not guarantee that the
  order of port attachments maps to the order of PCI slots inside the
  VM. Some clouds use different PCI slot assignment strategies. If the
  Cisco 9k interfaces don't map correctly (mgmt0, Ethernet1/1, ...),
  you may need to check the instance's XML or use PCI passthrough hints.

* **VTEP ARP reachability.** The switch's VTEP IP (loopback0) must be
  ARP-reachable from DevStack over the underlay network. NX-OS should
  respond to ARP for loopback0's IP on Ethernet1/1, but if it doesn't,
  a static ARP entry is needed on DevStack (see Troubleshooting).

* **sushy-tools Nova driver maturity.** The Nova driver for sushy-tools
  must support virtual media operations (typically via Nova rebuild).
  Verify that the version of sushy-tools installed by DevStack includes
  the Nova driver and supports the operations Ironic needs.

* **sushy-tools sees all instances.** The Nova driver lists ALL Nova
  instances in the configured project as Redfish Systems -- including
  the DevStack VM and Cisco 9k VM. This is harmless (Ironic only manages
  enrolled nodes) but may be confusing during debugging.

* **bridge_mappings configuration.** The DevStack ``local.conf`` sets
  ``OVS_PHYSICAL_BRIDGE=brbm`` and ``PHYSICAL_NETWORK=mynetwork``. Verify
  that DevStack correctly generates ``bridge_mappings = mynetwork:brbm``
  in the ML2 OVS agent config. If not, add it manually post-stack.

* **Large image uploads.** The Cisco 9k QCOW2 is 1-2 GB. Some clouds
  limit Glance image upload size or require importing from a URL. If
  the Terraform ``local_file_path`` upload fails, upload the image
  manually via ``openstack image create`` with ``--file``.

* **Underlay interface detection.** The ``02-setup-devstack.sh`` script
  auto-detects the underlay interface as the "second NIC" by alphabetical
  name sort. Cloud-init may rename interfaces unpredictably. Set the
  ``UNDERLAY_INTERFACE`` environment variable explicitly if detection fails.

File Reference
==============

::

    contrib/devstack-ironic-neutron-ml2/
    +-- README.rst                  This guide
    +-- terraform/
    |   +-- main.tf                 Provider and data sources
    |   +-- variables.tf            Input variables
    |   +-- network.tf              Networks, subnets, ports, security groups
    |   +-- compute.tf              VM instances and Glance image
    |   +-- outputs.tf              Terraform outputs (IPs, UUIDs, MACs)
    |   +-- terraform.tfvars.example
    +-- scripts/
        +-- 01-configure-switch.sh  Configure Cisco 9k via SSH (features, NVE, ports)
        +-- 02-setup-devstack.sh    Full DevStack setup + VXLAN tunnel creation
        +-- 03-enroll-nodes.sh      Enroll bare metal VMs in Ironic
        +-- 04-verify.sh            Post-deployment verification
        +-- 05-maintenance.sh       Lifecycle management
