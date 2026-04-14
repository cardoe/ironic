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

"""ironic-sim - Ironic simulator and testing tools.

Subcommands:
  rules   Test inspection rules against hardware inventory data.
"""

import argparse
import json
import sys
import yaml

import operator as _operator

from ironic.common.inspection_rules import actions
from ironic.common.inspection_rules import engine


def _get_nested(obj, path):
    """Navigate a dot-separated path in a nested dict/list.

    List elements may be addressed by integer index, e.g. "rules.0.matched".
    Returns None if any key is missing.
    """
    current = obj
    for part in path.split("."):
        if current is None:
            return None
        if isinstance(current, dict):
            current = current.get(part)
        elif isinstance(current, list):
            try:
                current = current[int(part)]
            except (ValueError, IndexError):
                return None
        else:
            return None
    return current


# Path validation operators use stdlib operator module, keeping the validator
# independent from the inspection rules code being tested.
# operator.contains(a, b) evaluates b in a, so actual is the haystack.
_PATH_OPS = {
    "eq":           _operator.eq,
    "ne":           _operator.ne,
    "gt":           _operator.gt,
    "gte":          _operator.ge,
    "lt":           _operator.lt,
    "lte":          _operator.le,
    "contains":     _operator.contains,
    "not_contains": lambda a, b: not _operator.contains(a, b),
}


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


class InspectionRulesEvaluator:
    """Evaluator for testing inspection rules against hardware inventory."""

    def __init__(
        self, node_file, inventory_file, rules_file,
        json_output=False, validate_file=None
    ):
        self.rules_file = rules_file
        self.inventory_file = inventory_file
        self.node_file = node_file
        self.json_output = json_output
        self.validate_file = validate_file
        self.rules = []
        self.inventory = {}
        self.plugin_data = {}
        self.node_data = {}
        self.results = []
        self.validations = []
        self.validation_results = []

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

    def load_validations(self):
        """Load validation checks from YAML/JSON file."""
        try:
            data = self._load_file("validations", self.validate_file)
        except Exception as e:
            print(f"{e}", file=sys.stderr)
            return False
        if not isinstance(data, list):
            print(
                f"Validations file must contain a YAML/JSON list, "
                f"got {type(data).__name__}",
                file=sys.stderr,
            )
            return False
        self.validations = data
        return True

    def evaluate_rules(self):
        """Evaluate inspection rules against the loaded inventory."""
        node = FakeNode(self.node_data)
        task = FakeTask(node)
        sorted_rules = sorted(
            self.rules, key=lambda r: r.get("priority", 0), reverse=True)
        self.results = [self._evaluate_single_rule(task, rule)
                        for rule in sorted_rules]

    def _evaluate_single_rule(self, task, rule):
        """Evaluate a single rule and return a result dict."""
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
                try:
                    action_class = actions.get_action(action["op"])
                    action_obj = action_class()

                    loop_items = action.get("loop", [])
                    if isinstance(loop_items, dict):
                        processed_args = action_obj._process_args(
                            task, action, masked_inventory, masked_plugin_data,
                            {"item": loop_items})
                        result["actions"].append(
                            {"index": idx, "op": action["op"],
                             "args": processed_args, "loop_index": 1})
                    elif isinstance(loop_items, list) and loop_items:
                        for loop_index, item in enumerate(loop_items, 1):
                            processed_args = action_obj._process_args(
                                task, action, masked_inventory,
                                masked_plugin_data, {"item": item})
                            result["actions"].append(
                                {"index": idx, "op": action["op"],
                                 "args": processed_args,
                                 "loop_index": loop_index})
                    else:
                        processed_args = action_obj._process_args(
                            task, action, masked_inventory, masked_plugin_data)
                        result["actions"].append(
                            {"index": idx, "op": action["op"],
                             "args": processed_args})
                except Exception as e:
                    result["errors"].append(str(e))

        return result

    def _build_result_dict(self):
        """Build the full result dict used for validation."""
        return {
            "summary": {
                "total_rules": len(self.results),
                "matched_rules": sum(1 for r in self.results if r["matched"]),
                "total_errors": sum(len(r["errors"]) for r in self.results),
            },
            "rules": self.results,
            "inventory": self.inventory,
            "plugin_data": self.plugin_data,
            "node": self.node_data,
        }

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------

    def _run_one_validation(self, check, result_dict):
        """Run a single validation check.

        Returns a dict with keys: description, passed, message.
        """
        vtype = check.get("type")
        desc = check.get("description") or f"[{vtype}]"

        if vtype == "has_trait":
            return self._validate_has_trait(desc, check, result_dict)
        elif vtype == "rule_matched":
            return self._validate_rule_matched(desc, check, result_dict)
        elif vtype == "no_errors":
            return self._validate_no_errors(desc, result_dict)
        elif vtype == "path":
            return self._validate_path(desc, check, result_dict)
        else:
            return {
                "description": desc,
                "passed": False,
                "message": f"unknown validation type '{vtype}'",
            }

    def _validate_has_trait(self, desc, check, result_dict):
        trait = check.get("trait")
        if not trait:
            return {"description": desc, "passed": False,
                    "message": "missing required field 'trait'"}

        # Trait may already be present on the node before inspection.
        node_traits = result_dict.get("node", {}).get("traits") or []
        if trait in node_traits:
            return {"description": desc, "passed": True,
                    "message": f"trait '{trait}' present on node"}

        # Or a matched rule may add it via add-trait.
        for rule in result_dict.get("rules", []):
            if not rule.get("matched"):
                continue
            for action in rule.get("actions", []):
                if (action.get("op") == "add-trait"
                        and action.get("args", {}).get("name") == trait):
                    return {"description": desc, "passed": True,
                            "message": (
                                f"trait '{trait}' added by rule "
                                f"'{rule['description']}'")}

        return {"description": desc, "passed": False,
                "message": f"trait '{trait}' not found"}

    def _validate_rule_matched(self, desc, check, result_dict):
        rule_uuid = check.get("rule_uuid")
        rule_desc = check.get("rule_description")
        if not rule_uuid and not rule_desc:
            return {"description": desc, "passed": False,
                    "message": "requires 'rule_uuid' or 'rule_description'"}

        for rule in result_dict.get("rules", []):
            uuid_ok = (not rule_uuid or rule.get("uuid") == rule_uuid)
            desc_ok = (not rule_desc
                       or rule.get("description") == rule_desc)
            if uuid_ok and desc_ok and rule.get("matched"):
                return {"description": desc, "passed": True,
                        "message": (
                            f"rule '{rule['description']}' matched")}

        label = rule_uuid or rule_desc
        return {"description": desc, "passed": False,
                "message": f"rule '{label}' did not match"}

    def _validate_no_errors(self, desc, result_dict):
        total = result_dict["summary"]["total_errors"]
        if total == 0:
            return {"description": desc, "passed": True,
                    "message": "no evaluation errors"}
        return {"description": desc, "passed": False,
                "message": f"{total} evaluation error(s) found"}

    def _validate_path(self, desc, check, result_dict):
        path = check.get("path")
        op = check.get("op")
        value = check.get("value")

        if not path:
            return {"description": desc, "passed": False,
                    "message": "missing required field 'path'"}
        if op not in _PATH_OPS:
            return {"description": desc, "passed": False,
                    "message": (
                        f"unknown op '{op}', must be one of: "
                        + ", ".join(sorted(_PATH_OPS)))}

        actual = _get_nested(result_dict, path)
        try:
            passed = _PATH_OPS[op](actual, value)
        except TypeError as e:
            return {"description": desc, "passed": False,
                    "message": f"type error comparing '{path}': {e}"}

        if passed:
            return {"description": desc, "passed": True,
                    "message": f"{path} {op} {value!r} (got {actual!r})"}
        return {"description": desc, "passed": False,
                "message": (
                    f"{path} {op} {value!r} failed (got {actual!r})")}

    def run_validations(self, result_dict):
        """Run all loaded validations against result_dict."""
        self.validation_results = [
            self._run_one_validation(check, result_dict)
            for check in self.validations
        ]

    def print_validation_results(self):
        """Print validation results in human-readable form."""
        passed = sum(1 for v in self.validation_results if v["passed"])
        total = len(self.validation_results)
        print(f"\nValidations: {passed}/{total} passed")
        for v in self.validation_results:
            status = "[PASS]" if v["passed"] else "[FAIL]"
            print(f"  {status} {v['description']}: {v['message']}")

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

    def output_json(self, result_dict):
        """Output the full evaluation result in JSON format."""
        print(json.dumps(result_dict, indent=2, default=str))

    def run(self):
        """Run the complete evaluation process."""
        if not self.load_rules():
            return 1
        if not self.load_inventory():
            return 1
        if not self.load_node():
            return 1
        if self.validate_file and not self.load_validations():
            return 1
        self.evaluate_rules()

        result_dict = self._build_result_dict()

        validation_failures = 0
        if self.validate_file:
            self.run_validations(result_dict)
            validation_failures = sum(
                1 for v in self.validation_results if not v["passed"])

        eval_errors = sum(len(r["errors"]) for r in self.results)
        exit_code = 1 if (eval_errors or validation_failures) else 0

        if self.json_output:
            self.output_json(result_dict)
        else:
            self.print_results()
            if self.validate_file:
                self.print_validation_results()

        return exit_code


def _run_rules(args):
    evaluator = InspectionRulesEvaluator(
        args.node_file,
        args.inventory_file,
        args.rules_file,
        json_output=args.json,
        validate_file=args.validate,
    )
    return evaluator.run()


def _add_rules_subparser(subparsers):
    parser = subparsers.add_parser(
        "rules",
        help="test inspection rules against hardware inventory",
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

  # JSON output for scripting
  %(prog)s --json node.yaml inventory.json rules.yaml > results.json

  # Validate expected outcomes (exits non-zero on failure)
  %(prog)s node.yaml inventory.json rules.yaml --validate checks.yaml

Validation file format (YAML list):
  - description: "node gains CUSTOM_FOO trait"
    type: has_trait
    trait: CUSTOM_FOO

  - description: "arch rule matched"
    type: rule_matched
    rule_uuid: "abc-123-def"        # match by UUID
    rule_description: "Set arch"    # or by description (both optional)

  - description: "no evaluation errors"
    type: no_errors

  - description: "at least two rules matched"
    type: path
    path: "summary.matched_rules"
    op: gte    # eq ne gt gte lt lte contains not_contains
    value: 2
        """,
    )
    parser.add_argument(
        "node_file",
        help="JSON or YAML file containing node data "
             "(e.g. from 'openstack baremetal node show <id> -f json')",
    )
    parser.add_argument(
        "inventory_file",
        help="JSON or YAML file containing hardware inventory and plugin data "
             "(e.g. from 'openstack baremetal node inventory save')",
    )
    parser.add_argument(
        "rules_file",
        help="YAML file containing inspection rules",
    )
    parser.add_argument(
        "--json", action="store_true",
        help="output the full evaluation result in JSON format",
    )
    parser.add_argument(
        "--validate",
        metavar="FILE",
        help="YAML/JSON file containing a list of validation checks to run "
             "against the evaluation results; exits non-zero if any fail",
    )
    parser.set_defaults(func=_run_rules)


def main():
    parser = argparse.ArgumentParser(
        prog="ironic-sim",
        description="Ironic simulator and testing tools.",
    )
    subparsers = parser.add_subparsers(dest="command", metavar="<command>")
    subparsers.required = True

    _add_rules_subparser(subparsers)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
