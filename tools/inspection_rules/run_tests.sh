#!/bin/bash
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

# Run inspection rules tester against all test cases in tests/.
# Each subdirectory of tests/ must contain:
#   node.yaml or node.json       - baremetal node data
#   inventory.yaml or inventory.json - hardware inventory and plugin data
#   rules.yaml                   - inspection rules to evaluate
# Optionally:
#   expected.yaml                - expected outcomes for validation

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$SCRIPT_DIR/tests"
TESTER="$SCRIPT_DIR/tester.py"

PASS=0
FAIL=0
ERRORS=()

if [ ! -d "$TESTS_DIR" ]; then
    echo "No tests directory found at $TESTS_DIR"
    exit 0
fi

# Collect subdirectories; skip if none exist
shopt -s nullglob
test_dirs=("$TESTS_DIR"/*/)
shopt -u nullglob

if [ ${#test_dirs[@]} -eq 0 ]; then
    echo "No test cases found in $TESTS_DIR"
    exit 0
fi

for test_dir in "${test_dirs[@]}"; do
    test_name=$(basename "$test_dir")

    # Find node file
    if [ -f "$test_dir/node.yaml" ]; then
        node_file="$test_dir/node.yaml"
    elif [ -f "$test_dir/node.json" ]; then
        node_file="$test_dir/node.json"
    else
        echo "FAIL: $test_name - missing node.yaml or node.json"
        FAIL=$((FAIL + 1))
        ERRORS+=("$test_name")
        continue
    fi

    # Find inventory file
    if [ -f "$test_dir/inventory.yaml" ]; then
        inventory_file="$test_dir/inventory.yaml"
    elif [ -f "$test_dir/inventory.json" ]; then
        inventory_file="$test_dir/inventory.json"
    else
        echo "FAIL: $test_name - missing inventory.yaml or inventory.json"
        FAIL=$((FAIL + 1))
        ERRORS+=("$test_name")
        continue
    fi

    # Find rules file
    if [ -f "$test_dir/rules.yaml" ]; then
        rules_file="$test_dir/rules.yaml"
    else
        echo "FAIL: $test_name - missing rules.yaml"
        FAIL=$((FAIL + 1))
        ERRORS+=("$test_name")
        continue
    fi

    # Build tester command, optionally adding --expected
    tester_cmd=(python "$TESTER" "$node_file" "$inventory_file" "$rules_file")
    if [ -f "$test_dir/expected.yaml" ]; then
        tester_cmd+=(--expected "$test_dir/expected.yaml")
    fi

    echo "Running: $test_name"
    if "${tester_cmd[@]}"; then
        echo "PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $test_name"
        FAIL=$((FAIL + 1))
        ERRORS+=("$test_name")
    fi
    echo ""
done

echo "Results: $PASS passed, $FAIL failed"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "Failed tests:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    exit 1
fi

exit 0
