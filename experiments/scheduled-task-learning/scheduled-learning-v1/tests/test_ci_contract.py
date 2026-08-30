import re
import unittest
from collections import Counter
from pathlib import Path
from typing import cast

import yaml

EXPECTED_STEPS = Counter(
    {
        "actions/checkout@v7": 2,
        "astral-sh/setup-uv@v10.0.1": 2,
        "scripts/lint.sh": 1,
        "scripts/test.sh": 1,
        "uv run python -B -m scheduled_learning_v1.conformance .": 1,
    }
)
EXPECTED_CHECKOUTS = 2
EXPECTED_JOBS = {"lint", "test"}
SUPPORTED_JOB_KEYS = {"runs-on", "steps", "timeout-minutes"}
SUPPORTED_STEP_KEYS = {"name", "run", "uses", "with"}
SECRET_CONTEXT_PATTERN = re.compile(
    r"\$\{\{(?:(?!\}\}).)*\bsecrets\b(?:(?!\}\}).)*\}\}",
    re.DOTALL,
)


def _mapping(value: object) -> dict[object, object] | None:
    if not isinstance(value, dict):
        return None
    return cast(dict[object, object], value)


def _sequence(value: object) -> list[object] | None:
    if not isinstance(value, list):
        return None
    return cast(list[object], value)


def _contains_forbidden_data(value: object) -> bool:
    if isinstance(value, str):
        return SECRET_CONTEXT_PATTERN.search(value) is not None
    mapping = _mapping(value)
    if mapping is not None:
        return any(
            key == "env" or _contains_forbidden_data(key) or _contains_forbidden_data(child)
            for key, child in mapping.items()
        )
    sequence = _sequence(value)
    return sequence is not None and any(_contains_forbidden_data(child) for child in sequence)


def _values_for_key(value: object, expected_key: str) -> list[object]:
    mapping = _mapping(value)
    if mapping is not None:
        values = [child for key, child in mapping.items() if key == expected_key]
        for key, child in mapping.items():
            values.extend(_values_for_key(key, expected_key))
            values.extend(_values_for_key(child, expected_key))
        return values
    sequence = _sequence(value)
    if sequence is None:
        return []
    values = []
    for child in sequence:
        values.extend(_values_for_key(child, expected_key))
    return values


def _workflow_steps(document: object) -> list[dict[object, object]] | None:
    root = _mapping(document)
    if root is None or _contains_forbidden_data(root):
        return None
    jobs = _mapping(root.get("jobs"))
    if jobs is None or set(jobs) != EXPECTED_JOBS:
        return None

    steps: list[dict[object, object]] = []
    for job_name in sorted(EXPECTED_JOBS):
        job = _mapping(jobs.get(job_name))
        if job is None or not set(job).issubset(SUPPORTED_JOB_KEYS):
            return None
        job_steps = _sequence(job.get("steps"))
        if job_steps is None:
            return None
        for value in job_steps:
            step = _mapping(value)
            if step is None or not set(step).issubset(SUPPORTED_STEP_KEYS):
                return None
            if "with" in step and _mapping(step["with"]) is None:
                return None
            steps.append(step)
    return steps


def _executable_steps(steps: list[dict[object, object]]) -> list[str] | None:
    executables: list[str] = []
    for step in steps:
        executable_keys = [key for key in ("uses", "run") if key in step]
        if len(executable_keys) != 1:
            return None
        value = step[executable_keys[0]]
        if not isinstance(value, str):
            return None
        executables.append(value)
    return executables


def _is_false_input(value: object) -> bool:
    return value is False or (isinstance(value, str) and value == "false")


def _checkout_credentials_are_disabled(
    document: object,
    steps: list[dict[object, object]],
) -> bool:
    checkout_steps = [step for step in steps if step.get("uses") == "actions/checkout@v7"]
    if len(checkout_steps) != EXPECTED_CHECKOUTS:
        return False
    for step in checkout_steps:
        inputs = _mapping(step.get("with"))
        if inputs is None or not _is_false_input(inputs.get("persist-credentials")):
            return False
    settings = _values_for_key(document, "persist-credentials")
    return len(settings) == EXPECTED_CHECKOUTS and all(_is_false_input(value) for value in settings)


def _workflow_satisfies_contract(workflow: str) -> bool:
    try:
        document: object = yaml.safe_load(workflow)
    except yaml.YAMLError:
        return False
    steps = _workflow_steps(document)
    if steps is None:
        return False
    executables = _executable_steps(steps)
    return (
        executables is not None
        and Counter(executables) == EXPECTED_STEPS
        and _checkout_credentials_are_disabled(document, steps)
    )


class CIContractTests(unittest.TestCase):
    def test_workflow_runs_only_the_complete_offline_allowlist_without_credentials(self) -> None:
        # Given
        repository_root = Path(__file__).resolve().parents[4]
        workflow_path = repository_root / ".github/workflows/python-scheduled-learning-v1.yml"
        workflow = workflow_path.read_text(encoding="utf-8")
        alternate_scalar_syntax = (
            workflow.replace(
                "- uses: actions/checkout@v7",
                '- "uses" : "actions/checkout@v7" # trusted checkout',
            )
            .replace(
                "- uses: astral-sh/setup-uv@v10.0.1",
                "- 'uses' : 'astral-sh/setup-uv@v10.0.1' # pinned setup",
            )
            .replace("run: scripts/lint.sh", '"run" : "scripts/lint.sh" # offline lint')
            .replace("run: scripts/test.sh", "'run' : 'scripts/test.sh' # offline tests")
            .replace(
                "run: uv run python -B -m scheduled_learning_v1.conformance .",
                '"run" : "uv run python -B -m scheduled_learning_v1.conformance ." # offline',
            )
            .replace(
                "persist-credentials: false",
                '"persist-credentials" : "false" # checkout stays credential-free',
            )
        )
        named_checkout_syntax = workflow.replace(
            "      - uses: actions/checkout@v7\n        with:",
            "      - name: Checkout source\n        uses: actions/checkout@v7\n        with:",
        )
        nested_action_input_syntax = workflow.replace(
            '          version: "0.12.5"',
            '          version: "0.12.5"\n          run: metadata-not-a-command',
            1,
        )
        rejected_mutations = {
            "flow-map live run": workflow.replace(
                "      - name: Run replay conformance",
                "      - {run: uv run python -B -m scheduled_learning_v1.run scored --root .}\n"
                "      - name: Run replay conformance",
            ),
            "flow-map attacker action": workflow.replace(
                "      - name: Run scripts/lint.sh",
                "      - {uses: attacker/action@v1}\n      - name: Run scripts/lint.sh",
            ),
            "bracket secret reference": workflow.replace(
                "name: Python Scheduled Learning V1",
                "name: ${{ secrets['MODEL_TOKEN'] }}",
            ),
            "extra reusable-workflow job": workflow.replace(
                "jobs:\n",
                "jobs:\n  delegated:\n    uses: attacker/workflows/.github/workflows/live.yml@v1\n",
            ),
            "quoted env key": workflow.replace(
                "  test:\n",
                '  test:\n    "env" :\n      MODEL_TOKEN: placeholder\n',
            ),
            "compact secret reference": workflow.replace(
                "name: Python Scheduled Learning V1",
                "name: ${{secrets.TOKEN}}",
            ),
            "spaced secret reference": workflow.replace(
                "name: Python Scheduled Learning V1",
                "name: ${{  secrets.TOKEN }}",
            ),
            "missing checkout credential setting": workflow.replace(
                "        with:\n          persist-credentials: false\n",
                "",
                1,
            ),
            "enabled checkout credentials": workflow.replace(
                "persist-credentials: false",
                "persist-credentials: true",
                1,
            ),
            "checkout setting under wrong parent": workflow.replace(
                "        with:\n          persist-credentials: false",
                "        unrelated:\n          persist-credentials: false",
            ),
        }

        # When
        workflow_is_closed = _workflow_satisfies_contract(workflow)
        alternate_syntax_is_closed = _workflow_satisfies_contract(alternate_scalar_syntax)
        named_checkout_syntax_is_closed = _workflow_satisfies_contract(named_checkout_syntax)
        nested_action_input_syntax_is_closed = _workflow_satisfies_contract(
            nested_action_input_syntax
        )
        mutation_results = {
            label: _workflow_satisfies_contract(mutation)
            for label, mutation in rejected_mutations.items()
        }

        # Then
        self.assertTrue(workflow_is_closed)
        for label, accepted in mutation_results.items():
            with self.subTest(label):
                self.assertFalse(accepted)
        self.assertTrue(alternate_syntax_is_closed)
        self.assertTrue(named_checkout_syntax_is_closed)
        self.assertTrue(nested_action_input_syntax_is_closed)
