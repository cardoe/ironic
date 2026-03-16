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

"""OpenAPI definitions for the /v1/nodes/{node_ident}/bios endpoints.

Microversion history relevant to this resource:

* **v1.40** – BIOS interface introduced (GET list and GET single).
* **v1.74** – Extended BIOS registry fields added (``allowable_values``,
  ``attribute_type``, ``lower_bound``, ``max_length``, ``min_length``,
  ``read_only``, ``reset_required``, ``unique``, ``upper_bound``).
"""

from ironic.api.openapi import (
    BaseResource,
    json_response,
    path_param,
    query_schema_to_parameters,
    with_error_responses,
)
from ironic.api.schemas.v1 import bios as schema

_V_INTRODUCED = 40   # MINOR_40_BIOS_INTERFACE
_V_REGISTRY = 74     # MINOR_74_BIOS_REGISTRY

# Shared path parameters for BIOS sub-resource endpoints.
_NODE_IDENT_PARAM = path_param(
    name='node_ident',
    schema={'type': 'string'},
    description='The UUID or logical name of the node.',
)
_SETTING_NAME_PARAM = path_param(
    name='setting_name',
    schema={'type': 'string'},
    description='The name of the BIOS setting.',
)


class BiosResource(BaseResource):
    """OpenAPI contributor for the Ironic node BIOS sub-resource."""

    def get_openapi(self, microversion: int):
        if microversion < _V_INTRODUCED:
            return {}, {}

        # Choose schema variants based on the requested microversion.
        if microversion >= _V_REGISTRY:
            index_query = schema.index_request_query_v74
            index_resp = schema.index_response_body_v74
            show_resp = schema.show_response_body_v74
        else:
            index_query = schema.index_request_query
            index_resp = schema.index_response_body
            show_resp = schema.show_response_body

        paths: dict = {
            '/nodes/{node_ident}/bios': {
                'parameters': [_NODE_IDENT_PARAM],
                'get': {
                    'summary': 'List BIOS settings for a node',
                    'description': (
                        'Return all BIOS settings for the specified node.  '
                        'From v1.74 the response includes extended registry '
                        'metadata (allowable values, type information, bounds '
                        'etc.).'
                    ),
                    'operationId': 'nodes_bios_list',
                    'parameters': query_schema_to_parameters(index_query),
                    'responses': with_error_responses({
                        '200': json_response(
                            index_resp,
                            description='BIOS settings list.',
                        ),
                    }),
                },
            },
            '/nodes/{node_ident}/bios/{setting_name}': {
                'parameters': [_NODE_IDENT_PARAM, _SETTING_NAME_PARAM],
                'get': {
                    'summary': 'Show a single BIOS setting',
                    'description': (
                        'Return details for a specific BIOS setting on the '
                        'given node.  From v1.74 the response includes '
                        'extended registry metadata.'
                    ),
                    'operationId': 'nodes_bios_show',
                    'parameters': query_schema_to_parameters(
                        schema.show_request_query
                    ),
                    'responses': with_error_responses({
                        '200': json_response(
                            show_resp,
                            description=(
                                'An object whose single key is the setting '
                                'name and whose value is the setting detail.'
                            ),
                        ),
                    }),
                },
            },
        }

        return paths, {}
