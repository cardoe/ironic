#!/usr/bin/env python3
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

"""Generate an OpenAPI 3.1 document for the Ironic REST API.

Usage
-----

Generate for the latest API microversion (default)::

    python tools/generate_openapi.py

Generate for a specific microversion::

    python tools/generate_openapi.py --microversion 96

Write to a file instead of stdout::

    python tools/generate_openapi.py --output openapi.yaml

Choose JSON output format::

    python tools/generate_openapi.py --format json --output openapi.json

Validate the generated document with a third-party tool::

    python tools/generate_openapi.py | python -c "
    import sys, yaml, jsonschema
    doc = yaml.safe_load(sys.stdin)
    print('paths:', list(doc['paths']))
    "

How to extend this tool
-----------------------

1.  Write the JSON Schema definitions for your new resource in a new module
    ``ironic/api/schemas/v1/myresource.py``, following the conventions used
    by ``ironic/api/schemas/v1/allocation.py``.

2.  Create ``ironic/api/openapi/resources/myresource.py`` containing a class
    that inherits from :class:`ironic.api.openapi.BaseResource`.  See the
    docstring in :mod:`ironic.api.openapi` for a full skeleton.

3.  Import your class and add an instance to :data:`ironic.api.openapi.resources.ALL`.

That is all.  Re-running this script will include the new resource.
"""

import argparse
import json
import sys

# oslo.config must be initialised before ironic modules that read CONF.
from oslo_config import cfg
cfg.CONF([], project='ironic')

from ironic.api.openapi import Generator, LATEST_MICROVERSION
from ironic.api.openapi import resources


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        '--microversion',
        type=int,
        default=LATEST_MICROVERSION,
        metavar='N',
        help=(
            'Generate schema for Ironic API microversion 1.N. '
            f'Defaults to the latest supported version ({LATEST_MICROVERSION}).'
        ),
    )
    parser.add_argument(
        '--format',
        choices=['yaml', 'json'],
        default='yaml',
        help='Output format (default: yaml).',
    )
    parser.add_argument(
        '--output',
        metavar='FILE',
        default='-',
        help="Output file path. Use '-' for stdout (default).",
    )
    args = parser.parse_args(argv)

    gen = Generator(microversion=args.microversion)
    for resource in resources.ALL:
        gen.register(resource)

    doc = gen.generate()

    if args.format == 'json':
        text = json.dumps(doc, indent=2, default=str)
    else:
        try:
            import yaml
        except ImportError:
            print(
                'ERROR: PyYAML is not installed.  Install it with '
                '"pip install PyYAML" or use --format json.',
                file=sys.stderr,
            )
            sys.exit(1)
        text = yaml.safe_dump(doc, allow_unicode=True, sort_keys=False)

    if args.output == '-':
        print(text)
    else:
        with open(args.output, 'w') as fh:
            fh.write(text)
        print(f'Written to {args.output}', file=sys.stderr)


if __name__ == '__main__':
    main()
