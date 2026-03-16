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

"""OpenAPI definitions for the /v1/allocations endpoints.

Microversion history relevant to this resource:

* **v1.52** – Allocation API introduced (GET list, GET single, POST, DELETE).
* **v1.57** – PATCH (update) support added.
* **v1.60** – ``owner`` field added to allocation objects and query filters.
"""

from ironic.api.openapi import (
    BaseResource,
    json_request_body,
    json_response,
    path_param,
    query_schema_to_parameters,
    with_error_responses,
    PAGINATION_PARAMETERS,
)
from ironic.api.schemas.v1 import allocation as schema

# Microversion constants for this resource.
_V_INTRODUCED = 52   # MINOR_52_ALLOCATION
_V_UPDATE = 57       # MINOR_57_ALLOCATION_UPDATE
_V_OWNER = 60        # MINOR_60_ALLOCATION_OWNER

# Path parameter shared by single-resource operations.
_ALLOCATION_IDENT_PARAM = path_param(
    name='allocation_ident',
    schema={'type': 'string'},
    description=(
        'The UUID or logical name of the allocation to operate on.'
    ),
)


class AllocationResource(BaseResource):
    """OpenAPI contributor for the Ironic allocations resource."""

    def get_openapi(self, microversion: int):
        if microversion < _V_INTRODUCED:
            return {}, {}

        # ------------------------------------------------------------------
        # Choose schema variants based on the requested microversion.
        # ------------------------------------------------------------------
        if microversion >= _V_OWNER:
            index_query = schema.index_request_query_v60
            show_query = schema.show_request_query_v60
            create_body = schema.create_request_body_v58
            update_body = schema.update_request_body_v60
            index_resp = schema.index_response_body_v60
            show_resp = schema.show_response_body_v60
            create_resp = schema.create_response_body_v60
            update_resp = schema.update_response_body_v60
        else:
            index_query = schema.index_request_query
            show_query = schema.show_request_query
            # v1.58 adds `node` to the create body but is below _V_OWNER.
            create_body = schema.create_request_body_v58
            update_body = schema.update_request_body
            index_resp = schema.index_response_body
            show_resp = schema.show_response_body
            create_resp = schema.create_response_body
            update_resp = schema.update_response_body

        # ------------------------------------------------------------------
        # Build the index (collection) query parameters.
        # The pagination parameters are common; extract the resource-specific
        # filters from the schema and merge them in.
        # ------------------------------------------------------------------
        resource_query_params = [
            p for p in query_schema_to_parameters(index_query)
            if p['name'] not in {'limit', 'marker', 'sort_key', 'sort_dir'}
        ]
        collection_params = PAGINATION_PARAMETERS + resource_query_params

        # ------------------------------------------------------------------
        # Path items
        # ------------------------------------------------------------------
        paths: dict = {
            '/allocations': {
                'get': {
                    'summary': 'List allocations',
                    'description': (
                        'Return a list of allocation resources. Supports '
                        'filtering by node, resource class, state and (from '
                        'v1.60) owner.'
                    ),
                    'operationId': 'allocations_list',
                    'parameters': collection_params,
                    'responses': with_error_responses({
                        '200': json_response(
                            index_resp,
                            description='A list of allocations.',
                        ),
                    }),
                },
                'post': {
                    'summary': 'Create an allocation',
                    'description': (
                        'Request a new allocation.  The scheduler will find '
                        'a suitable node and move it to ``active`` state.'
                    ),
                    'operationId': 'allocations_create',
                    'requestBody': json_request_body(
                        create_body,
                        description='Allocation creation request.',
                    ),
                    'responses': with_error_responses({
                        '200': json_response(
                            create_resp,
                            description='The created allocation.',
                        ),
                        '409': {
                            'description': (
                                'Conflict – a matching allocation already '
                                'exists.'
                            ),
                        },
                    }),
                },
            },
            '/allocations/{allocation_ident}': {
                'parameters': [_ALLOCATION_IDENT_PARAM],
                'get': {
                    'summary': 'Show allocation details',
                    'operationId': 'allocations_show',
                    'parameters': query_schema_to_parameters(show_query),
                    'responses': with_error_responses({
                        '200': json_response(
                            show_resp,
                            description='Allocation details.',
                        ),
                    }),
                },
                'delete': {
                    'summary': 'Delete an allocation',
                    'description': (
                        'Delete an allocation.  The associated node, if any, '
                        'will be returned to ``available`` state.'
                    ),
                    'operationId': 'allocations_delete',
                    'responses': with_error_responses({
                        '204': {'description': 'Allocation deleted.'},
                        '409': {
                            'description': (
                                'Conflict – the allocation cannot be deleted '
                                'in its current state.'
                            ),
                        },
                    }),
                },
            },
        }

        # PATCH is only available from v1.57 onwards.
        if microversion >= _V_UPDATE:
            paths['/allocations/{allocation_ident}']['patch'] = {
                'summary': 'Update an allocation',
                'description': (
                    'Apply a JSON Patch document to the allocation '
                    '(v1.57+).  Only ``name`` and ``extra`` may be patched.'
                ),
                'operationId': 'allocations_update',
                'requestBody': json_request_body(
                    update_body,
                    description='JSON Patch document.',
                ),
                'responses': with_error_responses({
                    '200': json_response(
                        update_resp,
                        description='Updated allocation.',
                    ),
                    '409': {
                        'description': (
                            'Conflict – the allocation cannot be updated '
                            'in its current state.'
                        ),
                    },
                }),
            }

        return paths, {}
