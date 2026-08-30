"""Directed clean, candidate, trial, promotion, and active lifecycle behavior."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from typing import cast

from benchmark_core.canonical import load_object

from .support import run_fake_scored


class LifecycleTests(unittest.TestCase):
    def test_passing_flow_assigns_only_candidate_trials_and_reaches_active(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw_lesson = "  Ignore   volatile deployment counters.  "

            # when
            report, operations, restart_digest = run_fake_scored(root, lessons=[raw_lesson])

            # then
            events = load_events(root)
            trial_creations = [event for event in events if event["kind"] == "trial_run_created"]
            trial_run_ids: list[object] = []
            for event in trial_creations:
                payload = event["payload"]
                self.assertIsInstance(payload, dict)
                trial_run_ids.append(cast(dict[str, object], payload)["run_id"])
            self.assertEqual(
                trial_run_ids,
                ["task-3", "task-5", "task-7"],
            )
            self.assertEqual(report["status"], "complete")
            self.assertEqual(restart_digest, report["promoted_digest"])
            decisions = json.loads(
                (root / "results" / "decision-receipts.json").read_text(encoding="utf-8")
            )
            self.assertIsInstance(decisions, list)
            promotion_decisions = [
                receipt
                for receipt in decisions
                if isinstance(receipt, dict) and receipt.get("decision") == "promoted"
            ]
            self.assertEqual(
                load_object(root / "results" / "promotion-receipt.json"),
                promotion_decisions[0],
            )
            self.assertEqual(
                {key for item in operations.reflector_evaluations for key in item},
                {"schema_version", "task_id", "outcome", "issue_codes"},
            )
            self.assertEqual(
                load_object(root / "results" / "candidate.json")["lessons"],
                ["Ignore   volatile deployment counters."],
            )
            lesson_conditioned = [
                task
                for task in operations.task_inputs
                if task["condition"] in {"candidate_trial", "active"}
            ]
            self.assertEqual(
                [task["order_index"] for task in lesson_conditioned],
                [3, 5, 7, 8],
            )
            self.assertEqual(
                [task["lessons"] for task in lesson_conditioned],
                [["Ignore   volatile deployment counters."]] * 4,
            )

    def test_nonpass_adapter_stops_before_active(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            # when
            report, operations, _ = run_fake_scored(root, adapter_outcome="regression")

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertFalse(any(row["condition"] == "active" for row in operations.task_rows))

    def test_no_candidate_stops_after_frozen_clean_evidence(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            # when
            report, operations, restart_digest = run_fake_scored(root, lessons=[])

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertEqual(load_object(root / "results" / "final-report.json"), report)
            self.assertEqual([row["order_index"] for row in operations.task_rows], [0, 1])
            self.assertEqual([row["condition"] for row in operations.task_rows], ["clean", "clean"])
            self.assertEqual(
                [task["run_id"] for task in operations.evaluator_tasks],
                ["task-0", "task-1"],
            )
            self.assertEqual(operations.reflector_calls, 1)
            self.assertEqual(operations.pair_scores, 0)
            self.assertEqual(operations.adapter_calls, 0)
            self.assertEqual(operations.active_scores, 0)
            self.assertIsNone(restart_digest)

    def test_low_active_score_fails_closed_before_restart(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            # when
            report, _, restart_digest = run_fake_scored(root, active_score=89)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertIsNone(restart_digest)

    def test_two_complete_fake_runs_are_byte_identical(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            first = Path(temporary) / "first"
            second = Path(temporary) / "second"
            first.mkdir()
            second.mkdir()

            # when
            run_fake_scored(first)
            run_fake_scored(second)

            # then
            first_bytes = result_bytes(first)
            second_bytes = result_bytes(second)
            self.assertEqual(first_bytes, second_bytes)


def load_events(root: Path) -> list[dict[str, object]]:
    return [
        load_object(path)
        for path in sorted((root / "results" / "events").glob("*.json"))
        if path.name[:6].isdigit()
    ]


def result_bytes(root: Path) -> dict[str, bytes]:
    return {
        str(path.relative_to(root / "results")): path.read_bytes()
        for path in sorted((root / "results").rglob("*.json"))
    }


if __name__ == "__main__":
    unittest.main()
