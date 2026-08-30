"""Ordered event dispatch for the scheduled-learning reducer."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from benchmark_core.contract_validation import ValidationIssue, issue

from benchmark_learning.learning_contract import (
    ReplayEvent,
    ReplayEventKind,
    canonical_event_log,
    replay_receipt,
)

from .candidates import (
    _apply_candidate_admitted,
    _apply_candidate_artifact,
    _apply_candidate_control,
    _apply_no_candidate,
)
from .evidence import (
    _apply_operation_finished,
    _apply_operation_started,
    _apply_stable_evaluation,
    _maybe_trigger,
    _record_owner_signal,
    _subject_issues,
    _supersession_issues,
)
from .promotion import _owner_rollback_trigger, _rollback_promotion
from .state import (
    _job_or_raise,
    _load_state,
    _reject,
    _replace_job,
    _require_valid,
)
from .trials import (
    _apply_adapter_receipt,
    _apply_hard_veto_receipt,
    _apply_trial_run_created,
    _apply_trial_run_settled,
    _reconcile_all,
    _reconcile_job,
)

_Handler = Callable[[dict[str, Any], ReplayEvent], tuple[dict[str, Any], list[dict[str, Any]]]]


def _apply_controller_started(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    expected = state["controller_generation"] + 1
    issues: list[ValidationIssue] = []
    if event.payload["controller_generation"] != expected:
        issue(
            issues,
            "policy.controller_generation",
            f"$.payload.controller_generation must equal {expected}",
        )
    _require_valid(issues)
    jobs: dict[str, Any] = {}
    for job_id, job in state["jobs"].items():
        operations = {
            operation_id: {
                **record,
                "status": "interrupted_unknown",
            }
            if record["status"] == "started" and record["attempt_generation"] < expected
            else record
            for operation_id, record in job["operations"].items()
        }
        jobs[job_id] = {**job, "operations": operations}
    after = {**state, "controller_generation": expected, "jobs": jobs}
    return _reconcile_all(after, event)


def _apply_clock_advanced(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    issues: list[ValidationIssue] = []
    if event.occurred_at < state["controlled_clock"]:
        issue(
            issues,
            "policy.controlled_clock",
            "$.occurred_at must not precede the controlled clock",
        )
    _require_valid(issues)
    state, decisions = _reconcile_all(
        {**state, "controlled_clock": event.occurred_at},
        event,
    )
    for job_id in sorted(state["jobs"]):
        state, produced = _maybe_trigger(state, job_id, event)
        decisions.extend(produced)
    return state, decisions


def _apply_owner_signal(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    issues: list[ValidationIssue] = []
    _subject_issues(job, payload, issues)
    _supersession_issues(job, payload, issues)
    _require_valid(issues)
    state = _replace_job(state, _record_owner_signal(job, event))
    decisions: list[dict[str, Any]] = []
    if payload["subject_kind"] == "candidate":
        state = _apply_candidate_control(state, event)
    rollback = _owner_rollback_trigger(state["jobs"][payload["job_id"]], event)
    if rollback is not None:
        reason, source_kind, source_matches, remaining = rollback
        return _rollback_promotion(
            state,
            event,
            reason=reason,
            source_kind=source_kind,
            source_matches=source_matches,
            remaining_supports=remaining,
        )
    if payload["subject_kind"] != "candidate":
        state, decisions = _maybe_trigger(state, payload["job_id"], event)
    state, trial_decisions = _reconcile_job(state, payload["job_id"], event)
    return state, [*decisions, *trial_decisions]


_HANDLERS: dict[ReplayEventKind, _Handler] = {
    ReplayEventKind.CONTROLLER_STARTED: _apply_controller_started,
    ReplayEventKind.CLOCK_ADVANCED: _apply_clock_advanced,
    ReplayEventKind.STABLE_EVALUATION_RECORDED: _apply_stable_evaluation,
    ReplayEventKind.OWNER_SIGNAL_RECORDED: _apply_owner_signal,
    ReplayEventKind.OPERATION_STARTED: _apply_operation_started,
    ReplayEventKind.OPERATION_FINISHED: _apply_operation_finished,
    ReplayEventKind.NO_CANDIDATE_RECORDED: _apply_no_candidate,
    ReplayEventKind.CANDIDATE_ARTIFACT_RECORDED: _apply_candidate_artifact,
    ReplayEventKind.CANDIDATE_ADMITTED: _apply_candidate_admitted,
    ReplayEventKind.TRIAL_RUN_CREATED: _apply_trial_run_created,
    ReplayEventKind.TRIAL_RUN_SETTLED: _apply_trial_run_settled,
    ReplayEventKind.ADAPTER_RECEIPT_RECORDED: _apply_adapter_receipt,
    ReplayEventKind.HARD_VETO_RECEIPT_RECORDED: _apply_hard_veto_receipt,
}


def replay(*, initial: dict[str, Any], events: list[ReplayEvent]) -> dict[str, Any]:
    """Reduce one ordered event log into canonical state, decisions, and a replay receipt."""

    state = _load_state(initial)
    canonical_event_log(events)
    decisions: list[dict[str, Any]] = []
    for event in events:
        handler = _HANDLERS.get(event.kind)
        if handler is None:
            _reject(
                "policy.unsupported_transition",
                f"$.kind {event.kind.value} has no replay transition",
            )
        state, produced = handler(state, event)
        decisions.extend(produced)
    receipt = replay_receipt(
        algorithm_id=state["algorithm_id"],
        events=events,
        decisions=decisions,
        final_state=state,
    )
    return {"state": state, "decisions": decisions, "receipt": receipt}
