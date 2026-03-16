.. _openapi:

=================================
OpenAPI Schema Generation
=================================

Ironic's REST API is documented via JSON Schema definitions that live in
``ironic/api/schemas/``.  A generator in ``ironic/api/openapi/`` combines
those definitions into a single `OpenAPI 3.1`_ document, which can be used
with any OpenAPI-compatible tooling (Swagger UI, Redoc, client generators,
linters, etc.).

.. _OpenAPI 3.1: https://spec.openapis.org/oas/v3.1.0

.. note::

   The **long-term upstream path** for OpenStack-wide OpenAPI generation is
   `openstack-codegenerator`_.  That project introspects a running Ironic
   instance, reads the same decorator-attached schemas, and produces a
   comprehensive OpenAPI document plus Rust SDK and CLI bindings.
   Progress is tracked in `Launchpad bug #2086121`_.

   The in-tree generator described on this page serves a **complementary,
   narrower purpose**: it requires no running service and no external
   dependencies — it works by importing the schema modules directly.  It
   is deliberately limited to the resources that already have complete JSON
   Schema coverage, making it useful today while the broader codegenerator
   integration matures.

.. _openstack-codegenerator: https://opendev.org/openstack/codegenerator
.. _Launchpad bug #2086121: https://bugs.launchpad.net/ironic/+bug/2086121

Overview
--------

The generator works in three layers:

1. **JSON Schema definitions** (``ironic/api/schemas/v1/*.py``) –
   microversion-aware request/response schemas used by both the live API
   validation decorators and this generator.  These are the **source of
   truth** and feed into codegenerator as well.

2. **Resource modules** (``ironic/api/openapi/resources/*.py``) –
   each module maps one or more URL paths to the schemas that describe
   them, producing OpenAPI `Path Item`_ and `Operation`_ objects.

3. **Generator** (``ironic/api/openapi/__init__.py``) –
   collects all registered resource modules and assembles them into a
   complete OpenAPI document.

.. _Path Item: https://spec.openapis.org/oas/v3.1.0#path-item-object
.. _Operation: https://spec.openapis.org/oas/v3.1.0#operation-object

Because Ironic uses API *microversions*, the generator accepts a
``--microversion`` argument.  Only the endpoints that are available at the
requested microversion are emitted, and the correct schema variant (e.g.
with or without the ``owner`` field on allocations) is selected
automatically.

Currently covered resources
---------------------------

.. list-table::
   :header-rows: 1
   :widths: 30 15 55

   * - Resource
     - Introduced in
     - Endpoints
   * - Allocations
     - v1.52
     - ``GET/POST /v1/allocations``,
       ``GET/PATCH/DELETE /v1/allocations/{id}``
   * - Node BIOS
     - v1.40
     - ``GET /v1/nodes/{node}/bios``,
       ``GET /v1/nodes/{node}/bios/{setting}``
   * - Node Firmware
     - v1.86
     - ``GET /v1/nodes/{node}/firmware``
   * - Inspection Rules
     - v1.96
     - ``GET/POST /v1/inspection_rules``,
       ``GET/PATCH/DELETE /v1/inspection_rules/{uuid}``
   * - Shards
     - v1.82
     - ``GET /v1/shards``

Generating the schema
---------------------

Run the following command from the repository root:

.. code-block:: console

   python tools/generate_openapi.py

This generates YAML output for the latest supported microversion.
Additional options:

.. code-block:: console

   # Specific microversion
   python tools/generate_openapi.py --microversion 96

   # JSON output
   python tools/generate_openapi.py --format json

   # Write to a file
   python tools/generate_openapi.py --output openapi.yaml

   # Show all options
   python tools/generate_openapi.py --help

The generated document can be served with any OpenAPI viewer, for example:

.. code-block:: console

   # Using swagger-ui-watcher (npm)
   python tools/generate_openapi.py --output openapi.yaml
   npx swagger-ui-watcher openapi.yaml

   # Using redocly CLI (npm)
   python tools/generate_openapi.py --output openapi.yaml
   npx @redocly/cli preview-docs openapi.yaml

Adding a new resource
---------------------

Follow these steps when new API schemas are added to
``ironic/api/schemas/v1/``.

Step 1 – Write the JSON schemas
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Add or update the schema file for the resource under
``ironic/api/schemas/v1/``.  Use the existing allocation schema
(``ironic/api/schemas/v1/allocation.py``) as a reference.

Key conventions:

* Name schemas after their intent: ``index_request_query``,
  ``create_request_body``, ``show_response_body``, etc.
* Create microversion variants by deep-copying the base schema and
  adding/removing properties:

  .. code-block:: python

     import copy
     create_request_body_v99 = copy.deepcopy(create_request_body)
     create_request_body_v99['properties']['new_field'] = {'type': 'string'}

* Embed ``style`` and ``explode`` hints inside array query parameters to
  convey OpenAPI serialisation behaviour.  The generator extracts these
  automatically:

  .. code-block:: python

     'fields': {
         'type': 'array',
         'items': {'enum': [...]},
         # OpenAPI serialisation hints – extracted by the generator
         'style': 'form',
         'explode': False,
     }

Step 2 – Create a resource module
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Create ``ironic/api/openapi/resources/myresource.py``.  The module must
contain one class that inherits from
:class:`~ironic.api.openapi.BaseResource` and implements
:meth:`~ironic.api.openapi.BaseResource.get_openapi`.

Minimal skeleton:

.. code-block:: python

   from ironic.api.openapi import (
       BaseResource,
       json_request_body,
       json_response,
       path_param,
       query_schema_to_parameters,
       with_error_responses,
       PAGINATION_PARAMETERS,
   )
   from ironic.api.schemas.v1 import myresource as schema

   _V_INTRODUCED = 99   # the MINOR_* constant for your resource

   _RESOURCE_IDENT_PARAM = path_param(
       name='myresource_uuid',
       schema={'type': 'string', 'format': 'uuid'},
       description='UUID of the resource.',
   )

   class MyResource(BaseResource):
       def get_openapi(self, microversion):
           if microversion < _V_INTRODUCED:
               return {}, {}   # not yet available

           # Select schema variants for the given microversion.
           if microversion >= 105:
               create_body = schema.create_request_body_v105
           else:
               create_body = schema.create_request_body

           # Build collection query params, merging pagination helpers.
           resource_params = [
               p for p in query_schema_to_parameters(schema.index_request_query)
               if p['name'] not in {'limit', 'marker', 'sort_key', 'sort_dir'}
           ]
           collection_params = PAGINATION_PARAMETERS + resource_params

           paths = {
               '/myresources': {
                   'get': {
                       'summary': 'List my resources',
                       'operationId': 'myresources_list',
                       'parameters': collection_params,
                       'responses': with_error_responses({
                           '200': json_response(schema.index_response_body),
                       }),
                   },
                   'post': {
                       'summary': 'Create a my resource',
                       'operationId': 'myresources_create',
                       'requestBody': json_request_body(create_body),
                       'responses': with_error_responses({
                           '200': json_response(schema.create_response_body),
                       }),
                   },
               },
               '/myresources/{myresource_uuid}': {
                   'parameters': [_RESOURCE_IDENT_PARAM],
                   'get': {
                       'summary': 'Show a my resource',
                       'operationId': 'myresources_show',
                       'responses': with_error_responses({
                           '200': json_response(schema.show_response_body),
                       }),
                   },
                   'delete': {
                       'summary': 'Delete a my resource',
                       'operationId': 'myresources_delete',
                       'responses': with_error_responses({
                           '204': {'description': 'Deleted.'},
                       }),
                   },
               },
           }
           return paths, {}

:meth:`~ironic.api.openapi.BaseResource.get_openapi` returns a **2-tuple**:

* ``paths`` – mapping of URL paths to OpenAPI
  `Path Item objects <https://spec.openapis.org/oas/v3.1.0#path-item-object>`_.
* ``component_schemas`` – mapping of schema names to JSON Schema objects to be
  added to ``components/schemas`` (use ``{}`` if your resource needs no shared
  components).

Helper functions available from :mod:`ironic.api.openapi`:

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - Helper
     - Purpose
   * - ``query_schema_to_parameters(schema)``
     - Convert a flat query-object JSON Schema into a list of OpenAPI
       ``Parameter`` objects.  Extracts ``style``/``explode`` hints.
   * - ``path_param(name, schema, description)``
     - Build a path Parameter object (``in: path``, ``required: true``).
   * - ``json_request_body(schema, description)``
     - Wrap a schema in a ``RequestBody`` object.
   * - ``json_response(schema, description)``
     - Wrap a schema in a 200 ``Response`` object.
   * - ``empty_response(description)``
     - Create a ``Response`` object with no body (e.g. 204 No Content).
   * - ``with_error_responses(success_responses)``
     - Merge standard 400/401/403/404/406 error responses into the
       operation's response map.
   * - ``PAGINATION_PARAMETERS``
     - Pre-built list of ``limit``, ``marker``, ``sort_key``, ``sort_dir``
       Parameter objects suitable for collection endpoints.

Step 3 – Register the resource
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Open ``ironic/api/openapi/resources/__init__.py`` and:

1. Add an import for your new module.
2. Append an instance of your class to the ``ALL`` list.

.. code-block:: python

   from ironic.api.openapi.resources import myresource   # ← add

   ALL = [
       allocation.AllocationResource(),
       bios.BiosResource(),
       firmware.FirmwareResource(),
       inspection_rule.InspectionRuleResource(),
       shard.ShardResource(),
       myresource.MyResource(),                          # ← add
   ]

That is the only change needed.  Re-running
``python tools/generate_openapi.py`` will include the new resource.

Design notes
------------

Why OpenAPI 3.1?
~~~~~~~~~~~~~~~~

Ironic's schema validator uses JSON Schema **Draft 2020-12**.  OpenAPI 3.1
is the first version of the specification to align with that draft, so the
existing schemas can be embedded directly without translation.  In
particular, ``type: ['string', 'null']`` and ``anyOf`` constructs work as
expected without the ``nullable: true`` workaround required by OpenAPI 3.0.

Microversion handling
~~~~~~~~~~~~~~~~~~~~~

OpenAPI does not have a native concept of API microversions.  The generator
takes a pragmatic approach: it generates a single snapshot for one
microversion, which is the most useful output for documentation and client
generation.  The resource modules select the correct schema variant
internally by comparing the requested microversion against the version
thresholds at which schemas changed.

The generator **does not** attempt to document every possible microversion
in a single file; doing so would require extensive use of ``oneOf``/
``discriminator`` constructs that make the output harder to read and use.

Relationship to the API-ref documentation
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The OpenAPI output is complementary to, not a replacement for, the
hand-authored API reference in ``api-ref/``.  The API-ref contains
narrative documentation, examples and cross-version tables that are
difficult to express in OpenAPI.  The generated schema is primarily useful
for client generation and automated validation.
