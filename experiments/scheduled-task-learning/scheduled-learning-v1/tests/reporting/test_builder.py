"""Complete and incomplete report projection."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from typing import cast

from benchmark_core.canonical import canonical_sha256, load_object, write
from scheduled_learning_v1.reporting import build_final_report

from .support import result_tree, result_tree_with_nondefault_thresholds


class FinalReportBuilderTests(unittest.TestCase):
    def test_complete_report_uses_frozen_thresholds_and_bound_digests(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = result_tree_with_nondefault_thresholds(root)
            approval = load_object(root / "freeze" / "owner-budget-approval.json")
            replay_receipt = load_object(root / "results" / "replay-receipt.json")
            decisions = json.loads(
                (root / "results" / "decision-receipts.json").read_text(encoding="utf-8")
            )
            self.assertIsInstance(decisions, list)
            decision_digests = [canonical_sha256(item) for item in decisions]
            self.assertNotEqual(decision_digests, sorted(decision_digests))
            candidate = load_object(root / "results" / "candidate.json")
            promotion = load_object(root / "results" / "promotion-receipt.json")
            adapter_receipt = load_object(root / "results" / "page-adapter-receipt.json")

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "complete")
            self.assertEqual(report["manifest_sha256"], canonical_sha256(manifest))
            self.assertEqual(
                report["thresholds"],
                {
                    "minimum_candidate_score": 91,
                    "minimum_mean_delta": 11,
                    "minimum_active_score": 94,
                    "minimum_restart_active_score": 95,
                },
            )
            self.assertEqual(report["freeze_commit"], approval["expected_freeze_commit"])
            self.assertEqual(report["event_log_sha256"], replay_receipt["events_sha256"])
            self.assertEqual(report["replay_receipt_sha256"], canonical_sha256(replay_receipt))
            self.assertEqual(report["decision_receipt_sha256s"], decision_digests)
            self.assertEqual(
                report["page_adapter_receipt_sha256"],
                canonical_sha256(adapter_receipt),
            )
            self.assertEqual(report["base_digest"], candidate["base_digest"])
            self.assertEqual(report["candidate_digest"], candidate["replacement_digest"])
            identities = cast(dict[str, object], promotion["artifact_identities"])
            self.assertEqual(report["promoted_digest"], identities["replacement_digest"])
            self.assertEqual(
                report["active_evidence"],
                {"score": 95, "threshold": 94, "passed": True},
            )
            self.assertEqual(
                report["restart_evidence"],
                {
                    "score": 96,
                    "threshold": 95,
                    "passed": True,
                    "promoted_digest_matched": True,
                },
            )
            self.assertFalse(report["m4_blocked"])

    def test_incomplete_tree_publishes_one_fail_closed_report(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root, complete=False)

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertTrue(report["m4_blocked"])
            self.assertIsNone(report["promoted_digest"])
            self.assertIsNone(report["active_evidence"])

    def test_failure_marker_overrides_an_otherwise_complete_tree(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)

            # when
            write(
                root / "results" / "failure.json",
                {"schema_version": 1, "status": "incomplete_failed", "error": "rerun rejected"},
            )
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertTrue(report["m4_blocked"])

    def test_projected_promotion_receipt_cannot_complete_report(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            exact = load_object(root / "results" / "promotion-receipt.json")
            identities = cast(dict[str, object], exact["artifact_identities"])
            write(
                root / "results" / "promotion-receipt.json",
                {"schema_version": 1, "promoted_digest": identities["replacement_digest"]},
            )

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertTrue(report["m4_blocked"])


if __name__ == "__main__":
    unittest.main()
