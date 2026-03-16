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

"""OpenAPI definitions for the /v1/nodes/{node_ident}/firmware endpoints.

Microversion history relevant to this resource:

* **v1.86** – Firmware interface introduced (GET list only).
"""

from ironic.api.openapi import (
    BaseResource,
    json_response,
    path_param,
    query_schema_to_parameters,
    with_error_responses,
)
from ironic.api.schemas.v1 import firmware as schema

_V_INTRODUCED = 86   # MINOR_86_FIRMWARE_INTERFACE

_NODE_IDENT_PARAM = path_param(
    name='node_ident',
    schema={'type': 'string'},
    description='The UUID or logical name of the node.',
)


class FirmwareResource(BaseResource):
    """OpenAPI contributor for the Ironic node firmware sub-resource."""

    def get_openapi(self, microversion: int):
        if microversion < _V_INTRODUCED:
            return {}, {}

        paths: dict = {
            '/nodes/{node_ident}/firmware': {
                'parameters': [_NODE_IDENT_PARAM],
                'get': {
                    'summary': 'List firmware components for a node',
                    'description': (
                        'Return all firmware component details for the '
                        'specified node, including initial version, current '
                        'version and the last version that was flashed.  '
                        'Introduced in v1.86.'
                    ),
                    'operationId': 'nodes_firmware_list',
                    'parameters': query_schema_to_parameters(
                        schema.index_request_query
                    ),
                    'responses': with_error_responses({
                        '200': json_response(
                            schema.index_response_body,
                            description='Firmware components list.',
                        ),
                    }),
                },
            },
        }

        return paths, {}
