"""Pure `scheduled-learning/v1` reducer over the closed ordered replay event log."""

from __future__ import annotations

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
    decision_receipt,
    event_json,
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
_MAX_TRIAL_ASSIGNMENTS = 3
_POSITIVE_TRIAL_RUNS = 2
_MAX_LESSONS = 3
_MAX_LESSON_BYTES = 512
_MAX_LESSON_SET_BYTES = 1536

# The fixed synthetic code an owner "not useful" signal contributes when the evaluator recorded
# no exact issue code of its own; version 1 performs no semantic clustering of free text.
_OWNER_NOT_USEFUL_CODE = "owner_not_useful"

_TRIGGER_DOMAIN = "scheduled-learning/v1/trigger"
_CANDIDATE_RECORD_DOMAIN = "scheduled-learning/v1/candidate-record"
_CANDIDATE_SOURCE_DOMAIN = "scheduled-learning/v1/candidate-source"
_TRIAL_DOMAIN = "scheduled-learning/v1/trial"
_TRIAL_EVALUATION_DOMAIN = "scheduled-learning/v1/trial-evaluation"
_PROMOTION_DOMAIN = "scheduled-learning/v1/promotion"

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
    "trial_run_ids",
    "trial",
    "promotion",
    "promotion_history",
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
)

_POSITIVE_EVALUATOR_OUTCOMES = {"no_issue"}
_NEGATIVE_EVALUATOR_OUTCOMES = {"reusable_issue"}
_OWNER_RESULT_SIGNALS = {"result_useful", "result_not_useful", "result_correction"}
_ADAPTER_BINDING_FIELDS = (
    "adapter_id",
    "adapter_version",
    "dataset_digest",
    "oracle_digest",
    "gates_digest",
    "execution_surface_digest",
)

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
            "trial_run_ids": [],
            "trial": None,
            "promotion": None,
            "promotion_history": [],
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


def _open_trial(job: dict[str, Any]) -> dict[str, Any] | None:
    trial = job["trial"]
    if trial is None or trial["status"] != "open":
        return None
    open_trial: dict[str, Any] = trial
    return open_trial


def _trial_assignment(job: dict[str, Any], run_id: Any) -> dict[str, Any] | None:
    trial = job["trial"]
    if trial is None:
        return None
    for record in trial["assignments"]:
        if record["run_id"] == run_id:
            assignment: dict[str, Any] = record
            return assignment
    return None


def _evaluation_run_id(job: dict[str, Any], digest: Any) -> str | None:
    for entry in job["evaluations"]:
        if entry["evaluation_digest"] == digest:
            run_id: str = entry["run_id"]
            return run_id
    trial = job["trial"]
    if trial is not None:
        for assignment in trial["assignments"]:
            if assignment.get("evaluation_digest") == digest:
                trial_run_id: str = assignment["run_id"]
                return trial_run_id
    promotion = job["promotion"]
    if promotion is not None:
        for support in promotion["positive_supports"]:
            if support["evaluation_digest"] == digest:
                support_run_id: str = support["run_id"]
                return support_run_id
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
