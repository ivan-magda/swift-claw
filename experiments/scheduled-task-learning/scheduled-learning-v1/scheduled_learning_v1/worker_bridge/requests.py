"""Closed request records and start-event authorization binding."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from benchmark_core.canonical import canonical_sha256, dumps


@dataclass(frozen=True)
class TaskAttemptCall:
    """Materialized task invocation core and its fixed input/result paths."""

    invocation_core: dict[str, object]
    invocation_path: Path
    result_path: Path


@dataclass(frozen=True)
class LearningCall:
    """Materialized evaluator or reflector request core and its fixed paths."""

    kind: Literal["evaluator", "reflector"]
    request_core: dict[str, object]
    request_path: Path
    result_path: Path


def bind_authorization(
    core: dict[str, object], event_path: Path, event_sha256: str
) -> dict[str, object]:
    """Add the sole post-hash field allowed to a closed worker input."""

    return {**core, "authorization": {"event_path": str(event_path), "event_sha256": event_sha256}}


def core_digest(core: dict[str, object]) -> str:
    """Return the canonical digest that Swift admission binds to its start event."""

    return canonical_sha256(core)


def write_closed_input(path: Path, value: dict[str, object]) -> None:
    """Publish the final canonical worker input at its already-authorized absolute path."""

    if not path.is_absolute():
        raise ValueError("worker input path must be absolute")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(dumps(value), encoding="utf-8")
