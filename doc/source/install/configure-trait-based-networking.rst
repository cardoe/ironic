.. _configure-trait-based-networking:


Configure Trait Based Networking to Plan Networking Related Operations at vif Attach
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Ironic has a feature called Trait Based Networking (or TBN) that allows
operators to configure how a node's network will be built and attached.

TBN applies to OpenStack installations utilizing Ironic, Neutron, and Nova
that want dynamic port scheduling based on networks and flavors chosen by the
instance creator.

Trait Based Networking is enabled by default. To use it, a few steps must be
completed.

#. Ensure Trait Based Networking is enabled in the ironic-conductor service
   configuration:

   .. code-block:: ini

       [conductor]

       # Enables Trait Based Networking, defaults to True
       enable_trait_based_networking=True

#. Optionally, supply a TBN configuration file:

   .. code-block:: ini

       [conductor]

       trait_based_networking_config_file=/etc/ironic/trait_based_networking.yaml

   For discussion of the syntax and format of the configuration file refer to
   :ref:`tbn-config-file`.

   If ``trait_based_networking_config_file`` is not set, the default
   configuration bundled with Ironic is used. It is reproduced below:

   .. literalinclude:: ../../../ironic/common/trait_based_networking/default_config.yaml
       :language: yaml

   A more complete example configuration file also ships with Ironic:

   .. literalinclude:: ../../../etc/ironic/trait_based_networks.yaml.sample
       :language: yaml

#. Set desired TBN traits on a node's ``instance_info.traits``. Trait names
   must match exactly for a TBN trait to be applied.


Then, when ``vif_attach`` is called, TBN will plan networking operations based
on the node's ``instance_info.traits`` and supplied configured traits. If
planning succeeds, then each network operation will be applied.
