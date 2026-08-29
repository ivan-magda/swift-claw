"""Closed ordered event and neutral adapter-receipt contracts for `scheduled-learning/v1`."""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from typing import Any

from benchmark_core.canonical import SHA256_HEX, canonical_sha256, dumps
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


class LearningContractError(ValueError):
    """Public-boundary error for the closed `scheduled-learning/v1` replay contract."""

    def __init__(self, issues: list[ValidationIssue]) -> None:
        self.issues = tuple(issues)
        super().__init__("; ".join(item.message for item in self.issues))


class ReplayEventKind(StrEnum):
    CONTROLLER_STARTED = "controller_started"
    CLOCK_ADVANCED = "clock_advanced"
    STABLE_EVALUATION_RECORDED = "stable_evaluation_recorded"
    OWNER_SIGNAL_RECORDED = "owner_signal_recorded"
    OPERATION_STARTED = "operation_started"
    OPERATION_FINISHED = "operation_finished"
    NO_CANDIDATE_RECORDED = "no_candidate_recorded"
    CANDIDATE_ARTIFACT_RECORDED = "candidate_artifact_recorded"
    CANDIDATE_ADMITTED = "candidate_admitted"
    TRIAL_RUN_CREATED = "trial_run_created"
    TRIAL_RUN_SETTLED = "trial_run_settled"
    ADAPTER_RECEIPT_RECORDED = "adapter_receipt_recorded"
    HARD_VETO_RECEIPT_RECORDED = "hard_veto_receipt_recorded"


class AdapterOutcome(StrEnum):
    PASS = "pass"  # noqa: S105 -- adapter gate outcome, not a credential
    REGRESSION = "regression"
    CRITICAL = "critical"
    INCONCLUSIVE = "inconclusive"


@dataclass(frozen=True)
class ReplayEvent:
    sequence: int
    occurred_at: str
    kind: ReplayEventKind
    payload: dict[str, Any]


@dataclass(frozen=True)
class AdapterEnvelope:
    adapter_id: str
    adapter_version: str
    candidate_digest: str
    dataset_digest: str
    oracle_digest: str
    gates_digest: str
    execution_surface_digest: str
    outcome: AdapterOutcome
    receipt_digest: str


_ENVELOPE_KEYS = {"schema_version", "sequence", "occurred_at", "kind", "payload"}
_EVENT_KIND_VALUES = tuple(kind.value for kind in ReplayEventKind)

# Exactly `YYYY-MM-DDTHH:MM:SSZ`: an RFC-3339 UTC whole-second timestamp. Fractional seconds,
# non-`Z` offsets, and lowercase `z` are all rejected by this fixed-width closed pattern.
_OCCURRED_AT = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

_ADAPTER_ENVELOPE_KEYS = {
    "adapter_id",
    "adapter_version",
    "candidate_digest",
    "dataset_digest",
    "oracle_digest",
    "gates_digest",
    "execution_surface_digest",
    "outcome",
    "receipt_digest",
}
_ADAPTER_OUTCOME_VALUES = tuple(outcome.value for outcome in AdapterOutcome)
_ADAPTER_GATE_DIGEST_FIELDS = (
    "dataset_digest",
    "oracle_digest",
    "gates_digest",
    "execution_surface_digest",
)
_ADAPTER_DIGEST_FIELDS = (
    "candidate_digest",
    *_ADAPTER_GATE_DIGEST_FIELDS,
    "receipt_digest",
)

_EVENT_PAYLOAD_KEYS: dict[ReplayEventKind, set[str]] = {
    ReplayEventKind.CLOCK_ADVANCED: set(),
    ReplayEventKind.CONTROLLER_STARTED: {"controller_generation"},
    ReplayEventKind.STABLE_EVALUATION_RECORDED: {
        "job_id",
        "run_id",
        "operation_id",
        "evaluation_digest",
        "logical_occurrence",
        "learning_epoch",
        "compatibility_digest",
        "stable_digest",
        "outcome",
        "issue_codes",
    },
    ReplayEventKind.OWNER_SIGNAL_RECORDED: {
        "job_id",
        "subject_kind",
        "subject_digest",
        "run_id",
        "signal",
        "payload",
        "revision",
        "supersedes_revision",
    },
    ReplayEventKind.OPERATION_STARTED: {
        "job_id",
        "operation_id",
        "operation_kind",
        "attempt_generation",
        "carrier_digest",
        "route_digest",
        "provider_call_id",
        "manifest_digest",
        "freeze_commit",
        "invocation_core_digest",
        "trigger_digest",
    },
    ReplayEventKind.OPERATION_FINISHED: {
        "job_id",
        "operation_id",
        "operation_kind",
        "attempt_generation",
        "status",
        "result_digest",
        "usage_digest",
    },
    ReplayEventKind.NO_CANDIDATE_RECORDED: {
        "job_id",
        "operation_id",
        "result_digest",
        "trigger_digest",
    },
    ReplayEventKind.CANDIDATE_ARTIFACT_RECORDED: {
        "job_id",
        "operation_id",
        "result_digest",
        "candidate_record_digest",
        "replacement_digest",
        "lessons",
        "source_manifest_digest",
        "base_digest",
        "base_revision",
        "learning_epoch",
        "feedback_revision",
        "algorithm_id",
        "trigger_digest",
    },
    ReplayEventKind.CANDIDATE_ADMITTED: {
        "job_id",
        "candidate_record_digest",
        "replacement_digest",
        "base_digest",
        "base_revision",
        "learning_epoch",
        "feedback_revision",
        "adapter",
    },
    ReplayEventKind.TRIAL_RUN_CREATED: {"job_id", "candidate_record_digest", "run_id"},
    ReplayEventKind.TRIAL_RUN_SETTLED: {"job_id", "run_id", "outcome"},
    ReplayEventKind.ADAPTER_RECEIPT_RECORDED: {
        "job_id",
        "subject_kind",
        "subject_digest",
        "envelope",
    },
    ReplayEventKind.HARD_VETO_RECEIPT_RECORDED: {
        "job_id",
        "promotion_digest",
        "candidate_record_digest",
        "replacement_digest",
        "trigger_kind",
        "receipt_digest",
        "receipt_version",
    },
}

_OWNER_SIGNAL_SUBJECT_KINDS = ("run", "evaluation", "candidate", "promotion")
_OWNER_SIGNAL_RUN_ID_SUBJECT_KINDS = {"run", "evaluation"}
_OWNER_SIGNAL_SIGNALS = (
    "result_useful",
    "result_not_useful",
    "result_correction",
    "evaluation_confirm",
    "evaluation_dispute",
    "candidate_approve",
    "candidate_reject",
    "candidate_edit",
    "promotion_rollback",
)
_CORRECTION_BODY_KEYS = {"correction_text"}
_CANDIDATE_EDIT_BODY_KEYS = {"lessons"}

_OPERATION_KINDS = ("task", "evaluator", "reflector")
_OPERATION_STATUSES = ("succeeded", "failed_no_call", "failed")
_TRIAL_RUN_OUTCOMES = ("positive", "negative", "neutral")
_ADAPTER_RECEIPT_SUBJECT_KINDS = ("trial", "promotion")
_HARD_VETO_TRIGGER_KINDS = ("security", "secret_leakage", "corruption", "invariant_violation")
_EVALUATOR_OUTCOMES = ("no_issue", "reusable_issue", "transient_issue", "uncertain")
_ADAPTER_BINDING_KEYS = {
    "adapter_id",
    "adapter_version",
    "dataset_digest",
    "oracle_digest",
    "gates_digest",
    "execution_surface_digest",
}

# Structural-only bounds: they reject pathological input sizes at parse time. The exact
# ADR-mandated admission numbers (<= 3 lessons, <= 512/1536 UTF-8 bytes, blank/duplicate
# rejection) are semantic `scheduled-learning/v1` decisions enforced by the reducer in
# `learning_replay.py`, not by this closed-shape contract layer.
_LESSON_COUNT_BOUNDS = (0, 32)
_LESSON_TEXT_BOUNDS = (0, 8192)
_ISSUE_CODE_COUNT_BOUNDS = (0, 32)
_OPAQUE_STRING_BOUNDS = (1, 128)

# Domain separators bind each receipt's identity to its own receipt kind, so a decision receipt
# and a replay receipt with coincidentally identical field bytes never collide on ID.
_DECISION_DOMAIN = "scheduled-learning/v1/decision"
_REPLAY_DOMAIN = "scheduled-learning/v1/replay"


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
    trigger_digest = payload.get("trigger_digest")
    if operation_kind == "reflector":
        _opaque_string_issues(trigger_digest, f"{path}.trigger_digest", issues)
    elif trigger_digest is not None:
        issue(
            issues,
            "schema.bounded_values",
            f"{path}.trigger_digest must be null for this operation kind",
        )


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


def parse_event(value: Any) -> ReplayEvent:
    """Parse one closed canonical event object."""

    try:
        issues: list[ValidationIssue] = []
        _event_issues(value, issues)
        _require_valid(issues)
    except ContractError as error:
        raise LearningContractError(list(error.issues)) from error
    return ReplayEvent(
        sequence=value["sequence"],
        occurred_at=value["occurred_at"],
        kind=ReplayEventKind(value["kind"]),
        payload=value["payload"],
    )


def event_json(event: ReplayEvent) -> dict[str, Any]:
    """Render one closed canonical event object."""

    return {
        "schema_version": 1,
        "sequence": event.sequence,
        "occurred_at": event.occurred_at,
        "kind": event.kind.value,
        "payload": event.payload,
    }


def parse_adapter_envelope(value: Any) -> AdapterEnvelope:
    """Parse the neutral adapter receipt envelope."""

    try:
        issues: list[ValidationIssue] = []
        _adapter_envelope_issues(value, "$", issues)
        _require_valid(issues)
    except ContractError as error:
        raise LearningContractError(list(error.issues)) from error
    return AdapterEnvelope(
        adapter_id=value["adapter_id"],
        adapter_version=value["adapter_version"],
        candidate_digest=value["candidate_digest"],
        dataset_digest=value["dataset_digest"],
        oracle_digest=value["oracle_digest"],
        gates_digest=value["gates_digest"],
        execution_surface_digest=value["execution_surface_digest"],
        outcome=AdapterOutcome(value["outcome"]),
        receipt_digest=value["receipt_digest"],
    )


def adapter_envelope_json(value: AdapterEnvelope) -> dict[str, Any]:
    """Render the neutral adapter receipt envelope."""

    return {
        "adapter_id": value.adapter_id,
        "adapter_version": value.adapter_version,
        "candidate_digest": value.candidate_digest,
        "dataset_digest": value.dataset_digest,
        "oracle_digest": value.oracle_digest,
        "gates_digest": value.gates_digest,
        "execution_surface_digest": value.execution_surface_digest,
        "outcome": value.outcome.value,
        "receipt_digest": value.receipt_digest,
    }


def canonical_event_log(events: list[ReplayEvent]) -> dict[str, Any]:
    """Validate the contiguous, nondecreasing ordered log and return its canonical object."""

    issues: list[ValidationIssue] = []
    previous_sequence = 0
    previous_occurred_at = ""
    for index, event in enumerate(events):
        path = f"$.events[{index}]"
        expected_sequence = previous_sequence + 1
        if event.sequence != expected_sequence:
            issue(
                issues,
                "schema.ordered_log",
                f"{path}.sequence must equal {expected_sequence}",
            )
        elif event.occurred_at < previous_occurred_at:
            issue(
                issues,
                "schema.ordered_log",
                f"{path}.occurred_at must not precede the previous event",
            )
        previous_sequence = event.sequence
        previous_occurred_at = event.occurred_at
    try:
        _require_valid(issues)
    except ContractError as error:
        raise LearningContractError(list(error.issues)) from error
    return {"schema_version": 1, "events": [event_json(event) for event in events]}


def decision_receipt(
    *,
    algorithm_id: str,
    decision: str,
    reason: str,
    triggering_event_sha256: str,
    before_state_sha256: str,
    after_state_sha256: str,
    artifact_identities: dict[str, Any],
) -> dict[str, Any]:
    """Build one canonical decision receipt with a domain-separated `decision_id`."""

    issues: list[ValidationIssue] = []
    _opaque_string_issues(algorithm_id, "$.algorithm_id", issues)
    _opaque_string_issues(decision, "$.decision", issues)
    _opaque_string_issues(reason, "$.reason", issues)
    _sha256_issues(triggering_event_sha256, "$.triggering_event_sha256", issues)
    _sha256_issues(before_state_sha256, "$.before_state_sha256", issues)
    _sha256_issues(after_state_sha256, "$.after_state_sha256", issues)
    _canonical_object_issues(artifact_identities, "$.artifact_identities", issues)
    try:
        _require_valid(issues)
    except ContractError as error:
        raise LearningContractError(list(error.issues)) from error

    core = {
        "schema_version": 1,
        "algorithm_id": algorithm_id,
        "decision": decision,
        "reason": reason,
        "triggering_event_sha256": triggering_event_sha256,
        "before_state_sha256": before_state_sha256,
        "after_state_sha256": after_state_sha256,
        "artifact_identities": artifact_identities,
    }
    decision_hash = canonical_sha256({"domain": _DECISION_DOMAIN, "value": core})
    return {**core, "decision_id": f"decision-{decision_hash[:12]}"}


def replay_receipt(
    *,
    algorithm_id: str,
    events: list[ReplayEvent],
    decisions: list[dict[str, Any]],
    final_state: dict[str, Any],
) -> dict[str, Any]:
    """Build the canonical whole-replay receipt with a domain-separated `receipt_id`."""

    issues: list[ValidationIssue] = []
    _opaque_string_issues(algorithm_id, "$.algorithm_id", issues)
    _decision_list_issues(decisions, "$.decisions", issues)
    _canonical_object_issues(final_state, "$.final_state", issues)
    try:
        _require_valid(issues)
    except ContractError as error:
        raise LearningContractError(list(error.issues)) from error

    core = {
        "schema_version": 1,
        "algorithm_id": algorithm_id,
        "events_sha256": canonical_sha256(canonical_event_log(events)),
        "decision_receipt_sha256s": [canonical_sha256(item) for item in decisions],
        "final_state_sha256": canonical_sha256(final_state),
    }
    replay_hash = canonical_sha256({"domain": _REPLAY_DOMAIN, "value": core})
    return {**core, "receipt_id": f"replay-{replay_hash[:12]}"}
