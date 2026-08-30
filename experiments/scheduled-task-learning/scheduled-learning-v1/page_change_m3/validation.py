"""Closed source/carrier validation for the fresh M3 page adapter.

Wraps the reused `page_benchmark.validation.validate_source` boundary as a
library call and adds the M3-specific closed carrier shapes on top of it. It
never reimplements page-change's own source/gold validation.
"""

from __future__ import annotations

from typing import Any

from benchmark_core.contract_validation import (
    ContractError,
    ValidationIssue,
    bounded_list,
    bounded_string,
    exact_keys,
    is_integer,
    issue,
    require_valid,
)
from page_benchmark.validation import validate_source

__all__ = [
    "ACTIVE_LESSONS_KEYS",
    "EVALUATOR_CARRIER_KEYS",
    "EVALUATOR_RUN_KEYS",
    "REFLECTOR_CARRIER_KEYS",
    "REFLECTOR_EVALUATION_SUMMARY_KEYS",
    "TASK_CARRIER_KEYS",
    "ContractError",
    "ValidationIssue",
    "require_valid_source",
    "validate_active_lessons",
    "validate_evaluator_carrier",
    "validate_reflector_carrier",
    "validate_task_carrier",
]

_MAX_LESSONS = 3
_LESSON_TEXT_BOUNDS = (1, 4000)
_FENCED_TEXT_BOUNDS = (1, 4200)
_OPAQUE_TOKEN_BOUNDS = (1, 128)
_MAX_ISSUE_CODES = 32
_MAX_OWNER_PAYLOADS = 16
_MAX_EVALUATIONS = 8
_MAX_RAW_OUTPUT_LENGTH = 20000

TASK_KEYS = {"before_html", "after_html", "region_ids"}
TASK_CARRIER_KEYS = {"schema_version", "task_id", "task", "active_lessons"}
ACTIVE_LESSONS_KEYS = {"schema_version", "lessons"}
EVALUATOR_CARRIER_KEYS = {"schema_version", "task_id", "task", "raw_output", "run"}
EVALUATOR_RUN_KEYS = {"run_id"}
REFLECTOR_CARRIER_KEYS = {
    "schema_version",
    "stable_lessons",
    "evaluations",
    "issue_codes",
    "owner_payloads",
}
REFLECTOR_EVALUATION_SUMMARY_KEYS = {"task_id", "outcome", "issue_codes"}


def require_valid_source(source: Any) -> None:
    """Validate a fresh source strictly through the reused page validator."""

    require_valid(source, validate_source)


def _validate_task_input(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if exact_keys(value, TASK_KEYS, TASK_KEYS, path, issues):
        bounded_string(value.get("before_html"), 1, 30000, f"{path}.before_html", issues)
        bounded_string(value.get("after_html"), 1, 30000, f"{path}.after_html", issues)
        bounded_list(value.get("region_ids"), 1, 32, f"{path}.region_ids", issues, unique=True)


def validate_active_lessons(value: Any) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    if not exact_keys(value, ACTIVE_LESSONS_KEYS, ACTIVE_LESSONS_KEYS, "$", issues):
        return issues
    if value.get("schema_version") != 1 or not is_integer(value.get("schema_version")):
        issue(
            issues,
            "schema.exact_version_identity",
            "active_lessons.schema_version must equal integer 1",
        )
    lessons = value.get("lessons")
    if bounded_list(lessons, 0, _MAX_LESSONS, "$.lessons", issues):
        for index, lesson in enumerate(lessons):
            bounded_string(lesson, *_LESSON_TEXT_BOUNDS, f"$.lessons[{index}]", issues)
    return issues


def validate_task_carrier(value: Any) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    if not exact_keys(value, TASK_CARRIER_KEYS, TASK_CARRIER_KEYS, "$", issues):
        return issues
    if value.get("schema_version") != 1 or not is_integer(value.get("schema_version")):
        issue(issues, "schema.exact_version_identity", "task carrier schema_version must equal 1")
    bounded_string(value.get("task_id"), 1, 32, "$.task_id", issues)
    _validate_task_input(value.get("task"), "$.task", issues)
    issues.extend(validate_active_lessons(value.get("active_lessons")))
    return issues


def validate_evaluator_carrier(value: Any) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    if not exact_keys(value, EVALUATOR_CARRIER_KEYS, EVALUATOR_CARRIER_KEYS, "$", issues):
        return issues
    if value.get("schema_version") != 1 or not is_integer(value.get("schema_version")):
        issue(
            issues, "schema.exact_version_identity", "evaluator carrier schema_version must equal 1"
        )
    bounded_string(value.get("task_id"), 1, 32, "$.task_id", issues)
    _validate_task_input(value.get("task"), "$.task", issues)
    bounded_string(value.get("raw_output"), 1, _MAX_RAW_OUTPUT_LENGTH, "$.raw_output", issues)
    run = value.get("run")
    if exact_keys(run, EVALUATOR_RUN_KEYS, EVALUATOR_RUN_KEYS, "$.run", issues):
        bounded_string(run.get("run_id"), *_OPAQUE_TOKEN_BOUNDS, "$.run.run_id", issues)
    return issues


def _validate_evaluation_summary(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not exact_keys(
        value, REFLECTOR_EVALUATION_SUMMARY_KEYS, REFLECTOR_EVALUATION_SUMMARY_KEYS, path, issues
    ):
        return
    bounded_string(value.get("task_id"), 1, 32, f"{path}.task_id", issues)
    bounded_string(value.get("outcome"), 1, 64, f"{path}.outcome", issues)
    codes = value.get("issue_codes")
    if bounded_list(codes, 0, _MAX_ISSUE_CODES, f"{path}.issue_codes", issues, unique=True):
        for index, code in enumerate(codes):
            bounded_string(code, *_OPAQUE_TOKEN_BOUNDS, f"{path}.issue_codes[{index}]", issues)


def validate_reflector_carrier(value: Any) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    if not exact_keys(value, REFLECTOR_CARRIER_KEYS, REFLECTOR_CARRIER_KEYS, "$", issues):
        return issues
    if value.get("schema_version") != 1 or not is_integer(value.get("schema_version")):
        issue(
            issues, "schema.exact_version_identity", "reflector carrier schema_version must equal 1"
        )
    stable_lessons = value.get("stable_lessons")
    if bounded_list(stable_lessons, 0, _MAX_LESSONS, "$.stable_lessons", issues):
        for index, lesson in enumerate(stable_lessons):
            bounded_string(lesson, *_FENCED_TEXT_BOUNDS, f"$.stable_lessons[{index}]", issues)
    evaluations = value.get("evaluations")
    if bounded_list(evaluations, 0, _MAX_EVALUATIONS, "$.evaluations", issues):
        for index, evaluation in enumerate(evaluations):
            _validate_evaluation_summary(evaluation, f"$.evaluations[{index}]", issues)
    codes = value.get("issue_codes")
    if bounded_list(codes, 0, _MAX_ISSUE_CODES, "$.issue_codes", issues, unique=True):
        for index, code in enumerate(codes):
            bounded_string(code, *_OPAQUE_TOKEN_BOUNDS, f"$.issue_codes[{index}]", issues)
    owner_payloads = value.get("owner_payloads")
    if bounded_list(owner_payloads, 0, _MAX_OWNER_PAYLOADS, "$.owner_payloads", issues):
        for index, payload in enumerate(owner_payloads):
            bounded_string(payload, *_FENCED_TEXT_BOUNDS, f"$.owner_payloads[{index}]", issues)
    return issues
