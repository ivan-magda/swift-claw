"""Offline verification rehashes every committed event."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from typing import cast

from benchmark_core.canonical import load_object, write
from scheduled_learning_v1.reporting import build_final_report, verify_results

from .support import publish_hash_consistent_replay, result_tree


class ResultVerificationTests(unittest.TestCase):
    def test_valid_tree_verifies_offline(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = result_tree(root)

            # when
            receipt = verify_results(root, manifest)

            # then
            self.assertEqual(receipt["status"], "verified")

    def test_changed_event_byte_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = result_tree(root)
            event_path = next((root / "results" / "events").glob("0*.json"))
            event_path.write_text(event_path.read_text(encoding="utf-8") + " ", encoding="utf-8")

            # when / then
            with self.assertRaises(ValueError):
                verify_results(root, manifest)

    def test_self_consistent_impossible_state_is_rejected_by_semantic_replay(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = result_tree(root)
            state_path = root / "results" / "state.json"
            decisions_path = root / "results" / "decision-receipts.json"
            state = load_object(state_path)
            state["controller_generation"] = 99
            decisions = json.loads(decisions_path.read_text(encoding="utf-8"))
            self.assertIsInstance(decisions, list)
            typed_decisions = cast(list[dict[str, object]], decisions)
            publish_hash_consistent_replay(root, state, typed_decisions)
            report = build_final_report(root)
            self.assertEqual(report["status"], "complete")

            # when / then
            with self.assertRaisesRegex(ValueError, "persisted state differs from semantic replay"):
                verify_results(root, manifest)

    def test_self_consistent_decision_mutation_is_rejected_by_semantic_replay(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = result_tree(root)
            state = load_object(root / "results" / "state.json")
            decisions = json.loads(
                (root / "results" / "decision-receipts.json").read_text(encoding="utf-8")
            )
            self.assertIsInstance(decisions, list)
            typed_decisions = cast(list[dict[str, object]], decisions)
            changed = False
            for decision in typed_decisions:
                if decision.get("decision") != "promoted":
                    decision["decision_id"] = "decision-mutated"
                    changed = True
                    break
            self.assertTrue(changed)
            publish_hash_consistent_replay(root, state, typed_decisions)
            report = build_final_report(root)
            self.assertEqual(report["status"], "complete")

            # when / then
            with self.assertRaisesRegex(
                ValueError,
                "persisted decisions differs from semantic replay",
            ):
                verify_results(root, manifest)

    def test_self_consistent_receipt_mutation_is_rejected_by_semantic_replay(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = result_tree(root)
            receipt_path = root / "results" / "replay-receipt.json"
            receipt = load_object(receipt_path)
            receipt["receipt_id"] = "replay-mutated"
            write(receipt_path, receipt)
            report = build_final_report(root)
            self.assertEqual(report["status"], "complete")

            # when / then
            with self.assertRaisesRegex(
                ValueError,
                "persisted replay receipt differs from semantic replay",
            ):
                verify_results(root, manifest)


if __name__ == "__main__":
    unittest.main()
