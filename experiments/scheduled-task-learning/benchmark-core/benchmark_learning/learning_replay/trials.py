"""Trial assignment, settlement, reconciliation, and adapter events."""

from __future__ import annotations

from typing import Any

from benchmark_core.canonical import canonical_sha256
from benchmark_core.contract_validation import ValidationIssue, issue

from benchmark_learning.learning_contract import (
    ReplayEvent,
    adapter_envelope_json,
    event_json,
    parse_adapter_envelope,
)

from .promotion import (
    _closed_trial_record,
    _effective_trial_outcome,
    _promote_trial,
    _remaining_positive_supports,
    _required_trial_evaluation_disputed,
    _rollback_promotion,
    _trial_artifact_identities,
)
from .state import (
    _ADAPTER_BINDING_FIELDS,
    _MAX_TRIAL_ASSIGNMENTS,
    _POSITIVE_TRIAL_RUNS,
    _TRIAL_EVALUATION_DOMAIN,
    _candidate,
    _decision,
    _job_or_raise,
    _open_trial,
    _reject,
    _replace_job,
    _require_valid,
    _trial_assignment,
)


def _close_trial(
    state: dict[str, Any],
    job: dict[str, Any],
    trial: dict[str, Any],
    event: ReplayEvent,
    *,
    decision: str,
    reason: str,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if decision == "promoted":
        return _promote_trial(state, job, trial, event, reason)
    closed_trial = _closed_trial_record(state, trial, decision)
    after = _replace_job(state, {**job, "trial": closed_trial})
    receipt = _decision(
        before=state,
        after=after,
        event=event,
        decision=decision,
        reason=reason,
        artifact_identities=_trial_artifact_identities(job, closed_trial),
    )
    return after, [receipt]


def _immediate_trial_decision(
    job: dict[str, Any],
    trial: dict[str, Any],
    outcomes: list[str | None],
) -> tuple[str, str] | None:
    candidate = _candidate(job, trial["candidate_record_digest"])
    if candidate is not None and candidate["vetoed"]:
        return "fallback", "hard_veto"
    if any(
        _required_trial_evaluation_disputed(job, assignment) for assignment in trial["assignments"]
    ):
        return "fallback", "hard_veto"
    adapter_receipt = trial["adapter_receipt"]
    adapter_outcome = None if adapter_receipt is None else adapter_receipt["outcome"]
    if adapter_outcome in {"critical", "regression"}:
        return "fallback", f"adapter_{adapter_outcome}"
    if "negative" in outcomes:
        return "fallback", "negative_trial_run"
    return None


def _closed_trial_decision(
    state: dict[str, Any],
    trial: dict[str, Any],
    *,
    all_settled: bool,
    positive_count: int,
) -> tuple[str, str] | None:
    if state["controlled_clock"] >= trial["decision_deadline"] and not all_settled:
        return "fallback", "decision_deadline_incomplete"
    if trial["assignment_closed_at"] is None or not all_settled:
        return None
    if positive_count < _POSITIVE_TRIAL_RUNS:
        return "fallback", "insufficient_positive_runs"
    adapter_receipt = trial["adapter_receipt"]
    if trial["adapter"] is not None and adapter_receipt is None:
        return "fallback", "adapter_pass_missing"
    if adapter_receipt is not None and adapter_receipt["outcome"] == "inconclusive":
        return "fallback", "adapter_inconclusive"
    return "promoted", "trial_evidence_satisfied"


def _reconcile_job(
    state: dict[str, Any],
    job_id: str,
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    job = state["jobs"][job_id]
    trial = _open_trial(job)
    if trial is None:
        return state, []

    outcomes = [_effective_trial_outcome(job, assignment) for assignment in trial["assignments"]]
    immediate = _immediate_trial_decision(job, trial, outcomes)
    if immediate is not None:
        decision, reason = immediate
        return _close_trial(
            state,
            job,
            trial,
            event,
            decision=decision,
            reason=reason,
        )

    all_settled = all(assignment["status"] == "settled" for assignment in trial["assignments"])
    positive_count = outcomes.count("positive")
    assignment_should_close = (
        len(trial["assignments"]) >= _MAX_TRIAL_ASSIGNMENTS
        or state["controlled_clock"] >= trial["assignment_deadline"]
        or (positive_count >= _POSITIVE_TRIAL_RUNS and all_settled)
    )
    if trial["assignment_closed_at"] is None and assignment_should_close:
        trial = {**trial, "assignment_closed_at": state["controlled_clock"]}
        job = {**job, "trial": trial}
        state = _replace_job(state, job)
    terminal = _closed_trial_decision(
        state,
        trial,
        all_settled=all_settled,
        positive_count=positive_count,
    )
    if terminal is None:
        return state, []
    decision, reason = terminal
    return _close_trial(
        state,
        job,
        trial,
        event,
        decision=decision,
        reason=reason,
    )


def _reconcile_all(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    decisions: list[dict[str, Any]] = []
    for job_id in sorted(state["jobs"]):
        state, produced = _reconcile_job(state, job_id, event)
        decisions.extend(produced)
    return state, decisions


def _apply_trial_run_created(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    trial = _open_trial(job)
    if trial is None:
        _reject("policy.no_open_trial", "$.payload.job_id has no open trial")
    issues: list[ValidationIssue] = []
    if (
        trial["base_digest"] != job["stable_digest"]
        or trial["base_revision"] != job["stable_revision"]
    ):
        issue(
            issues,
            "policy.stale_base",
            "$.payload cannot create a run for a trial whose frozen base is no longer current",
        )
    if payload["candidate_record_digest"] != trial["candidate_record_digest"]:
        issue(
            issues,
            "policy.trial_candidate",
            "$.payload.candidate_record_digest must equal the open trial candidate",
        )
    if trial["assignment_closed_at"] is not None or len(trial["assignments"]) >= (
        _MAX_TRIAL_ASSIGNMENTS
    ):
        issue(
            issues,
            "policy.assignment_limit",
            "$.payload cannot create a run after the trial assignment boundary",
        )
    if (
        any(entry["run_id"] == payload["run_id"] for entry in job["evaluations"])
        or payload["run_id"] in job["trial_run_ids"]
    ):
        issue(issues, "policy.duplicate_trial_run", "$.payload.run_id is already recorded")
    _require_valid(issues)
    assignment = {
        "run_id": payload["run_id"],
        "status": "created",
        "outcome": None,
        "evaluation_digest": None,
    }
    updated_trial = {**trial, "assignments": [*trial["assignments"], assignment]}
    state = _replace_job(
        state,
        {
            **job,
            "trial_run_ids": [*job["trial_run_ids"], payload["run_id"]],
            "trial": updated_trial,
        },
    )
    return _reconcile_job(state, payload["job_id"], event)


def _apply_trial_run_settled(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    trial = _open_trial(job)
    if trial is None:
        _reject("policy.no_open_trial", "$.payload.job_id has no open trial")
    assignment = _trial_assignment(job, payload["run_id"])
    if assignment is None:
        _reject("policy.unknown_trial_run", "$.payload.run_id is not assigned to this trial")
    if assignment["status"] != "created":
        _reject("policy.trial_run_settled", "$.payload.run_id is already settled")
    assignments = [
        {
            **record,
            "status": "settled",
            "outcome": payload["outcome"],
            "evaluation_digest": canonical_sha256(
                {"domain": _TRIAL_EVALUATION_DOMAIN, "value": event_json(event)}
            ),
        }
        if record["run_id"] == payload["run_id"]
        else record
        for record in trial["assignments"]
    ]
    state = _replace_job(state, {**job, "trial": {**trial, "assignments": assignments}})
    return _reconcile_job(state, payload["job_id"], event)


def _apply_adapter_receipt(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    envelope = adapter_envelope_json(parse_adapter_envelope(payload["envelope"]))
    if payload["subject_kind"] == "promotion":
        promotion = job["promotion"]
        if promotion is None:
            _reject(
                "policy.adapter_subject",
                "$.payload must name an exact retained promotion subject",
            )
        frozen_adapter = promotion["adapter"]
        source_matches = (
            payload["subject_digest"] == promotion["promotion_digest"]
            and frozen_adapter is not None
            and envelope["candidate_digest"] == promotion["replacement_digest"]
            and all(envelope[field] == frozen_adapter[field] for field in _ADAPTER_BINDING_FIELDS)
        )
        if envelope["outcome"] not in {"critical", "regression"}:
            if not source_matches:
                _reject(
                    "policy.adapter_binding",
                    "$.payload must match the exact retained promotion adapter identity",
                )
            return state, []
        return _rollback_promotion(
            state,
            event,
            reason=f"adapter_{envelope['outcome']}",
            source_kind="adapter_receipt",
            source_matches=source_matches,
            remaining_supports=_remaining_positive_supports(job, promotion),
        )

    trial = _open_trial(job)
    if trial is None:
        _reject("policy.no_open_trial", "$.payload.job_id has no open trial")
    issues: list[ValidationIssue] = []
    if payload["subject_kind"] != "trial" or payload["subject_digest"] != trial["trial_digest"]:
        issue(
            issues,
            "policy.adapter_subject",
            "$.payload must name the exact open trial subject",
        )
    frozen_adapter = trial["adapter"]
    if frozen_adapter is None:
        issue(
            issues,
            "policy.adapter_binding",
            "$.payload.envelope is not permitted when the trial froze no adapter",
        )
    else:
        for field in _ADAPTER_BINDING_FIELDS:
            if envelope[field] != frozen_adapter[field]:
                issue(
                    issues,
                    "policy.adapter_binding",
                    f"$.payload.envelope.{field} must equal the frozen trial identity",
                )
        if envelope["candidate_digest"] != trial["replacement_digest"]:
            issue(
                issues,
                "policy.adapter_binding",
                "$.payload.envelope.candidate_digest must equal the trial replacement",
            )
    if trial["adapter_receipt"] is not None:
        issue(
            issues,
            "policy.duplicate_adapter_receipt",
            "$.payload cannot replace the trial adapter receipt",
        )
    _require_valid(issues)
    state = _replace_job(state, {**job, "trial": {**trial, "adapter_receipt": envelope}})
    return _reconcile_job(state, payload["job_id"], event)


def _apply_hard_veto_receipt(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    promotion = job["promotion"]
    if promotion is None:
        _reject("policy.no_promotion", "$.payload.job_id has no retained promotion")
    source_matches = (
        payload["promotion_digest"] == promotion["promotion_digest"]
        and payload["candidate_record_digest"] == promotion["candidate_record_digest"]
        and payload["replacement_digest"] == promotion["replacement_digest"]
    )
    return _rollback_promotion(
        state,
        event,
        reason=f"hard_veto_{payload['trigger_kind']}",
        source_kind="hard_veto_receipt",
        source_matches=source_matches,
        remaining_supports=_remaining_positive_supports(job, promotion),
    )
