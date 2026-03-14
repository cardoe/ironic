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

.. contents:: Table of Contents
   :local:
   :depth: 3

Architecture
============

Two layers: the hosting cloud provides infrastructure; DevStack runs
inside it and manages "bare metal" that is actually VMs on the same cloud.

::

  Hosting OpenStack Cloud (Geneve tenant networks)
  ================================================

  Network: ironic-mgmt (Geneve, DHCP, router to external)
  -------------------------------------------------------
  172.24.5.10           172.24.5.20
  DevStack VM --------> Cisco 9k sim (mgmt0)
  (floating IP)         (SSH config, NGS access)


  Network: ironic-trunk (Geneve, no DHCP, port security off)
  ----------------------------------------------------------
  DevStack VM --------> Cisco 9k sim (Ethernet1/1 trunk)
  (OVS brbm)           (carries all VLANs)


  Network: ironic-bm-0 (Geneve, no DHCP, port security off)
  ----------------------------------------------------------
  BM Node 0 ----------> Cisco 9k sim (Ethernet1/2 access)

  Network: ironic-bm-1 (Geneve, no DHCP, port security off)
  ----------------------------------------------------------
  BM Node 1 ----------> Cisco 9k sim (Ethernet1/3 access)

  Network: ironic-bm-2 (Geneve, no DHCP, port security off)
  ----------------------------------------------------------
  BM Node 2 ----------> Cisco 9k sim (Ethernet1/4 access)


  Data Flow (during Ironic provisioning)
  =======================================

  1. Ironic tells sushy-tools to boot BM Node 0 via virtual media
  2. sushy-tools calls hosting cloud Nova API to rebuild instance
  3. NGS configures Cisco 9k: Ethernet1/2 -> provisioning VLAN
  4. IPA traffic: BM Node 0 -> ironic-bm-0 -> Cisco 9k Ethernet1/2
     -> trunk (VLAN tagged) -> ironic-trunk -> DevStack OVS brbm
     -> Neutron DHCP / Ironic conductor
  5. IPA phones home, Ironic deploys the OS
  6. NGS switches Ethernet1/2 to tenant VLAN

Key design decisions:

* **Geneve networks** provide L2 connectivity between VMs. Each
  "cable" between a bare metal node and a switch port is a separate
  Geneve network. This gives clean isolation without trunk port
  support on the hosting cloud.

* **Port security is disabled** on trunk and bare metal networks so
  VLAN-tagged frames and arbitrary DHCP can flow through.

* **DHCP is disabled** on bare metal networks so the hosting cloud's
  Neutron doesn't interfere. All bare metal DHCP comes from DevStack's
  Neutron via the switch.

* **The Cisco 9k runs as a Nova instance** with one NIC per network.
  NIC ordering matters: NIC 0 = mgmt0, NIC 1 = Ethernet1/1 (trunk),
  NIC 2+ = Ethernet1/2+ (access ports).

* **Bare metal VMs are pre-created** by Terraform, then managed by
  sushy-tools via the hosting cloud's Nova API. Ironic enrolls them
  using their Nova instance UUIDs as Redfish system IDs.

Prerequisites
=============

Hosting Cloud Requirements
--------------------------

* Geneve (or VXLAN) tenant networks with the ability to create many
* **Port security flexibility** -- one of the following (see
  `Port Security Strategies`_ below):

  * **Best:** ability to disable port security on networks/ports, OR
  * **Fallback:** ability to set ``allowed_address_pairs`` with
    ``ip_address=0.0.0.0/0`` on ports (most clouds allow this)
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

    # Test 1: Can port security be disabled at the network level?
    openstack network create --disable-port-security test-portsec
    openstack network delete test-portsec
    # If this works: use default settings (use_allowed_address_pairs = false)

    # Test 2: If Test 1 fails, can allowed_address_pairs be set?
    openstack network create test-aap
    openstack port create --network test-aap \
        --allowed-address ip-address=0.0.0.0/0 test-aap-port
    openstack port delete test-aap-port
    openstack network delete test-aap
    # If this works: set use_allowed_address_pairs = true in terraform.tfvars

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

.. _Port Security Strategies:

Port Security Strategies
~~~~~~~~~~~~~~~~~~~~~~~~~~

There are two separate port security concerns:

1. **Per-node bare metal links** (untagged traffic): Bare metal VMs get
   IPs from DevStack's Neutron, not the hosting cloud. The hosting cloud's
   anti-spoofing rules would drop frames with these "unexpected" source IPs.

2. **Trunk link** (VLAN-tagged traffic): The trunk between the Cisco 9k and
   DevStack carries 802.1Q-tagged frames. Port security drops these
   regardless of IP/MAC whitelisting.

**Strategy A -- Disable port security (default):**

Set ``use_allowed_address_pairs = false`` (default). Both networks and
ports are created with ``port_security_enabled = false``. This is the
simplest approach but requires the hosting cloud to allow it.

**Strategy B -- allowed_address_pairs fallback:**

Set ``use_allowed_address_pairs = true``. Per-node bare metal networks
keep port security ON, but ports get ``allowed_address_pairs`` with
``ip_address=0.0.0.0/0``, which permits any source IP from the port's
MAC address. Most clouds allow this even when they block disabling port
security entirely. This works for per-node links because the traffic is
**untagged** (switch access ports strip VLAN tags).

The trunk network still uses ``port_security_enabled = false`` because
VLAN-tagged frames cannot be whitelisted via ``allowed_address_pairs``.
If your cloud also blocks disabling port security on the trunk network,
run the Cisco 9k locally on the DevStack host -- the trunk becomes a
local OVS bridge and never touches the hosting cloud's network.

**Strategy C -- Full VXLAN overlay (last resort):**

If the cloud blocks both port security disable AND ``allowed_address_pairs``,
build a VXLAN overlay. All VMs go on a single standard network. VXLAN
tunnels (UDP port 4789) carry bare metal L2 traffic inside regular IP
packets that pass port security. The Cisco 9k must run locally. See
the `Known Limitations and TODOs`_ section for details.

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
* 1 trunk network (``ironic-trunk``, port security off)
* N bare metal networks (``ironic-bm-{0..N}``, port security off)
* DevStack VM (Ubuntu 24.04)
* Cisco Nexus 9000v VM (uploaded to Glance with UEFI properties)
* N bare metal VMs
* All ports with correct security and addressing

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
    #   feature lldp
    #   exit
    #   copy run start

**SSH-based configuration** (automated):

::

    # From a machine that can reach 172.24.5.20 (e.g., the DevStack VM)
    bash scripts/01-configure-switch.sh 172.24.5.20 "system_s3cret!" 3

Step 4: Set Up DevStack
------------------------

SSH to the DevStack VM and run the setup script::

    ssh ubuntu@$(terraform output -raw devstack_floating_ip)

    # Set hosting cloud credentials for sushy-tools Nova driver
    export HOSTING_CLOUD_AUTH_URL="https://your-cloud:5000/v3"
    export HOSTING_CLOUD_PROJECT="your-project"
    export HOSTING_CLOUD_USERNAME="your-user"
    export HOSTING_CLOUD_PASSWORD="your-password"

    bash scripts/02-setup-devstack.sh

This script:

1. Creates the ``stack`` user and clones DevStack
2. Writes hosting cloud credentials to ``clouds.yaml`` (for sushy-tools)
3. Generates ``local.conf`` with:

   - Ironic in hardware mode (``IRONIC_IS_HARDWARE=True``) -- no local VMs
   - Redfish driver (will be reconfigured for Nova driver post-stack)
   - Neutron ML2 with networking-generic-switch
   - VLAN tenant networking (range 100:150)

4. Runs ``stack.sh``
5. Post-stack: reconfigures sushy-tools for the Nova driver, configures
   NGS with the Cisco 9k switch details, bridges the trunk interface
   to OVS ``brbm``

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

    # Re-bridge trunk interface after a VM reboot
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

VLAN Traffic Not Flowing Through the Switch
---------------------------------------------

* Verify trunk interface is bridged: ``sudo ovs-vsctl list-ports brbm``
* Check switch trunk port: ``ssh admin@172.24.5.20 "show int trunk"``
* Verify port security settings on hosting cloud networks/ports:
  ``openstack port show <port-id> -c port_security_enabled -c allowed_address_pairs``
* If using ``allowed_address_pairs``, verify they're set:
  ``openstack port show <bm-port-id> -c allowed_address_pairs``
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

* **Trunk interface detection.** The ``02-setup-devstack.sh`` script
  auto-detects the trunk interface as the "second NIC" by alphabetical
  name sort. Cloud-init may rename interfaces unpredictably. Set the
  ``TRUNK_INTERFACE`` environment variable explicitly if detection fails.

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

* **VXLAN overlay (Strategy C) is not yet automated.** If your cloud
  blocks both ``port_security_enabled=false`` and ``allowed_address_pairs``,
  you would need a VXLAN overlay where all VMs sit on a single standard
  network and VXLAN tunnels carry the bare metal L2 traffic inside
  regular UDP packets. This requires:

  * Running the Cisco 9k locally on the DevStack host
  * Creating VXLAN tunnel endpoints on the DevStack host (one VNI per
    bare metal node, bridged to the Cisco 9k's tap interfaces)
  * Setting up matching VXLAN endpoints inside each bare metal VM
  * The chicken-and-egg problem: when sushy-tools rebuilds a bare metal
    VM (for virtual media boot), the VXLAN config inside it is wiped.
    A custom IPA ramdisk with VXLAN setup logic would be needed.

  This approach works but is not yet implemented in the scripts.

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
        +-- 01-configure-switch.sh  Configure Cisco 9k via SSH
        +-- 02-setup-devstack.sh    Full DevStack setup on the VM
        +-- 03-enroll-nodes.sh      Enroll bare metal VMs in Ironic
        +-- 04-verify.sh            Post-deployment verification
        +-- 05-maintenance.sh       Lifecycle management
