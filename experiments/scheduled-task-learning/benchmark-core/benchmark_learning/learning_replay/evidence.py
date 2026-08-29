"""Stable evidence, reflector operations, and owner-signal records."""

from __future__ import annotations

from typing import Any

from benchmark_core.canonical import canonical_sha256
from benchmark_core.contract_validation import ValidationIssue, issue

from benchmark_learning.learning_contract import ReplayEvent, event_json

from .state import (
    _EVIDENCE_WINDOW_DAYS,
    _EVIDENCE_WINDOW_SIZE,
    _NEGATIVE_EVALUATOR_OUTCOMES,
    _NEGATIVE_RUNS_FOR_TRIGGER,
    _OPERATION_START_FIELDS,
    _OWNER_NOT_USEFUL_CODE,
    _OWNER_RESULT_SIGNALS,
    _POSITIVE_EVALUATOR_OUTCOMES,
    _SCHEMA_VERSION,
    _SIGNAL_SUBJECT_KINDS,
    _TRIGGER_DOMAIN,
    _candidate,
    _copy_body,
    _decision,
    _evaluation_run_id,
    _job_or_raise,
    _open_trial,
    _reject,
    _replace_job,
    _require_valid,
    _shift_days,
    _trial_assignment,
    _trigger,
)

# MARK: - Compatible evidence window and effective outcomes


def _stable_window(state: dict[str, Any], job: dict[str, Any]) -> list[dict[str, Any]]:
    cutoff = _shift_days(state["controlled_clock"], -_EVIDENCE_WINDOW_DAYS)
    eligible = [
        entry
        for entry in job["evaluations"]
        if entry["learning_epoch"] == job["learning_epoch"]
        and entry["stable_digest"] == job["stable_digest"]
        and entry["compatibility_digest"] == job["compatibility_digest"]
        and entry["logical_occurrence"] >= cutoff
        and entry["logical_occurrence"] <= state["controlled_clock"]
    ]
    eligible.sort(key=lambda entry: (entry["logical_occurrence"], entry["run_id"]))
    return eligible[-_EVIDENCE_WINDOW_SIZE:]


def _signal_key(record: dict[str, Any]) -> Any:
    return record["subject_digest"]


def _effective_signal(job: dict[str, Any], subject_kind: str, key: Any) -> dict[str, Any] | None:
    for record in reversed(job["owner_signals"]):
        if record["superseded"] or record["subject_kind"] != subject_kind:
            continue
        if _signal_key(record) == key:
            signal: dict[str, Any] = record
            return signal
    return None


def _evaluator_outcome(evaluation: dict[str, Any]) -> tuple[str, list[str]]:
    outcome = evaluation["outcome"]
    if outcome in _POSITIVE_EVALUATOR_OUTCOMES:
        return "positive", []
    if outcome in _NEGATIVE_EVALUATOR_OUTCOMES:
        return "negative", list(evaluation["issue_codes"])
    return "neutral", []


def _effective_outcome(job: dict[str, Any], evaluation: dict[str, Any]) -> dict[str, Any] | None:
    """Resolve one run's effective outcome, or `None` when a dispute removed the evaluation."""

    judgement = _effective_signal(job, "evaluation", evaluation["evaluation_digest"])
    disputed = judgement is not None and judgement["signal"] == "evaluation_dispute"
    correction = False
    evaluation_required = False
    uses_evaluator_codes = bool(evaluation["issue_codes"]) and not disputed
    result = _effective_signal(job, "run", evaluation["run_id"])
    if result is not None and result["signal"] in _OWNER_RESULT_SIGNALS:
        if result["signal"] == "result_useful":
            outcome, codes = "positive", []
        elif result["signal"] == "result_not_useful":
            outcome = "negative"
            codes = (
                list(evaluation["issue_codes"])
                if uses_evaluator_codes
                else [_OWNER_NOT_USEFUL_CODE]
            )
            evaluation_required = uses_evaluator_codes
        else:
            outcome = "negative"
            codes = list(evaluation["issue_codes"]) if uses_evaluator_codes else []
            correction = True
            evaluation_required = uses_evaluator_codes
    else:
        if disputed:
            return None
        outcome, codes = _evaluator_outcome(evaluation)
        evaluation_required = True
    return {
        "run_id": evaluation["run_id"],
        "evaluation_digest": evaluation["evaluation_digest"],
        "evaluation_required": evaluation_required,
        "outcome": outcome,
        "issue_codes": sorted(codes),
        "correction": correction,
    }


def _outcomes(job: dict[str, Any], evaluations: list[dict[str, Any]]) -> list[dict[str, Any]]:
    resolved = (_effective_outcome(job, entry) for entry in evaluations)
    return [entry for entry in resolved if entry is not None]


def _support(outcomes: list[dict[str, Any]]) -> tuple[str, list[str]] | None:
    """Return the trigger support kind and its complete ordered qualifying issue codes."""

    corrections = [entry for entry in outcomes if entry["correction"]]
    if corrections:
        return "owner_correction", sorted(
            {code for entry in corrections for code in entry["issue_codes"]}
        )
    runs_by_code: dict[str, set[str]] = {}
    for entry in outcomes:
        if entry["outcome"] != "negative":
            continue
        for code in entry["issue_codes"]:
            runs_by_code.setdefault(code, set()).add(entry["run_id"])
    codes = sorted(
        code for code, runs in runs_by_code.items() if len(runs) >= _NEGATIVE_RUNS_FOR_TRIGGER
    )
    if not codes:
        return None
    return "two_negative_runs", codes


def _qualifying_trigger(state: dict[str, Any], job: dict[str, Any]) -> dict[str, Any] | None:
    outcomes = _outcomes(job, _stable_window(state, job))
    support = _support(outcomes)
    if support is None:
        return None
    kind, codes = support
    evidence = [
        {
            "run_id": entry["run_id"],
            "evaluation_digest": entry["evaluation_digest"],
            "evaluation_required": entry["evaluation_required"],
        }
        for entry in outcomes
    ]
    core = {
        "schema_version": _SCHEMA_VERSION,
        "algorithm_id": state["algorithm_id"],
        "job_id": job["job_id"],
        "learning_epoch": job["learning_epoch"],
        "stable_digest": job["stable_digest"],
        "evidence_digests": [entry["evaluation_digest"] for entry in evidence],
        "feedback_revision": job["feedback_revision"],
        "issue_codes": codes,
    }
    return {
        "trigger_digest": canonical_sha256({"domain": _TRIGGER_DOMAIN, "value": core}),
        "support": kind,
        "issue_codes": codes,
        "evidence": evidence,
        "stable_digest": job["stable_digest"],
        "learning_epoch": job["learning_epoch"],
        "feedback_revision": job["feedback_revision"],
        "attempted": False,
        "operation_id": None,
        "closed": False,
        "closure": None,
        "candidate_record_digest": None,
    }


def _maybe_trigger(
    state: dict[str, Any],
    job_id: str,
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    job = state["jobs"][job_id]
    if job["cancelled"] or not job["repeatable"] or _open_trial(job) is not None:
        return state, []
    trigger = _qualifying_trigger(state, job)
    if trigger is None or _trigger(job, trigger["trigger_digest"]) is not None:
        return state, []
    after = _replace_job(state, {**job, "triggers": [*job["triggers"], trigger]})
    receipt = _decision(
        before=state,
        after=after,
        event=event,
        decision="reflected",
        reason=trigger["support"],
        artifact_identities={
            "job_id": job_id,
            "trigger_digest": trigger["trigger_digest"],
            "issue_codes": trigger["issue_codes"],
            "evidence_digests": [entry["evaluation_digest"] for entry in trigger["evidence"]],
            "stable_digest": trigger["stable_digest"],
            "learning_epoch": trigger["learning_epoch"],
            "feedback_revision": trigger["feedback_revision"],
        },
    )
    return after, [receipt]


# MARK: - Controller, clock, and operations


def _trigger_snapshot_issues(
    job: dict[str, Any],
    trigger: dict[str, Any],
    issues: list[ValidationIssue],
) -> None:
    if (
        trigger["stable_digest"] != job["stable_digest"]
        or trigger["learning_epoch"] != job["learning_epoch"]
        or trigger["feedback_revision"] != job["feedback_revision"]
    ):
        issue(
            issues,
            "policy.stale_trigger",
            "$.payload.trigger_digest must retain the current job snapshot",
        )


def _apply_operation_started(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    issues: list[ValidationIssue] = []
    if payload["operation_id"] in job["operations"]:
        issue(issues, "policy.duplicate_operation", "$.payload.operation_id is already recorded")
    if payload["attempt_generation"] != state["controller_generation"]:
        issue(
            issues,
            "policy.attempt_generation",
            "$.payload.attempt_generation must equal the current controller generation",
        )
    trigger = None
    if payload["operation_kind"] == "reflector":
        trigger = _trigger(job, payload["trigger_digest"])
        if trigger is None:
            issue(
                issues,
                "policy.unknown_trigger",
                "$.payload.trigger_digest is not a frozen trigger",
            )
        elif trigger["closed"]:
            issue(
                issues,
                "policy.closed_trigger",
                "$.payload.trigger_digest is already closed",
            )
        elif trigger["attempted"]:
            issue(
                issues,
                "policy.attempted_trigger",
                "$.payload.trigger_digest already owns a reflector attempt",
            )
        if trigger is not None:
            _trigger_snapshot_issues(job, trigger, issues)
    _require_valid(issues)
    record = {field: payload[field] for field in _OPERATION_START_FIELDS}
    record.update({"status": "started", "result_digest": None, "usage_digest": None})
    operations = {**job["operations"], payload["operation_id"]: record}
    triggers = job["triggers"]
    if trigger is not None:
        triggers = [
            {
                **entry,
                "attempted": True,
                "operation_id": payload["operation_id"],
            }
            if entry["trigger_digest"] == payload["trigger_digest"]
            else entry
            for entry in triggers
        ]
    return _replace_job(state, {**job, "operations": operations, "triggers": triggers}), []


def _apply_operation_finished(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    issues: list[ValidationIssue] = []
    record = job["operations"].get(payload["operation_id"])
    if record is None:
        _reject("policy.unknown_operation", "$.payload.operation_id is not a started process")
    if record["operation_kind"] != payload["operation_kind"]:
        issue(issues, "policy.operation_identity", "$.payload.operation_kind must match the start")
    if record["attempt_generation"] != payload["attempt_generation"]:
        issue(
            issues,
            "policy.operation_identity",
            "$.payload.attempt_generation must match the start",
        )
    if record["status"] != "started":
        issue(issues, "policy.operation_identity", "$.payload.operation_id is already terminal")
    _require_valid(issues)
    finished = {
        **record,
        "status": payload["status"],
        "result_digest": payload["result_digest"],
        "usage_digest": payload["usage_digest"],
    }
    operations = {**job["operations"], payload["operation_id"]: finished}
    return _replace_job(state, {**job, "operations": operations}), []


# MARK: - Owner signals


def _subject_issues(
    job: dict[str, Any],
    payload: dict[str, Any],
    issues: list[ValidationIssue],
) -> None:
    kind = payload["subject_kind"]
    if kind != _SIGNAL_SUBJECT_KINDS[payload["signal"]]:
        issue(issues, "policy.signal_subject", "$.payload.signal cannot target this subject kind")
        return
    if kind == "run":
        recorded = (
            any(entry["run_id"] == payload["run_id"] for entry in job["evaluations"])
            or _trial_assignment(job, payload["run_id"]) is not None
        )
        if not recorded:
            issue(issues, "policy.unknown_subject", "$.payload.run_id is not a recorded run")
        elif payload["subject_digest"] != payload["run_id"]:
            issue(
                issues,
                "policy.unknown_subject",
                "$.payload.subject_digest must equal the exact recorded run_id",
            )
        return
    if kind == "evaluation":
        evaluation_run_id = _evaluation_run_id(job, payload["subject_digest"])
        if evaluation_run_id is None:
            issue(
                issues,
                "policy.unknown_subject",
                "$.payload.subject_digest is not a recorded evaluation",
            )
        elif evaluation_run_id != payload["run_id"]:
            issue(
                issues,
                "policy.unknown_subject",
                "$.payload.run_id disagrees with the evaluation subject",
            )
        return
    if kind == "candidate":
        if _candidate(job, payload["subject_digest"]) is None:
            issue(
                issues,
                "policy.unknown_subject",
                "$.payload.subject_digest is not a recorded candidate",
            )
        return
    promotion = job["promotion"]
    current_digest = None if promotion is None else promotion["promotion_digest"]
    if (
        payload["subject_digest"] != current_digest
        and payload["subject_digest"] not in job["promotion_history"]
    ):
        issue(issues, "policy.unknown_subject", "$.payload.subject_digest is not the promotion")


def _supersession_issues(
    job: dict[str, Any],
    payload: dict[str, Any],
    issues: list[ValidationIssue],
) -> None:
    current = _effective_signal(job, payload["subject_kind"], _signal_key(payload))
    supersedes = payload["supersedes_revision"]
    if supersedes is None:
        if current is not None:
            issue(
                issues,
                "policy.supersession",
                "$.payload.supersedes_revision must link the effective signal on this subject",
            )
        return
    if current is None or current["revision"] != supersedes:
        issue(
            issues,
            "policy.supersession",
            "$.payload.supersedes_revision must equal the effective signal revision",
        )
        return
    if payload["revision"] <= supersedes:
        issue(issues, "policy.supersession", "$.payload.revision must exceed the superseded one")


def _record_owner_signal(job: dict[str, Any], event: ReplayEvent) -> dict[str, Any]:
    payload = event.payload
    key = _signal_key(payload)
    signals: list[dict[str, Any]] = []
    for record in job["owner_signals"]:
        superseded = (
            not record["superseded"]
            and record["subject_kind"] == payload["subject_kind"]
            and _signal_key(record) == key
        )
        signals.append({**record, "superseded": True} if superseded else record)
    signals.append(
        {
            "subject_kind": payload["subject_kind"],
            "subject_digest": payload["subject_digest"],
            "run_id": payload["run_id"],
            "signal": payload["signal"],
            "payload": _copy_body(payload["payload"]),
            "revision": payload["revision"],
            "supersedes_revision": payload["supersedes_revision"],
            "superseded": False,
            "event_digest": canonical_sha256(event_json(event)),
        }
    )
    return {
        **job,
        "owner_signals": signals,
        "feedback_revision": job["feedback_revision"] + 1,
    }


def _apply_stable_evaluation(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    issues: list[ValidationIssue] = []
    if any(
        entry["evaluation_digest"] == payload["evaluation_digest"] for entry in job["evaluations"]
    ):
        issue(
            issues,
            "policy.duplicate_evaluation",
            "$.payload.evaluation_digest is already recorded",
        )
    if payload["run_id"] in job["trial_run_ids"]:
        issue(
            issues,
            "policy.trial_run_stable_classification",
            "$.payload.run_id was already assigned to a trial",
        )
    _require_valid(issues)
    record = {**payload, "issue_codes": list(payload["issue_codes"])}
    state = _replace_job(state, {**job, "evaluations": [*job["evaluations"], record]})
    return _maybe_trigger(state, payload["job_id"], event)
