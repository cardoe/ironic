# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

"""OpenAPI 3.1 schema generator for the Ironic REST API.

This module provides a :class:`Generator` that assembles a complete OpenAPI
3.1 document by collecting path and component definitions registered by
individual *resource* modules under :mod:`ironic.api.openapi.resources`.

.. note::

    The upstream OpenStack-wide tool for OpenAPI generation is
    ``openstack-codegenerator`` (https://opendev.org/openstack/codegenerator).
    That tool introspects a *running* Ironic instance and is the long-term
    solution tracked in Launchpad bug #2086121.  This in-tree generator is a
    lightweight complement: it imports schema modules directly and requires no
    running service or external dependencies.  Only the resources that already
    have complete JSON Schema coverage are included.

Usage::

    from ironic.api.openapi import Generator
    from ironic.api.openapi import resources

    gen = Generator(microversion=111)
    for resource in resources.ALL:
        gen.register(resource)

    doc = gen.generate()

The returned dict is a complete OpenAPI 3.1 document and can be serialised
with :mod:`json` or :mod:`yaml`.
"""

import copy
import typing as ty

from ironic.api.controllers.v1 import versions as api_versions

#: The OpenAPI specification version we emit.
OPENAPI_VERSION = '3.1.0'

#: Current Ironic API major version string.
API_MAJOR_VERSION = '1'

#: Latest supported Ironic API microversion.
LATEST_MICROVERSION: int = api_versions.MINOR_MAX_VERSION

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

#: Non-standard keywords that Ironic schema files embed inside JSON Schema
#: property definitions as hints for OpenAPI Parameter serialisation.  These
#: must be *lifted* to the enclosing Parameter object and stripped from the
#: schema before it is emitted.
_OPENAPI_PARAM_KEYWORDS = frozenset(['style', 'explode'])


def _strip_param_keywords(schema: dict) -> tuple[dict, dict]:
    """Separate OpenAPI parameter keywords from a JSON Schema fragment.

    Returns ``(clean_schema, param_extras)`` where *clean_schema* has the
    OpenAPI-specific serialisation hints removed and *param_extras* is a
    (possibly empty) dict containing those hints ready to be merged into the
    enclosing Parameter object.
    """
    schema = copy.deepcopy(schema)
    param_extras: dict[str, ty.Any] = {}
    for key in list(schema.keys()):
        if key in _OPENAPI_PARAM_KEYWORDS:
            param_extras[key] = schema.pop(key)
    return schema, param_extras


def query_schema_to_parameters(schema: dict) -> list[dict]:
    """Convert a flat request-query JSON Schema into a list of OpenAPI
    Parameter objects.

    The existing Ironic query schemas use a top-level ``object`` with one
    property per query parameter.  This function expands those properties into
    individual OpenAPI Parameter objects, hoisting any ``style``/``explode``
    hints that were embedded inside the schema onto the Parameter itself.

    :param schema: A JSON Schema object describing the allowed query string.
    :returns: A list of OpenAPI Parameter dicts (``in: query``).
    """
    parameters = []
    required = set(schema.get('required', []))

    for name, prop_schema in schema.get('properties', {}).items():
        clean_schema, param_extras = _strip_param_keywords(prop_schema)

        param: dict[str, ty.Any] = {
            'name': name,
            'in': 'query',
            'required': name in required,
            'schema': clean_schema,
        }
        param.update(param_extras)
        parameters.append(param)

    return parameters


def path_param(name: str, schema: dict, description: str = '') -> dict:
    """Convenience helper to build an OpenAPI path Parameter object."""
    param: dict[str, ty.Any] = {
        'name': name,
        'in': 'path',
        'required': True,
        'schema': copy.deepcopy(schema),
    }
    if description:
        param['description'] = description
    return param


def json_request_body(schema: dict, description: str = '') -> dict:
    """Wrap a JSON Schema in an OpenAPI RequestBody object (required)."""
    body: dict[str, ty.Any] = {
        'required': True,
        'content': {
            'application/json': {
                'schema': copy.deepcopy(schema),
            },
        },
    }
    if description:
        body['description'] = description
    return body


def json_response(schema: dict, description: str = 'Success') -> dict:
    """Wrap a JSON Schema in an OpenAPI Response object (200 OK)."""
    return {
        'description': description,
        'content': {
            'application/json': {
                'schema': copy.deepcopy(schema),
            },
        },
    }


def empty_response(description: str = 'No Content') -> dict:
    """Return an OpenAPI Response object for operations that return no body."""
    return {'description': description}


# ---------------------------------------------------------------------------
# Common reusable parameter objects
# ---------------------------------------------------------------------------

#: Standard pagination parameters shared by all collection endpoints.
PAGINATION_PARAMETERS: list[dict] = [
    {
        'name': 'limit',
        'in': 'query',
        'required': False,
        'description': (
            'Maximum number of resources to return in a single result. '
            'The value 0 means returning all items.'
        ),
        'schema': {'type': 'integer', 'minimum': 0},
    },
    {
        'name': 'marker',
        'in': 'query',
        'required': False,
        'description': (
            'The UUID of the last item in the previous list, used to '
            'retrieve the next page of results.'
        ),
        'schema': {'type': 'string', 'format': 'uuid'},
    },
    {
        'name': 'sort_key',
        'in': 'query',
        'required': False,
        'description': 'Field to sort results by.',
        'schema': {'type': 'string'},
    },
    {
        'name': 'sort_dir',
        'in': 'query',
        'required': False,
        'description': 'Direction to sort: ``asc`` (default) or ``desc``.',
        'schema': {'type': 'string', 'enum': ['asc', 'desc']},
    },
]

# ---------------------------------------------------------------------------
# Common error response references used across all endpoints
# ---------------------------------------------------------------------------

_COMMON_ERROR_RESPONSES: dict[str, dict] = {
    '400': {'description': 'Bad Request – invalid parameter or body.'},
    '401': {'description': 'Unauthorized – missing or invalid credentials.'},
    '403': {'description': 'Forbidden – insufficient privileges.'},
    '404': {'description': 'Not Found – resource does not exist.'},
    '406': {'description': 'Not Acceptable – the requested API version is '
                           'not supported.'},
}


def with_error_responses(
    success_responses: dict[str, dict],
    extra_errors: ty.Optional[list[str]] = None,
) -> dict[str, dict]:
    """Merge common error responses with operation-specific success responses.

    :param success_responses: Mapping of HTTP status code strings to response
        objects for the successful cases (e.g. ``{'200': ...}``).
    :param extra_errors: Optional list of additional HTTP status codes (as
        strings) from :data:`_COMMON_ERROR_RESPONSES` to include.
    :returns: Combined responses dict.
    """
    responses = dict(success_responses)
    for code, resp in _COMMON_ERROR_RESPONSES.items():
        responses.setdefault(code, resp)
    if extra_errors:
        for code in extra_errors:
            if code in _COMMON_ERROR_RESPONSES:
                responses[code] = _COMMON_ERROR_RESPONSES[code]
    return responses


# ---------------------------------------------------------------------------
# Generator
# ---------------------------------------------------------------------------

class Generator:
    """Assembles a complete OpenAPI 3.1 document from registered resources.

    Example::

        gen = Generator(microversion=111)
        gen.register(AllocationResource())
        gen.register(BiosResource())

        import json
        print(json.dumps(gen.generate(), indent=2))

    :param microversion: The Ironic API microversion for which to generate the
        schema.  Defaults to :data:`LATEST_MICROVERSION`.  Only endpoints that
        are available at the given microversion are included, and the schema
        variant appropriate for that version is used.
    """

    def __init__(self, microversion: int = LATEST_MICROVERSION) -> None:
        self.microversion = microversion
        self._resources: list = []

    def register(self, resource: 'BaseResource') -> None:
        """Register a resource with this generator.

        :param resource: An instance of a :class:`BaseResource` subclass.
        """
        self._resources.append(resource)

    def generate(self) -> dict:
        """Build and return the complete OpenAPI document as a plain dict.

        The returned dict can be serialised directly with :func:`json.dumps`
        or :func:`yaml.safe_dump`.
        """
        paths: dict[str, dict] = {}
        component_schemas: dict[str, dict] = {}

        for resource in self._resources:
            resource_paths, resource_schemas = resource.get_openapi(
                self.microversion
            )
            # Merge paths; fail loudly on duplicate path definitions so that
            # resource authors notice conflicts early.
            for path, path_item in resource_paths.items():
                if path in paths:
                    raise ValueError(
                        f"Duplicate path definition for '{path}' from "
                        f"{resource.__class__.__name__}"
                    )
                paths[path] = path_item

            component_schemas.update(resource_schemas)

        return {
            'openapi': OPENAPI_VERSION,
            'info': {
                'title': 'OpenStack Ironic API',
                'description': (
                    'REST API for OpenStack Ironic – the Bare Metal '
                    'Provisioning service.  '
                    'Generated for microversion v1.{mv}.'.format(
                        mv=self.microversion
                    )
                ),
                'version': f'1.{self.microversion}',
                'license': {
                    'name': 'Apache 2.0',
                    'url': 'https://www.apache.org/licenses/LICENSE-2.0.html',
                },
            },
            'servers': [
                {
                    'url': 'http://{host}:{port}/v1',
                    'description': 'Ironic API endpoint',
                    'variables': {
                        'host': {'default': 'localhost'},
                        'port': {'default': '6385'},
                    },
                },
            ],
            'paths': paths,
            'components': {
                'schemas': component_schemas,
                'securitySchemes': {
                    'keystoneToken': {
                        'type': 'apiKey',
                        'in': 'header',
                        'name': 'X-Auth-Token',
                        'description': 'Keystone authentication token.',
                    },
                },
            },
            'security': [{'keystoneToken': []}],
        }


# ---------------------------------------------------------------------------
# BaseResource – base class that all resource modules extend
# ---------------------------------------------------------------------------

class BaseResource:
    """Base class for OpenAPI resource contributors.

    Subclasses implement :meth:`get_openapi` to return the path definitions
    and any reusable component schemas for the resource they describe.

    Implementing :meth:`get_openapi` is the *only* requirement.  The helper
    methods inherited from this class (:func:`query_schema_to_parameters`,
    :func:`json_request_body`, :func:`json_response`, etc.) are available at
    module level and can be imported directly.

    Example skeleton::

        from ironic.api.openapi import (
            BaseResource,
            json_request_body,
            json_response,
            query_schema_to_parameters,
            with_error_responses,
        )
        from ironic.api.schemas.v1 import myresource as schema

        class MyResource(BaseResource):
            # Introduced in microversion 99
            INTRODUCED_IN = 99

            def get_openapi(self, microversion):
                if microversion < self.INTRODUCED_IN:
                    return {}, {}

                # Pick the correct schema variant for the requested version.
                req_schema = (
                    schema.create_request_body_v99
                    if microversion >= 99
                    else schema.create_request_body
                )

                paths = {
                    '/myresources': {
                        'get': {
                            'summary': 'List my resources',
                            'operationId': 'myresources_list',
                            'parameters': query_schema_to_parameters(
                                schema.index_request_query
                            ),
                            'responses': with_error_responses({
                                '200': json_response(schema.index_response_body),
                            }),
                        },
                        'post': {
                            'summary': 'Create a my resource',
                            'operationId': 'myresources_create',
                            'requestBody': json_request_body(req_schema),
                            'responses': with_error_responses({
                                '200': json_response(schema.create_response_body),
                            }),
                        },
                    },
                }
                return paths, {}
    """

    def get_openapi(
        self, microversion: int
    ) -> tuple[dict[str, dict], dict[str, dict]]:
        """Return ``(paths, component_schemas)`` for the given microversion.

        :param microversion: The requested Ironic API microversion.
        :returns: A 2-tuple of ``(paths_dict, component_schemas_dict)``.
            *paths_dict* maps OpenAPI path strings to path item objects.
            *component_schemas_dict* maps schema names to JSON Schema objects
            that should be added to ``components/schemas``.  Return empty
            dicts when the resource is not yet available at *microversion*.
        :raises NotImplementedError: Subclasses must override this method.
        """
        raise NotImplementedError(
            f'{self.__class__.__name__} must implement get_openapi()'
        )
