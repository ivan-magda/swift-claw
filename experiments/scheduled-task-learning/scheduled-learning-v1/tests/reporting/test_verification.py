"""Offline verification rehashes every committed event."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest.mock import patch

from benchmark_core.canonical import canonical_sha256, load_object, write
from scheduled_learning_v1.frozen_contract import AGGREGATE_BUDGETS
from scheduled_learning_v1.reporting import build_final_report, verify_results

from .support import artifact_result_tree, publish_hash_consistent_replay, rewrite_finish_event


class ResultVerificationTests(unittest.TestCase):
    def test_valid_tree_verifies_offline(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)

            # when
            receipt = verify_results(root, manifest)

            # then
            self.assertEqual(receipt["status"], "verified_self_contained")
            self.assertTrue(receipt["self_verifying"])
            self.assertEqual(receipt["unreconstructable_terminal_digests"], 0)

    def test_changed_auxiliary_projection_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            auxiliary = root / "results" / "events" / "state.json"
            state = load_object(auxiliary)
            state["controller_generation"] = 99
            write(auxiliary, state)

            # when / then
            with self.assertRaisesRegex(ValueError, "auxiliary state"):
                verify_results(root, manifest)

    def test_changed_task_carrier_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            carrier_path = root / "results" / "task-attempts" / "task-0" / "carrier.json"
            carrier = load_object(carrier_path)
            carrier["task_id"] = "changed-task"
            write(carrier_path, carrier)

            # when / then
            with self.assertRaisesRegex(ValueError, "task carrier digest"):
                verify_results(root, manifest)

    def test_changed_task_configuration_binding_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            path = root / "results" / "task-attempts" / "task-0" / "configuration.json"
            configuration = load_object(path)
            configuration["fixed_timestamp"] = "2030-01-01T00:00:00Z"
            write(path, configuration)

            # when / then
            with self.assertRaisesRegex(ValueError, "task configuration digest"):
                verify_results(root, manifest)

    def test_changed_task_invocation_core_binding_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            path = root / "results" / "task-attempts" / "task-0" / "invocation.json"
            invocation = load_object(path)
            budget = cast(dict[str, object], invocation["budget"])
            budget["global_accounted_tokens"] = 1
            write(path, invocation)

            # when / then
            with self.assertRaisesRegex(ValueError, "task invocation core digest"):
                verify_results(root, manifest)

    def test_changed_task_result_binding_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            path = root / "results" / "task-attempts" / "task-0" / "result.json"
            result = load_object(path)
            result["raw_output"] = "changed"
            write(path, result)

            # when / then
            with self.assertRaisesRegex(ValueError, "task result digest"):
                verify_results(root, manifest)

    def test_changed_task_usage_binding_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            rewrite_finish_event(root, "task-0", usage_digest="0" * 64)

            # when / then
            with self.assertRaisesRegex(ValueError, "task usage digest"):
                verify_results(root, manifest)

    def test_changed_aggregate_budget_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            budget_path = root / "results" / "aggregate-budget.json"
            budget = load_object(budget_path)
            budget["task_attempts"] = 3
            write(budget_path, budget)

            # when / then
            with self.assertRaisesRegex(ValueError, "aggregate budget"):
                verify_results(root, manifest)

    def test_reconstructed_budget_must_fit_manifest_and_owner_authorization(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            result_path = root / "results" / "task-attempts" / "task-0" / "result.json"
            result = load_object(result_path)
            original_accounted_tokens = result["accounted_tokens"]
            self.assertIsInstance(original_accounted_tokens, int)
            result["accounted_tokens"] = AGGREGATE_BUDGETS["accounted_tokens"] + 1
            write(result_path, result)
            rewrite_finish_event(root, "task-0", result_digest=canonical_sha256(result))
            budget_path = root / "results" / "aggregate-budget.json"
            budget = load_object(budget_path)
            budget["accounted_tokens"] = (
                budget["accounted_tokens"] - original_accounted_tokens + result["accounted_tokens"]
            )
            write(budget_path, budget)
            state = load_object(root / "results" / "state.json")
            decisions = json.loads(
                (root / "results" / "decision-receipts.json").read_text(encoding="utf-8")
            )
            self.assertIsInstance(decisions, list)
            publish_hash_consistent_replay(root, state, cast(list[dict[str, object]], decisions))
            build_final_report(root)

            # when
            with self.assertRaisesRegex(ValueError, "authorized accounted_tokens") as raised:
                verify_results(root, manifest)

            # then
            self.assertIsInstance(raised.exception, ValueError)

    def test_reconstructed_budget_must_fit_manifest_when_owner_limit_is_higher(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(
                root,
                manifest_accounted_token_limit=1_845,
                approval_accounted_token_limit=2_000,
            )

            # when
            with self.assertRaisesRegex(
                ValueError,
                "^reconstructed total exceeds manifest authorized accounted_tokens$",
            ) as raised:
                verify_results(root, manifest)

            # then
            self.assertIsInstance(raised.exception, ValueError)

    def test_reconstructed_budget_must_fit_owner_when_manifest_limit_is_higher(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(
                root,
                manifest_accounted_token_limit=2_000,
                approval_accounted_token_limit=1_845,
            )

            # when
            with self.assertRaisesRegex(
                ValueError,
                "^reconstructed total exceeds owner authorized accounted_tokens$",
            ) as raised:
                verify_results(root, manifest)

            # then
            self.assertIsInstance(raised.exception, ValueError)

    def test_offline_verification_rejects_rebound_active_score_evidence(self) -> None:
        # given
        for name, key, value in (
            ("task identity", "task_id", "task-other"),
            ("scoring condition", "scoring_condition", "restart"),
            ("promoted lessons", "promoted_digest", "f" * 64),
            ("score", "score", 99),
            ("critical codes", "critical_codes", ["critical.invalid"]),
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                manifest = artifact_result_tree(root, active_evidence=True)
                path = root / "results" / "active-evidence.json"
                evidence = load_object(path)
                evidence[key] = value
                write(path, evidence)

                # when
                report = build_final_report(root)
                with (
                    patch("scheduled_learning_v1.reporting.verification.verify_manifest"),
                    self.assertRaisesRegex(
                        ValueError,
                        "active evidence is not bound to its frozen task result",
                    ) as raised,
                ):
                    verify_results(root, manifest)

                # then
                self.assertEqual(report["status"], "incomplete_failed")
                self.assertTrue(report["m4_blocked"])
                self.assertIsInstance(raised.exception, ValueError)

    def test_aggregate_reconstruction_counts_heterogeneous_usage(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)

            # when
            receipt = verify_results(root, manifest)

            # then
            self.assertEqual(receipt["status"], "verified_self_contained")
            self.assertEqual(
                load_object(root / "results" / "aggregate-budget.json"),
                {
                    "schema_version": 1,
                    "task_attempts": 2,
                    "evaluator_calls": 2,
                    "reflector_calls": 1,
                    "responses_sends": 5,
                    "accounted_tokens": 1846,
                },
            )

    def test_changed_learning_carrier_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            carrier_path = root / "results" / "learning-calls" / "evaluator-task-0" / "carrier.json"
            carrier = load_object(carrier_path)
            carrier["operation_id"] = "changed-operation"
            write(carrier_path, carrier)

            # when / then
            with self.assertRaisesRegex(ValueError, "learning carrier digest"):
                verify_results(root, manifest)

    def test_changed_learning_authorized_request_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            path = root / "results" / "learning-calls" / "evaluator-task-0" / "request.json"
            request = load_object(path)
            authorization = cast(dict[str, object], request["authorization"])
            authorization["event_sha256"] = "0" * 64
            write(path, request)

            # when / then
            with self.assertRaisesRegex(ValueError, "authorization digest"):
                verify_results(root, manifest)

    def test_changed_learning_authorized_request_core_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            path = root / "results" / "learning-calls" / "evaluator-task-0" / "request.json"
            request = load_object(path)
            request["state_root"] = str(root / "changed-learning-state")
            write(path, request)

            # when / then
            with self.assertRaisesRegex(ValueError, "learning request core digest"):
                verify_results(root, manifest)

    def test_changed_learning_result_binding_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            path = root / "results" / "learning-calls" / "evaluator-task-0" / "result.json"
            result = load_object(path)
            result["output"] = "changed"
            write(path, result)

            # when / then
            with self.assertRaisesRegex(ValueError, "learning result digest"):
                verify_results(root, manifest)

    def test_changed_learning_result_provenance_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            path = root / "results" / "learning-calls" / "evaluator-task-0" / "result.json"
            result = load_object(path)
            provenance = cast(dict[str, object], result["provenance"])
            provenance["request_sha256"] = "0" * 64
            write(path, result)
            rewrite_finish_event(
                root,
                "evaluator-task-0",
                result_digest=canonical_sha256(result),
            )

            # when / then
            with self.assertRaisesRegex(ValueError, "request digest"):
                verify_results(root, manifest)

    def test_changed_learning_usage_binding_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            rewrite_finish_event(root, "evaluator-task-0", usage_digest="0" * 64)

            # when / then
            with self.assertRaisesRegex(ValueError, "learning usage digest"):
                verify_results(root, manifest)

    def test_valid_terminal_sidecar_verifies_offline(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root, terminal=True)

            # when
            receipt = verify_results(root, manifest)

            # then
            operation = root / "results" / "task-attempts" / "task-0"
            terminal = load_object(operation / "terminal.json")
            self.assertEqual(receipt["status"], "verified_self_contained")
            self.assertEqual(terminal["status"], "process_failed")
            self.assertFalse((operation / "result.json").exists())
            self.assertEqual(
                load_object(root / "results" / "aggregate-budget.json"),
                {
                    "schema_version": 1,
                    "task_attempts": 1,
                    "evaluator_calls": 0,
                    "reflector_calls": 0,
                    "responses_sends": 0,
                    "accounted_tokens": 0,
                },
            )

    def test_future_missing_result_and_terminal_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            result_path = root / "results" / "task-attempts" / "task-0" / "result.json"
            result_path.unlink()

            # when / then
            with self.assertRaisesRegex(ValueError, "result or terminal"):
                verify_results(root, manifest)

    def test_unowned_result_artifact_is_rejected(self) -> None:
        for relative in (
            "results/invented.json",
            "results/events/invented.json",
            "results/task-attempts/task-0/invented.json",
        ):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary:
                # given
                root = Path(temporary)
                manifest = artifact_result_tree(root)
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                write(path, {"schema_version": 1})

                # when / then
                with self.assertRaisesRegex(ValueError, "unowned .*artifact"):
                    verify_results(root, manifest)

    def test_leaked_private_learning_state_root_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            leaked = (
                root / "results" / ".private-learning-state" / "evaluator-task-0" / "result.json"
            )
            leaked.parent.mkdir(parents=True)
            write(leaked, {"schema_version": 1})

            # when
            with self.assertRaisesRegex(
                ValueError,
                "unowned result artifact: .private-learning-state",
            ) as raised:
                verify_results(root, manifest)

            # then
            self.assertIsInstance(raised.exception, ValueError)

    def test_forged_legacy_worker_failure_sidecar_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            operation = root / "results" / "task-attempts" / "task-0"
            configuration = load_object(operation / "configuration.json")
            invocation = load_object(operation / "invocation.json")
            manifest_binding = cast(dict[str, object], invocation["manifest"])
            write(
                operation / "result.json.worker-failure.json",
                {
                    "schema_version": 1,
                    "invocation_id": "00000000-0000-0000-0000-000000000000",
                    "configuration_sha256": invocation["configuration_sha256"],
                    "attempt_id": configuration["attempt_id"],
                    "manifest_sha256": manifest_binding["manifest_sha256"],
                    "classification": "carrier_failure",
                    "reason": "source_digest_mismatch",
                },
            )

            # when / then
            with self.assertRaisesRegex(ValueError, "task operation has an unowned artifact"):
                verify_results(root, manifest)

    def test_unknown_operation_directory_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            path = root / "results" / "task-attempts" / "unknown-operation" / "carrier.json"
            path.parent.mkdir(parents=True)
            write(path, {"schema_version": 1})

            # when / then
            with self.assertRaisesRegex(ValueError, "operation directory inventory"):
                verify_results(root, manifest)

    def test_preserved_tree_reports_legacy_incomplete_audit(self) -> None:
        # given
        root = Path(__file__).resolve().parents[2]
        manifest = load_object(root / "freeze" / "manifest.json")

        # when
        receipt = verify_results(root, manifest)

        # then
        self.assertEqual(receipt["status"], "verified_legacy_incomplete")
        self.assertFalse(receipt["self_verifying"])
        self.assertEqual(receipt["unreconstructable_terminal_digests"], 1)
        self.assertEqual(
            receipt["manifest_sha256"],
            "d16ae90f1e54e866a75af773ae304884906fa943ad937a2e74c00a4638842c07",
        )

    def test_changed_event_byte_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            event_path = next((root / "results" / "events").glob("0*.json"))
            event_path.write_text(event_path.read_text(encoding="utf-8") + " ", encoding="utf-8")

            # when / then
            with self.assertRaises(ValueError):
                verify_results(root, manifest)

    def test_self_consistent_impossible_state_is_rejected_by_semantic_replay(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
            state_path = root / "results" / "state.json"
            decisions_path = root / "results" / "decision-receipts.json"
            state = load_object(state_path)
            state["controller_generation"] = 99
            decisions = json.loads(decisions_path.read_text(encoding="utf-8"))
            self.assertIsInstance(decisions, list)
            typed_decisions = cast(list[dict[str, object]], decisions)
            publish_hash_consistent_replay(root, state, typed_decisions)
            build_final_report(root)

            # when / then
            with self.assertRaisesRegex(ValueError, "persisted state differs from semantic replay"):
                verify_results(root, manifest)

    def test_self_consistent_decision_mutation_is_rejected_by_semantic_replay(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = artifact_result_tree(root)
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
            build_final_report(root)

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
            manifest = artifact_result_tree(root)
            receipt_path = root / "results" / "replay-receipt.json"
            receipt = load_object(receipt_path)
            receipt["receipt_id"] = "replay-mutated"
            write(receipt_path, receipt)
            write(root / "results" / "events" / "replay-receipt.json", receipt)
            build_final_report(root)

            # when / then
            with self.assertRaisesRegex(
                ValueError,
                "persisted replay receipt differs from semantic replay",
            ):
                verify_results(root, manifest)


if __name__ == "__main__":
    unittest.main()
