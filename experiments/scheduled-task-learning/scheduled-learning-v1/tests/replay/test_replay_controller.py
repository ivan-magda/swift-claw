"""Immutable-journal-backed replay controller tests."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from typing import Any

from benchmark_core.canonical import dumps, load_object
from benchmark_learning.learning_replay import initial_state
from scheduled_learning_v1 import ALGORITHM_ID
from scheduled_learning_v1.replay_controller import EventJournal, ReplayController

_CONTROLLED_CLOCK = "2026-01-31T00:00:00Z"


def _job(job_id: str) -> dict[str, Any]:
    return {
        "job_id": job_id,
        "repeatable": True,
        "cancelled": False,
        "learning_epoch": 0,
        "job_definition_digest": "job-definition-0",
        "stable_digest": "stable-0",
        "stable_revision": 0,
        "compatibility_digest": "compatibility-0",
        "feedback_revision": 0,
    }


def _stable_evaluation_payload(occurred_at: str, job_id: str, run_id: str) -> dict[str, Any]:
    return {
        "job_id": job_id,
        "run_id": run_id,
        "operation_id": f"evaluator-{run_id}",
        "evaluation_digest": f"evaluation-{run_id}",
        "logical_occurrence": occurred_at,
        "learning_epoch": 0,
        "compatibility_digest": "compatibility-0",
        "stable_digest": "stable-0",
        "outcome": "reusable_issue",
        "issue_codes": ["x"],
    }


class ReplayControllerTests(unittest.TestCase):
    def test_replay_persists_the_exact_core_receipt(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            journal = EventJournal(root)
            journal.append(
                "controller_started", "2030-01-01T00:00:00Z", {"controller_generation": 2}
            )

            # when
            result = ReplayController(journal).replay()

            # then
            self.assertEqual(load_object(root / "replay-receipt.json"), result["receipt"])

    def test_replay_persists_the_exact_state_and_ordered_decisions_without_reordering(
        self,
    ) -> None:
        # given
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            initial = initial_state(
                algorithm_id=ALGORITHM_ID,
                controlled_clock=_CONTROLLED_CLOCK,
                jobs=[_job("job-a"), _job("job-b")],
            )
            journal = EventJournal(root)
            journal.append(
                "stable_evaluation_recorded",
                "2026-01-01T00:00:00Z",
                _stable_evaluation_payload("2026-01-01T00:00:00Z", "job-a", "run-1"),
            )
            journal.append(
                "stable_evaluation_recorded",
                "2026-01-02T00:00:00Z",
                _stable_evaluation_payload("2026-01-02T00:00:00Z", "job-a", "run-2"),
            )
            journal.append(
                "stable_evaluation_recorded",
                "2026-01-03T00:00:00Z",
                _stable_evaluation_payload("2026-01-03T00:00:00Z", "job-b", "run-1"),
            )
            journal.append(
                "stable_evaluation_recorded",
                "2026-01-04T00:00:00Z",
                _stable_evaluation_payload("2026-01-04T00:00:00Z", "job-b", "run-2"),
            )

            # when
            result = ReplayController(journal, initial=initial).replay()

            # then
            self.assertEqual(
                [item["decision"] for item in result["decisions"]], ["reflected", "reflected"]
            )
            self.assertEqual(
                [item["artifact_identities"]["job_id"] for item in result["decisions"]],
                ["job-a", "job-b"],
            )
            self.assertEqual(load_object(root / "state.json"), result["state"])
            self.assertEqual(
                (root / "decision-receipts.json").read_text(encoding="utf-8"),
                dumps(result["decisions"]),
            )

    def test_reopened_journal_feeds_the_controller_the_same_committed_events(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = EventJournal(root)
            original.append(
                "controller_started", "2030-01-01T00:00:00Z", {"controller_generation": 2}
            )

            # when
            reopened = EventJournal(root)
            result = ReplayController(reopened).replay()

            # then
            self.assertEqual(reopened.load(), original.load())
            self.assertEqual(load_object(root / "replay-receipt.json"), result["receipt"])


if __name__ == "__main__":
    unittest.main()
