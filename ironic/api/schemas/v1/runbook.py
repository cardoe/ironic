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

import copy

from ironic.api.schemas.common import request_types
from ironic.api.schemas.common import response_types
from ironic.conductor import steps as conductor_steps


# request parameter schemas

_runbook_request_parameter = {
    'type': 'object',
    'properties': {
        'runbook_ident': request_types.uuid_or_name,
    },
    'required': ['runbook_ident'],
    'additionalProperties': False,
}

show_request_parameter = copy.deepcopy(_runbook_request_parameter)
update_request_parameter = copy.deepcopy(_runbook_request_parameter)
delete_request_parameter = copy.deepcopy(_runbook_request_parameter)

# request query string schemas

index_request_query = {
    'type': 'object',
    'properties': {
        'detail': {'type': 'boolean'},
        'fields': {
            'type': 'array',
            'items': {
                'enum': [
                    'created_at',
                    'disable_ramdisk',
                    'extra',
                    'links',
                    'name',
                    'owner',
                    'public',
                    'steps',
                    'updated_at',
                    'uuid',
                ],
            },
            # OpenAPI-specific properties
            # https://swagger.io/docs/specification/v3_0/serialization/#query-parameters
            'style': 'form',
            'explode': False,
        },
        'limit': request_types.limit,
        'marker': {'type': 'string', 'format': 'uuid'},
        'project': {'type': 'boolean'},
        'sort_dir': request_types.sort_dir,
        # TODO(stephenfin): This could be much stricter. As things stand,
        # invalid sort keys will fail at the controller layer.
        'sort_key': {'type': 'string'},
    },
    'required': [],
    'additionalProperties': False,
}

show_request_query = {
    'type': 'object',
    'properties': {
        'fields': {
            'type': 'array',
            'items': {
                'enum': [
                    'created_at',
                    'disable_ramdisk',
                    'extra',
                    'links',
                    'name',
                    'owner',
                    'public',
                    'steps',
                    'updated_at',
                    'uuid',
                ],
            },
            # OpenAPI-specific properties
            # https://swagger.io/docs/specification/v3_0/serialization/#query-parameters
            'style': 'form',
            'explode': False,
        },
    },
    'required': [],
    'additionalProperties': False,
}

# request body schemas

_runbook_step_request = {
    'type': 'object',
    'properties': {
        'args': {'type': 'object'},
        'interface': {
            'type': 'string',
            'enum': list(conductor_steps.CLEANING_INTERFACE_PRIORITY),
        },
        'order': {'anyOf': [
            {'type': 'integer', 'minimum': 0},
            {'type': 'string', 'minLength': 1, 'pattern': '^[0-9]+$'},
        ]},
        'step': {'type': 'string', 'minLength': 1},
    },
    'required': ['interface', 'step', 'order'],
    'additionalProperties': False,
}

create_request_body = {
    'type': 'object',
    'properties': {
        # TODO(stephenfin): description is present in the inline schema but is
        # not a field of the Runbook object and is not returned in responses.
        # It is included here for completeness until the discrepancy is
        # resolved.
        'description': {'type': ['string', 'null'], 'maxLength': 255},
        'disable_ramdisk': {'type': ['boolean', 'null']},
        'extra': {'type': ['object', 'null']},
        'name': response_types.traits,
        'owner': {'type': ['string', 'null'], 'maxLength': 255},
        'public': {'type': ['boolean', 'null']},
        'steps': {
            'type': 'array',
            'items': _runbook_step_request,
            'minItems': 1,
        },
        'uuid': {'type': ['string', 'null'], 'format': 'uuid'},
    },
    'required': ['steps', 'name'],
    'additionalProperties': False,
}

# TODO(stephenfin): This needs to be completed. We probably want a helper to
# generate these since they are superficially identical, with only the allowed
# patch fields changing.
update_request_body = {
    'type': 'array',
    'items': {
        'type': 'object',
        'properties': {
            'op': {'enum': ['add', 'replace', 'remove']},
            'path': {'type': 'string'},
            'value': {
                'type': ['string', 'object', 'array', 'null',
                         'integer', 'boolean'],
            },
        },
        'required': ['op', 'path'],
        'additionalProperties': False,
    },
}

# response body schemas

_runbook_step_response = {
    'type': 'object',
    'properties': {
        'args': {'type': ['object', 'null']},
        'interface': {'type': 'string'},
        'order': {'anyOf': [
            {'type': 'integer'},
            {'type': 'string'},
        ]},
        'step': {'type': 'string'},
    },
    'required': ['interface', 'step', 'args'],
    'additionalProperties': False,
}

_runbook_response_body = {
    'type': 'object',
    'properties': {
        'created_at': {'type': 'string', 'format': 'date-time'},
        'disable_ramdisk': {'type': 'boolean'},
        'extra': {'type': ['object', 'null']},
        'links': response_types.links,
        'name': response_types.traits,
        'owner': {'type': ['string', 'null']},
        'public': {'type': 'boolean'},
        'steps': {
            'type': 'array',
            'items': _runbook_step_response,
        },
        'updated_at': {'type': ['string', 'null'], 'format': 'date-time'},
        'uuid': {'type': ['string', 'null'], 'format': 'uuid'},
    },
    # NOTE(stephenfin): The 'fields' parameter means nothing is required
    'required': [],
    'additionalProperties': False,
}

index_response_body = {
    'type': 'object',
    'properties': {
        'next': {'type': 'string'},
        'runbooks': {
            'type': 'array',
            'items': copy.deepcopy(_runbook_response_body),
        },
    },
    'required': ['runbooks'],
    'additionalProperties': False,
}

show_response_body = copy.deepcopy(_runbook_response_body)
create_response_body = copy.deepcopy(_runbook_response_body)
update_response_body = copy.deepcopy(_runbook_response_body)
