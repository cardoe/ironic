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

"""OpenAPI definitions for the /v1/inspection_rules endpoints.

Microversion history relevant to this resource:

* **v1.96** – Inspection rules API introduced (GET list, GET single, POST,
  PATCH, DELETE).
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
from ironic.api.schemas.v1 import inspection_rule as schema

_V_INTRODUCED = 96   # MINOR_96_INSPECTION_RULES

_RULE_UUID_PARAM = path_param(
    name='inspection_rule_uuid',
    schema={'type': 'string', 'format': 'uuid'},
    description='The UUID of the inspection rule.',
)


class InspectionRuleResource(BaseResource):
    """OpenAPI contributor for the Ironic inspection rules resource."""

    def get_openapi(self, microversion: int):
        if microversion < _V_INTRODUCED:
            return {}, {}

        # Build collection query parameters.  Pagination parameters are common;
        # the resource-specific filters are extracted from the schema.
        resource_query_params = [
            p for p in query_schema_to_parameters(schema.index_request_query)
            if p['name'] not in {'limit', 'marker', 'sort_key', 'sort_dir'}
        ]
        collection_params = PAGINATION_PARAMETERS + resource_query_params

        paths: dict = {
            '/inspection_rules': {
                'get': {
                    'summary': 'List inspection rules',
                    'description': (
                        'Return a list of inspection rule resources.  '
                        'Introduced in v1.96.'
                    ),
                    'operationId': 'inspection_rules_list',
                    'parameters': collection_params,
                    'responses': with_error_responses({
                        '200': json_response(
                            # Inline a minimal list wrapper since no separate
                            # index_response_body schema exists in the schema
                            # module yet.
                            {
                                'type': 'object',
                                'properties': {
                                    'inspection_rules': {
                                        'type': 'array',
                                        'items': _inspection_rule_item(),
                                    },
                                },
                                'required': ['inspection_rules'],
                                'additionalProperties': False,
                            },
                            description='A list of inspection rules.',
                        ),
                    }),
                },
                'post': {
                    'summary': 'Create an inspection rule',
                    'operationId': 'inspection_rules_create',
                    'requestBody': json_request_body(
                        schema.create_request_body,
                        description='Inspection rule creation request.',
                    ),
                    'responses': with_error_responses({
                        '200': json_response(
                            _inspection_rule_item(),
                            description='The created inspection rule.',
                        ),
                        '409': {
                            'description': (
                                'Conflict – a rule with the same UUID already '
                                'exists.'
                            ),
                        },
                    }),
                },
            },
            '/inspection_rules/{inspection_rule_uuid}': {
                'parameters': [_RULE_UUID_PARAM],
                'get': {
                    'summary': 'Show inspection rule details',
                    'operationId': 'inspection_rules_show',
                    'parameters': query_schema_to_parameters(
                        schema.show_request_query
                    ),
                    'responses': with_error_responses({
                        '200': json_response(
                            _inspection_rule_item(),
                            description='Inspection rule details.',
                        ),
                    }),
                },
                'patch': {
                    'summary': 'Update an inspection rule',
                    'description': (
                        'Apply a JSON Patch document to the inspection rule.'
                    ),
                    'operationId': 'inspection_rules_update',
                    'requestBody': json_request_body(
                        schema.update_request_body,
                        description='JSON Patch document.',
                    ),
                    'responses': with_error_responses({
                        '200': json_response(
                            _inspection_rule_item(),
                            description='Updated inspection rule.',
                        ),
                    }),
                },
                'delete': {
                    'summary': 'Delete an inspection rule',
                    'operationId': 'inspection_rules_delete',
                    'responses': with_error_responses({
                        '204': {'description': 'Inspection rule deleted.'},
                    }),
                },
            },
        }

        return paths, {}


def _inspection_rule_item() -> dict:
    """Return a JSON Schema describing a single inspection rule object."""
    return {
        'type': 'object',
        'properties': {
            'uuid': {'type': 'string', 'format': 'uuid'},
            'description': {'type': ['string', 'null'], 'maxLength': 255},
            'phase': {'type': ['string', 'null'], 'maxLength': 16},
            'priority': {'type': 'integer', 'minimum': 0},
            'sensitive': {'type': ['boolean', 'null']},
            'conditions': {
                'type': 'array',
                'items': {'type': 'object'},
            },
            'actions': {
                'type': 'array',
                'items': {'type': 'object'},
            },
            'created_at': {'type': 'string', 'format': 'date-time'},
            'updated_at': {'type': ['string', 'null'], 'format': 'date-time'},
            'links': {
                'type': 'array',
                'items': {
                    'type': 'object',
                    'properties': {
                        'rel': {'type': 'string'},
                        'href': {'type': 'string', 'format': 'uri'},
                    },
                },
            },
        },
        'required': [],
        'additionalProperties': False,
    }
