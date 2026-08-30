"""Current-tree contract for the final immutable scheduled-learning result."""

from __future__ import annotations

import unittest
from pathlib import Path

from benchmark_core.canonical import load_object


class FinalArchiveContractTests(unittest.TestCase):
    def test_current_tree_preserves_the_final_failed_experiment(self) -> None:
        # given
        root = Path(__file__).resolve().parents[1]
        approval_path = root / "freeze" / "owner-budget-approval.json"
        report_path = root / "results" / "final-report.json"
        active_path = root / "results" / "active-evidence.json"
        restart_path = root / "results" / "restart-evidence.json"

        # when
        approval = load_object(approval_path)
        report = load_object(report_path)
        active = load_object(active_path)

        # then
        self.assertEqual(
            approval["expected_freeze_commit"],
            "0f30c1519b20a8a8ebfa45502d9b28207ea83336",
        )
        self.assertEqual(
            report["manifest_sha256"],
            "ce1db83b83df2ac5a22e205441cab7f85a65119208a9fb588a5e6e9fd6ff532c",
        )
        self.assertEqual(report["status"], "incomplete_failed")
        self.assertEqual(active["score"], 30.0)
        self.assertEqual(active["critical_codes"], ["material.missed"])
        self.assertFalse(restart_path.exists())


if __name__ == "__main__":
    unittest.main()
