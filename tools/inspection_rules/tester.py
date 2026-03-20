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

"""Inspection Rules Tester - Test inspection rules against hardware inventory.

This tool runs the inspection rules evaluation process to help test and
debug inspection rules before deploying them to a production environment.
"""

import argparse
import json
import sys
import yaml

from ironic.common.inspection_rules import actions
from ironic.common.inspection_rules import engine

_MISSING = object()


class FakeNode:
    """Fake node built from 'openstack baremetal node show' output."""

    def __init__(self, data):
        for key, value in data.items():
            setattr(self, key, value)
        self._changes = []

    def save(self):
        pass


class FakeTask:
    """Minimal fake task object for testing."""

    def __init__(self, node):
        self.node = node
        self.context = None
        self.ports = []


class InspectionRulesEvaluator:
    """Evaluator for testing inspection rules against hardware inventory."""

    def __init__(
        self, node_file, inventory_file, rules_file,
        expected_file=None, json_output=False
    ):
        self.rules_file = rules_file
        self.inventory_file = inventory_file
        self.node_file = node_file
        self.expected_file = expected_file
        self.json_output = json_output
        self.rules = []
        self.inventory = {}
        self.plugin_data = {}
        self.node_data = {}
        self.node = None
        self.expected = {}
        self.results = []

    def _load_file(self, ftype, fname):
        """Load file and report errors."""
        try:
            with open(fname, "r") as f:
                return yaml.safe_load(f)
        except FileNotFoundError:
            raise Exception(f"{ftype} file not found: {fname}")
        except yaml.YAMLError as e:
            raise Exception(f"Error loading {ftype}: {e}")

    def load_rules(self):
        """Load and validate inspection rules from YAML file."""
        try:
            self.rules = engine.get_built_in_rules(self.rules_file)
        except FileNotFoundError:
            print(f"Rules file not found: {self.rules_file}", file=sys.stderr)
            return False
        except Exception as e:
            print(f"Error loading rules: {e}", file=sys.stderr)
            return False
        return True

    def load_inventory(self):
        """Load hardware inventory and plugin data from JSON or YAML file."""
        try:
            data = self._load_file("inventory", self.inventory_file)
        except Exception as e:
            print(f"{e}", file=sys.stderr)
            return False

        self.inventory = data.get("inventory", {})
        self.plugin_data = data.get("plugin_data", {})
        return True

    def load_node(self):
        """Load node data from YAML file."""
        try:
            self.node_data = self._load_file("node", self.node_file)
        except Exception as e:
            print(f"{e}", file=sys.stderr)
            return False
        return True

    def load_expected(self):
        """Load expected results from YAML file."""
        try:
            self.expected = self._load_file("expected", self.expected_file)
        except Exception as e:
            print(f"{e}", file=sys.stderr)
            return False
        if not isinstance(self.expected, dict):
            print("Expected file must be a YAML mapping", file=sys.stderr)
            return False
        return True

    def evaluate_rules(self):
        """Evaluate and apply inspection rules against the loaded inventory."""
        node = FakeNode(self.node_data)
        task = FakeTask(node)
        sorted_rules = sorted(
            self.rules, key=lambda r: r.get("priority", 0), reverse=True)
        self.results = [self._evaluate_single_rule(task, rule)
                        for rule in sorted_rules]
        self.node = node

    def _evaluate_single_rule(self, task, rule):
        """Evaluate and apply a single rule, returning a result dict."""
        result = {
            "uuid": rule.get("uuid"),
            "description": rule.get("description", "No description"),
            "priority": rule.get("priority", 0),
            "matched": False,
            "conditions": [],
            "actions": [],
            "errors": [],
        }

        try:
            check_result = engine._check_rule(
                task, rule, self.inventory, self.plugin_data)
        except Exception as e:
            result["errors"].append(str(e))
            return result

        if not rule.get("conditions"):
            result["matched"] = True
            masked_inventory, masked_plugin_data = (
                self.inventory, self.plugin_data)
        else:
            result["matched"] = check_result is not None
            masked_inventory, masked_plugin_data = (
                check_result if check_result is not None
                else (self.inventory, self.plugin_data))

            for idx, condition in enumerate(rule["conditions"], 1):
                entry = {"index": idx, "op": condition["op"],
                         "args": condition.get("args", {}), "passed": False}
                try:
                    entry["passed"] = engine.check_conditions(
                        task, {
                            "uuid": rule["uuid"],
                            "conditions": [condition]
                        },
                        masked_inventory, masked_plugin_data)
                except Exception as e:
                    result["errors"].append(str(e))
                result["conditions"].append(entry)

        if result["matched"]:
            for idx, action in enumerate(rule["actions"], 1):
                op = action["op"]
                entry = {"index": idx, "op": op,
                         "args": action.get("args", {})}
                try:
                    action_obj = actions.get_action(op)()
                    if action.get("loop"):
                        action_obj.execute_with_loop(
                            task, action, masked_inventory, masked_plugin_data)
                    else:
                        action_obj.execute_action(
                            task, action, masked_inventory, masked_plugin_data)
                except Exception as e:
                    result["errors"].append(str(e))
                result["actions"].append(entry)

        return result

    def _check_partial(self, expected, actual, path):
        """Recursively check that all expected keys/values are present."""
        failures = []
        if isinstance(expected, dict):
            if not isinstance(actual, dict):
                failures.append(
                    f"  {path}: expected a mapping, "
                    f"got {type(actual).__name__}")
                return failures
            for key, exp_val in expected.items():
                if key not in actual:
                    failures.append(
                        f"  {path}.{key}: expected {exp_val!r}, "
                        f"key not present")
                else:
                    failures.extend(
                        self._check_partial(
                            exp_val, actual[key], f"{path}.{key}"))
        else:
            if expected != actual:
                failures.append(
                    f"  {path}: expected {expected!r}, got {actual!r}")
        return failures

    def _find_rule_result(self, rule_exp):
        """Find a rule result by uuid or description."""
        if "uuid" in rule_exp:
            for r in self.results:
                if r["uuid"] == rule_exp["uuid"]:
                    return r
        if "description" in rule_exp:
            for r in self.results:
                if r["description"] == rule_exp["description"]:
                    return r
        return None

    def validate(self):
        """Validate results against expected.yaml.

        Returns a list of failure message strings; empty means all passed.
        """
        failures = []

        if "matched_rules" in self.expected:
            matched = sum(1 for r in self.results if r["matched"])
            exp = self.expected["matched_rules"]
            if matched != exp:
                failures.append(
                    f"matched_rules: expected {exp}, got {matched}")

        if "errors" in self.expected:
            errors = sum(len(r["errors"]) for r in self.results)
            exp = self.expected["errors"]
            if errors != exp:
                failures.append(f"errors: expected {exp}, got {errors}")

        for rule_exp in self.expected.get("rules", []):
            identifier = rule_exp.get(
                "uuid") or rule_exp.get("description", "<unknown>")
            rule_result = self._find_rule_result(rule_exp)
            if rule_result is None:
                failures.append(f"rule {identifier!r}: not found in results")
                continue
            if ("matched" in rule_exp
                    and rule_result["matched"] != rule_exp["matched"]):
                failures.append(
                    f"rule {identifier!r}: "
                    f"matched={rule_result['matched']}, "
                    f"expected {rule_exp['matched']}")

        for attr, exp_val in self.expected.get("node", {}).items():
            act_val = getattr(self.node, attr, _MISSING)
            if act_val is _MISSING:
                failures.append(
                    f"node.{attr}: expected {exp_val!r}, "
                    f"attribute not present")
            else:
                failures.extend(
                    self._check_partial(exp_val, act_val, f"node.{attr}"))

        return failures

    def print_results(self):
        """Print all results in human-readable form."""
        print(f"Node:        {self.node_file}")
        print(f"Inventory:   {self.inventory_file}")
        print(f"Rules file:  {self.rules_file}")
        print()

        for result in self.results:
            status = "[MATCH]" if result["matched"] else "[SKIP]"
            print(f"Rule: {result['description']} {status}")
            print(f"  UUID: {result['uuid']}, Priority: {result['priority']}")

            if result["errors"]:
                for err in result["errors"]:
                    print(f"  ERROR: {err}")
            elif not result["conditions"]:
                print("  Conditions: none (always matches)")
            else:
                for c in result["conditions"]:
                    cstatus = "PASSED" if c["passed"] else "FAILED"
                    print(f"  Condition {c['index']} [{c['op']}]: {cstatus}")

            for a in result["actions"]:
                print(f"  Action {a['index']} [{a['op']}]: {a['args']}")

            print()

        matched = sum(1 for r in self.results if r["matched"])
        total = len(self.results)
        errors = sum(len(r["errors"]) for r in self.results)
        summary = f"Summary: {matched}/{total} rules matched"
        if errors:
            summary += f", {errors} error(s)"
        print(summary)

    def output_json(self):
        """Output results in JSON format."""
        node_state = {
            k: v for k, v in vars(self.node).items()
            if not k.startswith("_")
        } if self.node else {}
        output = {
            "summary": {
                "total_rules": len(self.results),
                "matched_rules": sum(1 for r in self.results if r["matched"]),
                "total_errors": sum(len(r["errors"]) for r in self.results),
            },
            "rules": self.results,
            "node": node_state,
            "inventory": self.inventory,
            "plugin_data": self.plugin_data,
        }
        print(json.dumps(output, indent=2, default=str))

    def run(self):
        """Run the complete evaluation process."""
        if not self.load_rules():
            return 1
        if not self.load_inventory():
            return 1
        if not self.load_node():
            return 1
        if self.expected_file and not self.load_expected():
            return 1
        self.evaluate_rules()
        errors = sum(len(r["errors"]) for r in self.results)
        if self.json_output:
            self.output_json()
        else:
            self.print_results()
            if errors:
                return 1
        if self.expected_file:
            failures = self.validate()
            if failures:
                print("\nValidation FAILED:", file=sys.stderr)
                for msg in failures:
                    print(msg, file=sys.stderr)
                return 1
        return 0


def main():
    parser = argparse.ArgumentParser(
        prog="Inspection Rules Tester",
        description=(
            "Test inspection rules against hardware inventory data "
            "to see which rules match and what actions would be "
            "executed."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Capture node and inventory data then evaluate
  openstack baremetal node show <node-id> -f yaml > node.yaml
  openstack baremetal node inventory save --file inventory.json <node-id>
  %(prog)s node.yaml inventory.json rules.yaml

  # Validate results against expected outcomes
  %(prog)s node.yaml inventory.json rules.yaml --expected expected.yaml

  # JSON output for automation
  %(prog)s --json node.yaml inventory.json rules.yaml > results.json
        """,
    )

    parser.add_argument(
        "node_file",
        help="JSON or YAML file containing node data "
             "(e.g. from 'openstack baremetal node show <id> -f json')"
    )
    parser.add_argument(
        "inventory_file",
        help="JSON or YAML file containing hardware inventory and plugin data "
             "(e.g. from 'openstack baremetal node inventory save')"
    )
    parser.add_argument(
        "rules_file", help="YAML file containing inspection rules"
    )
    parser.add_argument(
        "--expected",
        metavar="FILE",
        help="YAML file describing expected outcomes; if provided, the tester "
             "validates results and exits non-zero on any mismatch"
    )
    parser.add_argument(
        "--json", action="store_true", help="Output results in JSON format"
    )

    args = parser.parse_args()

    evaluator = InspectionRulesEvaluator(
        args.node_file,
        args.inventory_file,
        args.rules_file,
        expected_file=args.expected,
        json_output=args.json,
    )

    return evaluator.run()


if __name__ == "__main__":
    sys.exit(main())
