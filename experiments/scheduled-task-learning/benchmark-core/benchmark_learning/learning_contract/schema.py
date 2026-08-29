"""Closed ordered event and neutral adapter-receipt contracts for `scheduled-learning/v1`."""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import StrEnum
from typing import Any

from benchmark_core.contract_validation import ValidationIssue


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
