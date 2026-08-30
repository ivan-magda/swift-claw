"""Directed clean, candidate, trial, promotion, and active lifecycle behavior."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest.mock import patch

from benchmark_core.canonical import load_object
from scheduled_learning_v1.execution import run_scored

from .support import frozen_tree, run_fake_scored


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

    def test_malformed_manifest_still_publishes_bound_incomplete_report(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frozen_tree(root)
            manifest_path = root / "freeze" / "manifest.json"
            approval_path = root / "freeze" / "owner-budget-approval.json"
            failure_path = root / "results" / "failure.json"
            manifest_path.write_bytes(b'{"schema_version":')
            entries = 0

            def factory(*args: object, **kwargs: object) -> object:
                nonlocal entries
                entries += 1
                raise AssertionError("malformed freeze reached external operation construction")

            # when
            with patch("scheduled_learning_v1.execution.lifecycle._make_operations", factory):
                report = run_scored(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertTrue(report["m4_blocked"])
            self.assertEqual(entries, 0)
            self.assertEqual(
                report["manifest_sha256"],
                hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                report["owner_approval_sha256"],
                hashlib.sha256(approval_path.read_bytes()).hexdigest(),
            )
            self.assertTrue(failure_path.is_file())
            self.assertEqual(
                report["failure_sha256"],
                hashlib.sha256(failure_path.read_bytes()).hexdigest(),
            )
            self.assertIsNone(report["thresholds"])
            self.assertIsNone(report["event_log_sha256"])
            self.assertIsNone(report["replay_receipt_sha256"])
            self.assertIsNone(report["decision_receipt_sha256s"])
            self.assertIsNone(report["active_evidence"])
            self.assertIsNone(report["restart_evidence"])
            self.assertEqual(load_object(root / "results" / "final-report.json"), report)

    def test_malformed_approval_still_publishes_manifest_bound_incomplete_report(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frozen_tree(root)
            manifest_path = root / "freeze" / "manifest.json"
            approval_path = root / "freeze" / "owner-budget-approval.json"
            failure_path = root / "results" / "failure.json"
            approval_path.write_bytes(b'{"schema_version":')
            entries = 0

            def factory(*args: object, **kwargs: object) -> object:
                nonlocal entries
                entries += 1
                raise AssertionError("malformed approval reached external operation construction")

            # when
            with patch("scheduled_learning_v1.execution.lifecycle._make_operations", factory):
                report = run_scored(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertTrue(report["m4_blocked"])
            self.assertEqual(entries, 0)
            self.assertEqual(
                report["manifest_sha256"],
                hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                report["owner_approval_sha256"],
                hashlib.sha256(approval_path.read_bytes()).hexdigest(),
            )
            self.assertTrue(failure_path.is_file())
            self.assertEqual(
                report["failure_sha256"],
                hashlib.sha256(failure_path.read_bytes()).hexdigest(),
            )
            self.assertIsNone(report["freeze_commit"])
            self.assertEqual(
                report["thresholds"],
                {
                    "adapter_pass_rule": {
                        "minimum_valid_pairs": 2,
                        "maximum_valid_pairs": 3,
                        "minimum_candidate_score": 90,
                        "minimum_mean_delta": 10,
                        "allow_critical_result": False,
                        "allow_negative_delta": False,
                    },
                    "minimum_active_score": 90,
                    "minimum_restart_active_score": 90,
                },
            )
            self.assertIsNone(report["event_log_sha256"])
            self.assertIsNone(report["replay_receipt_sha256"])
            self.assertIsNone(report["decision_receipt_sha256s"])
            self.assertIsNone(report["active_evidence"])
            self.assertIsNone(report["restart_evidence"])
            self.assertEqual(load_object(root / "results" / "final-report.json"), report)


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
