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

"""Registry of all OpenAPI resource contributors.

:data:`ALL` is the canonical list of :class:`~ironic.api.openapi.BaseResource`
instances that the generator will query.

Adding a new resource
---------------------

1. Create a new module under ``ironic/api/openapi/resources/`` (e.g.
   ``myresource.py``).  The module must contain a class that inherits from
   :class:`~ironic.api.openapi.BaseResource` and implements
   :meth:`~ironic.api.openapi.BaseResource.get_openapi`.

2. Import and instantiate that class in this module.

3. Append the instance to :data:`ALL`.

That is the *only* change required – the CLI tool and any other consumers
iterate over :data:`ALL` automatically.

Example::

    # ironic/api/openapi/resources/myresource.py
    from ironic.api.openapi import BaseResource, ...
    class MyResource(BaseResource):
        ...

    # ironic/api/openapi/resources/__init__.py
    from ironic.api.openapi.resources import myresource
    ALL = [
        ...
        myresource.MyResource(),
    ]
"""

from ironic.api.openapi.resources import allocation
from ironic.api.openapi.resources import bios
from ironic.api.openapi.resources import firmware
from ironic.api.openapi.resources import inspection_rule
from ironic.api.openapi.resources import shard

#: The complete set of registered resources, in a sensible display order.
ALL = [
    allocation.AllocationResource(),
    bios.BiosResource(),
    firmware.FirmwareResource(),
    inspection_rule.InspectionRuleResource(),
    shard.ShardResource(),
]
