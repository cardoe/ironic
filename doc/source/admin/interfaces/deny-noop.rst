========================
Deny and noop interfaces
========================

Every hardware type has to provide an implementation for every interface
type, even for features a given node does not need, or that an operator does
not want ironic to use. Two generic families of interfaces exist for this
purpose. They are implemented for every interface type (``bios``, ``boot``,
``console``, ``deploy``, ``firmware``, ``inspect``, ``management``,
``network``, ``power``, ``raid``, ``rescue``, ``storage`` and ``vendor``).

``deny``
    Explicitly refuses the feature. Validation fails and every action raises
    ``UnsupportedDriverExtension``, except for caching BIOS settings and
    firmware components, which the conductor does on a best-effort basis and
    which therefore succeed without doing anything. Use it when something must
    *never* happen to a node.

``noop``
    Accepts the feature and does nothing. Validation passes, actions succeed
    without side effects and getters return empty or neutral values. Use it
    when the feature is irrelevant for a node, and ironic should carry on as
    if it had succeeded.

.. warning::
   A ``noop`` interface reports success without doing the work. For example,
   the ``noop`` inspect interface reports inspection as complete without
   collecting anything, ``noop`` rescue reports the node as rescued, and
   ``noop`` power reports whatever power state is already recorded for the
   node. Do not use ``noop`` as a stand-in for an interface you actually need.

Enabling and selecting
======================

The interfaces are available in the ``generic`` family of hardware types
(for example ``manual-management``) and in ``redfish``. As with any other
interface, add them to the relevant ``enabled_*_interfaces`` option in
``ironic.conf``, then select them per node:

.. code-block:: ini

   [DEFAULT]
   enabled_bios_interfaces = redfish,no-bios,deny
   enabled_raid_interfaces = redfish,no-raid,deny
   enabled_firmware_interfaces = redfish,no-firmware,deny

.. code-block:: console

   baremetal node set <node> --bios-interface deny

Entry point names
-----------------

The ``deny`` name is available for every interface type. The ``noop`` name
already existed for three interface types before these families were
introduced, and keeps its original meaning there:

====================  ==================================================
Interface type        ``noop`` refers to
====================  ==================================================
``bios``              new ``NoopBIOS``
``boot``              new ``NoopBoot``
``console``           new ``NoopConsole``
``deploy``            new ``NoopDeploy``
``firmware``          new ``NoopFirmware``
``inspect``           new ``NoopInspect``
``management``        existing ``NoopManagement`` (``noop_mgmt``)
``network``           existing ``NoopNetwork`` (``network.noop``)
``power``             new ``NoopPower``
``raid``              new ``NoopRAID``
``rescue``            new ``NoopRescue``
``storage``           existing ``NoopStorage`` (``storage.noop``)
``vendor``            new ``NoopVendor``
====================  ==================================================

The older ``no-bios``, ``no-console``, ``no-firmware``, ``no-inspect``,
``no-raid``, ``no-rescue`` and ``no-vendor`` names are kept for compatibility
and are the defaults of many hardware types. They are aliases of ``deny`` for
the same interface type, and the ``noop`` deploy interface is the same as the
new ``NoopDeploy``. Nodes that already use these names keep working.

.. note::
   Because an alias and its ``deny`` counterpart are the same implementation,
   do not enable both in the same ``enabled_*_interfaces`` option. Ironic
   maps implementations back to names when it picks a default interface, so
   with both enabled the default may be either name.

Example: protecting a node from changes
=======================================

Consider a node that must be deployed, but whose firmware, BIOS settings and
storage configuration must not be altered by ironic under any circumstances,
for example hardware managed by an external team, or a node being adopted from
another system.

Enable ``deny`` for the interfaces that could change the hardware, as shown
above, and select it on the node:

.. code-block:: console

   baremetal node create --driver redfish \
       --bios-interface deny \
       --raid-interface deny \
       --firmware-interface deny \
       --console-interface deny \
       --rescue-interface deny \
       --vendor-interface deny

Deploying the node keeps working, because deployment only validates and uses
the power, management, boot, deploy, network and storage interfaces. Any
attempt to apply BIOS settings, configure RAID, update firmware, start a
console, rescue the node, or call vendor passthru methods through these
interfaces is rejected with an error, regardless of who requests it.

``deny`` only guards the interface it is set on. It does not stop the deploy
interface from writing the instance image, nor the agent from running
cleaning steps such as erasing disks. To prevent those, disable automated
cleaning for the node and deny the ``deploy`` interface as described below.

.. note::
   ``baremetal node validate`` reports every ``deny`` interface as failing.
   This is expected: it is how the interface states that the feature is
   unavailable. Deploy and cleaning only validate the interfaces they use, so
   the failures do not block them.

Using ``deny`` on an interface that deployment *needs* (such as ``power`` or
``deploy``) makes the node impossible to provision. This is intentional, and
can be used to freeze a node completely. Teardown and cleanup methods of a
denied interface also raise, so a node with, for example, a denied ``storage``
or ``network`` interface cannot be torn down through ironic either.

Periodic tasks
==============

Interfaces that do nothing have nothing to poll. Both families set
``skip_periodics = True``, and the conductor therefore:

* does not register periodic tasks defined on these interfaces;
* skips nodes with a ``deny`` or ``noop`` power interface when synchronizing
  power states (:doc:`/admin/power-sync`) and recovering from power failures;
* skips nodes with a ``deny`` or ``noop`` management interface when
  collecting sensor data (:doc:`/admin/health-monitoring`).

The conductor still takes a shared lock on each node before it can tell which
interface it uses, but no calls are made to the node's hardware.

For driver authors
==================

Any interface can opt out of conductor polling by setting the class attribute
``skip_periodics`` to ``True`` (it defaults to ``False`` on
:py:class:`ironic.drivers.base.BaseInterface`). The conductor only honors the
exact value ``True``. The ``deny`` and ``noop`` modules,
``ironic.drivers.modules.deny`` and ``ironic.drivers.modules.noop``, are
also a good template for a minimal interface of each type, and for hardware
types that want to offer them:

.. code-block:: python

   from ironic.drivers.modules import deny
   from ironic.drivers.modules import noop

   class MyHardware(generic.GenericHardware):
       @property
       def supported_raid_interfaces(self):
           return super().supported_raid_interfaces + [
               deny.DenyRAID, noop.NoopRAID]

A new entry point name is also needed in ``pyproject.toml`` for each interface
class to be selectable by name.
