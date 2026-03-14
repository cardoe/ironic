=====================================================================
DevStack: Ironic + Neutron ML2 with sushy-tools Nova Driver and
Cisco Nexus 9000v on a Hosting OpenStack Cloud
=====================================================================

This guide sets up a development environment for working on Ironic and
Neutron ML2 drivers. The key design: a **hosting OpenStack cloud** provides
compute and networking, while **DevStack** runs inside a VM on that cloud.
sushy-tools uses the **Nova driver** to manage sibling VMs (on the same
hosting cloud) as virtual bare metal nodes. A **Cisco Nexus 9000v** switch
simulator runs locally inside the DevStack VM (nested virtualization),
providing realistic VLAN switching for ML2 driver testing.

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
  172.24.5.10
  DevStack VM -------- BM Node 0 ---- BM Node 1 ---- BM Node 2
  (floating IP)        (sushy-tools reaches via hosting cloud Nova API)


  Network: ironic-bm-0 (no DHCP, allowed_address_pairs)
  ------------------------------------------------------
  DevStack VM (ethN) <------> BM Node 0 (eth0)

  Network: ironic-bm-1 (no DHCP, allowed_address_pairs)
  ------------------------------------------------------
  DevStack VM (ethN) <------> BM Node 1 (eth0)

  Network: ironic-bm-2 (no DHCP, allowed_address_pairs)
  ------------------------------------------------------
  DevStack VM (ethN) <------> BM Node 2 (eth0)


  Inside DevStack VM (nested virtualization)
  ==========================================

                            +-------------------------+
                            |  Cisco 9k (local QEMU)  |
                            |                         |
  OVS brbm <-- tap-trunk -> | Ethernet1/1 (trunk)     |
                            |                         |
  br-bm-0 <--- tap -------> | Ethernet1/2 (access) ---+--> ethN (ironic-bm-0)
  br-bm-1 <--- tap -------> | Ethernet1/3 (access) ---+--> ethM (ironic-bm-1)
  br-bm-2 <--- tap -------> | Ethernet1/4 (access) ---+--> ethP (ironic-bm-2)
                            |                         |
  br-sw-mgmt <-- tap -----> | mgmt0 (192.168.100.20)  |
                            +-------------------------+


  Data Flow (during Ironic provisioning)
  =======================================

  1. Ironic tells sushy-tools to boot BM Node 0 via virtual media
  2. sushy-tools calls hosting cloud Nova API to rebuild instance
  3. NGS configures Cisco 9k: Ethernet1/2 -> provisioning VLAN
  4. IPA traffic: BM Node 0 eth0 -> ironic-bm-0 network
     -> DevStack ethN -> br-bm-0 -> 9k Ethernet1/2
     -> trunk (VLAN tagged) -> tap-sw-trunk -> OVS brbm
     -> Neutron DHCP / Ironic conductor
  5. IPA phones home, Ironic deploys the OS
  6. NGS switches Ethernet1/2 to tenant VLAN

Key design decisions:

* **Per-node networks** on the hosting cloud provide L2 connectivity
  between each bare metal VM and the DevStack VM. Each "cable" between
  a bare metal node and a switch port is a separate hosting cloud network.

* **``allowed_address_pairs``** with ``0.0.0.0/0`` on all per-node
  ports. Bare metal VMs get IPs from DevStack's Neutron, not the hosting
  cloud. The ``allowed_address_pairs`` permits these IPs through.
  Traffic is untagged (switch access ports), so this is sufficient.

* **Cisco 9k runs locally** inside the DevStack VM via nested KVM/QEMU.
  The trunk between the switch and OVS brbm is a local tap device. This
  avoids needing ``port_security_enabled=false`` on the hosting cloud
  (VLAN-tagged trunk frames cannot pass with just ``allowed_address_pairs``).

* **DHCP is disabled** on bare metal networks so the hosting cloud's
  Neutron doesn't interfere. All bare metal DHCP comes from DevStack's
  Neutron via the switch.

* **Bare metal VMs are pre-created** by Terraform, then managed by
  sushy-tools via the hosting cloud's Nova API. Ironic enrolls them
  using their Nova instance UUIDs as Redfish system IDs.

Prerequisites
=============

Hosting Cloud Requirements
--------------------------

* Tenant networks with the ability to create many
* ``allowed_address_pairs`` with ``ip_address=0.0.0.0/0`` on ports
* **Nested virtualization** support (the DevStack VM runs a QEMU VM
  inside it for the Cisco 9k). Alternatively the 9k can run under TCG
  (software emulation) but this is very slow.
* Sufficient quota: ~4 instances (1 DevStack + 3 BM), ~4 networks, ~10 ports,
  1 floating IP
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

    # Check nested virt: launch a test instance and check for /dev/kvm
    # (If not available, the 9k will run under TCG -- slow but functional)

    # Check quotas
    openstack quota show

Flavor Sizing
-------------

============== ====== ====== ======
VM             vCPUs  RAM    Disk
============== ====== ====== ======
DevStack       8+     32 GB  100 GB
Bare metal (x3) 1-2   2-4 GB 10 GB
============== ====== ====== ======

The DevStack flavor needs extra headroom (2 vCPU, 8 GB RAM) for the
nested Cisco 9k VM.

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
* N bare metal networks (``ironic-bm-{0..N}``, ``allowed_address_pairs``)
* DevStack VM (Ubuntu 24.04) with 1 mgmt NIC + N BM NICs
* N bare metal VMs (one NIC each on their per-node network)
* All ports with ``allowed_address_pairs`` for BM traffic

Step 3: Copy the Cisco 9k Image
---------------------------------

::

    scp /path/to/nexus9300v.qcow2 \
        ubuntu@$(terraform output -raw devstack_floating_ip):/tmp/nexus9300v.qcow2

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
3. Creates local bridges: ``br-sw-mgmt`` (switch management),
   ``br-bm-{N}`` (per-node, bridging hosting cloud NIC to 9k tap)
4. Launches the Cisco 9k as a local QEMU VM with correct NIC ordering:
   mgmt0, trunk (tap to brbm), access ports (taps to per-node bridges)
5. Generates ``local.conf`` with:

   - Ironic in hardware mode (``IRONIC_IS_HARDWARE=True``) -- no local VMs
   - Redfish driver (reconfigured for Nova driver post-stack)
   - Neutron ML2 with networking-generic-switch
   - VLAN tenant networking (range 100:150)

6. Runs ``stack.sh``
7. Post-stack: bridges trunk tap to OVS brbm, reconfigures sushy-tools
   for the Nova driver, configures NGS with the local switch IP

Step 5: Configure the Cisco 9k Switch
---------------------------------------

The switch needs initial console-based setup (POAP skip, admin password,
SSH enable) before SSH-based configuration can proceed.

**Initial console setup** (one-time, manual)::

    # On the DevStack VM
    telnet 127.0.0.1 4000

    # Wait ~5-10 minutes for "Abort Power On Auto Provisioning"
    # Then run these commands:
    #   skip
    #   (wait for login prompt)
    #   admin
    #   (blank password)
    #   configure
    #   username admin password system_s3cret! role network-admin
    #   int mgmt0
    #   ip address 192.168.100.20/24
    #   exit
    #   feature ssh
    #   feature lldp
    #   exit
    #   copy run start

**SSH-based configuration** (automated)::

    # On the DevStack VM
    bash scripts/01-configure-switch.sh 192.168.100.20 "system_s3cret!" 3

Step 6: Enroll Bare Metal Nodes
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

Step 7: Verify
---------------

::

    bash scripts/04-verify.sh

Step 8: Test a Deployment
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

    # Re-bridge interfaces after a VM reboot
    bash scripts/05-maintenance.sh reconnect

    # Undeploy all instances and reset nodes
    bash scripts/05-maintenance.sh redeploy

    # Tail logs
    bash scripts/05-maintenance.sh logs

Tear Down
---------

::

    # On the DevStack VM (stop the local 9k)
    sudo kill $(cat /tmp/cisco9k.pid) 2>/dev/null || true
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
   cloud/project as Redfish Systems. The DevStack VM will also appear.
   This is harmless -- Ironic only manages explicitly enrolled nodes.

VLAN Traffic Not Flowing Through the Switch
---------------------------------------------

* Verify trunk tap is bridged: ``sudo ovs-vsctl list-ports brbm``
  (should include ``tap-sw-trunk``)
* Verify per-node bridges: ``bridge link show``
  (each ``br-bm-N`` should have the hosting cloud NIC and a 9k tap)
* Check switch trunk port: ``ssh admin@192.168.100.20 "show int trunk"``
* Check OVS flows: ``sudo ovs-ofctl dump-flows brbm``

Cisco 9k Serial Console
-------------------------

::

    telnet 127.0.0.1 4000

Default switch credentials: ``admin`` / ``system_s3cret!``

Bare Metal Node Won't Boot
---------------------------

* Check Ironic node state: ``openstack baremetal node show <uuid>``
* Check sushy-tools can control it:
  ``curl http://localhost:9132/redfish/v1/Systems/<nova-uuid>``
* Verify the correct Nova instance UUID is used as the Redfish system ID
* Check Ironic conductor logs: ``journalctl -u devstack@ir-cond``

Nested Virtualization Not Available
-------------------------------------

If ``/dev/kvm`` is not present inside the DevStack VM, the Cisco 9k
will run under QEMU TCG (software emulation). This works but is
significantly slower (~10x boot time). Check with your hosting cloud
whether nested virtualization can be enabled for the DevStack flavor.

Known Limitations and TODOs
===========================

* **sushy-tools Nova driver maturity.** The Nova driver for sushy-tools
  must support virtual media operations (typically via Nova rebuild).
  Verify that the version of sushy-tools installed by DevStack includes
  the Nova driver and supports the operations Ironic needs.

* **sushy-tools sees all instances.** The Nova driver lists ALL Nova
  instances in the configured project as Redfish Systems -- including
  the DevStack VM itself. This is harmless (Ironic only manages enrolled
  nodes) but may be confusing during debugging.

* **bridge_mappings configuration.** The DevStack ``local.conf`` sets
  ``OVS_PHYSICAL_BRIDGE=brbm`` and ``PHYSICAL_NETWORK=mynetwork``. Verify
  that DevStack correctly generates ``bridge_mappings = mynetwork:brbm``
  in the ML2 OVS agent config. If not, add it manually post-stack.

* **BM interface detection.** The ``02-setup-devstack.sh`` script
  auto-detects BM network interfaces as all NICs after the first one
  (sorted alphabetically). Cloud-init may rename interfaces
  unpredictably. If detection fails, set up bridges manually.

* **Cisco 9k NIC ordering.** Inside the local QEMU VM, NX-OS maps
  virtio NICs in order: NIC 0 = mgmt0, NIC 1 = Ethernet1/1 (trunk),
  NIC 2+ = Ethernet1/2+ (access ports). The QEMU command builds
  NICs in this order. If interfaces don't map correctly, check the
  QEMU command arguments.

File Reference
==============

::

    contrib/devstack-ironic-neutron-ml2/
    +-- README.rst                  This guide
    +-- terraform/
    |   +-- main.tf                 Provider and data sources
    |   +-- variables.tf            Input variables
    |   +-- network.tf              Networks, subnets, ports, security groups
    |   +-- compute.tf              VM instances (DevStack + bare metal)
    |   +-- outputs.tf              Terraform outputs (IPs, UUIDs, MACs)
    |   +-- terraform.tfvars.example
    +-- scripts/
        +-- 01-configure-switch.sh  Configure Cisco 9k via SSH (local)
        +-- 02-setup-devstack.sh    Full DevStack setup + local 9k launch
        +-- 03-enroll-nodes.sh      Enroll bare metal VMs in Ironic
        +-- 04-verify.sh            Post-deployment verification
        +-- 05-maintenance.sh       Lifecycle management
