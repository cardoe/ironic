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

"""OpenAPI definitions for the /v1/shards endpoints.

Microversion history relevant to this resource:

* **v1.82** – Node sharding capability introduced; the ``/v1/shards`` endpoint
  returns the list of known shards and their node counts.
"""

from ironic.api.openapi import (
    BaseResource,
    json_response,
    with_error_responses,
)
from ironic.api.schemas.v1 import shard as schema

_V_INTRODUCED = 82   # MINOR_82_NODE_SHARD


class ShardResource(BaseResource):
    """OpenAPI contributor for the Ironic shards resource."""

    def get_openapi(self, microversion: int):
        if microversion < _V_INTRODUCED:
            return {}, {}

        paths: dict = {
            '/shards': {
                'get': {
                    'summary': 'List node shards',
                    'description': (
                        'Return the list of shards known to the conductor '
                        'along with a count of the nodes assigned to each '
                        'shard.  Introduced in v1.82.'
                    ),
                    'operationId': 'shards_list',
                    'responses': with_error_responses({
                        '200': json_response(
                            schema.index_response_body,
                            description='A list of shards.',
                        ),
                    }),
                },
            },
        }

        return paths, {}
