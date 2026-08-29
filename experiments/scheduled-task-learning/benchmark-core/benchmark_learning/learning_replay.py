"""Pure `scheduled-learning/v1` reducer over the closed ordered replay event log."""

from __future__ import annotations

import unicodedata
from collections.abc import Callable
from datetime import datetime, timedelta
from typing import Any, NoReturn

from benchmark_core.canonical import canonical_sha256, dumps, loads_object
from benchmark_core.contract_validation import (
    ValidationIssue,
    bounded_string,
    exact_keys,
    is_integer,
    issue,
)

from benchmark_learning.learning_contract import (
    LearningContractError,
    ReplayEvent,
    ReplayEventKind,
    canonical_event_log,
    decision_receipt,
    event_json,
    replay_receipt,
)

_SCHEMA_VERSION = 1
_INITIAL_CONTROLLER_GENERATION = 1
_OPAQUE_STRING_BOUNDS = (1, 128)
_TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

_EVIDENCE_WINDOW_DAYS = 30
_EVIDENCE_WINDOW_SIZE = 5
_NEGATIVE_RUNS_FOR_TRIGGER = 2
_ASSIGNMENT_DEADLINE_DAYS = 30
_DECISION_DEADLINE_DAYS = 37
_MAX_LESSONS = 3
_MAX_LESSON_BYTES = 512
_MAX_LESSON_SET_BYTES = 1536

# The fixed synthetic code an owner "not useful" signal contributes when the evaluator recorded
# no exact issue code of its own; version 1 performs no semantic clustering of free text.
_OWNER_NOT_USEFUL_CODE = "owner_not_useful"

_TRIGGER_DOMAIN = "scheduled-learning/v1/trigger"
_CANDIDATE_RECORD_DOMAIN = "scheduled-learning/v1/candidate-record"
_CANDIDATE_SOURCE_DOMAIN = "scheduled-learning/v1/candidate-source"

_INITIAL_JOB_KEYS = {
    "job_id",
    "repeatable",
    "cancelled",
    "learning_epoch",
    "job_definition_digest",
    "stable_digest",
    "stable_revision",
    "compatibility_digest",
    "feedback_revision",
}
_DERIVED_JOB_KEYS = {
    "evaluations",
    "owner_signals",
    "operations",
    "triggers",
    "candidates",
    "closed_replacements",
    "vetoes",
    "trial",
    "promotion",
}
_JOB_KEYS = _INITIAL_JOB_KEYS | _DERIVED_JOB_KEYS
_STATE_KEYS = {
    "schema_version",
    "algorithm_id",
    "controlled_clock",
    "jobs",
    "controller_generation",
}

_OPAQUE_JOB_FIELDS = ("job_id", "job_definition_digest", "stable_digest", "compatibility_digest")
_COUNTER_JOB_FIELDS = ("learning_epoch", "stable_revision", "feedback_revision")

_OPERATION_START_FIELDS = (
    "operation_kind",
    "attempt_generation",
    "carrier_digest",
    "route_digest",
    "provider_call_id",
    "manifest_digest",
    "freeze_commit",
    "invocation_core_digest",
    "trigger_digest",
)

_POSITIVE_EVALUATOR_OUTCOMES = {"no_issue"}
_NEGATIVE_EVALUATOR_OUTCOMES = {"reusable_issue"}
_OWNER_RESULT_SIGNALS = {"result_useful", "result_not_useful", "result_correction"}

# One signal kind may target exactly one subject kind. An owner statement about a run's usefulness
# can never be replayed as a statement about a candidate or an active promotion.
_SIGNAL_SUBJECT_KINDS = {
    "result_useful": "run",
    "result_not_useful": "run",
    "result_correction": "run",
    "evaluation_confirm": "evaluation",
    "evaluation_dispute": "evaluation",
    "candidate_approve": "candidate",
    "candidate_reject": "candidate",
    "candidate_edit": "candidate",
    "promotion_rollback": "promotion",
}

_Handler = Callable[[dict[str, Any], ReplayEvent], tuple[dict[str, Any], list[dict[str, Any]]]]


def _require_valid(issues: list[ValidationIssue]) -> None:
    if issues:
        raise LearningContractError(issues)


def _reject(requirement: str, message: str) -> NoReturn:
    raise LearningContractError([ValidationIssue(requirement, message)])


def _opaque_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    bounded_string(value, *_OPAQUE_STRING_BOUNDS, path, issues)


def _parse_timestamp(value: str) -> datetime:
    return datetime.strptime(value, _TIMESTAMP_FORMAT)


def _format_timestamp(value: datetime) -> str:
    return value.strftime(_TIMESTAMP_FORMAT)


def _shift_days(value: str, days: int) -> str:
    return _format_timestamp(_parse_timestamp(value) + timedelta(days=days))


def _is_canonical_timestamp(value: str) -> bool:
    # Round-tripping is the format check: it rejects every spelling whose fixed-width bytes would
    # not sort in chronological order, which is what the window and deadline comparisons rely on.
    try:
        parsed = _parse_timestamp(value)
    except ValueError:
        return False
    return _format_timestamp(parsed) == value


def _timestamp_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not isinstance(value, str) or not _is_canonical_timestamp(value):
        issue(issues, "schema.bounded_values", f"{path} must be a canonical UTC timestamp")


def _nonnegative_int_issues(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    if not is_integer(value) or value < 0:
        issue(issues, "schema.bounded_values", f"{path} must be a non-negative integer")


def _canonical_copy(value: dict[str, Any]) -> dict[str, Any]:
    return loads_object(dumps(value))


def _copy_body(value: Any) -> Any:
    if isinstance(value, dict):
        return _canonical_copy(value)
    return value


# MARK: - Initial state


def _initial_job_issues(entry: dict[str, Any], path: str, issues: list[ValidationIssue]) -> None:
    for field in _OPAQUE_JOB_FIELDS:
        _opaque_issues(entry.get(field), f"{path}.{field}", issues)
    for field in _COUNTER_JOB_FIELDS:
        _nonnegative_int_issues(entry.get(field), f"{path}.{field}", issues)
    for field in ("repeatable", "cancelled"):
        if not isinstance(entry.get(field), bool):
            issue(issues, "schema.bounded_values", f"{path}.{field} must be a boolean")


def _new_job(entry: dict[str, Any]) -> dict[str, Any]:
    job: dict[str, Any] = {field: entry[field] for field in sorted(_INITIAL_JOB_KEYS)}
    job.update(
        {
            "evaluations": [],
            "owner_signals": [],
            "operations": {},
            "triggers": [],
            "candidates": [],
            "closed_replacements": [],
            "vetoes": [],
            "trial": None,
            "promotion": None,
        }
    )
    return job


def initial_state(
    *,
    algorithm_id: str,
    controlled_clock: str,
    jobs: list[dict[str, Any]],
) -> dict[str, Any]:
    """Create the closed canonical replay state for one algorithm and its jobs."""

    issues: list[ValidationIssue] = []
    _opaque_issues(algorithm_id, "$.algorithm_id", issues)
    _timestamp_issues(controlled_clock, "$.controlled_clock", issues)
    records: dict[str, Any] = {}
    for index, entry in enumerate(jobs):
        path = f"$.jobs[{index}]"
        if not exact_keys(entry, _INITIAL_JOB_KEYS, _INITIAL_JOB_KEYS, path, issues):
            continue
        _initial_job_issues(entry, path, issues)
        job_id = entry["job_id"]
        if not isinstance(job_id, str):
            continue
        if job_id in records:
            issue(issues, "policy.unique_jobs", f"{path}.job_id repeats an earlier job")
        records[job_id] = _new_job(entry)
    _require_valid(issues)
    return {
        "schema_version": _SCHEMA_VERSION,
        "algorithm_id": algorithm_id,
        "controlled_clock": controlled_clock,
        "controller_generation": _INITIAL_CONTROLLER_GENERATION,
        "jobs": records,
    }


def _loaded_job_issues(
    job_id: Any,
    entry: Any,
    path: str,
    issues: list[ValidationIssue],
) -> None:
    if not exact_keys(entry, _JOB_KEYS, _JOB_KEYS, path, issues):
        return
    _initial_job_issues(entry, path, issues)
    if entry["job_id"] != job_id:
        issue(issues, "policy.unique_jobs", f"{path}.job_id must equal its map key")
    for field in _DERIVED_JOB_KEYS - {"operations", "trial", "promotion"}:
        if entry[field] != []:
            issue(issues, "policy.initial_state", f"{path}.{field} must start empty")
    if entry["operations"] != {}:
        issue(issues, "policy.initial_state", f"{path}.operations must start empty")
    for field in ("trial", "promotion"):
        if entry[field] is not None:
            issue(issues, "policy.initial_state", f"{path}.{field} must start null")


def _load_state(initial: dict[str, Any]) -> dict[str, Any]:
    issues: list[ValidationIssue] = []
    if exact_keys(initial, _STATE_KEYS, _STATE_KEYS, "$", issues):
        if initial["schema_version"] != _SCHEMA_VERSION:
            issue(issues, "schema.bounded_values", "$.schema_version must equal 1")
        _opaque_issues(initial["algorithm_id"], "$.algorithm_id", issues)
        _timestamp_issues(initial["controlled_clock"], "$.controlled_clock", issues)
        generation = initial["controller_generation"]
        if not is_integer(generation) or generation < _INITIAL_CONTROLLER_GENERATION:
            issue(issues, "schema.bounded_values", "$.controller_generation must be positive")
        if not isinstance(initial["jobs"], dict):
            issue(issues, "schema.single_object", "$.jobs must be an object")
        else:
            for job_id, entry in initial["jobs"].items():
                _loaded_job_issues(job_id, entry, f"$.jobs[{job_id}]", issues)
    _require_valid(issues)
    return _canonical_copy(initial)


# MARK: - State access


def _job_or_raise(state: dict[str, Any], job_id: str) -> dict[str, Any]:
    if job_id not in state["jobs"]:
        _reject("policy.unknown_job", f"$.payload.job_id must name a replay job: {job_id}")
    job: dict[str, Any] = state["jobs"][job_id]
    return job


def _replace_job(state: dict[str, Any], job: dict[str, Any]) -> dict[str, Any]:
    return {**state, "jobs": {**state["jobs"], job["job_id"]: job}}


def _candidate(job: dict[str, Any], digest: Any) -> dict[str, Any] | None:
    for record in job["candidates"]:
        if record["candidate_record_digest"] == digest:
            candidate: dict[str, Any] = record
            return candidate
    return None


def _trigger(job: dict[str, Any], digest: Any) -> dict[str, Any] | None:
    for record in job["triggers"]:
        if record["trigger_digest"] == digest:
            trigger: dict[str, Any] = record
            return trigger
    return None


def _decision(
    *,
    before: dict[str, Any],
    after: dict[str, Any],
    event: ReplayEvent,
    decision: str,
    reason: str,
    artifact_identities: dict[str, Any],
) -> dict[str, Any]:
    return decision_receipt(
        algorithm_id=after["algorithm_id"],
        decision=decision,
        reason=reason,
        triggering_event_sha256=canonical_sha256(event_json(event)),
        before_state_sha256=canonical_sha256(before),
        after_state_sha256=canonical_sha256(after),
        artifact_identities=artifact_identities,
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
    if job["cancelled"] or not job["repeatable"] or job["trial"] is not None:
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
    return {**state, "controller_generation": expected}, []


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
    return {**state, "controlled_clock": event.occurred_at}, []


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
        recorded = any(entry["run_id"] == payload["run_id"] for entry in job["evaluations"])
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
        evaluation = next(
            (
                entry
                for entry in job["evaluations"]
                if entry["evaluation_digest"] == payload["subject_digest"]
            ),
            None,
        )
        if evaluation is None:
            issue(
                issues,
                "policy.unknown_subject",
                "$.payload.subject_digest is not a recorded evaluation",
            )
        elif evaluation["run_id"] != payload["run_id"]:
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
    if promotion is None or promotion["promotion_digest"] != payload["subject_digest"]:
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
    if payload["subject_kind"] == "candidate":
        return _apply_candidate_control(state, event), []
    return _maybe_trigger(state, payload["job_id"], event)


# MARK: - Candidate lessons and digests


def _normalize_lesson(text: str) -> str:
    return unicodedata.normalize("NFC", text).replace("\r\n", "\n").replace("\r", "\n").strip()


def _normalize_lessons(lessons: list[str]) -> list[str]:
    return [_normalize_lesson(text) for text in lessons]


def _lesson_issues(lessons: list[str], path: str, issues: list[ValidationIssue]) -> None:
    if len(lessons) > _MAX_LESSONS:
        issue(issues, "policy.lesson_count", f"{path} must contain at most {_MAX_LESSONS} lessons")
    if any(text == "" for text in lessons):
        issue(issues, "policy.empty_lesson", f"{path} must not contain an empty normalized lesson")
    if len(set(lessons)) != len(lessons):
        issue(issues, "policy.duplicate_lesson", f"{path} must not repeat a normalized lesson")
    sizes = [len(text.encode("utf-8")) for text in lessons]
    if any(size > _MAX_LESSON_BYTES for size in sizes):
        issue(issues, "policy.lesson_bytes", f"{path} lessons must be <= {_MAX_LESSON_BYTES} bytes")
    if sum(sizes) > _MAX_LESSON_SET_BYTES:
        issue(
            issues,
            "policy.lesson_set_bytes",
            f"{path} must total <= {_MAX_LESSON_SET_BYTES} bytes",
        )


def _lesson_set_digest(lessons: list[str]) -> str:
    return canonical_sha256({"schema_version": _SCHEMA_VERSION, "lessons": lessons})


def _validated_replacement(
    job: dict[str, Any],
    lessons: list[str],
    path: str,
    issues: list[ValidationIssue],
) -> str | None:
    before = len(issues)
    _lesson_issues(lessons, path, issues)
    if len(issues) != before:
        return None
    digest = _lesson_set_digest(lessons)
    if digest == job["stable_digest"]:
        issue(issues, "policy.noop_replacement", f"{path} must differ from the stable lesson set")
        return None
    return digest


def _closed_replacement_key(
    state: dict[str, Any],
    job: dict[str, Any],
    replacement_digest: str,
) -> dict[str, Any]:
    return {
        "job_id": job["job_id"],
        "algorithm_id": state["algorithm_id"],
        "base_digest": job["stable_digest"],
        "replacement_digest": replacement_digest,
    }


def _candidate_record(
    *,
    origin: str,
    candidate_record_digest: str,
    replacement_digest: str,
    lessons: list[str],
    source_manifest_digest: str,
    job: dict[str, Any],
    algorithm_id: str,
    operation_id: str | None,
    result_digest: str | None,
    trigger_digest: str | None,
    predecessor: str | None,
) -> dict[str, Any]:
    return {
        "candidate_record_digest": candidate_record_digest,
        "replacement_digest": replacement_digest,
        "lessons": lessons,
        "source_manifest_digest": source_manifest_digest,
        "base_digest": job["stable_digest"],
        "base_revision": job["stable_revision"],
        "learning_epoch": job["learning_epoch"],
        "feedback_revision": job["feedback_revision"],
        "algorithm_id": algorithm_id,
        "origin": origin,
        "operation_id": operation_id,
        "result_digest": result_digest,
        "trigger_digest": trigger_digest,
        "predecessor_candidate_record_digest": predecessor,
        "admitted": False,
        "superseded": False,
        "vetoed": False,
    }


def _with_candidate_flags(
    job: dict[str, Any],
    digest: str,
    **flags: bool,
) -> list[dict[str, Any]]:
    return [
        {**record, **flags} if record["candidate_record_digest"] == digest else record
        for record in job["candidates"]
    ]


# MARK: - Candidate controls


def _candidate_control_issues(
    job: dict[str, Any],
    candidate: dict[str, Any],
    issues: list[ValidationIssue],
) -> None:
    if candidate["superseded"]:
        issue(issues, "policy.superseded_candidate", "$.payload.subject_digest is superseded")
    if candidate["vetoed"]:
        issue(issues, "policy.hard_veto", "$.payload.subject_digest is vetoed")
    if (
        candidate["base_digest"] != job["stable_digest"]
        or candidate["base_revision"] != job["stable_revision"]
    ):
        issue(issues, "policy.stale_base", "$.payload.subject_digest has a stale base")
    if candidate["learning_epoch"] != job["learning_epoch"]:
        issue(issues, "policy.stale_epoch", "$.payload.subject_digest has a stale learning epoch")


def _apply_candidate_approve(state: dict[str, Any], event: ReplayEvent) -> dict[str, Any]:
    payload = event.payload
    job = state["jobs"][payload["job_id"]]
    predecessor = _candidate(job, payload["subject_digest"])
    if predecessor is None:
        return state
    issues: list[ValidationIssue] = []
    _candidate_control_issues(job, predecessor, issues)
    if predecessor["admitted"]:
        issue(
            issues,
            "policy.candidate_already_admitted",
            "$.payload.subject_digest is already admitted",
        )
    _require_valid(issues)
    source_core = {
        "schema_version": _SCHEMA_VERSION,
        "origin": "owner_approval",
        "job_id": job["job_id"],
        "predecessor_candidate_record_digest": predecessor["candidate_record_digest"],
        "predecessor_source_manifest_digest": predecessor["source_manifest_digest"],
        "approval_event_digest": job["owner_signals"][-1]["event_digest"],
        "base_digest": job["stable_digest"],
        "base_revision": job["stable_revision"],
        "learning_epoch": job["learning_epoch"],
        "feedback_revision": job["feedback_revision"],
        "algorithm_id": state["algorithm_id"],
    }
    source_manifest_digest = canonical_sha256(
        {"domain": _CANDIDATE_SOURCE_DOMAIN, "value": source_core}
    )
    candidate_core = {
        "schema_version": _SCHEMA_VERSION,
        "job_id": job["job_id"],
        "predecessor_candidate_record_digest": predecessor["candidate_record_digest"],
        "replacement_digest": predecessor["replacement_digest"],
        "lessons": list(predecessor["lessons"]),
        "source_manifest_digest": source_manifest_digest,
        "base_digest": job["stable_digest"],
        "base_revision": job["stable_revision"],
        "learning_epoch": job["learning_epoch"],
        "feedback_revision": job["feedback_revision"],
        "algorithm_id": state["algorithm_id"],
    }
    successor = _candidate_record(
        origin="owner_approval",
        candidate_record_digest=canonical_sha256(
            {"domain": _CANDIDATE_RECORD_DOMAIN, "value": candidate_core}
        ),
        replacement_digest=predecessor["replacement_digest"],
        lessons=list(predecessor["lessons"]),
        source_manifest_digest=source_manifest_digest,
        job=job,
        algorithm_id=state["algorithm_id"],
        operation_id=None,
        result_digest=None,
        trigger_digest=predecessor["trigger_digest"],
        predecessor=predecessor["candidate_record_digest"],
    )
    candidates = _with_candidate_flags(job, predecessor["candidate_record_digest"], superseded=True)
    return _replace_job(state, {**job, "candidates": [*candidates, successor]})


def _apply_candidate_reject(state: dict[str, Any], event: ReplayEvent) -> dict[str, Any]:
    payload = event.payload
    job = state["jobs"][payload["job_id"]]
    digest = payload["subject_digest"]
    if _candidate(job, digest) is None:
        return state
    veto = {"subject_kind": "candidate", "subject_digest": digest, "origin": "candidate_reject"}
    return _replace_job(
        state,
        {
            **job,
            "candidates": _with_candidate_flags(job, digest, vetoed=True),
            "vetoes": [*job["vetoes"], veto],
        },
    )


def _apply_candidate_edit(state: dict[str, Any], event: ReplayEvent) -> dict[str, Any]:
    payload = event.payload
    job = state["jobs"][payload["job_id"]]
    predecessor = _candidate(job, payload["subject_digest"])
    if predecessor is None:
        return state
    issues: list[ValidationIssue] = []
    if predecessor["superseded"]:
        issue(issues, "policy.superseded_candidate", "$.payload.subject_digest is superseded")
    lessons = _normalize_lessons(payload["payload"]["lessons"])
    replacement_digest = _validated_replacement(job, lessons, "$.payload.payload.lessons", issues)
    _require_valid(issues)
    if replacement_digest is None:
        return state
    source_core = {
        "schema_version": _SCHEMA_VERSION,
        "origin": "owner_edit",
        "job_id": job["job_id"],
        "edit_event_digest": job["owner_signals"][-1]["event_digest"],
        "predecessor_candidate_record_digest": predecessor["candidate_record_digest"],
        "base_digest": job["stable_digest"],
        "base_revision": job["stable_revision"],
        "learning_epoch": job["learning_epoch"],
        "feedback_revision": job["feedback_revision"],
        "algorithm_id": state["algorithm_id"],
    }
    source_manifest_digest = canonical_sha256(
        {"domain": _CANDIDATE_SOURCE_DOMAIN, "value": source_core}
    )
    candidate_core = {
        **source_core,
        "replacement_digest": replacement_digest,
        "lessons": lessons,
        "source_manifest_digest": source_manifest_digest,
    }
    edited = _candidate_record(
        origin="owner_edit",
        candidate_record_digest=canonical_sha256(
            {"domain": _CANDIDATE_RECORD_DOMAIN, "value": candidate_core}
        ),
        replacement_digest=replacement_digest,
        lessons=lessons,
        source_manifest_digest=source_manifest_digest,
        job=job,
        algorithm_id=state["algorithm_id"],
        operation_id=None,
        result_digest=None,
        trigger_digest=None,
        predecessor=predecessor["candidate_record_digest"],
    )
    veto = {
        "subject_kind": "candidate",
        "subject_digest": predecessor["candidate_record_digest"],
        "origin": "candidate_edit",
    }
    candidates = _with_candidate_flags(
        job, predecessor["candidate_record_digest"], superseded=True, vetoed=True
    )
    return _replace_job(
        state,
        {**job, "candidates": [*candidates, edited], "vetoes": [*job["vetoes"], veto]},
    )


_CANDIDATE_CONTROLS: dict[str, Callable[[dict[str, Any], ReplayEvent], dict[str, Any]]] = {
    "candidate_approve": _apply_candidate_approve,
    "candidate_reject": _apply_candidate_reject,
    "candidate_edit": _apply_candidate_edit,
}


def _apply_candidate_control(state: dict[str, Any], event: ReplayEvent) -> dict[str, Any]:
    return _CANDIDATE_CONTROLS[event.payload["signal"]](state, event)


# MARK: - Reflector results


def _reflector_result_issues(
    job: dict[str, Any],
    payload: dict[str, Any],
    issues: list[ValidationIssue],
) -> None:
    record = job["operations"].get(payload["operation_id"])
    if record is None:
        issue(
            issues, "policy.unknown_operation", "$.payload.operation_id is not a recorded process"
        )
        return
    if record["operation_kind"] != "reflector":
        issue(issues, "policy.operation_identity", "$.payload.operation_id is not a reflector")
    if record["status"] != "succeeded":
        issue(issues, "policy.operation_identity", "$.payload.operation_id did not succeed")
    if record["result_digest"] != payload["result_digest"]:
        issue(
            issues,
            "policy.result_binding",
            "$.payload.result_digest must equal the durable operation result",
        )
    if record["trigger_digest"] != payload["trigger_digest"]:
        issue(
            issues,
            "policy.trigger_binding",
            "$.payload.trigger_digest must equal the operation's frozen trigger",
        )


def _open_trigger_issues(
    job: dict[str, Any],
    payload: dict[str, Any],
    issues: list[ValidationIssue],
) -> dict[str, Any] | None:
    trigger = _trigger(job, payload["trigger_digest"])
    if trigger is None:
        issue(issues, "policy.unknown_trigger", "$.payload.trigger_digest is not a frozen trigger")
        return None
    if trigger["closed"]:
        issue(issues, "policy.closed_trigger", "$.payload.trigger_digest is already closed")
        return None
    return trigger


def _closed_triggers(
    job: dict[str, Any],
    digest: str,
    closure: str,
    candidate_record_digest: str | None,
) -> list[dict[str, Any]]:
    return [
        {
            **record,
            "closed": True,
            "closure": closure,
            "candidate_record_digest": candidate_record_digest,
        }
        if record["trigger_digest"] == digest
        else record
        for record in job["triggers"]
    ]


def _apply_no_candidate(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    issues: list[ValidationIssue] = []
    _reflector_result_issues(job, payload, issues)
    _open_trigger_issues(job, payload, issues)
    _require_valid(issues)
    triggers = _closed_triggers(job, payload["trigger_digest"], "no_candidate", None)
    after = _replace_job(state, {**job, "triggers": triggers})
    receipt = _decision(
        before=state,
        after=after,
        event=event,
        decision="no_candidate",
        reason="reflector_returned_no_candidate",
        artifact_identities={
            "job_id": job["job_id"],
            "trigger_digest": payload["trigger_digest"],
            "operation_id": payload["operation_id"],
            "result_digest": payload["result_digest"],
        },
    )
    return after, [receipt]


def _candidate_artifact_issues(
    state: dict[str, Any],
    job: dict[str, Any],
    payload: dict[str, Any],
    issues: list[ValidationIssue],
) -> tuple[list[str], str | None]:
    _reflector_result_issues(job, payload, issues)
    _open_trigger_issues(job, payload, issues)
    if payload["algorithm_id"] != state["algorithm_id"]:
        issue(issues, "policy.algorithm_mismatch", "$.payload.algorithm_id must match the replay")
    if (
        payload["base_digest"] != job["stable_digest"]
        or payload["base_revision"] != job["stable_revision"]
    ):
        issue(issues, "policy.stale_base", "$.payload.base_digest must be the current stable base")
    if payload["learning_epoch"] != job["learning_epoch"]:
        issue(issues, "policy.stale_epoch", "$.payload.learning_epoch must be current")
    if payload["feedback_revision"] != job["feedback_revision"]:
        issue(
            issues,
            "policy.stale_feedback_revision",
            "$.payload.feedback_revision must be current",
        )
    lessons = _normalize_lessons(payload["lessons"])
    replacement_digest = _validated_replacement(job, lessons, "$.payload.lessons", issues)
    if replacement_digest is None:
        return lessons, None
    if replacement_digest != payload["replacement_digest"]:
        issue(
            issues,
            "policy.replacement_digest",
            "$.payload.replacement_digest must equal the normalized lesson-set digest",
        )
        return lessons, None
    if _closed_replacement_key(state, job, replacement_digest) in job["closed_replacements"]:
        issue(
            issues,
            "policy.closed_replacement",
            "$.payload.replacement_digest is closed against this base and algorithm",
        )
    return lessons, replacement_digest


def _apply_candidate_artifact(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    issues: list[ValidationIssue] = []
    lessons, replacement_digest = _candidate_artifact_issues(state, job, payload, issues)
    candidate_core = None
    if replacement_digest is not None:
        candidate_core = {
            "schema_version": _SCHEMA_VERSION,
            "job_id": payload["job_id"],
            "operation_id": payload["operation_id"],
            "result_digest": payload["result_digest"],
            "replacement_digest": replacement_digest,
            "lessons": lessons,
            "source_manifest_digest": payload["source_manifest_digest"],
            "base_digest": payload["base_digest"],
            "base_revision": payload["base_revision"],
            "learning_epoch": payload["learning_epoch"],
            "feedback_revision": payload["feedback_revision"],
            "algorithm_id": payload["algorithm_id"],
            "trigger_digest": payload["trigger_digest"],
        }
        record_digest = canonical_sha256(
            {"domain": _CANDIDATE_RECORD_DOMAIN, "value": candidate_core}
        )
        if record_digest != payload["candidate_record_digest"]:
            issue(
                issues,
                "policy.candidate_record_digest",
                "$.payload.candidate_record_digest must equal its identifier-free projection",
            )
        elif _candidate(job, record_digest) is not None:
            issue(issues, "policy.duplicate_candidate", "$.payload names a recorded candidate")
    _require_valid(issues)
    candidate = _candidate_record(
        origin="reflector",
        candidate_record_digest=payload["candidate_record_digest"],
        replacement_digest=payload["replacement_digest"],
        lessons=lessons,
        source_manifest_digest=payload["source_manifest_digest"],
        job=job,
        algorithm_id=payload["algorithm_id"],
        operation_id=payload["operation_id"],
        result_digest=payload["result_digest"],
        trigger_digest=payload["trigger_digest"],
        predecessor=None,
    )
    triggers = _closed_triggers(
        job, payload["trigger_digest"], "candidate", payload["candidate_record_digest"]
    )
    updated = {**job, "candidates": [*job["candidates"], candidate], "triggers": triggers}
    return _replace_job(state, updated), []


# MARK: - Admission


def _trigger_support(job: dict[str, Any], trigger: dict[str, Any]) -> str | None:
    for dependency in trigger["evidence"]:
        judgement = _effective_signal(job, "evaluation", dependency["evaluation_digest"])
        disputed = judgement is not None and judgement["signal"] == "evaluation_dispute"
        if dependency["evaluation_required"] and disputed:
            return None
    digests = {entry["evaluation_digest"] for entry in trigger["evidence"]}
    evidence = [entry for entry in job["evaluations"] if entry["evaluation_digest"] in digests]
    support = _support(_outcomes(job, evidence))
    if support is None:
        return None
    return support[0]


def _admission_support(job: dict[str, Any], candidate: dict[str, Any]) -> str | None:
    if candidate["origin"] != "reflector":
        return str(candidate["origin"])
    trigger = _trigger(job, candidate["trigger_digest"])
    if trigger is None:
        return None
    return _trigger_support(job, trigger)


def _admission_issues(
    state: dict[str, Any],
    job: dict[str, Any],
    candidate: dict[str, Any],
    payload: dict[str, Any],
    issues: list[ValidationIssue],
) -> None:
    if not job["repeatable"]:
        issue(issues, "policy.job_not_repeatable", "$.payload.job_id is not a repeatable job")
    if job["cancelled"]:
        issue(issues, "policy.job_cancelled", "$.payload.job_id is cancelled")
    if job["trial"] is not None:
        issue(issues, "policy.open_trial", "$.payload.job_id already has an open trial")
    if candidate["admitted"]:
        issue(issues, "policy.candidate_already_admitted", "$.payload names an admitted candidate")
    if candidate["superseded"]:
        issue(issues, "policy.superseded_candidate", "$.payload names a superseded candidate")
    if candidate["vetoed"]:
        issue(issues, "policy.hard_veto", "$.payload names a vetoed candidate")
    if candidate["replacement_digest"] != payload["replacement_digest"]:
        issue(
            issues,
            "policy.replacement_digest",
            "$.payload.replacement_digest must equal the candidate replacement",
        )
    if (
        payload["base_digest"] != job["stable_digest"]
        or payload["base_revision"] != job["stable_revision"]
        or candidate["base_digest"] != job["stable_digest"]
        or candidate["base_revision"] != job["stable_revision"]
    ):
        issue(issues, "policy.stale_base", "$.payload.base_digest must be the current stable base")
    if not (candidate["learning_epoch"] == payload["learning_epoch"] == job["learning_epoch"]):
        issue(issues, "policy.stale_epoch", "$.payload.learning_epoch must be current")
    if not (
        candidate["feedback_revision"] == payload["feedback_revision"] == job["feedback_revision"]
    ):
        issue(
            issues,
            "policy.stale_feedback_revision",
            "$.payload.feedback_revision must be current",
        )
    if candidate["algorithm_id"] != state["algorithm_id"]:
        issue(
            issues,
            "policy.algorithm_mismatch",
            "$.payload candidate algorithm must match the replay",
        )
    if (
        _closed_replacement_key(state, job, payload["replacement_digest"])
        in (job["closed_replacements"])
    ):
        issue(
            issues,
            "policy.closed_replacement",
            "$.payload.replacement_digest is closed against this base and algorithm",
        )
    if _admission_support(job, candidate) is None:
        issue(
            issues,
            "policy.absent_trigger_support",
            "$.payload names a candidate without effective trigger or owner support",
        )


def _apply_candidate_admitted(
    state: dict[str, Any],
    event: ReplayEvent,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    payload = event.payload
    job = _job_or_raise(state, payload["job_id"])
    candidate = _candidate(job, payload["candidate_record_digest"])
    if candidate is None:
        _reject(
            "policy.unknown_candidate",
            "$.payload.candidate_record_digest is not a candidate of this job",
        )
    issues: list[ValidationIssue] = []
    _admission_issues(state, job, candidate, payload, issues)
    _require_valid(issues)
    admitted_at = state["controlled_clock"]
    trial = {
        "candidate_record_digest": payload["candidate_record_digest"],
        "replacement_digest": payload["replacement_digest"],
        "base_digest": payload["base_digest"],
        "base_revision": payload["base_revision"],
        "learning_epoch": payload["learning_epoch"],
        "feedback_revision": payload["feedback_revision"],
        "algorithm_id": state["algorithm_id"],
        "adapter": _copy_body(payload["adapter"]),
        "admitted_at": admitted_at,
        "assignment_deadline": _shift_days(admitted_at, _ASSIGNMENT_DEADLINE_DAYS),
        "decision_deadline": _shift_days(admitted_at, _DECISION_DEADLINE_DAYS),
        "assignments": [],
        "status": "open",
    }
    closed = _closed_replacement_key(state, job, payload["replacement_digest"])
    updated = {
        **job,
        "candidates": _with_candidate_flags(job, payload["candidate_record_digest"], admitted=True),
        "closed_replacements": [*job["closed_replacements"], closed],
        "trial": trial,
    }
    after = _replace_job(state, updated)
    receipt = _decision(
        before=state,
        after=after,
        event=event,
        decision="admitted",
        reason=_admission_support(job, candidate) or "",
        artifact_identities={
            "job_id": job["job_id"],
            "candidate_record_digest": payload["candidate_record_digest"],
            "replacement_digest": payload["replacement_digest"],
            "base_digest": payload["base_digest"],
            "base_revision": payload["base_revision"],
            "learning_epoch": payload["learning_epoch"],
            "feedback_revision": payload["feedback_revision"],
            "adapter": trial["adapter"],
            "assignment_deadline": trial["assignment_deadline"],
            "decision_deadline": trial["decision_deadline"],
        },
    )
    return after, [receipt]


# MARK: - Stable evaluations and replay


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
    _require_valid(issues)
    record = {**payload, "issue_codes": list(payload["issue_codes"])}
    state = _replace_job(state, {**job, "evaluations": [*job["evaluations"], record]})
    return _maybe_trigger(state, payload["job_id"], event)


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
