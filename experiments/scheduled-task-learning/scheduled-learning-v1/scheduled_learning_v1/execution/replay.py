"""Deterministic M3 replay bootstrap, publication, and promoted-state selection."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256, load_object, write
from benchmark_learning.learning_replay import initial_state

from scheduled_learning_v1 import ALGORITHM_ID
from scheduled_learning_v1.replay_controller import EventJournal, ReplayController

JOB_ID = "page-change-m3"
EMPTY_LESSON_SET = {"schema_version": 1, "lessons": []}
_SHA256_LENGTH = 64


def initial_replay_state(
    manifest: dict[str, object], approval: dict[str, object]
) -> dict[str, Any]:
    """Derive the one nine-field M3 job bootstrap from frozen projections."""

    controlled_clock = _whole_second(str(approval["approved_at"]))
    return initial_state(
        algorithm_id=ALGORITHM_ID,
        controlled_clock=controlled_clock,
        jobs=[
            {
                "job_id": JOB_ID,
                "repeatable": True,
                "cancelled": False,
                "learning_epoch": 0,
                "job_definition_digest": canonical_sha256(
                    {
                        "algorithm_id": manifest["algorithm_id"],
                        "job_id": JOB_ID,
                        "protocol": manifest["protocol"],
                        "run_order": manifest["run_order"],
                    }
                ),
                "stable_digest": canonical_sha256(EMPTY_LESSON_SET),
                "stable_revision": 0,
                "compatibility_digest": compatibility_digest(manifest),
                "feedback_revision": 0,
            }
        ],
    )


def compatibility_digest(manifest: dict[str, object]) -> str:
    """Bind replay compatibility to the frozen page identities and task route."""

    execution = _object(manifest.get("swift_execution"), "swift execution")
    return canonical_sha256(
        {"identities": manifest["identities"], "task_execution": execution["task_route"]}
    )


def replay_and_publish(root: Path, controller: ReplayController) -> dict[str, Any]:
    """Replay the complete journal and publish its exact canonical projections."""

    result = controller.replay()
    results = root / "results"
    write(results / "state.json", result["state"])
    write(results / "decision-receipts.json", result["decisions"])
    write(results / "replay-receipt.json", result["receipt"])
    return result


def refresh_replay(root: Path) -> None:
    """Best-effort reconstruction for a fail-closed report after an execution error."""

    try:
        manifest = cast(dict[str, object], load_object(root / "freeze" / "manifest.json"))
        approval = cast(
            dict[str, object], load_object(root / "freeze" / "owner-budget-approval.json")
        )
        journal = EventJournal(root / "results" / "events")
        controller = ReplayController(journal, initial=initial_replay_state(manifest, approval))
        replay_and_publish(root, controller)
    except Exception:
        return


def replay_job(result: dict[str, Any]) -> dict[str, Any]:
    """Select the fixed M3 job from one replay result."""

    state = _object(result.get("state"), "replay state")
    jobs = _object(state.get("jobs"), "replay jobs")
    return _object(jobs.get(JOB_ID), "M3 job")


def promoted_digest(job: dict[str, Any]) -> str:
    """Return the digest of the replay-authorized active lesson set."""

    promotion = _object(job.get("promotion"), "promotion")
    if promotion.get("status") != "active":
        raise ValueError("replayed job has no active promotion")
    return _required_digest(promotion.get("replacement_digest"), "promoted lesson set")


def promoted_lessons(job: dict[str, Any]) -> list[str]:
    """Select the exact admitted candidate artifact named by active promotion."""

    promotion = _object(job.get("promotion"), "promotion")
    candidate_digest = promotion.get("candidate_record_digest")
    candidates = job.get("candidates")
    if isinstance(candidates, list):
        for candidate in candidates:
            if (
                isinstance(candidate, dict)
                and candidate.get("candidate_record_digest") == candidate_digest
            ):
                return _lessons(candidate)
    raise ValueError("promoted candidate artifact is unavailable")


def require_no_interrupted(result: dict[str, Any]) -> None:
    """Reject a fresh process when replay exposes an indeterminate model operation."""

    operations = _object(replay_job(result).get("operations"), "replayed operations")
    if any(record.get("status") == "interrupted_unknown" for record in operations.values()):
        raise ValueError("replayed operations contain interrupted_unknown")


def _lessons(value: dict[str, object]) -> list[str]:
    lessons = value.get("lessons")
    if not isinstance(lessons, list) or any(not isinstance(item, str) for item in lessons):
        raise ValueError("promoted lesson artifact is invalid")
    return cast(list[str], lessons)


def _object(value: object, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return cast(dict[str, Any], value)


def _required_digest(value: object, name: str) -> str:
    if not isinstance(value, str) or len(value) != _SHA256_LENGTH:
        raise ValueError(f"{name} digest is invalid")
    return value


def _whole_second(value: str) -> str:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
