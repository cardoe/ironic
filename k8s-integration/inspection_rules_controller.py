#!/usr/bin/env python3
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

"""Kubernetes controller for Ironic InspectionRule CRDs.

This controller watches InspectionRule custom resources in Kubernetes and
maintains a combined rules file on disk for the Ironic conductor to consume.
"""

import argparse
import datetime
import logging
import os
import signal
import sys
import tempfile
import time
import uuid

import yaml

try:
    from kubernetes import client, config, watch
    from kubernetes.client.rest import ApiException
except ImportError:
    print("ERROR: kubernetes Python package is required. "
          "Install it with: pip install kubernetes")
    sys.exit(1)


LOG = logging.getLogger(__name__)

# CRD configuration
GROUP = 'ironic.openstack.org'
VERSION = 'v1'
PLURAL = 'inspectionrules'

# Default output file path
DEFAULT_OUTPUT_PATH = '/etc/ironic/inspection_rules.yaml'


class InspectionRulesController:
    """Controller for managing InspectionRule CRDs."""

    def __init__(self, namespace, output_path, sync_interval=30):
        """Initialize the controller.

        :param namespace: Kubernetes namespace to watch (None for all namespaces)
        :param output_path: Path where the combined rules file will be written
        :param sync_interval: Interval in seconds for periodic full syncs
        """
        self.namespace = namespace
        self.output_path = output_path
        self.sync_interval = sync_interval
        self.running = True
        self.last_sync_time = None

        # Initialize Kubernetes client
        try:
            # Try to load in-cluster config first
            config.load_incluster_config()
            LOG.info("Loaded in-cluster Kubernetes configuration")
        except config.ConfigException:
            # Fall back to kubeconfig
            config.load_kube_config()
            LOG.info("Loaded Kubernetes configuration from kubeconfig")

        self.custom_api = client.CustomObjectsApi()
        self.api_client = client.ApiClient()

    def _get_all_rules(self):
        """Retrieve all InspectionRule resources from Kubernetes.

        :returns: List of InspectionRule resources
        :raises: ApiException on Kubernetes API errors
        """
        try:
            if self.namespace:
                response = self.custom_api.list_namespaced_custom_object(
                    group=GROUP,
                    version=VERSION,
                    namespace=self.namespace,
                    plural=PLURAL
                )
            else:
                response = self.custom_api.list_cluster_custom_object(
                    group=GROUP,
                    version=VERSION,
                    plural=PLURAL
                )
            return response.get('items', [])
        except ApiException as e:
            LOG.error("Error retrieving InspectionRule resources: %s", e)
            raise

    def _convert_crd_to_rule(self, crd):
        """Convert a CRD resource to an inspection rule dictionary.

        :param crd: Kubernetes CRD resource
        :returns: Dictionary representing the inspection rule
        """
        spec = crd.get('spec', {})
        metadata = crd.get('metadata', {})

        # Generate or use existing UUID
        rule_uuid = spec.get('uuid')
        if not rule_uuid:
            rule_uuid = str(uuid.uuid4())

        # Build the rule dictionary
        rule = {
            'uuid': rule_uuid,
            'priority': spec.get('priority', 0),
            'phase': spec.get('phase', 'main'),
            'actions': spec.get('actions', []),
        }

        # Add optional fields
        if 'description' in spec:
            rule['description'] = spec['description']

        if 'conditions' in spec:
            rule['conditions'] = spec['conditions']

        if 'sensitive' in spec:
            rule['sensitive'] = spec['sensitive']

        if 'scope' in spec:
            rule['scope'] = spec['scope']

        # Add metadata for tracking
        rule['_k8s_metadata'] = {
            'name': metadata.get('name'),
            'namespace': metadata.get('namespace'),
            'resource_version': metadata.get('resourceVersion'),
        }

        return rule

    def _write_rules_file(self, rules):
        """Write rules to the output file atomically.

        :param rules: List of rule dictionaries
        :raises: IOError on file write errors
        """
        try:
            # Remove k8s metadata before writing
            clean_rules = []
            for rule in rules:
                clean_rule = {k: v for k, v in rule.items()
                             if not k.startswith('_k8s_')}
                clean_rules.append(clean_rule)

            # Sort by priority (highest first)
            clean_rules.sort(key=lambda r: r.get('priority', 0), reverse=True)

            # Write to temporary file first for atomic update
            output_dir = os.path.dirname(self.output_path)
            with tempfile.NamedTemporaryFile(
                mode='w',
                dir=output_dir,
                delete=False,
                prefix='.inspection_rules_',
                suffix='.yaml.tmp'
            ) as tmp_file:
                yaml.safe_dump(clean_rules, tmp_file,
                             default_flow_style=False,
                             sort_keys=False)
                tmp_path = tmp_file.name

            # Atomic rename
            os.rename(tmp_path, self.output_path)

            LOG.info("Successfully wrote %d rules to %s",
                    len(clean_rules), self.output_path)

        except Exception as e:
            LOG.error("Error writing rules file: %s", e)
            raise

    def _update_crd_status(self, name, namespace, state, message=None):
        """Update the status of an InspectionRule CRD.

        :param name: Name of the CRD
        :param namespace: Namespace of the CRD
        :param state: State to set (Active, Error, Pending)
        :param message: Optional status message
        """
        try:
            status = {
                'state': state,
                'lastSyncTime': datetime.datetime.utcnow().isoformat() + 'Z'
            }
            if message:
                status['message'] = message

            # Update the status subresource
            self.custom_api.patch_namespaced_custom_object_status(
                group=GROUP,
                version=VERSION,
                namespace=namespace,
                plural=PLURAL,
                name=name,
                body={'status': status}
            )
        except ApiException as e:
            LOG.warning("Failed to update status for %s/%s: %s",
                       namespace, name, e)

    def sync_rules(self):
        """Perform a full sync of all rules."""
        try:
            LOG.info("Starting full sync of inspection rules")

            # Get all rules from Kubernetes
            crds = self._get_all_rules()

            # Convert CRDs to rules
            rules = []
            for crd in crds:
                try:
                    rule = self._convert_crd_to_rule(crd)
                    rules.append(rule)

                    # Update CRD status to Active
                    metadata = crd.get('metadata', {})
                    self._update_crd_status(
                        metadata.get('name'),
                        metadata.get('namespace'),
                        'Active',
                        'Rule synchronized successfully'
                    )
                except Exception as e:
                    metadata = crd.get('metadata', {})
                    LOG.error("Error converting CRD %s/%s: %s",
                             metadata.get('namespace'),
                             metadata.get('name'), e)
                    self._update_crd_status(
                        metadata.get('name'),
                        metadata.get('namespace'),
                        'Error',
                        f'Failed to process rule: {str(e)}'
                    )

            # Write rules to file
            self._write_rules_file(rules)

            self.last_sync_time = time.time()
            LOG.info("Full sync completed successfully")

        except Exception as e:
            LOG.error("Error during full sync: %s", e)
            raise

    def watch_rules(self):
        """Watch for changes to InspectionRule resources."""
        w = watch.Watch()

        LOG.info("Starting watch on InspectionRule resources in %s",
                self.namespace or "all namespaces")

        # Perform initial sync
        self.sync_rules()

        while self.running:
            try:
                # Set up the watch
                if self.namespace:
                    stream = w.stream(
                        self.custom_api.list_namespaced_custom_object,
                        group=GROUP,
                        version=VERSION,
                        namespace=self.namespace,
                        plural=PLURAL,
                        timeout_seconds=self.sync_interval
                    )
                else:
                    stream = w.stream(
                        self.custom_api.list_cluster_custom_object,
                        group=GROUP,
                        version=VERSION,
                        plural=PLURAL,
                        timeout_seconds=self.sync_interval
                    )

                # Process watch events
                for event in stream:
                    event_type = event['type']
                    obj = event['object']
                    metadata = obj.get('metadata', {})

                    LOG.info("Received %s event for InspectionRule %s/%s",
                            event_type,
                            metadata.get('namespace'),
                            metadata.get('name'))

                    # Trigger a full sync on any change
                    self.sync_rules()

            except ApiException as e:
                if e.status == 410:
                    # Resource version is too old, restart watch
                    LOG.warning("Watch expired, restarting...")
                    continue
                else:
                    LOG.error("API error during watch: %s", e)
                    time.sleep(5)
            except Exception as e:
                LOG.error("Error during watch: %s", e)
                time.sleep(5)

            # Check if we need to do a periodic sync
            if (self.last_sync_time is None or
                time.time() - self.last_sync_time > self.sync_interval):
                try:
                    self.sync_rules()
                except Exception as e:
                    LOG.error("Error during periodic sync: %s", e)

    def stop(self):
        """Stop the controller."""
        LOG.info("Stopping controller")
        self.running = False


def setup_logging(log_level):
    """Configure logging for the controller."""
    logging.basicConfig(
        level=log_level,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        stream=sys.stdout
    )


def signal_handler(signum, frame, controller):
    """Handle termination signals gracefully."""
    LOG.info("Received signal %s, shutting down", signum)
    controller.stop()
    sys.exit(0)


def main():
    """Main entry point for the controller."""
    parser = argparse.ArgumentParser(
        description='Kubernetes controller for Ironic InspectionRule CRDs'
    )
    parser.add_argument(
        '--namespace',
        help='Kubernetes namespace to watch (default: all namespaces)',
        default=None
    )
    parser.add_argument(
        '--output-path',
        help=f'Path to write combined rules file (default: {DEFAULT_OUTPUT_PATH})',
        default=DEFAULT_OUTPUT_PATH
    )
    parser.add_argument(
        '--sync-interval',
        type=int,
        help='Interval in seconds for periodic full syncs (default: 30)',
        default=30
    )
    parser.add_argument(
        '--log-level',
        help='Logging level (default: INFO)',
        choices=['DEBUG', 'INFO', 'WARNING', 'ERROR'],
        default='INFO'
    )
    parser.add_argument(
        '--one-shot',
        action='store_true',
        help='Perform a single sync and exit (useful for testing)'
    )

    args = parser.parse_args()

    # Setup logging
    setup_logging(getattr(logging, args.log_level))

    # Create output directory if it doesn't exist
    output_dir = os.path.dirname(args.output_path)
    if output_dir and not os.path.exists(output_dir):
        os.makedirs(output_dir)
        LOG.info("Created output directory: %s", output_dir)

    # Initialize controller
    controller = InspectionRulesController(
        namespace=args.namespace,
        output_path=args.output_path,
        sync_interval=args.sync_interval
    )

    # Setup signal handlers
    signal.signal(signal.SIGINT,
                 lambda s, f: signal_handler(s, f, controller))
    signal.signal(signal.SIGTERM,
                 lambda s, f: signal_handler(s, f, controller))

    try:
        if args.one_shot:
            LOG.info("Running in one-shot mode")
            controller.sync_rules()
            LOG.info("One-shot sync completed")
        else:
            LOG.info("Starting InspectionRule controller")
            controller.watch_rules()
    except KeyboardInterrupt:
        LOG.info("Received keyboard interrupt, shutting down")
        controller.stop()
    except Exception as e:
        LOG.exception("Fatal error: %s", e)
        sys.exit(1)


if __name__ == '__main__':
    main()
