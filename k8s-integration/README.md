# Ironic InspectionRule Kubernetes CRD

This directory contains a Kubernetes Custom Resource Definition (CRD) for managing Ironic hardware inspection rules, along with a Python controller that watches these CRDs and generates a combined rules file for the Ironic conductor.

## Overview

The InspectionRule CRD allows you to define hardware inspection rules as Kubernetes resources, making them:
- Version controlled alongside your infrastructure code
- Easily manageable with standard Kubernetes tools (kubectl, GitOps, etc.)
- Automatically synchronized to the Ironic conductor

The controller watches for changes to InspectionRule resources and maintains a combined YAML file that Ironic conductor reads to process inspection data.

## Components

### 1. Custom Resource Definition (CRD)

**File:** `inspectionrule-crd.yaml`

Defines the `InspectionRule` custom resource with full support for:
- Conditions (with operators like eq, lt, gt, contains, matches, etc.)
- Actions (set-attribute, add-trait, fail, etc.)
- Priority-based rule ordering
- Multiple inspection phases
- Loop constructs for processing arrays
- Sensitive data handling

### 2. Controller

**File:** `inspection_rules_controller.py`

A Python-based Kubernetes controller that:
- Watches InspectionRule CRDs in Kubernetes
- Converts CRDs to Ironic's inspection rule format
- Writes a combined rules file to disk atomically
- Updates CRD status to reflect sync state
- Performs periodic full syncs for resilience

### 3. Deployment Manifests

**File:** `deployment.yaml`

Kubernetes resources for deploying the controller:
- ServiceAccount with minimal required permissions
- ClusterRole and ClusterRoleBinding for RBAC
- ConfigMap for configuration
- Deployment for the controller
- Optional PersistentVolumeClaim for sharing rules with Ironic

## Installation

### Prerequisites

- Kubernetes cluster (1.19+)
- `kubectl` configured to access your cluster
- Docker (if building the controller image)

### Step 1: Install the CRD

```bash
kubectl apply -f inspectionrule-crd.yaml
```

Verify the CRD is installed:

```bash
kubectl get crds inspectionrules.ironic.openstack.org
```

### Step 2: Build and Push the Controller Image

```bash
# Build the image
docker build -t ironic/inspection-rules-controller:latest .

# Push to your registry (adjust as needed)
docker tag ironic/inspection-rules-controller:latest your-registry/inspection-rules-controller:latest
docker push your-registry/inspection-rules-controller:latest
```

Update the image reference in `deployment.yaml` if using a custom registry.

### Step 3: Deploy the Controller

```bash
kubectl apply -f deployment.yaml
```

Verify the controller is running:

```bash
kubectl get pods -l app=inspection-rules-controller
kubectl logs -l app=inspection-rules-controller -f
```

## Usage

### Creating an InspectionRule

Create a YAML file with your inspection rule:

```yaml
apiVersion: ironic.openstack.org/v1
kind: InspectionRule
metadata:
  name: my-custom-rule
  namespace: default
spec:
  description: "My custom inspection rule"
  priority: 100
  phase: main
  conditions:
  - op: eq
    args:
      field: inventory/cpu/architecture
      value: x86_64
  actions:
  - op: set-attribute
    args:
      path: properties/cpu_arch
      value: "{inventory[cpu][architecture]}"
```

Apply it to your cluster:

```bash
kubectl apply -f my-rule.yaml
```

### Viewing InspectionRules

List all rules:

```bash
kubectl get inspectionrules
# or use the short name
kubectl get ir
```

Get detailed information:

```bash
kubectl describe inspectionrule my-custom-rule
```

View the generated rules file (from controller pod):

```bash
kubectl exec -it deployment/inspection-rules-controller -- cat /etc/ironic/inspection_rules.yaml
```

### Updating an InspectionRule

Edit the rule:

```bash
kubectl edit inspectionrule my-custom-rule
```

Or apply an updated YAML file:

```bash
kubectl apply -f my-updated-rule.yaml
```

The controller will automatically detect changes and regenerate the rules file.

### Deleting an InspectionRule

```bash
kubectl delete inspectionrule my-custom-rule
```

The controller will remove the rule from the combined rules file.

## Rule Specification

### Spec Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `uuid` | string | No | UUID for the rule (auto-generated if not provided) |
| `description` | string | No | Human-readable description (max 255 chars) |
| `priority` | integer | No | Priority (0-9999, higher = evaluated first, default: 0) |
| `phase` | string | No | Inspection phase (currently only 'main' supported) |
| `sensitive` | boolean | No | Whether rule handles sensitive data (default: false) |
| `scope` | string | No | Optional scope for rule application |
| `conditions` | array | No | Conditions that must be met for actions to execute |
| `actions` | array | Yes | Actions to perform when conditions are met |

### Condition Operators

Conditions support the following operators (prefix with `!` for negation):

- `eq` - Equal to
- `lt` - Less than
- `gt` - Greater than
- `is-empty` - Field is empty
- `in-net` - IP address is in network
- `matches` - Regex match
- `contains` - Contains value
- `one-of` - Value is one of list
- `is-none` - Field is None/null
- `is-true` - Field is true
- `is-false` - Field is false

### Action Operators

Actions support the following operators:

- `set-attribute` - Set a node attribute
- `set-capability` - Set a node capability
- `unset-capability` - Remove a node capability
- `extend-attribute` - Extend an array/dict attribute
- `add-trait` - Add a trait to the node
- `remove-trait` - Remove a trait from the node
- `set-plugin-data` - Set plugin data
- `extend-plugin-data` - Extend plugin data
- `unset-plugin-data` - Remove plugin data
- `log` - Log a message
- `del-attribute` - Delete an attribute
- `set-port-attribute` - Set port attribute
- `extend-port-attribute` - Extend port attribute
- `del-port-attribute` - Delete port attribute
- `api-call` - Make an API call
- `fail` - Fail the inspection

### Variable Interpolation

Rules support variable interpolation using Python format strings:

- `{node[field]}` - Access node fields
- `{inventory[field]}` - Access inventory data
- `{plugin_data[field]}` - Access plugin data
- `{item[field]}` - Access current loop item (in loop contexts)

Example:

```yaml
actions:
- op: set-attribute
  args:
    path: properties/memory_mb
    value: "{inventory[memory][physical_mb]}"
```

### Loop Constructs

Both conditions and actions support loops for processing arrays:

```yaml
conditions:
- op: contains
  args:
    field: "{item[name]}"
    value: "eth"
  loop: "{inventory[interfaces]}"
  multiple: any  # any, all, first, last
```

## Examples

See `example-inspectionrule.yaml` for various usage patterns including:
- Setting node properties from inventory
- Configuring BMC addresses
- Adding traits based on hardware capabilities
- Failing inspection on specific conditions
- Using loops to process arrays

## Configuration

### Controller Arguments

The controller accepts the following command-line arguments:

| Argument | Default | Description |
|----------|---------|-------------|
| `--namespace` | all namespaces | Kubernetes namespace to watch |
| `--output-path` | `/etc/ironic/inspection_rules.yaml` | Path to write rules file |
| `--sync-interval` | 30 | Interval in seconds for periodic syncs |
| `--log-level` | INFO | Logging level (DEBUG, INFO, WARNING, ERROR) |
| `--one-shot` | false | Perform single sync and exit (for testing) |

### Environment Variables

When using the deployment manifest, configure via the ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: inspection-rules-controller-config
data:
  NAMESPACE: "default"
  OUTPUT_PATH: "/etc/ironic/inspection_rules.yaml"
  SYNC_INTERVAL: "30"
  LOG_LEVEL: "INFO"
```

## Integration with Ironic Conductor

To use the generated rules file with Ironic conductor:

### Option 1: Shared Volume

Use a PersistentVolumeClaim with `ReadWriteMany` access mode to share the rules file between the controller and Ironic conductor pods:

```yaml
volumes:
- name: rules-output
  persistentVolumeClaim:
    claimName: ironic-inspection-rules
```

Mount this volume in both the controller and conductor pods.

### Option 2: ConfigMap Sync

Use a sidecar or init container to copy the rules file to a ConfigMap that the conductor can mount.

### Option 3: File Sync

If running on the same node, use a hostPath volume or external file sync mechanism.

### Ironic Configuration

Configure Ironic to use the rules file by setting in `ironic.conf`:

```ini
[inspection_rules]
built_in_rules = /etc/ironic/inspection_rules.yaml
```

## Monitoring and Troubleshooting

### Check Controller Logs

```bash
kubectl logs -l app=inspection-rules-controller -f
```

### Check Rule Status

```bash
kubectl get inspectionrule my-rule -o jsonpath='{.status}'
```

The status will show:
- `state`: Active, Error, or Pending
- `lastSyncTime`: When the rule was last synced
- `message`: Any error or status messages

### Validate Rule Syntax

Use the `--one-shot` mode to test rule generation:

```bash
kubectl run test-controller --rm -it --restart=Never \
  --image=ironic/inspection-rules-controller:latest \
  -- --one-shot --namespace=default --log-level=DEBUG
```

### Common Issues

**Issue:** Rules not appearing in output file
- Check controller logs for errors
- Verify RBAC permissions are correct
- Ensure the CRD is properly installed

**Issue:** Rule validation errors
- Check the rule status: `kubectl describe inspectionrule <name>`
- Verify operator names match supported operators
- Ensure required fields (actions) are present

**Issue:** Controller not starting
- Check if CRD is installed: `kubectl get crd inspectionrules.ironic.openstack.org`
- Verify ServiceAccount and RBAC are created
- Check pod logs for initialization errors

## Development

### Running Locally

For development, you can run the controller locally:

```bash
# Install dependencies
pip install -r requirements.txt

# Run controller (uses your kubeconfig)
python3 inspection_rules_controller.py \
  --namespace=default \
  --output-path=/tmp/inspection_rules.yaml \
  --log-level=DEBUG
```

### Testing

Test with the `--one-shot` flag to perform a single sync:

```bash
python3 inspection_rules_controller.py \
  --one-shot \
  --namespace=default \
  --output-path=/tmp/test_rules.yaml
```

## Architecture

```
┌─────────────────────────────────────────┐
│          Kubernetes API Server          │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │   InspectionRule CRD Resources    │  │
│  └───────────────────────────────────┘  │
└─────────────────┬───────────────────────┘
                  │
                  │ Watch/List
                  │
                  ▼
┌─────────────────────────────────────────┐
│   InspectionRule Controller (Pod)       │
│                                         │
│  - Watches InspectionRule CRDs          │
│  - Converts to Ironic format            │
│  - Generates combined rules file        │
│  - Updates CRD status                   │
└─────────────────┬───────────────────────┘
                  │
                  │ Writes to
                  │ Shared Volume
                  ▼
┌─────────────────────────────────────────┐
│     /etc/ironic/inspection_rules.yaml   │
│                                         │
│  Combined rules file (YAML)             │
└─────────────────┬───────────────────────┘
                  │
                  │ Reads from
                  │
                  ▼
┌─────────────────────────────────────────┐
│         Ironic Conductor                │
│                                         │
│  - Processes hardware inspections       │
│  - Applies rules to inspection data     │
│  - Updates node properties/traits       │
└─────────────────────────────────────────┘
```

## Contributing

When contributing new features or bug fixes:

1. Ensure changes are backward compatible with existing rules
2. Update the CRD schema if adding new fields
3. Add validation in the controller for new operators
4. Update documentation and examples
5. Test thoroughly with various rule configurations

## License

Licensed under the Apache License, Version 2.0. See the LICENSE file for details.

## Support

For issues and questions:
- File issues in the Ironic project issue tracker
- Join the OpenStack Ironic IRC channel: #openstack-ironic
- Mailing list: openstack-discuss@lists.openstack.org

## References

- [Ironic Documentation](https://docs.openstack.org/ironic/latest/)
- [Inspection Rules Documentation](https://docs.openstack.org/ironic/latest/admin/inspection.html)
- [Kubernetes Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
