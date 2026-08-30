"""Public event and adapter-envelope parsing."""

from __future__ import annotations

from typing import Any

from benchmark_core.contract_validation import ContractError, ValidationIssue, issue

from .schema import (
    AdapterEnvelope,
    AdapterOutcome,
    LearningContractError,
    ReplayEvent,
    ReplayEventKind,
)
from .validation import _adapter_envelope_issues, _event_issues, _require_valid


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
