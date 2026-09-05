"""Filesystem-only immutable event journal for the scheduled-learning replay controller."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from benchmark_core.canonical import canonical_sha256, dumps, load_object
from benchmark_learning.learning_contract import ReplayEvent, event_json, parse_event

_EVENT_FILENAME = re.compile(r"^(\d{6})-[0-9a-f]{64}\.json$")


@dataclass(frozen=True)
class CommittedEvent:
    event: ReplayEvent
    path: Path
    sha256: str


def _write_new_file(target: Path, text: str) -> None:
    """Create `target` with `text`, refusing to replace an existing file."""

    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        target.unlink(missing_ok=True)
        raise
    directory_descriptor = os.open(target.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


class EventJournal:
    """One append-only, canonical-JSON-per-file event log rooted at a directory."""

    def __init__(self, root: Path) -> None:
        self._root = Path(root)
        self._root.mkdir(parents=True, exist_ok=True)
        self._next_sequence = len(self._committed_paths()) + 1

    @property
    def root(self) -> Path:
        return self._root

    def _committed_paths(self) -> list[Path]:
        matches = [
            (int(match.group(1)), path)
            for path in self._root.iterdir()
            if path.is_file() and (match := _EVENT_FILENAME.match(path.name)) is not None
        ]
        matches.sort(key=lambda entry: entry[0])
        return [path for _, path in matches]

    def append(
        self,
        kind: str,
        occurred_at: str,
        payload: dict[str, Any],
    ) -> CommittedEvent:
        """Commit the next ordered event, rejecting an already-committed target."""

        sequence = self._next_sequence
        event = parse_event(
            {
                "schema_version": 1,
                "sequence": sequence,
                "occurred_at": occurred_at,
                "kind": kind,
                "payload": payload,
            }
        )
        rendered = event_json(event)
        digest = canonical_sha256(rendered)
        target = self._root / f"{sequence:06d}-{digest}.json"
        if target.exists():
            raise FileExistsError(f"event journal target already committed: {target}")
        _write_new_file(target, dumps(rendered))
        self._next_sequence = sequence + 1
        return CommittedEvent(event=event, path=target, sha256=digest)

    def load(self) -> list[ReplayEvent]:
        """Read every committed event from disk, ordered by its numeric sequence."""

        return [parse_event(load_object(path)) for path in self._committed_paths()]
