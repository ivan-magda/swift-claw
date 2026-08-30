"""Closed event and adapter payload validation."""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from typing import Any

from benchmark_core.canonical import SHA256_HEX, dumps
from benchmark_core.contract_validation import (
    ContractError,
    ValidationIssue,
    bounded_list,
    bounded_string,
    closed_enum,
    exact_keys,
    is_integer,
    issue,
)

from .schema import (
    _ADAPTER_BINDING_KEYS,
    _ADAPTER_DIGEST_FIELDS,
    _ADAPTER_ENVELOPE_KEYS,
    _ADAPTER_GATE_DIGEST_FIELDS,
    _ADAPTER_OUTCOME_VALUES,
    _ADAPTER_RECEIPT_SUBJECT_KINDS,
    _CANDIDATE_EDIT_BODY_KEYS,
    _CORRECTION_BODY_KEYS,
    _ENVELOPE_KEYS,
    _EVALUATOR_OUTCOMES,
    _EVENT_KIND_VALUES,
    _EVENT_PAYLOAD_KEYS,
    _HARD_VETO_TRIGGER_KINDS,
    _ISSUE_CODE_COUNT_BOUNDS,
    _LESSON_COUNT_BOUNDS,
    _LESSON_TEXT_BOUNDS,
    _OCCURRED_AT,
    _OPAQUE_STRING_BOUNDS,
    _OPERATION_KINDS,
    _OPERATION_STATUSES,
    _OWNER_SIGNAL_RUN_ID_SUBJECT_KINDS,
    _OWNER_SIGNAL_SIGNALS,
    _OWNER_SIGNAL_SUBJECT_KINDS,
    _TRIAL_RUN_OUTCOMES,
    ReplayEventKind,
)


def _opaque_string_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    bounded_string(value, *_OPAQUE_STRING_BOUNDS, path, issues)


def _sha256_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    bounded_string(value, 64, 64, path, issues, SHA256_HEX)


def _is_canonical_utc_whole_second(value: Any) -> bool:
    if not isinstance(value, str) or _OCCURRED_AT.fullmatch(value) is None:
        return False
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return parsed.strftime("%Y-%m-%dT%H:%M:%SZ") == value


def _occurred_at_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not _is_canonical_utc_whole_second(value):
        issue(
            issues,
            "schema.bounded_values",
            f"{path} must be a canonical RFC3339 UTC whole-second timestamp",
        )


def _nonnegative_int_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not is_integer(value) or value < 0:
        issue(issues, "schema.bounded_values", f"{path} must be a non-negative integer")


def _positive_int_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not is_integer(value) or value < 1:
        issue(issues, "schema.bounded_values", f"{path} must be a positive integer")


def _lesson_set_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not isinstance(value, list):
        issue(issues, "schema.bounded_values", f"{path} must be an array")
        return
    bounded_list(value, *_LESSON_COUNT_BOUNDS, path, issues)
    for index, lesson in enumerate(value):
        bounded_string(lesson, *_LESSON_TEXT_BOUNDS, f"{path}[{index}]", issues)


def _issue_codes_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not isinstance(value, list):
        issue(issues, "schema.bounded_values", f"{path} must be an array")
        return
    bounded_list(value, *_ISSUE_CODE_COUNT_BOUNDS, path, issues, unique=True)
    for index, code in enumerate(value):
        _opaque_string_issues(code, f"{path}[{index}]", issues)


def _has_only_string_keys(value: Any) -> bool:
    if isinstance(value, dict):
        return all(
            isinstance(key, str) and _has_only_string_keys(item) for key, item in value.items()
        )
    if isinstance(value, list):
        return all(_has_only_string_keys(item) for item in value)
    return True


def _canonical_object_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not isinstance(value, dict) or not _has_only_string_keys(value):
        issue(issues, "schema.single_object", f"{path} must be a canonical JSON object")
        return
    try:
        dumps(value)
    except (TypeError, ValueError):
        issue(issues, "schema.single_object", f"{path} must be canonically serializable")


def _decision_list_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not isinstance(value, list):
        issue(issues, "schema.bounded_values", f"{path} must be an array")
        return
    for index, item in enumerate(value):
        _canonical_object_issues(item, f"{path}[{index}]", issues)


def _adapter_binding_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if value is None:
        return
    if not exact_keys(value, _ADAPTER_BINDING_KEYS, _ADAPTER_BINDING_KEYS, path, issues):
        return
    _opaque_string_issues(value.get("adapter_id"), f"{path}.adapter_id", issues)
    _opaque_string_issues(value.get("adapter_version"), f"{path}.adapter_version", issues)
    for field in _ADAPTER_GATE_DIGEST_FIELDS:
        _sha256_issues(value.get(field), f"{path}.{field}", issues)


def _adapter_envelope_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not exact_keys(value, _ADAPTER_ENVELOPE_KEYS, _ADAPTER_ENVELOPE_KEYS, path, issues):
        return
    _opaque_string_issues(value.get("adapter_id"), f"{path}.adapter_id", issues)
    _opaque_string_issues(value.get("adapter_version"), f"{path}.adapter_version", issues)
    for field in _ADAPTER_DIGEST_FIELDS:
        _sha256_issues(value.get(field), f"{path}.{field}", issues)
    closed_enum(value.get("outcome"), _ADAPTER_OUTCOME_VALUES, f"{path}.outcome", issues)


def _owner_signal_body_issues(
    signal: Any,
    body: Any,
    path: str,
    issues: list[ValidationIssue],
) -> None:
    if signal == "result_correction":
        if not exact_keys(body, _CORRECTION_BODY_KEYS, _CORRECTION_BODY_KEYS, path, issues):
            return
        bounded_string(body.get("correction_text"), 1, 4096, f"{path}.correction_text", issues)
        return
    if signal == "candidate_edit":
        if not exact_keys(body, _CANDIDATE_EDIT_BODY_KEYS, _CANDIDATE_EDIT_BODY_KEYS, path, issues):
            return
        _lesson_set_issues(body.get("lessons"), f"{path}.lessons", issues)
        return
    if body is not None:
        issue(issues, "schema.bounded_values", f"{path} must be null for this signal")


def _owner_signal_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    _opaque_string_issues(payload.get("job_id"), f"{path}.job_id", issues)
    subject_kind = payload.get("subject_kind")
    closed_enum(subject_kind, _OWNER_SIGNAL_SUBJECT_KINDS, f"{path}.subject_kind", issues)
    _opaque_string_issues(payload.get("subject_digest"), f"{path}.subject_digest", issues)
    run_id = payload.get("run_id")
    if subject_kind in _OWNER_SIGNAL_RUN_ID_SUBJECT_KINDS:
        _opaque_string_issues(run_id, f"{path}.run_id", issues)
    elif run_id is not None:
        issue(issues, "schema.bounded_values", f"{path}.run_id must be null for this subject")
    signal = payload.get("signal")
    closed_enum(signal, _OWNER_SIGNAL_SIGNALS, f"{path}.signal", issues)
    _owner_signal_body_issues(signal, payload.get("payload"), f"{path}.payload", issues)
    _nonnegative_int_issues(payload.get("revision"), f"{path}.revision", issues)
    supersedes_revision = payload.get("supersedes_revision")
    if supersedes_revision is not None:
        _nonnegative_int_issues(supersedes_revision, f"{path}.supersedes_revision", issues)


def _controller_started_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    _positive_int_issues(
        payload.get("controller_generation"), f"{path}.controller_generation", issues
    )


def _stable_evaluation_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    for field in (
        "job_id",
        "run_id",
        "operation_id",
        "evaluation_digest",
        "compatibility_digest",
        "stable_digest",
    ):
        _opaque_string_issues(payload.get(field), f"{path}.{field}", issues)
    _occurred_at_issues(payload.get("logical_occurrence"), f"{path}.logical_occurrence", issues)
    _nonnegative_int_issues(payload.get("learning_epoch"), f"{path}.learning_epoch", issues)
    closed_enum(payload.get("outcome"), _EVALUATOR_OUTCOMES, f"{path}.outcome", issues)
    _issue_codes_issues(payload.get("issue_codes"), f"{path}.issue_codes", issues)


def _operation_started_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    _opaque_string_issues(payload.get("job_id"), f"{path}.job_id", issues)
    _opaque_string_issues(payload.get("operation_id"), f"{path}.operation_id", issues)
    operation_kind = payload.get("operation_kind")
    closed_enum(operation_kind, _OPERATION_KINDS, f"{path}.operation_kind", issues)
    _positive_int_issues(payload.get("attempt_generation"), f"{path}.attempt_generation", issues)
    for field in (
        "carrier_digest",
        "route_digest",
        "provider_call_id",
        "manifest_digest",
        "freeze_commit",
        "invocation_core_digest",
    ):
        _opaque_string_issues(payload.get(field), f"{path}.{field}", issues)


def _operation_finished_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    _opaque_string_issues(payload.get("job_id"), f"{path}.job_id", issues)
    _opaque_string_issues(payload.get("operation_id"), f"{path}.operation_id", issues)
    closed_enum(payload.get("operation_kind"), _OPERATION_KINDS, f"{path}.operation_kind", issues)
    _positive_int_issues(payload.get("attempt_generation"), f"{path}.attempt_generation", issues)
    status = payload.get("status")
    closed_enum(status, _OPERATION_STATUSES, f"{path}.status", issues)
    _opaque_string_issues(payload.get("result_digest"), f"{path}.result_digest", issues)
    usage_digest = payload.get("usage_digest")
    if status == "failed_no_call":
        if usage_digest is not None:
            issue(
                issues,
                "schema.bounded_values",
                f"{path}.usage_digest must be null for failed_no_call",
            )
    else:
        _opaque_string_issues(usage_digest, f"{path}.usage_digest", issues)


def _no_candidate_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    for field in ("job_id", "operation_id", "result_digest", "trigger_digest"):
        _opaque_string_issues(payload.get(field), f"{path}.{field}", issues)


def _candidate_artifact_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    for field in (
        "job_id",
        "operation_id",
        "result_digest",
        "source_manifest_digest",
        "base_digest",
        "algorithm_id",
        "trigger_digest",
    ):
        _opaque_string_issues(payload.get(field), f"{path}.{field}", issues)
    # The reducer computes both digests from this event's own frozen inputs and verifies
    # them against its recomputed projections, so they are real canonical SHA-256, not
    # opaque cross-references.
    _sha256_issues(
        payload.get("candidate_record_digest"), f"{path}.candidate_record_digest", issues
    )
    _sha256_issues(payload.get("replacement_digest"), f"{path}.replacement_digest", issues)
    _lesson_set_issues(payload.get("lessons"), f"{path}.lessons", issues)
    _nonnegative_int_issues(payload.get("base_revision"), f"{path}.base_revision", issues)
    _nonnegative_int_issues(payload.get("learning_epoch"), f"{path}.learning_epoch", issues)
    _nonnegative_int_issues(payload.get("feedback_revision"), f"{path}.feedback_revision", issues)


def _candidate_admitted_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    _opaque_string_issues(payload.get("job_id"), f"{path}.job_id", issues)
    _opaque_string_issues(payload.get("base_digest"), f"{path}.base_digest", issues)
    _sha256_issues(
        payload.get("candidate_record_digest"), f"{path}.candidate_record_digest", issues
    )
    _sha256_issues(payload.get("replacement_digest"), f"{path}.replacement_digest", issues)
    _nonnegative_int_issues(payload.get("base_revision"), f"{path}.base_revision", issues)
    _nonnegative_int_issues(payload.get("learning_epoch"), f"{path}.learning_epoch", issues)
    _nonnegative_int_issues(payload.get("feedback_revision"), f"{path}.feedback_revision", issues)
    _adapter_binding_issues(payload.get("adapter"), f"{path}.adapter", issues)


def _trial_run_created_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    for field in ("job_id", "run_id"):
        _opaque_string_issues(payload.get(field), f"{path}.{field}", issues)
    # `candidate_record_digest` is real canonical SHA-256 wherever it appears; the format is a
    # property of the value, not of the event kind carrying it.
    _sha256_issues(
        payload.get("candidate_record_digest"), f"{path}.candidate_record_digest", issues
    )


def _trial_run_settled_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    _opaque_string_issues(payload.get("job_id"), f"{path}.job_id", issues)
    _opaque_string_issues(payload.get("run_id"), f"{path}.run_id", issues)
    closed_enum(payload.get("outcome"), _TRIAL_RUN_OUTCOMES, f"{path}.outcome", issues)


def _adapter_receipt_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    _opaque_string_issues(payload.get("job_id"), f"{path}.job_id", issues)
    closed_enum(
        payload.get("subject_kind"), _ADAPTER_RECEIPT_SUBJECT_KINDS, f"{path}.subject_kind", issues
    )
    _opaque_string_issues(payload.get("subject_digest"), f"{path}.subject_digest", issues)
    _adapter_envelope_issues(payload.get("envelope"), f"{path}.envelope", issues)


def _hard_veto_receipt_payload_issues(
    payload: dict[str, Any],
    path: str,
    issues: list[ValidationIssue],
) -> None:
    _opaque_string_issues(payload.get("job_id"), f"{path}.job_id", issues)
    _opaque_string_issues(payload.get("promotion_digest"), f"{path}.promotion_digest", issues)
    # Same identity, same format wherever it is carried: see `_candidate_artifact_payload_issues`.
    _sha256_issues(
        payload.get("candidate_record_digest"), f"{path}.candidate_record_digest", issues
    )
    _sha256_issues(payload.get("replacement_digest"), f"{path}.replacement_digest", issues)
    closed_enum(
        payload.get("trigger_kind"), _HARD_VETO_TRIGGER_KINDS, f"{path}.trigger_kind", issues
    )
    _sha256_issues(payload.get("receipt_digest"), f"{path}.receipt_digest", issues)
    _opaque_string_issues(payload.get("receipt_version"), f"{path}.receipt_version", issues)


_PayloadValidator = Callable[[dict[str, Any], str, list[ValidationIssue]], None]

_PAYLOAD_VALIDATORS: dict[ReplayEventKind, _PayloadValidator] = {
    ReplayEventKind.CONTROLLER_STARTED: _controller_started_payload_issues,
    ReplayEventKind.STABLE_EVALUATION_RECORDED: _stable_evaluation_payload_issues,
    ReplayEventKind.OWNER_SIGNAL_RECORDED: _owner_signal_payload_issues,
    ReplayEventKind.OPERATION_STARTED: _operation_started_payload_issues,
    ReplayEventKind.OPERATION_FINISHED: _operation_finished_payload_issues,
    ReplayEventKind.NO_CANDIDATE_RECORDED: _no_candidate_payload_issues,
    ReplayEventKind.CANDIDATE_ARTIFACT_RECORDED: _candidate_artifact_payload_issues,
    ReplayEventKind.CANDIDATE_ADMITTED: _candidate_admitted_payload_issues,
    ReplayEventKind.TRIAL_RUN_CREATED: _trial_run_created_payload_issues,
    ReplayEventKind.TRIAL_RUN_SETTLED: _trial_run_settled_payload_issues,
    ReplayEventKind.ADAPTER_RECEIPT_RECORDED: _adapter_receipt_payload_issues,
    ReplayEventKind.HARD_VETO_RECEIPT_RECORDED: _hard_veto_receipt_payload_issues,
}


def _payload_issues(
    kind: ReplayEventKind,
    payload: Any,
    path: str,
    issues: list[ValidationIssue],
) -> None:
    keys = _EVENT_PAYLOAD_KEYS[kind]
    if not exact_keys(payload, keys, keys, path, issues):
        return
    validator = _PAYLOAD_VALIDATORS.get(kind)
    if validator is not None:
        validator(payload, path, issues)


def _event_issues(value: Any, issues: list[ValidationIssue]) -> None:
    if not exact_keys(value, _ENVELOPE_KEYS, _ENVELOPE_KEYS, "$", issues):
        return
    schema_version = value.get("schema_version")
    if not is_integer(schema_version) or schema_version != 1:
        issue(issues, "schema.bounded_values", "$.schema_version must equal 1")
    _positive_int_issues(value.get("sequence"), "$.sequence", issues)
    _occurred_at_issues(value.get("occurred_at"), "$.occurred_at", issues)
    kind_value = value.get("kind")
    if not closed_enum(kind_value, _EVENT_KIND_VALUES, "$.kind", issues):
        return
    _payload_issues(ReplayEventKind(kind_value), value.get("payload"), "$.payload", issues)


def _require_valid(issues: list[ValidationIssue]) -> None:
    if issues:
        raise ContractError(issues)
