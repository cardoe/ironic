=====================================================================
DevStack: Ironic + Neutron ML2 with sushy-tools and Cisco Nexus 9k
=====================================================================

This guide walks through setting up a development environment for working on
Ironic and Neutron ML2 drivers. The environment uses:

* **DevStack** deployed on a real OpenStack cloud instance (or bare-metal host)
* **sushy-tools** as the Redfish BMC emulator for virtual bare metal nodes
* **Nova with Ironic virt driver** to manage bare metal (virtual) nodes
* **Cisco Nexus 9000v switch simulator** attached to virtual bare metal node
  ports for testing Neutron ML2 driver integration via networking-generic-switch

.. contents:: Table of Contents
   :local:
   :depth: 3

Architecture Overview
=====================

::

  +-----------------------------------------------------------------+
  |  Host (OpenStack VM or Bare Metal)                              |
  |                                                                 |
  |  +-----------------------------------------------------------+  |
  |  | DevStack                                                  |  |
  |  |                                                           |  |
  |  |  +----------+  +----------+  +---------+  +----------+   |  |
  |  |  | Keystone |  | Glance   |  | Neutron |  | Nova     |   |  |
  |  |  +----------+  +----------+  +---------+  +----------+   |  |
  |  |                                  |            |           |  |
  |  |                           +------+------+     |           |  |
  |  |                           |  ML2 Plugin |     |           |  |
  |  |                           | (NGS+OVS)   |     |           |  |
  |  |                           +------+------+     |           |  |
  |  |                                  |            |           |  |
  |  |  +----------+  +-------------+   |      +----+-------+   |  |
  |  |  | Ironic   |  | sushy-tools |   |      | Ironic     |   |  |
  |  |  | API      |  | (Redfish    |   |      | Conductor  |   |  |
  |  |  |          |  |  Emulator)  |   |      |            |   |  |
  |  |  +----------+  +------+------+   |      +----+-------+   |  |
  |  |                       |          |           |            |  |
  |  +-----------------------------------------------------------+  |
  |                          |          |           |               |
  |  +-----------------------+----------+-----------+------------+  |
  |  | libvirt / QEMU                                            |  |
  |  |                                                           |  |
  |  |  +-----------+  +-----------+  +-----------+              |  |
  |  |  | BM Node 0 |  | BM Node 1 |  | BM Node 2 |             |  |
  |  |  | (VM)      |  | (VM)      |  | (VM)      |             |  |
  |  |  +-----+-----+  +-----+-----+  +-----+-----+             |  |
  |  |        |              |              |                     |  |
  |  +--------+--------------+--------------+--------------------+  |
  |           |              |              |                       |
  |  +--------+--------------+--------------+--------------------+  |
  |  | Virtual Network Bridges (Linux bridges)                   |  |
  |  |   sim-node-0-p0  sim-node-1-p0  sim-node-2-p0             |  |
  |  |       |               |               |                   |  |
  |  |   sw-node-0-p0   sw-node-1-p0   sw-node-2-p0              |  |
  |  +--------+--------------+--------------+--------------------+  |
  |           |              |              |                       |
  |  +--------+--------------+--------------+--------------------+  |
  |  | Cisco Nexus 9000v Simulator (QEMU VM)                     |  |
  |  |   Ethernet1/2    Ethernet1/3    Ethernet1/4                |  |
  |  |                                                           |  |
  |  |   Ethernet1/1 (trunk) --> OVS br-int                      |  |
  |  |   mgmt0               --> br-infra (172.24.5.20)          |  |
  |  +-----------------------------------------------------------+  |
  +-----------------------------------------------------------------+

Prerequisites
=============

Hardware Requirements
---------------------

The host machine (physical or cloud VM) needs:

* **CPU**: 8+ vCPUs (nested virtualization required if running in a VM)
* **RAM**: 32 GB minimum (recommended 48+ GB)

  - DevStack services: ~4 GB
  - Cisco Nexus 9000v simulator: 8 GB
  - Each bare metal VM node: 2.5-4 GB (x3 = 7.5-12 GB)
  - IPA ramdisk and OS overhead: ~4 GB

* **Disk**: 100 GB+ free space
* **Network**: At least one NIC with internet access

Software Requirements
---------------------

* **OS**: Ubuntu 24.04 LTS (Noble) -- strongly recommended
* **Nested virtualization**: Must be enabled if running inside a VM

  Check with::

    cat /sys/module/kvm_intel/parameters/nested  # Intel
    cat /sys/module/kvm_amd/parameters/nested    # AMD

  The output should be ``Y`` or ``1``.

* **Git**: For cloning repositories
* **Python 3.10+**: Required by Ironic

Cisco Nexus 9000v Simulator Image
----------------------------------

You must obtain the Cisco Nexus 9000v (NX-OSv 9000) QCOW2 disk image. This is
available from Cisco's software download portal and requires a Cisco account
(and potentially a service contract) to access.

1. Go to https://software.cisco.com
2. Search for "Nexus 9000v" or "NX-OSv 9000"
3. Download the QCOW2 image (e.g., ``nexus9300v64.10.3.7.M.qcow2``)
4. Place the image at ``/opt/stack/nexus9300v64.10.3.7.M.qcow2``

.. note::
   The image filename may vary by version. If you use a different version,
   update the ``CISCO_NEXUS_IMAGE`` variable in the scripts accordingly.
   The devstack plugin currently expects the above filename by default.

Setup Steps
===========

Step 1: Prepare the Host
------------------------

Run the prerequisite check script to verify and install system dependencies::

    cd contrib/devstack-ironic-neutron-ml2
    sudo bash 01-prereqs.sh

This script:

* Verifies nested virtualization support
* Installs required system packages (libvirt, qemu, openvswitch, etc.)
* Creates the ``stack`` user if it does not exist
* Enables and starts required services
* Verifies the Cisco Nexus 9000v image is in place

Step 2: Generate local.conf
----------------------------

Switch to the stack user and generate the DevStack configuration::

    sudo su - stack
    cd /opt/stack
    git clone https://opendev.org/openstack/devstack.git
    # Copy the scripts to /opt/stack for convenience
    cp -r <path-to-ironic>/contrib/devstack-ironic-neutron-ml2/*.sh .

    bash 02-generate-local-conf.sh

This generates ``devstack/local.conf`` configured for:

* Ironic with Redfish (sushy-tools) as the deploy driver
* Neutron with ML2 plugin and networking-generic-switch
* Cisco Nexus 9000v as the network simulator
* VLAN-based tenant networking
* 3 virtual bare metal nodes
* Swift for the direct deploy interface

You can customize the generated configuration by setting environment variables
before running the script. See the script header for available options.

Step 3: Run DevStack
--------------------

::

    cd /opt/stack/devstack
    ./stack.sh

This will take 20-40 minutes depending on your hardware and network speed.
The Cisco Nexus 9000v simulator boot adds an additional 5-10 minutes on top
of the normal DevStack deployment time.

.. warning::
   The Cisco Nexus 9000v simulator is **slow** to boot (400-500 seconds for
   initial startup). This is expected. DevStack will wait for it.

Step 4: Verify the Deployment
------------------------------

After ``stack.sh`` completes, run the verification script::

    bash 03-verify.sh

This checks:

* All DevStack services are running
* Ironic nodes are enrolled and available
* The Cisco Nexus 9000v switch is reachable via SSH
* Neutron ML2 networking-generic-switch configuration is correct
* sushy-tools Redfish emulator is responding

Step 5: Test a Deployment
--------------------------

Source credentials and deploy a test instance::

    export OS_CLOUD=devstack-admin-demo

    # Get network and image
    net_id=$(openstack network list | awk '/private/ {print $2}')
    image=$(openstack image list | grep -- '-disk' | awk '{ print $2 }')

    # Create keypair
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa 2>/dev/null || true
    openstack keypair create --public-key ~/.ssh/id_rsa.pub default 2>/dev/null || true

    # Boot instance
    openstack server create --flavor baremetal --nic net-id=$net_id \
        --image $image --key-name default testing

    # Watch progress
    watch openstack server list --long

Maintenance
===========

Restarting DevStack Services
----------------------------

If you need to restart services after a reboot or crash::

    bash 04-maintenance.sh restart

Tearing Down
-------------

To completely tear down the DevStack environment::

    cd /opt/stack/devstack
    ./unstack.sh

To also clean up all created resources::

    cd /opt/stack/devstack
    ./clean.sh
    bash 04-maintenance.sh cleanup

Re-stacking
------------

After ``unstack.sh`` or ``clean.sh``, you can re-run ``./stack.sh`` to
rebuild the environment. The Cisco Nexus 9000v image will be re-copied from
the original, ensuring a clean switch state.

Using a Different Ironic Branch
-------------------------------

To test changes from a Gerrit review or a different branch, modify the
``enable_plugin`` line in ``local.conf``::

    # For a Gerrit review:
    enable_plugin ironic https://opendev.org/openstack/ironic refs/changes/XX/XXXXXX/Y

    # For a specific branch:
    enable_plugin ironic https://opendev.org/openstack/ironic stable/2024.2

If you're developing locally, you can point the plugin at your local checkout::

    enable_plugin ironic /path/to/your/ironic

Troubleshooting
===============

Nested Virtualization Not Available
------------------------------------

If running in a cloud VM, ensure your cloud provider supports nested
virtualization and that it's enabled for your instance. On OpenStack, you may
need a flavor with the ``hw:cpu_policy=dedicated`` property and the host must
have nested virt enabled.

Alternatively, you can set ``IRONIC_VM_ENGINE=qemu`` in ``local.conf`` to use
full software emulation, but this will be significantly slower.

Cisco Nexus 9000v Fails to Boot
---------------------------------

* Ensure ``/opt/stack/nexus9300v64.10.3.7.M.qcow2`` exists and is a valid
  QCOW2 image
* Ensure KVM is available (``ls /dev/kvm``)
* Check the simulator console: ``telnet localhost 55001``
* Review the service log: ``journalctl -u devstack@ir-sw-sim``

Switch Not Reachable via SSH
-----------------------------

* The switch takes 400-500 seconds to fully boot
* Verify the management interface: ``ping 172.24.5.20``
* Try connecting via the serial console: ``telnet localhost 55001``
* Default credentials: ``admin`` / ``system_s3cret!``

sushy-tools Not Responding
---------------------------

* Check the service: ``systemctl status devstack@redfish-emulator``
* Verify it's listening: ``curl http://localhost:9132/redfish/v1/``
* Check logs: ``journalctl -u devstack@redfish-emulator``

Node Stuck in "wait call-back"
-------------------------------

* Check IPA ramdisk logs in ``$IRONIC_VM_LOG_DIR``
* Ensure the provisioning network has DHCP: ``openstack subnet list``
* Check Ironic conductor logs: ``journalctl -u devstack@ir-cond``
* Verify the node's BMC is accessible::

    curl http://localhost:9132/redfish/v1/Systems/

ML2 Plugin Not Configuring Switch Ports
----------------------------------------

* Check Neutron server logs: ``journalctl -u devstack@neutron-api``
* Verify NGS configuration::

    grep -A5 'genericswitch' /etc/neutron/plugins/ml2/ml2_conf.ini

* Ensure the switch is reachable from the Neutron server host
* Check that the port's ``local_link_connection`` info matches the switch config

Key Configuration Files
========================

After deployment, these are the important configuration files:

* ``/etc/ironic/ironic.conf`` -- Ironic configuration
* ``/etc/neutron/plugins/ml2/ml2_conf.ini`` -- Neutron ML2 plugin config
* ``/etc/neutron/plugins/ml2/ml2_conf_genericswitch.ini`` -- NGS switch config
  (if separate)
* ``$IRONIC_CONF_DIR/redfish/emulator.conf`` -- sushy-tools configuration
* ``/etc/openstack/clouds.yaml`` -- OpenStack client credentials

Useful Commands
================

::

    # Ironic node management
    export OS_CLOUD=devstack-system-admin
    openstack baremetal node list
    openstack baremetal node show <node-uuid>
    openstack baremetal port list --node <node-uuid>

    # Check sushy-tools
    curl http://localhost:9132/redfish/v1/Systems/

    # Connect to Cisco switch console
    telnet localhost 55001

    # SSH to Cisco switch (after boot)
    ssh admin@172.24.5.20

    # Check libvirt VMs
    sudo virsh list --all

    # Neutron network inspection
    export OS_CLOUD=devstack-admin
    openstack network list
    openstack port list
    openstack port show <port-id> -c binding_profile

Scripts Reference
==================

``01-prereqs.sh``
    Checks and installs system prerequisites. Run with sudo on a fresh host.

``02-generate-local-conf.sh``
    Generates a ``devstack/local.conf`` tailored for the Ironic + Neutron ML2
    + Cisco Nexus 9000v setup. Customizable via environment variables.

``03-verify.sh``
    Post-deployment verification. Checks all services, connectivity, and
    configuration.

``04-maintenance.sh``
    Lifecycle management: restart services, cleanup resources, check status.
