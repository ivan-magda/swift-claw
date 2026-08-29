"""Closed M3 carrier construction: task, evaluator, and reflector inputs.

Depends on `fixtures.py` (frozen fresh fixture identity) and `validation.py`
(closed source/carrier shape) to construct carriers; neither of those modules
imports this one.
"""

from __future__ import annotations

import unicodedata
from typing import Any

from benchmark_core.canonical import canonical_sha256
from benchmark_core.contract_validation import ContractError, ValidationIssue

from .fixtures import ALL_FRESH_FIXTURE_IDS
from .validation import (
    REFLECTOR_EVALUATION_SUMMARY_KEYS,
    require_valid_source,
    validate_evaluator_carrier,
    validate_reflector_carrier,
    validate_task_carrier,
)

_SCHEMA_VERSION = 1
_RUN_ID_LENGTH = 32


def normalize_lesson_text(text: str) -> str:
    """Normalize one lesson string before it is carried or hashed.

    Unicode NFC plus CRLF/CR collapse and outer-whitespace trimming is an
    independent, from-scratch normalization for the page adapter boundary; it
    is not an import of, or a line-for-line port of, the generic reducer's own
    private candidate normalization.
    """

    return unicodedata.normalize("NFC", text).replace("\r\n", "\n").replace("\r", "\n").strip()


def materialize_task(source: dict[str, Any], lessons: list[str]) -> dict[str, Any]:
    """Build the closed task carrier for one clean/trial/active attempt.

    Validates the fresh source through the reused page validator first, then
    emits exactly `schema_version`, `task_id`, `task`, and `active_lessons`.
    `source["task"]` is preserved as the exact object, never stringified.
    """

    require_valid_source(source)
    if source.get("fixture_id") not in ALL_FRESH_FIXTURE_IDS:
        raise ContractError(
            (
                ValidationIssue(
                    "fixtures.frozen_split_membership",
                    "materialize_task only accepts the seven frozen fresh M3 fixtures",
                ),
            )
        )
    normalized_lessons = [normalize_lesson_text(text) for text in lessons]
    carrier = {
        "schema_version": _SCHEMA_VERSION,
        "task_id": source["task_id"],
        "task": source["task"],
        "active_lessons": {"schema_version": _SCHEMA_VERSION, "lessons": normalized_lessons},
    }
    issues = validate_task_carrier(carrier)
    if issues:
        raise ContractError(issues)
    return carrier


def _run_identity(task_id: str, output: str) -> dict[str, Any]:
    token = canonical_sha256({"task_id": task_id, "raw_output": output})[:_RUN_ID_LENGTH]
    return {"run_id": token}


def build_evaluator_carrier(task: dict[str, Any], output: str) -> dict[str, Any]:
    """Build the closed, tool-free evaluator carrier.

    Permits only task identity, task input, the raw output under evaluation,
    and a run identity derived from those two values; it drops the incoming
    task carrier's `active_lessons` and every trial/candidate/scoring field.
    """

    task_issues = validate_task_carrier(task)
    if task_issues:
        raise ContractError(task_issues)
    if not isinstance(output, str) or not output:
        raise ContractError(
            (ValidationIssue("schema.bounded_values", "$.raw_output must be a non-empty string"),)
        )
    carrier = {
        "schema_version": _SCHEMA_VERSION,
        "task_id": task["task_id"],
        "task": task["task"],
        "raw_output": output,
        "run": _run_identity(task["task_id"], output),
    }
    issues = validate_evaluator_carrier(carrier)
    if issues:
        raise ContractError(issues)
    return carrier


def _fence_untrusted(category: str, index: int, text: str) -> str:
    """Mark one untrusted text span so a prompt cannot mistake it for an instruction."""

    return f'<untrusted data="{category}" index="{index}">{text}</untrusted>'


def _blind_evaluation_summary(evaluation: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(evaluation, dict):
        raise ContractError(
            (ValidationIssue("schema.single_object", "$.evaluations[] must be an object"),)
        )
    missing = REFLECTOR_EVALUATION_SUMMARY_KEYS - evaluation.keys()
    if missing:
        raise ContractError(
            (
                ValidationIssue(
                    "schema.closed_properties",
                    f"$.evaluations[] missing keys: {sorted(missing)}",
                ),
            )
        )
    return {
        "task_id": evaluation["task_id"],
        "outcome": evaluation["outcome"],
        "issue_codes": list(evaluation["issue_codes"]),
    }


def build_reflector_carrier(
    stable_lessons: list[str],
    evaluations: list[dict[str, Any]],
    issue_codes: list[str],
    owner_payloads: list[str],
) -> dict[str, Any]:
    """Build the closed, tool-free reflector carrier.

    Permits only the current stable lesson strings, blind evaluation
    summaries (task identity, outcome, issue codes — no oracle, gold, score,
    or candidate/promotion state), qualifying exact issue codes, and bounded
    owner payloads. Every lesson and owner payload is independently fenced as
    untrusted data.
    """

    fenced_lessons = [
        _fence_untrusted("lesson", index, normalize_lesson_text(text))
        for index, text in enumerate(stable_lessons)
    ]
    evaluation_summaries = [_blind_evaluation_summary(evaluation) for evaluation in evaluations]
    fenced_owner_payloads = [
        _fence_untrusted("owner_payload", index, text) for index, text in enumerate(owner_payloads)
    ]
    carrier = {
        "schema_version": _SCHEMA_VERSION,
        "stable_lessons": fenced_lessons,
        "evaluations": evaluation_summaries,
        "issue_codes": list(issue_codes),
        "owner_payloads": fenced_owner_payloads,
    }
    issues = validate_reflector_carrier(carrier)
    if issues:
        raise ContractError(issues)
    return carrier
