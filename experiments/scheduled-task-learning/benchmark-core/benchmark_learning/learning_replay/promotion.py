"""Promotion and rollback decisions over frozen trial evidence."""

from __future__ import annotations

from typing import Any

from benchmark_core.canonical import canonical_sha256

from benchmark_learning.learning_contract import (
    ReplayEvent,
    event_json,
)

from .evidence import _effective_signal
from .state import (
    _ADAPTER_BINDING_FIELDS,
    _OWNER_RESULT_SIGNALS,
    _POSITIVE_TRIAL_RUNS,
    _PROMOTION_DOMAIN,
    _SCHEMA_VERSION,
    _TRIAL_DOMAIN,
    _candidate,
    _decision,
    _open_trial,
    _replace_job,
)

# MARK: - Trial lifecycle


def _effective_trial_outcome(job: dict[str, Any], assignment: dict[str, Any]) -> str | None:
    if assignment["status"] != "settled":
        return None
    signal = _effective_signal(job, "run", assignment["run_id"])
    if signal is not None:
        if signal["signal"] == "result_useful":
            return "positive"
        if signal["signal"] in {"result_not_useful", "result_correction"}:
            return "negative"
    judgement = _effective_signal(job, "evaluation", assignment["evaluation_digest"])
    if judgement is not None and judgement["signal"] == "evaluation_dispute":
        return None
    outcome: str = assignment["outcome"]
    return outcome


def _required_trial_evaluation_disputed(
    job: dict[str, Any],
    assignment: dict[str, Any],
) -> bool:
    if assignment["status"] != "settled" or assignment["outcome"] != "positive":
        return False
    result = _effective_signal(job, "run", assignment["run_id"])
    if result is not None and result["signal"] in _OWNER_RESULT_SIGNALS:
        return False
    judgement = _effective_signal(job, "evaluation", assignment["evaluation_digest"])
    return judgement is not None and judgement["signal"] == "evaluation_dispute"


def _trial_artifact_identities(job: dict[str, Any], trial: dict[str, Any]) -> dict[str, Any]:
    assignments = [
        {
            **assignment,
            "effective_outcome": _effective_trial_outcome(job, assignment),
        }
        for assignment in trial["assignments"]
    ]
    return {
        "job_id": job["job_id"],
        "trial_digest": trial["trial_digest"],
        "candidate_record_digest": trial["candidate_record_digest"],
        "replacement_digest": trial["replacement_digest"],
        "base_digest": trial["base_digest"],
        "base_revision": trial["base_revision"],
        "learning_epoch": trial["learning_epoch"],
        "feedback_revision": trial["feedback_revision"],
        "algorithm_id": trial["algorithm_id"],
        "source_manifest_digest": trial["source_manifest_digest"],
        "job_definition_digest": trial["job_definition_digest"],
        "compatibility_digest": trial["compatibility_digest"],
        "adapter": trial["adapter"],
        "adapter_receipt": trial["adapter_receipt"],
        "assignments": assignments,
        "positive_run_ids": sorted(
            assignment["run_id"]
            for assignment in assignments
            if assignment["effective_outcome"] == "positive"
        ),
    }


def _trial_core_from_record(trial: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": _SCHEMA_VERSION,
        "job_id": trial["job_id"],
        "candidate_record_digest": trial["candidate_record_digest"],
        "replacement_digest": trial["replacement_digest"],
        "base_digest": trial["base_digest"],
        "base_revision": trial["base_revision"],
        "learning_epoch": trial["learning_epoch"],
        "feedback_revision": trial["feedback_revision"],
        "algorithm_id": trial["algorithm_id"],
        "adapter": trial["adapter"],
        "admitted_at": trial["admitted_at"],
        "assignment_deadline": trial["assignment_deadline"],
        "decision_deadline": trial["decision_deadline"],
    }


def _settled_cohort(job: dict[str, Any], trial: dict[str, Any]) -> list[dict[str, Any]]:
    cohort: list[dict[str, Any]] = []
    for assignment in trial["assignments"]:
        signal = _effective_signal(job, "run", assignment["run_id"])
        owner_signal_event_digest = (
            signal["event_digest"]
            if signal is not None and signal["signal"] in _OWNER_RESULT_SIGNALS
            else None
        )
        cohort.append(
            {
                "run_id": assignment["run_id"],
                "outcome": assignment["outcome"],
                "evaluation_digest": assignment["evaluation_digest"],
                "effective_outcome": _effective_trial_outcome(job, assignment),
                "evaluation_required": owner_signal_event_digest is None,
                "owner_signal_event_digest": owner_signal_event_digest,
            }
        )
    return cohort


def _adapter_pass_matches(trial: dict[str, Any]) -> bool:
    adapter = trial["adapter"]
    receipt = trial["adapter_receipt"]
    if adapter is None:
        return receipt is None
    if receipt is None or receipt["outcome"] != "pass":
        return False
    if receipt["candidate_digest"] != trial["replacement_digest"]:
        return False
    return all(receipt[field] == adapter[field] for field in _ADAPTER_BINDING_FIELDS)


def _promotion_cas_failures(
    state: dict[str, Any],
    job: dict[str, Any],
    trial: dict[str, Any],
) -> list[str]:
    failures: list[str] = []
    candidate = _candidate(job, trial["candidate_record_digest"])
    if not job["repeatable"] or job["cancelled"]:
        failures.append("job_status")
    if trial["job_id"] != job["job_id"]:
        failures.append("trial_job_id")
    recomputed_trial_digest = canonical_sha256(
        {"domain": _TRIAL_DOMAIN, "value": _trial_core_from_record(trial)}
    )
    if trial["trial_digest"] != recomputed_trial_digest:
        failures.append("trial_digest")
    if candidate is None:
        failures.append("candidate_record_digest")
    else:
        if candidate["replacement_digest"] != trial["replacement_digest"]:
            failures.append("replacement_digest")
        if (
            candidate["base_digest"] != trial["base_digest"]
            or candidate["base_revision"] != trial["base_revision"]
        ):
            failures.append("candidate_base")
        if candidate["learning_epoch"] != trial["learning_epoch"]:
            failures.append("candidate_learning_epoch")
        if candidate["feedback_revision"] != trial["feedback_revision"]:
            failures.append("candidate_feedback_revision")
        if candidate["algorithm_id"] != trial["algorithm_id"]:
            failures.append("candidate_algorithm_id")
        if candidate["source_manifest_digest"] != trial["source_manifest_digest"]:
            failures.append("source_manifest_digest")
        if not candidate["admitted"] or candidate["superseded"] or candidate["vetoed"]:
            failures.append("candidate_status")
    if (
        job["stable_digest"] != trial["base_digest"]
        or job["stable_revision"] != trial["base_revision"]
    ):
        failures.append("stable_pointer")
    if job["learning_epoch"] != trial["learning_epoch"]:
        failures.append("learning_epoch")
    if job["feedback_revision"] != trial["feedback_revision"]:
        failures.append("feedback_revision")
    if state["algorithm_id"] != trial["algorithm_id"]:
        failures.append("algorithm_id")
    if job["job_definition_digest"] != trial["job_definition_digest"]:
        failures.append("job_definition_digest")
    if job["compatibility_digest"] != trial["compatibility_digest"]:
        failures.append("compatibility_digest")
    if not _adapter_pass_matches(trial):
        failures.append("adapter_gate")
    cohort = _settled_cohort(job, trial)
    if any(entry["effective_outcome"] == "negative" for entry in cohort):
        failures.append("negative_support")
    if sum(entry["effective_outcome"] == "positive" for entry in cohort) < (_POSITIVE_TRIAL_RUNS):
        failures.append("positive_support")
    if any(
        assignment["status"] != "settled" or assignment["evaluation_digest"] is None
        for assignment in trial["assignments"]
    ):
        failures.append("settled_cohort")
    return failures


def _closed_trial_record(
    state: dict[str, Any],
    trial: dict[str, Any],
    status: str,
) -> dict[str, Any]:
    return {
        **trial,
        "assignment_closed_at": trial["assignment_closed_at"] or state["controlled_clock"],
        "status": status,
        "decided_at": state["controlled_clock"],
    }


def _promote_trial(
    state: dict[str, Any],
    job: dict[str, Any],
    trial: dict[str, Any],
    event: ReplayEvent,
    reason: str,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    failures = _promotion_cas_failures(state, job, trial)
    if failures:
        closed_trial = _closed_trial_record(state, trial, "stale_promotion")
        after = _replace_job(state, {**job, "trial": closed_trial})
        identities = {
            **_trial_artifact_identities(job, closed_trial),
            "failed_predicates": failures,
            "current_stable_digest": job["stable_digest"],
            "current_stable_revision": job["stable_revision"],
            "current_feedback_revision": job["feedback_revision"],
        }
        receipt = _decision(
            before=state,
            after=after,
            event=event,
            decision="stale_promotion",
            reason="promotion_compare_and_swap_miss",
            artifact_identities=identities,
        )
        return after, [receipt]

    closed_trial = _closed_trial_record(state, trial, "promoted")
    cohort = _settled_cohort(job, closed_trial)
    positive_supports = [entry for entry in cohort if entry["effective_outcome"] == "positive"]
    promotion_revision = trial["base_revision"] + 1
    promotion_core = {
        "schema_version": _SCHEMA_VERSION,
        "job_id": job["job_id"],
        "trial_digest": trial["trial_digest"],
        "candidate_record_digest": trial["candidate_record_digest"],
        "replacement_digest": trial["replacement_digest"],
        "source_manifest_digest": trial["source_manifest_digest"],
        "base_digest": trial["base_digest"],
        "base_revision": trial["base_revision"],
        "learning_epoch": trial["learning_epoch"],
        "feedback_revision": trial["feedback_revision"],
        "algorithm_id": trial["algorithm_id"],
        "job_definition_digest": trial["job_definition_digest"],
        "compatibility_digest": trial["compatibility_digest"],
        "adapter": trial["adapter"],
        "adapter_receipt": trial["adapter_receipt"],
        "settled_cohort": cohort,
        "positive_supports": positive_supports,
        "promotion_revision": promotion_revision,
        "activated_at": state["controlled_clock"],
        "triggering_event": event_json(event),
    }
    promotion = {
        **{field: value for field, value in promotion_core.items() if field != "schema_version"},
        "promotion_digest": canonical_sha256(
            {"domain": _PROMOTION_DOMAIN, "value": promotion_core}
        ),
        "status": "active",
        "rollback": None,
    }
    promotion_history = [*job["promotion_history"]]
    if job["promotion"] is not None:
        promotion_history.append(job["promotion"]["promotion_digest"])
    updated = {
        **job,
        "stable_digest": trial["replacement_digest"],
        "stable_revision": promotion_revision,
        "trial": closed_trial,
        "promotion": promotion,
        "promotion_history": promotion_history,
    }
    after = _replace_job(state, updated)
    identities = {
        **_trial_artifact_identities(job, closed_trial),
        "promotion_digest": promotion["promotion_digest"],
        "promotion_revision": promotion_revision,
        "settled_cohort": cohort,
        "positive_supports": positive_supports,
    }
    receipt = _decision(
        before=state,
        after=after,
        event=event,
        decision="promoted",
        reason=reason,
        artifact_identities=identities,
    )
    return after, [receipt]


def _promotion_core_from_record(promotion: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": _SCHEMA_VERSION,
        "job_id": promotion["job_id"],
        "trial_digest": promotion["trial_digest"],
        "candidate_record_digest": promotion["candidate_record_digest"],
        "replacement_digest": promotion["replacement_digest"],
        "source_manifest_digest": promotion["source_manifest_digest"],
        "base_digest": promotion["base_digest"],
        "base_revision": promotion["base_revision"],
        "learning_epoch": promotion["learning_epoch"],
        "feedback_revision": promotion["feedback_revision"],
        "algorithm_id": promotion["algorithm_id"],
        "job_definition_digest": promotion["job_definition_digest"],
        "compatibility_digest": promotion["compatibility_digest"],
        "adapter": promotion["adapter"],
        "adapter_receipt": promotion["adapter_receipt"],
        "settled_cohort": promotion["settled_cohort"],
        "positive_supports": promotion["positive_supports"],
        "promotion_revision": promotion["promotion_revision"],
        "activated_at": promotion["activated_at"],
        "triggering_event": promotion["triggering_event"],
    }


def _remaining_positive_supports(
    job: dict[str, Any],
    promotion: dict[str, Any],
) -> list[dict[str, Any]]:
    remaining: list[dict[str, Any]] = []
    for support in promotion["positive_supports"]:
        result = _effective_signal(job, "run", support["run_id"])
        if result is not None and result["signal"] in {
            "result_not_useful",
            "result_correction",
        }:
            continue
        owner_supports = result is not None and result["signal"] == "result_useful"
        judgement = _effective_signal(job, "evaluation", support["evaluation_digest"])
        disputed = judgement is not None and judgement["signal"] == "evaluation_dispute"
        if disputed and support["evaluation_required"] and not owner_supports:
            continue
        remaining.append(support)
    return remaining


def _owner_rollback_trigger(
    job: dict[str, Any],
    event: ReplayEvent,
) -> tuple[str, str, bool, list[dict[str, Any]]] | None:
    promotion = job["promotion"]
    if promotion is None:
        return None
    payload = event.payload
    signal = payload["signal"]
    remaining = _remaining_positive_supports(job, promotion)
    trigger: tuple[str, str, bool, list[dict[str, Any]]] | None = None
    if (
        signal == "candidate_reject"
        and payload["subject_digest"] == promotion["candidate_record_digest"]
    ):
        trigger = (
            "owner_candidate_reject",
            "owner_candidate_reject",
            True,
            remaining,
        )
    elif signal == "promotion_rollback":
        trigger = (
            "owner_promotion_rollback",
            "owner_promotion_rollback",
            payload["subject_digest"] == promotion["promotion_digest"],
            remaining,
        )
    elif signal in {"result_not_useful", "result_correction"}:
        supports_run = any(
            support["run_id"] == payload["run_id"] for support in promotion["positive_supports"]
        )
        if supports_run and len(remaining) < _POSITIVE_TRIAL_RUNS:
            trigger = "owner_support_invalidated", "owner_run_feedback", True, remaining
    elif signal == "evaluation_dispute":
        supports_evaluation = any(
            support["evaluation_digest"] == payload["subject_digest"]
            and support["evaluation_required"]
            for support in promotion["positive_supports"]
        )
        if supports_evaluation and len(remaining) < _POSITIVE_TRIAL_RUNS:
            trigger = "owner_support_invalidated", "owner_evaluation_dispute", True, remaining
    return trigger


def _rollback_cas_failures(
    state: dict[str, Any],
    job: dict[str, Any],
    promotion: dict[str, Any],
    *,
    source_matches: bool,
) -> list[str]:
    failures: list[str] = []
    if not source_matches:
        failures.append("trigger_identity")
    if promotion["job_id"] != job["job_id"]:
        failures.append("promotion_job_id")
    if promotion["status"] != "active":
        failures.append("promotion_status")
    if job["stable_digest"] != promotion["replacement_digest"]:
        failures.append("stable_digest")
    if job["stable_revision"] != promotion["promotion_revision"]:
        failures.append("stable_revision")
    if job["learning_epoch"] != promotion["learning_epoch"]:
        failures.append("learning_epoch")
    if state["algorithm_id"] != promotion["algorithm_id"]:
        failures.append("algorithm_id")
    if job["job_definition_digest"] != promotion["job_definition_digest"]:
        failures.append("job_definition_digest")
    if job["compatibility_digest"] != promotion["compatibility_digest"]:
        failures.append("compatibility_digest")
    if promotion["promotion_revision"] != promotion["base_revision"] + 1:
        failures.append("promotion_revision")
    candidate = _candidate(job, promotion["candidate_record_digest"])
    if candidate is None:
        failures.append("candidate_record_digest")
    else:
        if candidate["replacement_digest"] != promotion["replacement_digest"]:
            failures.append("replacement_digest")
        if (
            candidate["base_digest"] != promotion["base_digest"]
            or candidate["base_revision"] != promotion["base_revision"]
        ):
            failures.append("candidate_base")
        if candidate["learning_epoch"] != promotion["learning_epoch"]:
            failures.append("candidate_learning_epoch")
        if candidate["feedback_revision"] != promotion["feedback_revision"]:
            failures.append("candidate_feedback_revision")
        if candidate["algorithm_id"] != promotion["algorithm_id"]:
            failures.append("candidate_algorithm_id")
        if candidate["source_manifest_digest"] != promotion["source_manifest_digest"]:
            failures.append("source_manifest_digest")
    recomputed = canonical_sha256(
        {"domain": _PROMOTION_DOMAIN, "value": _promotion_core_from_record(promotion)}
    )
    if promotion["promotion_digest"] != recomputed:
        failures.append("promotion_digest")
    return failures


def _rollback_artifact_identities(
    job: dict[str, Any],
    promotion: dict[str, Any],
    event: ReplayEvent,
    *,
    source_kind: str,
    remaining_supports: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "job_id": job["job_id"],
        "promotion_digest": promotion["promotion_digest"],
        "trial_digest": promotion["trial_digest"],
        "candidate_record_digest": promotion["candidate_record_digest"],
        "replacement_digest": promotion["replacement_digest"],
        "base_digest": promotion["base_digest"],
        "base_revision": promotion["base_revision"],
        "promotion_revision": promotion["promotion_revision"],
        "before_stable_digest": job["stable_digest"],
        "before_stable_revision": job["stable_revision"],
        "source_kind": source_kind,
        "triggering_event": event_json(event),
        "remaining_positive_supports": remaining_supports,
    }


def _rollback_promotion(
    state: dict[str, Any],
    event: ReplayEvent,
    *,
    reason: str,
    source_kind: str,
    source_matches: bool,
    remaining_supports: list[dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    job = state["jobs"][event.payload["job_id"]]
    promotion = job["promotion"]
    if promotion is None:
        return state, []
    failures = _rollback_cas_failures(
        state,
        job,
        promotion,
        source_matches=source_matches,
    )
    identities = _rollback_artifact_identities(
        job,
        promotion,
        event,
        source_kind=source_kind,
        remaining_supports=remaining_supports,
    )
    if failures:
        receipt = _decision(
            before=state,
            after=state,
            event=event,
            decision="stale_rollback",
            reason="rollback_compare_and_swap_miss",
            artifact_identities={**identities, "failed_predicates": failures},
        )
        return state, [receipt]

    after_revision = job["stable_revision"] + 1
    rollback = {
        "reason": reason,
        "source_kind": source_kind,
        "triggering_event": event_json(event),
        "remaining_positive_supports": remaining_supports,
        "restored_digest": promotion["base_digest"],
        "before_stable_revision": job["stable_revision"],
        "after_stable_revision": after_revision,
        "rolled_back_at": state["controlled_clock"],
    }
    updated_promotion = {**promotion, "status": "rolled_back", "rollback": rollback}
    dependent_trial = _open_trial(job)
    closed_dependent_trial = (
        None
        if dependent_trial is None
        else _closed_trial_record(state, dependent_trial, "fallback")
    )
    after = _replace_job(
        state,
        {
            **job,
            "stable_digest": promotion["base_digest"],
            "stable_revision": after_revision,
            "trial": job["trial"] if closed_dependent_trial is None else closed_dependent_trial,
            "promotion": updated_promotion,
        },
    )
    decisions: list[dict[str, Any]] = []
    if closed_dependent_trial is not None:
        decisions.append(
            _decision(
                before=state,
                after=after,
                event=event,
                decision="fallback",
                reason="promotion_rollback_invalidated_base",
                artifact_identities={
                    **_trial_artifact_identities(job, closed_dependent_trial),
                    "invalidating_promotion_digest": promotion["promotion_digest"],
                    "before_stable_digest": job["stable_digest"],
                    "before_stable_revision": job["stable_revision"],
                    "after_stable_digest": promotion["base_digest"],
                    "after_stable_revision": after_revision,
                    "triggering_event": event_json(event),
                },
            )
        )
    receipt = _decision(
        before=state,
        after=after,
        event=event,
        decision="rollback",
        reason=reason,
        artifact_identities={
            **identities,
            "after_stable_digest": promotion["base_digest"],
            "after_stable_revision": after_revision,
        },
    )
    return after, [*decisions, receipt]
