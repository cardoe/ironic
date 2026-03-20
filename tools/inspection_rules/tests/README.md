# Inspection Rules Test Cases

Each subdirectory here is an independent test case run by the inspection rules
tester. To add a test case, create a new directory and populate it with three
files:

| File | Description |
|------|-------------|
| `node.yaml` or `node.json` | Baremetal node data |
| `inventory.yaml` or `inventory.json` | Hardware inventory and plugin data |
| `rules.yaml` | Inspection rules to evaluate |

## Capturing data from a real node

```bash
# Capture node data
openstack baremetal node show <node-id> -f yaml > node.yaml

# Capture hardware inventory
openstack baremetal node inventory save --file inventory.json <node-id>
```

## Running the tests

```bash
tox -e inspection-rules
```

Or invoke the tester directly against a single test case:

```bash
python tools/inspection_rules/tester.py \
    <test-dir>/node.yaml \
    <test-dir>/inventory.json \
    <test-dir>/rules.yaml
```
