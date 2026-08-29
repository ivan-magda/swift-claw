"""Candidate normalization, controls, reflector results, and admission."""

from __future__ import annotations

import unicodedata
from collections.abc import Callable
from typing import Any

from benchmark_core.canonical import canonical_sha256
from benchmark_core.contract_validation import ValidationIssue, issue

from benchmark_learning.learning_contract import ReplayEvent

from .evidence import _effective_signal, _outcomes, _support, _trigger_snapshot_issues
from .state import (
    _ASSIGNMENT_DEADLINE_DAYS,
    _CANDIDATE_RECORD_DOMAIN,
    _CANDIDATE_SOURCE_DOMAIN,
    _DECISION_DEADLINE_DAYS,
    _MAX_LESSON_BYTES,
    _MAX_LESSON_SET_BYTES,
    _MAX_LESSONS,
    _SCHEMA_VERSION,
    _TRIAL_DOMAIN,
    _candidate,
    _copy_body,
    _decision,
    _job_or_raise,
    _open_trial,
    _reject,
    _replace_job,
    _require_valid,
    _shift_days,
    _trigger,
)

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
    if any(
        character != "\n" and unicodedata.category(character) in {"Cc", "Cf"}
        for text in lessons
        for character in text
    ):
        issue(
            issues,
            "policy.lesson_characters",
            f"{path} must not contain control or Unicode format characters",
        )
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
    if payload["operation_id"] != payload["trigger_digest"]:
        issue(
            issues,
            "policy.trigger_binding",
            "$.payload.trigger_digest must equal the reflector operation identifier",
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
    trigger = _open_trigger_issues(job, payload, issues)
    if trigger is not None:
        _trigger_snapshot_issues(job, trigger, issues)
        if (
            payload["base_digest"] != trigger["stable_digest"]
            or payload["learning_epoch"] != trigger["learning_epoch"]
            or payload["feedback_revision"] != trigger["feedback_revision"]
        ):
            issue(
                issues,
                "policy.stale_trigger",
                "$.payload frozen facts must equal the bound trigger snapshot",
            )
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
    origin = str(candidate["origin"])
    source = candidate
    while source["origin"] == "owner_approval":
        predecessor = _candidate(job, source["predecessor_candidate_record_digest"])
        if predecessor is None:
            return None
        source = predecessor
    if source["origin"] != "reflector":
        return origin
    trigger = _trigger(job, source["trigger_digest"])
    if trigger is None:
        return None
    support = _trigger_support(job, trigger)
    if support is None:
        return None
    return origin if origin == "owner_approval" else support


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
    if _open_trial(job) is not None:
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
    assignment_deadline = _shift_days(admitted_at, _ASSIGNMENT_DEADLINE_DAYS)
    decision_deadline = _shift_days(admitted_at, _DECISION_DEADLINE_DAYS)
    adapter = _copy_body(payload["adapter"])
    trial_core = {
        "schema_version": _SCHEMA_VERSION,
        "job_id": job["job_id"],
        "candidate_record_digest": payload["candidate_record_digest"],
        "replacement_digest": payload["replacement_digest"],
        "base_digest": payload["base_digest"],
        "base_revision": payload["base_revision"],
        "learning_epoch": payload["learning_epoch"],
        "feedback_revision": payload["feedback_revision"],
        "algorithm_id": state["algorithm_id"],
        "adapter": adapter,
        "admitted_at": admitted_at,
        "assignment_deadline": assignment_deadline,
        "decision_deadline": decision_deadline,
    }
    trial = {
        **{field: value for field, value in trial_core.items() if field != "schema_version"},
        "trial_digest": canonical_sha256({"domain": _TRIAL_DOMAIN, "value": trial_core}),
        "source_manifest_digest": candidate["source_manifest_digest"],
        "job_definition_digest": job["job_definition_digest"],
        "compatibility_digest": job["compatibility_digest"],
        "assignments": [],
        "assignment_closed_at": None,
        "adapter_receipt": None,
        "status": "open",
        "decided_at": None,
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
            "trial_digest": trial["trial_digest"],
        },
    )
    return after, [receipt]
