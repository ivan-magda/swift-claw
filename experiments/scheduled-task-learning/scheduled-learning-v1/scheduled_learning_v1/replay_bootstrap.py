"""Deterministic initial state for the one frozen M3 replay job."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from benchmark_core.canonical import canonical_sha256
from benchmark_learning.learning_replay import initial_state

from scheduled_learning_v1 import ALGORITHM_ID

JOB_ID = "page-change-m3"
EMPTY_LESSON_SET = {"schema_version": 1, "lessons": []}


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


def _object(value: object, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return value


def _whole_second(value: str) -> str:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
