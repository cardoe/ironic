# Inspection Rules Test Cases

Each subdirectory here is an independent test case run by the inspection rules
tester. To add a test case, create a new directory and populate it with the
required files and an optional validation file:

| File | Required | Description |
|------|----------|-------------|
| `node.yaml` or `node.json` | Yes | Baremetal node data |
| `inventory.yaml` or `inventory.json` | Yes | Hardware inventory and plugin data |
| `rules.yaml` | Yes | Inspection rules to evaluate |
| `expected.yaml` | No | Expected outcomes for validation |

## Capturing data from a real node

```bash
# Capture node data
openstack baremetal node show <node-id> -f yaml > node.yaml

# Capture hardware inventory
openstack baremetal node inventory save --file inventory.json <node-id>
```

## Validating expected outcomes

Add an `expected.yaml` to assert what should happen when the rules run.
All fields are optional — include only what you want to verify.

```yaml
# Total number of rules that should match
matched_rules: 2

# Total number of action execution errors expected (usually 0)
errors: 0

# Per-rule match assertions, identified by uuid or description
rules:
  - uuid: "abc-123"
    matched: true
  - description: "Set IPMI credentials"
    matched: false

# Node attribute assertions after all matched rules have been applied.
# Only the listed keys are checked (partial matching); other attributes
# on the node are ignored.
node:
  name: "rack3-slot7"
  driver_info:
    ipmi_address: "192.168.1.10"
```

Node assertions use partial matching, so a test only needs to declare the
attributes it cares about. Nested dicts are matched recursively — any key
present in `expected.yaml` must be present with the same value on the node,
but extra keys on the node are not an error.

## Running the tests

```bash
tox -e inspection-rules
```

Or invoke the tester directly against a single test case:

```bash
python tools/inspection_rules/tester.py \
    <test-dir>/node.yaml \
    <test-dir>/inventory.json \
    <test-dir>/rules.yaml \
    --expected <test-dir>/expected.yaml
```
