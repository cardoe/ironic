.. meta::
   :description: Common deployment scenarios for OpenStack Ironic bare metal service, including standalone, OpenStack-integrated, and full cloud configurations.
   :keywords: ironic deployment, standalone ironic, ironic with nova, bare metal deployment patterns, bifrost, metal3
   :author: OpenStack Ironic Team
   :robots: index, follow
   :audience: cloud operators, system administrators, architects

====================
Deployment Scenarios
====================

Ironic can be deployed in several different ways depending on what you need
from it. The scenarios below cover the most common patterns, though they are
not exhaustive — your environment may not map cleanly to any one of them, and
that is fine. Think of these as starting points, not a checklist.

Scenarios at a Glance
=====================

.. list-table::
   :header-rows: 1

   * - Scenario
     - Scale
     - Multi-tenancy
     - User-facing API
   * - :ref:`deploy-scenarios-standalone`
     - 1 to ~100 nodes
     - No
     - Ironic API directly
   * - :ref:`deploy-scenarios-openstack-no-nova`
     - Small to large
     - Yes (owner/lessee)
     - Ironic API
   * - :ref:`deploy-scenarios-full-openstack`
     - 1 node to multiple datacenters
     - Yes (native)
     - Nova Compute API

.. _deploy-scenarios-standalone:

Standalone
==========

This is Ironic without any other OpenStack services. You manage and provision
hardware through the Ironic API directly — no Keystone, no Neutron, no Glance.
This makes sense when you need to provision machines without building out an
OpenStack cloud, or when you are writing automation that drives Ironic
directly.

The hard constraint is that there is **no multi-tenancy**. One set of
credentials controls everything. Authentication is handled either by disabling
it entirely (``noauth``) or using HTTP Basic auth — see
:doc:`/install/standalone/configure` for both. For networking, a flat network
is sufficient to get started. If you want switch-level automation without
Neutron, the :doc:`ironic-networking service </install/standalone/networking>`
handles that without pulling in the rest of OpenStack.

Two projects build on top of Ironic in this mode and are worth knowing about:

* :bifrost-doc:`Bifrost <>` — Ansible playbooks that automate deployment
  onto a set of known hardware. If you are already comfortable with Ansible,
  this is the fastest path to a working standalone setup.

* `Metal3`_ — A Kubernetes operator that manages bare metal nodes using
  Ironic. The right choice if your workloads run on Kubernetes and you want
  bare metal nodes to participate in that model.

Both are single-tenant by nature. When you find yourself wanting to give
different teams different levels of access — or wanting to integrate with a
broader platform — that is the signal to move to the next scenario.

.. _Metal3: http://metal3.io/

.. _deploy-scenarios-openstack-no-nova:

OpenStack without Nova
======================

This is Ironic integrated with :keystone-doc:`Keystone <>`,
:glance-doc:`Glance <>`, and :neutron-doc:`Neutron <>`, but without Nova.
Users still provision nodes directly through the Ironic API, but now with
real credentials tied to Keystone projects. That opens up multi-tenancy and
gives you the full OpenStack access control model.

Multi-tenancy works through the owner and lessee model on nodes. A node can
be assigned to a project as an owner (full administrative control over that
node) or as a lessee (temporary, limited access). A system administrator sets
the owner field; the owner operates from there. See
:doc:`/admin/node-multitenancy` for how to configure this, and
:doc:`/admin/secure-rbac` for the full RBAC model.

Glance stores the images you deploy onto nodes. Neutron handles IPAM and,
with the right ML2 plugin — `networking-generic-switch`_ is a common choice
— can automate switch port configuration as part of the provisioning
lifecycle. See :doc:`/admin/networking` for the full picture on which network
interface options are available and what each one requires.

This configuration scales from a handful of nodes up to a large deployment.
It can be installed with any standard OpenStack deployment tool —
Kolla-Ansible, OpenStack-Ansible, and OpenStack Helm all work here. See
:doc:`configure-integration` for the OpenStack service integration setup.

If you need users to provision bare metal without knowing or caring which
specific node they get, read on.

.. _networking-generic-switch: https://opendev.org/openstack/networking-generic-switch/src/branch/master/README.rst

.. _deploy-scenarios-full-openstack:

Full OpenStack
==============

This adds :nova-doc:`Nova <>` and Placement to the previous scenario. Users
request bare metal through the Nova Compute API using flavors — Nova handles
scheduling and Placement tracks resource availability. From a user's
perspective, bare metal looks like any other instance type.

This is the right choice when you want a unified API for both virtual and
physical resources, or when Nova's scheduling model should decide which
hardware a workload lands on. Multi-tenancy is built into Nova's project
model, so there is nothing extra to configure for that beyond what you already
set up for Keystone.

The scale range here is wide. A single node running everything is a valid
starting point; at the other end, multiple data centers with distributed
conductor groups managing hardware regionally is a well-tested configuration.
Nova flavors map to Ironic resource classes, which Placement uses to match
workloads to available hardware. See :doc:`configure-compute` for the Nova
integration and :doc:`configure-nova-flavors` for flavor setup.

The same deployment tools that work for the previous scenario —
Kolla-Ansible, OpenStack-Ansible, and OpenStack Helm — support this one
as well.

For a concrete example of this configuration at small scale, see
:doc:`refarch/small-cloud-trusted-tenants`.

User Personas
=============

Who interacts with Ironic depends on which scenario you are running. In
standalone mode there is effectively one role. In OpenStack deployments the
RBAC model creates meaningful distinctions between people who manage hardware,
people who own or lease specific nodes, and people who provision and consume
them.

Cloud Operator / Hardware Administrator
---------------------------------------

This person manages the physical hardware fleet: enrolling nodes, configuring
out-of-band management (IPMI, Redfish), updating firmware, and setting
maintenance state. In OpenStack deployments this maps to a system-scoped
admin or member role. In standalone mode, this is whoever holds the API
credentials.

Cloud Administrator
-------------------

This person manages the Ironic service itself — policies, conductor groups,
and service-level configuration. In smaller deployments this is often the
same person as the hardware operator. In OpenStack deployments they hold a
system-scoped admin role.

Project Administrator / Node Owner
-----------------------------------

This role exists in the OpenStack scenarios only. A node owner has been
assigned specific nodes within a Keystone project via the ``owner`` field on
a node and can provision, deprovision, and configure those nodes. A system
administrator sets the owner; the owner operates from there. See
:doc:`/admin/node-multitenancy`.

Node Lessee
-----------

A lessee has temporary, limited access to specific nodes via the ``lessee``
field. They can provision and interact with leased nodes but cannot view
sensitive fields like ``driver_info`` or ``driver_internal_info`` by default.
This role exists in the OpenStack scenarios only. See
:doc:`/admin/node-multitenancy` and :doc:`/admin/secure-rbac`.

End User / Tenant
-----------------

This person provisions nodes. In standalone and OpenStack-without-Nova
deployments, they interact with the Ironic API directly. In a full OpenStack
deployment they use the Nova Compute API and may not know they are getting
physical hardware at all. Their access is bounded by whatever the policy
configuration allows.

In standalone deployments the end user and the operator are often the same
person — there is no access control separating them.

Choosing Your Path
==================

* **No OpenStack:** Standalone. Consider :bifrost-doc:`Bifrost <>` for
  Ansible-based automation or `Metal3`_ if you are running Kubernetes.

* **Need multi-tenancy or OpenStack integration, want direct control over
  which node is used:** OpenStack without Nova. You get the full OpenStack
  access model while keeping explicit control over node selection.

* **Users expect a VM-like experience or you need a unified API for virtual
  and physical resources:** Full OpenStack. Nova handles scheduling and users
  work through the familiar Compute API.

* **Not sure:** Start with OpenStack without Nova. Nova can be added later
  without rebuilding the Ironic deployment.
