# Quick Start Guide

This guide will help you get started with Ironic InspectionRule CRDs in under 5 minutes.

## Prerequisites

- A Kubernetes cluster (kind, minikube, or production cluster)
- `kubectl` configured and connected to your cluster
- Docker (only if building the image yourself)

## Step 1: Install the CRD

```bash
kubectl apply -f inspectionrule-crd.yaml
```

Verify installation:

```bash
$ kubectl get crds | grep inspection
inspectionrules.ironic.openstack.org   2024-01-13T10:30:00Z
```

## Step 2: Deploy the Controller

If using the pre-built image:

```bash
kubectl apply -f deployment.yaml
```

If building from source:

```bash
make build
make deploy
```

## Step 3: Verify the Controller is Running

```bash
$ kubectl get pods -l app=inspection-rules-controller
NAME                                            READY   STATUS    RESTARTS   AGE
inspection-rules-controller-7d8f9b5c4d-x9z2k    1/1     Running   0          30s
```

Check the logs:

```bash
kubectl logs -l app=inspection-rules-controller -f
```

You should see output like:

```
2024-01-13 10:31:00,123 - __main__ - INFO - Loaded in-cluster Kubernetes configuration
2024-01-13 10:31:00,456 - __main__ - INFO - Starting full sync of inspection rules
2024-01-13 10:31:00,789 - __main__ - INFO - Successfully wrote 0 rules to /etc/ironic/inspection_rules.yaml
2024-01-13 10:31:00,790 - __main__ - INFO - Full sync completed successfully
2024-01-13 10:31:00,791 - __main__ - INFO - Starting watch on InspectionRule resources in default
```

## Step 4: Create Your First InspectionRule

Create a file named `my-first-rule.yaml`:

```yaml
apiVersion: ironic.openstack.org/v1
kind: InspectionRule
metadata:
  name: set-cpu-architecture
  namespace: default
spec:
  description: "Set CPU architecture from inspection data"
  priority: 100
  phase: main
  conditions:
  - op: "!is-empty"
    args:
      field: inventory/cpu/architecture
  actions:
  - op: set-attribute
    args:
      path: properties/cpu_arch
      value: "{inventory[cpu][architecture]}"
  - op: log
    args:
      message: "Set CPU architecture to {inventory[cpu][architecture]} for node {node[uuid]}"
```

Apply it:

```bash
kubectl apply -f my-first-rule.yaml
```

## Step 5: Verify the Rule Was Created

List all inspection rules:

```bash
$ kubectl get inspectionrules
NAME                    PRIORITY   PHASE   DESCRIPTION                                AGE
set-cpu-architecture    100        main    Set CPU architecture from inspection data  10s
```

Get detailed information:

```bash
kubectl describe inspectionrule set-cpu-architecture
```

Check that the controller picked it up:

```bash
kubectl logs -l app=inspection-rules-controller --tail=20
```

You should see:

```
2024-01-13 10:35:00,123 - __main__ - INFO - Received ADDED event for InspectionRule default/set-cpu-architecture
2024-01-13 10:35:00,456 - __main__ - INFO - Starting full sync of inspection rules
2024-01-13 10:35:00,789 - __main__ - INFO - Successfully wrote 1 rules to /etc/ironic/inspection_rules.yaml
```

## Step 6: View the Generated Rules File

```bash
kubectl exec -it deployment/inspection-rules-controller -- cat /etc/ironic/inspection_rules.yaml
```

You should see your rule in YAML format:

```yaml
- uuid: <generated-uuid>
  priority: 100
  phase: main
  actions:
  - op: set-attribute
    args:
      path: properties/cpu_arch
      value: '{inventory[cpu][architecture]}'
  - op: log
    args:
      message: 'Set CPU architecture to {inventory[cpu][architecture]} for node {node[uuid]}'
  description: Set CPU architecture from inspection data
  conditions:
  - op: '!is-empty'
    args:
      field: inventory/cpu/architecture
```

## Step 7: Try the Examples

Install the example rules:

```bash
kubectl apply -f example-inspectionrule.yaml
```

This will create several example rules demonstrating different features:
- Setting basic properties
- Configuring BMC addresses
- Adding traits based on hardware
- Failing inspection on specific conditions
- Using loops to process arrays

List all rules:

```bash
$ kubectl get ir
NAME                       PRIORITY   PHASE   DESCRIPTION
add-sriov-trait           150        main    Add SR-IOV trait if network devices support it
configure-disk-wwn        50         main    Set disk WWN for all disks in inventory
minimum-memory-check      500        main    Fail inspection if node has less than 8GB RAM
set-basic-properties      100        main    Set basic node properties from inspection data
set-bmc-address          200        main    Configure BMC driver info from discovered BMC address
set-cpu-architecture      100        main    Set CPU architecture from inspection data
```

## Step 8: Modify a Rule

Edit a rule directly:

```bash
kubectl edit inspectionrule set-cpu-architecture
```

Or update your YAML file and reapply:

```bash
kubectl apply -f my-first-rule.yaml
```

The controller will automatically detect the change and regenerate the rules file.

## Step 9: Integrate with Ironic Conductor

To use these rules with Ironic conductor, you need to share the generated rules file.

### Option A: Using a Shared Volume

1. Create a PersistentVolumeClaim (already in `deployment.yaml`):

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ironic-inspection-rules
  namespace: default
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 100Mi
EOF
```

2. Update the controller deployment to use this PVC (uncomment in `deployment.yaml`)

3. Mount the same PVC in your Ironic conductor pod

4. Configure Ironic to use the rules file in `ironic.conf`:

```ini
[inspection_rules]
built_in_rules = /etc/ironic/inspection_rules.yaml
```

### Option B: Using ConfigMap (for small deployments)

Create a script to sync the rules to a ConfigMap:

```bash
#!/bin/bash
RULES=$(kubectl exec deployment/inspection-rules-controller -- cat /etc/ironic/inspection_rules.yaml)
kubectl create configmap ironic-inspection-rules --from-literal=rules.yaml="$RULES" --dry-run=client -o yaml | kubectl apply -f -
```

Mount this ConfigMap in your Ironic conductor.

## Step 10: Monitor and Troubleshoot

Watch the controller logs:

```bash
kubectl logs -l app=inspection-rules-controller -f
```

Check rule status:

```bash
kubectl get inspectionrule set-cpu-architecture -o jsonpath='{.status}' | jq
```

Test locally (outside of Kubernetes):

```bash
make test-oneshot
```

## Next Steps

- Read the full [README.md](README.md) for detailed documentation
- Explore the [example-inspectionrule.yaml](example-inspectionrule.yaml) for more complex patterns
- Check the [Ironic inspection documentation](https://docs.openstack.org/ironic/latest/admin/inspection.html)
- Set up GitOps to manage your InspectionRules declaratively

## Clean Up

To remove everything:

```bash
# Delete example rules
kubectl delete -f example-inspectionrule.yaml

# Delete your custom rule
kubectl delete inspectionrule set-cpu-architecture

# Remove the controller
kubectl delete -f deployment.yaml

# Remove the CRD (this will delete all InspectionRule resources!)
kubectl delete -f inspectionrule-crd.yaml
```

Or use the Makefile:

```bash
make teardown
```

## Troubleshooting

### Controller won't start

Check RBAC permissions:

```bash
kubectl get serviceaccount inspection-rules-controller
kubectl get clusterrole inspection-rules-controller
kubectl get clusterrolebinding inspection-rules-controller
```

### Rules not syncing

Check controller logs:

```bash
kubectl logs -l app=inspection-rules-controller --tail=50
```

Verify the CRD is installed:

```bash
kubectl get crd inspectionrules.ironic.openstack.org
```

### Rule validation errors

Describe the rule to see status:

```bash
kubectl describe inspectionrule <name>
```

Look for the status section showing any errors.

## Getting Help

- GitHub Issues: File an issue in the Ironic repository
- IRC: #openstack-ironic on OFTC
- Mailing list: openstack-discuss@lists.openstack.org
