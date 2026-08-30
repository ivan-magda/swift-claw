"""Complete and incomplete report projection."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from typing import cast

from benchmark_core.canonical import canonical_sha256, load_object, write
from scheduled_learning_v1.reporting import build_final_report

from .support import (
    publish_rebound_adapter,
    result_tree,
    result_tree_with_nondefault_thresholds,
    result_tree_with_rebound_negative_delta,
)


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
            candidate_path = root / "results" / "candidate.json"
            promotion_path = root / "results" / "promotion-receipt.json"
            adapter_path = root / "results" / "page-adapter-receipt.json"

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "complete")
            self.assertEqual(report["manifest_sha256"], canonical_sha256(manifest))
            self.assertEqual(
                report["thresholds"],
                {
                    "adapter_pass_rule": {
                        "minimum_valid_pairs": 3,
                        "maximum_valid_pairs": 4,
                        "minimum_candidate_score": 92,
                        "minimum_mean_delta": 12,
                        "allow_critical_result": True,
                        "allow_negative_delta": True,
                    },
                    "minimum_active_score": 94,
                    "minimum_restart_active_score": 95,
                },
            )
            self.assertEqual(
                report["adapter_evidence"],
                {
                    "outcome": "pass",
                    "pair_count": 3,
                    "valid_pair_count": 3,
                    "minimum_candidate_score": 95,
                    "mean_delta": 25,
                    "critical_result_present": False,
                    "negative_delta_present": False,
                },
            )
            self.assertEqual(report["freeze_commit"], approval["expected_freeze_commit"])
            self.assertEqual(
                report["owner_approval_sha256"],
                _raw_sha256(root / "freeze" / "owner-budget-approval.json"),
            )
            self.assertEqual(report["event_log_sha256"], replay_receipt["events_sha256"])
            self.assertEqual(report["replay_receipt_sha256"], canonical_sha256(replay_receipt))
            self.assertEqual(
                report["decision_receipts_sha256"],
                _raw_sha256(root / "results" / "decision-receipts.json"),
            )
            self.assertEqual(report["decision_receipt_sha256s"], decision_digests)
            self.assertEqual(
                report["page_adapter_receipt_sha256"],
                _raw_sha256(adapter_path),
            )
            self.assertEqual(report["candidate_artifact_sha256"], _raw_sha256(candidate_path))
            self.assertEqual(report["promotion_receipt_sha256"], _raw_sha256(promotion_path))
            self.assertIsNone(report["failure_sha256"])
            self.assertEqual(report["base_digest"], candidate["base_digest"])
            self.assertEqual(report["candidate_digest"], candidate["replacement_digest"])
            identities = cast(dict[str, object], promotion["artifact_identities"])
            self.assertEqual(report["promoted_digest"], identities["replacement_digest"])
            self.assertEqual(
                report["active_evidence"],
                {"score": 100, "threshold": 94, "passed": True},
            )
            self.assertEqual(
                report["restart_evidence"],
                {
                    "score": 100,
                    "threshold": 95,
                    "passed": True,
                    "promoted_digest_matched": True,
                },
            )
            self.assertFalse(report["m4_blocked"])

    def test_candidate_lesson_bytes_must_match_declared_digest(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            candidate_path = root / "results" / "candidate.json"
            candidate = load_object(candidate_path)
            candidate["lessons"] = ["substituted lesson bytes"]
            write(candidate_path, candidate)

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertEqual(report["candidate_digest"], candidate["replacement_digest"])
            self.assertTrue(report["m4_blocked"])

    def test_adapter_observations_enforce_critical_gate_after_exact_decision_rebinding(
        self,
    ) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            adapter_path = root / "results" / "page-adapter-receipt.json"
            adapter = load_object(adapter_path)
            pairs = cast(list[dict[str, object]], adapter["pairs"])
            candidate_score = cast(dict[str, object], pairs[0]["candidate"])
            candidate_score["critical_codes"] = ["critical-substitution"]
            publish_rebound_adapter(root, adapter)

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            observations = cast(dict[str, object], report["adapter_evidence"])
            self.assertTrue(observations["critical_result_present"])
            thresholds = cast(dict[str, object], report["thresholds"])
            adapter_gate = cast(dict[str, object], thresholds["adapter_pass_rule"])
            self.assertFalse(adapter_gate["allow_critical_result"])
            self.assertTrue(report["m4_blocked"])

    def test_negative_delta_observation_enforces_frozen_disallow_policy(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree_with_rebound_negative_delta(root)

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            observations = cast(dict[str, object], report["adapter_evidence"])
            self.assertEqual(observations["minimum_candidate_score"], 95)
            self.assertAlmostEqual(cast(float, observations["mean_delta"]), 47 / 3)
            self.assertTrue(observations["negative_delta_present"])
            thresholds = cast(dict[str, object], report["thresholds"])
            frozen_gate = cast(dict[str, object], thresholds["adapter_pass_rule"])
            self.assertFalse(frozen_gate["allow_negative_delta"])
            self.assertTrue(report["m4_blocked"])

    def test_evidence_digests_bind_full_active_and_restart_bytes(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            active_path = root / "results" / "active-evidence.json"
            restart_path = root / "results" / "restart-evidence.json"
            before = load_object(root / "results" / "final-report.json")
            active = load_object(active_path)
            active["critical_codes"] = ["changed-active-evidence"]
            write(active_path, active)
            restart = load_object(restart_path)
            restart["score_receipt_digest"] = "f" * 64
            write(restart_path, restart)

            # when
            report = build_final_report(root)

            # then
            self.assertNotEqual(report["active_evidence_sha256"], before["active_evidence_sha256"])
            self.assertNotEqual(
                report["restart_evidence_sha256"],
                before["restart_evidence_sha256"],
            )
            self.assertEqual(report["active_evidence_sha256"], _raw_sha256(active_path))
            self.assertEqual(report["restart_evidence_sha256"], _raw_sha256(restart_path))

    def test_active_and_restart_evidence_is_closed_and_bound_to_frozen_tasks(self) -> None:
        # given
        for name, path_name, key, value, remove in (
            ("cross-task active", "active-evidence.json", "operation_id", "task-9", False),
            ("missing active", "active-evidence.json", "gold_sha256", None, True),
            ("invented restart", "restart-evidence.json", "invented", True, False),
            (
                "forged restart receipt",
                "restart-evidence.json",
                "score_receipt_digest",
                "f" * 64,
                False,
            ),
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                result_tree(root)
                path = root / "results" / path_name
                evidence = load_object(path)
                if remove:
                    evidence.pop(key)
                else:
                    evidence[key] = value
                write(path, evidence)

                # when
                report = build_final_report(root)

                # then
                self.assertEqual(report["status"], "incomplete_failed")
                self.assertTrue(report["m4_blocked"])

    def test_score_evidence_rejects_each_rebound_production_identity(self) -> None:
        # given
        for name, key, value in (
            ("task result digest", "task_result_digest", "f" * 64),
            ("fixture", "fixture_id", "pc-sealed-06"),
            ("condition", "condition", "post_restart_active"),
            ("source", "source_sha256", "f" * 64),
            ("gold", "gold_sha256", "f" * 64),
            ("attempt", "attempt_sha256", "f" * 64),
            ("scorer", "scorer_sha256", "f" * 64),
            ("oracle", "oracle_digest", "f" * 64),
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                result_tree(root)
                path = root / "results" / "active-evidence.json"
                evidence = load_object(path)
                evidence[key] = value
                write(path, evidence)

                # when
                report = build_final_report(root)

                # then
                self.assertEqual(report["status"], "incomplete_failed")
                self.assertTrue(report["m4_blocked"])

    def test_replay_decision_digest_binding_is_required_for_completion(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            replay_path = root / "results" / "replay-receipt.json"
            replay = load_object(replay_path)
            digests = cast(list[str], replay["decision_receipt_sha256s"])
            replay["decision_receipt_sha256s"] = list(reversed(digests))
            write(replay_path, replay)

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertTrue(report["m4_blocked"])

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

    def test_malformed_active_evidence_binds_raw_bytes_and_fails_closed(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            active_path = root / "results" / "active-evidence.json"
            active_path.write_bytes(b'{"schema_version":')

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertEqual(report["active_evidence_sha256"], _raw_sha256(active_path))
            self.assertIsNone(report["active_evidence"])
            self.assertTrue(report["m4_blocked"])

    def test_deeply_nested_active_evidence_binds_raw_bytes_and_fails_closed(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            active_path = root / "results" / "active-evidence.json"
            final_report_path = root / "results" / "final-report.json"
            nesting_depth = 30_000
            active_path.write_bytes(
                b'{"value":' + (b"[" * nesting_depth) + b"0" + (b"]" * nesting_depth) + b"}\n"
            )
            final_report_path.unlink()

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(load_object(final_report_path), report)
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertEqual(report["active_evidence_sha256"], _raw_sha256(active_path))
            self.assertIsNone(report["active_evidence"])
            self.assertTrue(report["m4_blocked"])

    def test_malformed_decision_list_binds_raw_bytes_and_fails_closed(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            decisions_path = root / "results" / "decision-receipts.json"
            decisions_path.write_bytes(b"[{")

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertEqual(
                report["decision_receipts_sha256"],
                _raw_sha256(decisions_path),
            )
            self.assertIsNone(report["decision_receipt_sha256s"])
            self.assertTrue(report["m4_blocked"])

    def test_deeply_nested_decision_list_binds_raw_bytes_and_fails_closed(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            decisions_path = root / "results" / "decision-receipts.json"
            final_report_path = root / "results" / "final-report.json"
            nesting_depth = 30_000
            decisions_path.write_bytes(
                b'[{"value":' + (b"[" * nesting_depth) + b"0" + (b"]" * nesting_depth) + b"}]\n"
            )
            final_report_path.unlink()

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(load_object(final_report_path), report)
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertEqual(
                report["decision_receipts_sha256"],
                _raw_sha256(decisions_path),
            )
            self.assertIsNone(report["decision_receipt_sha256s"])
            self.assertTrue(report["m4_blocked"])

    def test_overflowed_decision_number_binds_raw_bytes_and_fails_closed(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            decisions_path = root / "results" / "decision-receipts.json"
            decisions_path.write_bytes(b'[{"value":1e400}]')

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(
                load_object(root / "results" / "final-report.json"),
                report,
            )
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertEqual(
                report["decision_receipts_sha256"],
                _raw_sha256(decisions_path),
            )
            self.assertIsNone(report["decision_receipt_sha256s"])
            self.assertTrue(report["m4_blocked"])

    def test_noncanonical_decision_json_binds_raw_bytes_and_fails_closed(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result_tree(root)
            decisions_path = root / "results" / "decision-receipts.json"
            canonical_bytes = decisions_path.read_bytes()
            self.assertTrue(canonical_bytes.endswith(b"\n"))
            decisions_path.write_bytes(canonical_bytes + b" ")

            # when
            report = build_final_report(root)

            # then
            self.assertEqual(
                load_object(root / "results" / "final-report.json"),
                report,
            )
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertEqual(
                report["decision_receipts_sha256"],
                _raw_sha256(decisions_path),
            )
            self.assertIsNone(report["decision_receipt_sha256s"])
            self.assertTrue(report["m4_blocked"])

    def test_schema_declares_closed_complete_and_incomplete_conditions(self) -> None:
        # given
        schema_path = Path(__file__).resolve().parents[2] / "schemas" / "final-report.schema.json"

        # when
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        conditional = schema["allOf"][0]
        complete = conditional["then"]["properties"]
        incomplete = conditional["else"]["properties"]
        expected_complete = {
            "manifest_sha256": {"$ref": "#/$defs/sha256"},
            "owner_approval_sha256": {"$ref": "#/$defs/sha256"},
            "freeze_commit": {"type": "string", "pattern": "^[0-9a-f]{40}$"},
            "event_log_sha256": {"$ref": "#/$defs/sha256"},
            "replay_receipt_sha256": {"$ref": "#/$defs/sha256"},
            "decision_receipts_sha256": {"$ref": "#/$defs/sha256"},
            "decision_receipt_sha256s": {"type": "array"},
            "base_digest": {"$ref": "#/$defs/sha256"},
            "candidate_digest": {"$ref": "#/$defs/sha256"},
            "candidate_artifact_sha256": {"$ref": "#/$defs/sha256"},
            "promoted_digest": {"$ref": "#/$defs/sha256"},
            "promotion_receipt_sha256": {"$ref": "#/$defs/sha256"},
            "page_adapter_receipt_sha256": {"$ref": "#/$defs/sha256"},
            "adapter_evidence": {
                "allOf": [
                    {"$ref": "#/$defs/adapterEvidence"},
                    {
                        "properties": {
                            "minimum_candidate_score": {"type": "number"},
                            "mean_delta": {"type": "number"},
                        }
                    },
                ]
            },
            "active_evidence_sha256": {"$ref": "#/$defs/sha256"},
            "active_evidence": {"$ref": "#/$defs/activeEvidence"},
            "restart_evidence_sha256": {"$ref": "#/$defs/sha256"},
            "restart_evidence": {"$ref": "#/$defs/restartEvidence"},
            "failure_sha256": {"type": "null"},
            "thresholds": {"$ref": "#/$defs/thresholds"},
            "m4_blocked": {"const": False},
        }
        expected_top_level = {
            "schema_version": {"const": 1},
            "status": {"enum": ["complete", "incomplete_failed"]},
            "manifest_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "owner_approval_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "freeze_commit": {
                "type": ["string", "null"],
                "pattern": "^[0-9a-f]{40}$",
            },
            "event_log_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "replay_receipt_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "decision_receipts_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "decision_receipt_sha256s": {
                "type": ["array", "null"],
                "items": {"$ref": "#/$defs/sha256"},
            },
            "base_digest": {"$ref": "#/$defs/sha256OrNull"},
            "candidate_digest": {"$ref": "#/$defs/sha256OrNull"},
            "candidate_artifact_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "promoted_digest": {"$ref": "#/$defs/sha256OrNull"},
            "promotion_receipt_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "page_adapter_receipt_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "adapter_evidence": {
                "oneOf": [
                    {"$ref": "#/$defs/adapterEvidence"},
                    {"type": "null"},
                ]
            },
            "active_evidence_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "active_evidence": {
                "oneOf": [
                    {"$ref": "#/$defs/activeEvidence"},
                    {"type": "null"},
                ]
            },
            "restart_evidence_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "restart_evidence": {
                "oneOf": [
                    {"$ref": "#/$defs/restartEvidence"},
                    {"type": "null"},
                ]
            },
            "failure_sha256": {"$ref": "#/$defs/sha256OrNull"},
            "thresholds": {
                "oneOf": [
                    {"$ref": "#/$defs/thresholds"},
                    {"type": "null"},
                ]
            },
            "m4_blocked": {"type": "boolean"},
        }

        # then
        with self.subTest(contract="conditional selects complete status"):
            self.assertEqual(
                conditional["if"],
                {"properties": {"status": {"const": "complete"}}},
            )
        with self.subTest(contract="complete branch has the exact closed binding map"):
            self.assertEqual(complete, expected_complete)
        with self.subTest(contract="incomplete remains M4 blocked"):
            self.assertEqual(incomplete["m4_blocked"], {"const": True})
        with self.subTest(contract="top-level null declarations are exact"):
            self.assertEqual(schema["properties"], expected_top_level)


def _raw_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    unittest.main()
