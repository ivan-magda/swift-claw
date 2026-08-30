"""Reducer delegation and canonical publication for the scheduled-learning replay controller."""

from __future__ import annotations

from typing import Any

from benchmark_core.canonical import write
from benchmark_learning.learning_replay import initial_state, replay

from scheduled_learning_v1 import ALGORITHM_ID

from .journal import EventJournal

# The M3 harness has not yet assigned real per-job frozen facts (job_definition_digest,
# stable_digest, etc.); a controller with no `initial` override starts with zero jobs so
# consuming callers that only replay controller/clock events never need to invent them.
_DEFAULT_CONTROLLED_CLOCK = "1970-01-01T00:00:00Z"


class ReplayController:
    """Delegates one journal's ordered events to the pure reducer and publishes the result."""

    def __init__(self, journal: EventJournal, *, initial: dict[str, Any] | None = None) -> None:
        self._journal = journal
        self._initial = (
            initial
            if initial is not None
            else initial_state(
                algorithm_id=ALGORITHM_ID,
                controlled_clock=_DEFAULT_CONTROLLED_CLOCK,
                jobs=[],
            )
        )

    def replay(self) -> dict[str, Any]:
        """Reduce every committed event and publish canonical state, decisions, and receipt."""

        events = self._journal.load()
        result = replay(initial=self._initial, events=events)
        root = self._journal.root
        write(root / "state.json", result["state"])
        write(root / "decision-receipts.json", result["decisions"])
        write(root / "replay-receipt.json", result["receipt"])
        return result
