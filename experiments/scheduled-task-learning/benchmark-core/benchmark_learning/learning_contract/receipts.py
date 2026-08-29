"""Canonical decision and replay receipt builders."""

from __future__ import annotations

from typing import Any

from benchmark_core.canonical import canonical_sha256
from benchmark_core.contract_validation import ContractError, ValidationIssue

from .events import canonical_event_log
from .schema import _DECISION_DOMAIN, _REPLAY_DOMAIN, LearningContractError, ReplayEvent
from .validation import (
    _canonical_object_issues,
    _decision_list_issues,
    _opaque_string_issues,
    _require_valid,
    _sha256_issues,
)


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
