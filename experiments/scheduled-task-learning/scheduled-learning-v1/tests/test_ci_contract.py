import json
import re
import unittest
from collections import Counter
from pathlib import Path
from typing import NamedTuple

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
ENTRY_PATTERN = re.compile(
    r"^(?P<indent>[ ]*)(?P<sequence>-[ ]+)?"
    r"(?P<key>\"(?:\\.|[^\"\\])*\"|'(?:''|[^'])*'|[A-Za-z][A-Za-z0-9-]*)"
    r"[ \t]*:[ \t]*(?P<value>.*)$"
)
QUOTED_SCALAR_PATTERN = re.compile(r'^("(?:\\.|[^"\\])*"|\'(?:\'\'|[^\'])*\')(.*)$')
SECRET_REFERENCE_PATTERN = re.compile(r"\$\{\{\s*secrets\.")


class _ScalarEntry(NamedTuple):
    indent: int
    sequence_item: bool
    key: str
    value: str | None


def _scalar_entries(workflow: str) -> list[_ScalarEntry]:
    entries: list[_ScalarEntry] = []
    for line in workflow.splitlines():
        match = ENTRY_PATTERN.fullmatch(line)
        if match is None:
            continue
        key = _scalar(match.group("key"))
        if key is None:
            continue
        entries.append(
            _ScalarEntry(
                indent=len(match.group("indent")),
                sequence_item=match.group("sequence") is not None,
                key=key,
                value=_scalar(match.group("value")),
            )
        )
    return entries


def _scalar(raw: str) -> str | None:
    stripped = raw.strip()
    if not stripped:
        return None
    quoted = QUOTED_SCALAR_PATTERN.fullmatch(stripped)
    if quoted is not None:
        token, trailing = quoted.groups()
        if trailing and (not trailing[0].isspace() or not trailing.lstrip().startswith("#")):
            return None
        if token.startswith('"'):
            decoded = json.loads(token)
            return decoded if isinstance(decoded, str) else None
        return token[1:-1].replace("''", "'")
    comment = re.search(r"[ \t]+#", stripped)
    value = stripped[: comment.start()] if comment is not None else stripped
    return value.rstrip() or None


def _sequence_groups(entries: list[_ScalarEntry]) -> list[list[_ScalarEntry]]:
    groups: list[list[_ScalarEntry]] = []
    index = 0
    while index < len(entries):
        first = entries[index]
        if not first.sequence_item:
            index += 1
            continue
        group = [first]
        index += 1
        while index < len(entries):
            candidate = entries[index]
            if candidate.indent < first.indent or (
                candidate.sequence_item and candidate.indent == first.indent
            ):
                break
            group.append(candidate)
            index += 1
        groups.append(group)
    return groups


def _entry_paths(group: list[_ScalarEntry]) -> list[tuple[tuple[str, ...], _ScalarEntry]]:
    parents: list[tuple[int, str]] = []
    paths: list[tuple[tuple[str, ...], _ScalarEntry]] = []
    for entry in group:
        mapping_indent = entry.indent + (2 if entry.sequence_item else 0)
        while parents and parents[-1][0] >= mapping_indent:
            parents.pop()
        path = (*[key for _, key in parents], entry.key)
        paths.append((path, entry))
        if entry.value is None:
            parents.append((mapping_indent, entry.key))
    return paths


def _checkout_credentials_are_disabled(entries: list[_ScalarEntry]) -> bool:
    checkout_groups = []
    for group in _sequence_groups(entries):
        paths = _entry_paths(group)
        if any(path == ("uses",) and entry.value == "actions/checkout@v7" for path, entry in paths):
            checkout_groups.append(paths)
    if len(checkout_groups) != EXPECTED_CHECKOUTS:
        return False
    for paths in checkout_groups:
        settings = [entry.value for path, entry in paths if path == ("with", "persist-credentials")]
        if settings != ["false"]:
            return False
    all_settings = [entry for entry in entries if entry.key == "persist-credentials"]
    return len(all_settings) == EXPECTED_CHECKOUTS and all(
        entry.value == "false" for entry in all_settings
    )


def _workflow_satisfies_contract(workflow: str) -> bool:
    entries = _scalar_entries(workflow)
    actual_steps = Counter(
        entry.value for entry in entries if entry.key in {"uses", "run"} and entry.value is not None
    )
    return (
        actual_steps == EXPECTED_STEPS
        and all(entry.key != "env" for entry in entries)
        and SECRET_REFERENCE_PATTERN.search(workflow) is None
        and _checkout_credentials_are_disabled(entries)
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
        rejected_mutations = {
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
