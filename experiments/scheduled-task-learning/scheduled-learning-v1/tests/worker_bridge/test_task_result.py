from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import cast

from benchmark_core.canonical import canonical_sha256, dumps
from scheduled_learning_v1.worker_bridge import TaskAttemptCall, validate_task_result

from .support import task_core, task_result


class TaskResultTests(unittest.TestCase):
    def test_rejects_malformed_and_substituted_carrier_results(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            call = TaskAttemptCall(core, root / "invocation.json", root / "result.json")

            # when / then
            with self.assertRaises(ValueError):
                validate_task_result(call, {})
            substituted = task_result(core)
            substituted["learning_carrier_sha256"] = "0" * 64
            with self.assertRaises(ValueError):
                validate_task_result(call, substituted)
            substituted_lessons = {**task_result(core), "lesson_ids": ["other"]}
            with self.assertRaises(ValueError):
                validate_task_result(call, substituted_lessons)
            self.assertEqual(validate_task_result(call, task_result(core))["raw_output"], "result")

    def test_binds_canonical_result_identity_route_provenance_and_accounting(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            call = TaskAttemptCall(core, root / "invocation.json", root / "result.json")
            valid = task_result(core)

            # when / then
            self.assertEqual(validate_task_result(call, valid)["accounted_tokens"], 12)
            mutations = (
                {**valid, "attempt_id": "other"},
                {**valid, "process_uuid": "not-a-uuid"},
                {**valid, "lock_acquisition_id": "not-a-uuid"},
                {**valid, "manifest_sha256": "0" * 64},
                {**valid, "accounted_tokens": 13},
                {**valid, "critical_code": "impossible-completed-code"},
                {**valid, "replacement_disposition": "eligible"},
                {
                    **valid,
                    "output_counts": {
                        "utf8Bytes": 6,
                        "graphemes": 6,
                        "limitExceeded": True,
                    },
                },
                {**valid, "invented_operation_id": core["operation_id"]},
            )
            for changed in mutations:
                with self.subTest(keys=changed.keys()), self.assertRaises(ValueError):
                    validate_task_result(call, changed)

    def test_rejects_broken_carrier_protocol_and_configuration_provenance(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            call = TaskAttemptCall(core, root / "invocation.json", root / "result.json")
            valid = task_result(core)

            # when / then
            for changed in (
                {**valid, "learning_initial_tainted": False},
                {**valid, "learning_carrier_verified": False},
                {
                    **valid,
                    "provenance": {
                        **cast(dict[str, object], valid["provenance"]),
                        "freeze_commit": "0" * 40,
                    },
                },
            ):
                with self.assertRaises(ValueError):
                    validate_task_result(call, changed)

            configuration_path = Path(str(core["configuration_path"]))
            configuration = cast(
                dict[str, object], json.loads(configuration_path.read_text(encoding="utf-8"))
            )
            approval = cast(dict[str, object], configuration["approval"])
            configuration["approval"] = {**approval, "invented": True}
            configuration_path.write_text(dumps(configuration), encoding="utf-8")
            changed_core = {
                **core,
                "configuration_sha256": canonical_sha256(configuration),
            }
            changed_call = TaskAttemptCall(
                changed_core,
                root / "invocation.json",
                root / "result.json",
            )
            with self.assertRaises(ValueError):
                validate_task_result(changed_call, task_result(changed_core))

    def test_rejects_coordinated_scheduled_receipt_identity_substitution(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            call = TaskAttemptCall(core, root / "invocation.json", root / "result.json")
            valid = task_result(core)
            receipt = {
                **cast(dict[str, object], valid["carrier_receipt"]),
                "lesson_set_id": "substituted-set",
                "lesson_ids": ["substituted-lesson"],
            }
            receipt_sha256 = canonical_sha256(receipt)
            workspace = {
                **cast(dict[str, object], valid["workspace"]),
                "lesson_set_id": "substituted-set",
                "lesson_ids": ["substituted-lesson"],
                "carrier_receipt": receipt,
                "carrier_receipt_sha256": receipt_sha256,
            }
            changed = {
                **valid,
                "lesson_set_id": "substituted-set",
                "lesson_ids": ["substituted-lesson"],
                "carrier_receipt": receipt,
                "carrier_receipt_sha256": receipt_sha256,
                "workspace": workspace,
            }

            # when / then
            with self.assertRaises(ValueError):
                validate_task_result(call, changed)

    def test_binds_every_usage_row_to_result_and_frozen_route_identity(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            call = TaskAttemptCall(core, root / "invocation.json", root / "result.json")
            valid = task_result(core)
            usage = cast(list[dict[str, object]], valid["usage"])

            # when / then
            for key, value in (("run_id", 9), ("session_id", 10), ("model", "other-model")):
                changed_usage = [{**usage[0], key: value}]
                with self.subTest(key=key), self.assertRaises(ValueError):
                    validate_task_result(call, {**valid, "usage": changed_usage})

    def test_accepts_canonical_failure_with_missing_output_counts(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            call = TaskAttemptCall(core, root / "invocation.json", root / "result.json")
            valid = task_result(core)
            canonical_failure = {
                key: value
                for key, value in {
                    **valid,
                    "outcome": "provider_failure",
                    "raw_output": None,
                    "replacement_reason": "provider_terminal",
                }.items()
                if key != "output_counts"
            }

            # when
            result = validate_task_result(call, canonical_failure)

            # then
            self.assertEqual(result["status"], "failed")

    def test_completed_result_requires_non_null_output_counts(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            call = TaskAttemptCall(core, root / "invocation.json", root / "result.json")
            valid = task_result(core)
            without_counts = {key: value for key, value in valid.items() if key != "output_counts"}
            null_counts = {**valid, "output_counts": None}

            # when / then
            for name, changed in (("missing", without_counts), ("null", null_counts)):
                with self.subTest(counts=name), self.assertRaises(ValueError):
                    validate_task_result(call, changed)

    def test_rejects_outcome_specific_failure_shape_mutations(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            call = TaskAttemptCall(core, root / "invocation.json", root / "result.json")
            valid = task_result(core)
            generic_failure = {
                **valid,
                "raw_output": None,
                "replacement_disposition": "ineligible",
            }
            mutations = (
                ("provider_failure", "unexpected", "provider_terminal"),
                ("authentication_required", "unexpected", "authentication"),
                ("access_denied", "unexpected", "access"),
                ("quota_limited", "unexpected", "quota"),
                ("invalid_provider_state", None, "invalid_provider_state"),
                ("local_output_limit", None, "local_output_limit"),
                ("model_identity_mismatch", None, "model_identity_mismatch"),
                ("budget_stopped", None, "budget_or_tool_deviation"),
                ("tool_contract_failure", None, "task_contract_failure"),
                ("policy_mismatch", "policy_mismatch", "policy_mismatch"),
                ("harness_failure", None, "harness_integrity_failure"),
            )

            # when / then
            for outcome, critical_code, reason in mutations:
                changed = {
                    **generic_failure,
                    "outcome": outcome,
                    "critical_code": critical_code,
                    "replacement_reason": reason,
                }
                with self.subTest(outcome=outcome), self.assertRaises(ValueError):
                    validate_task_result(call, changed)
            eligible_with_critical = {
                **generic_failure,
                "outcome": "provider_failure",
                "critical_code": "unexpected",
                "replacement_disposition": "eligible",
                "replacement_reason": "transport_failure",
            }
            with self.assertRaises(ValueError):
                validate_task_result(call, eligible_with_critical)
            for malformed in (
                {**generic_failure, "outcome": "provider_failure", "replacement_disposition": []},
                {
                    **generic_failure,
                    "outcome": "model_identity_mismatch",
                    "critical_code": [],
                    "replacement_reason": "model_identity_mismatch",
                },
            ):
                with self.assertRaises(ValueError):
                    validate_task_result(call, malformed)
            for outcome in (
                "provider_failure",
                "authentication_required",
                "access_denied",
                "quota_limited",
                "invalid_provider_state",
                "local_output_limit",
                "model_identity_mismatch",
                "budget_stopped",
                "tool_contract_failure",
                "policy_mismatch",
                "harness_failure",
            ):
                with self.subTest(completed_shape=outcome), self.assertRaises(ValueError):
                    validate_task_result(call, {**valid, "outcome": outcome})

    def test_rejects_unknown_nonempty_tool_contract_critical_code(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            call = TaskAttemptCall(core, root / "invocation.json", root / "result.json")
            changed = {
                **task_result(core),
                "outcome": "tool_contract_failure",
                "critical_code": "invented_tool_violation",
                "replacement_reason": "task_contract_failure",
            }

            # when / then
            with self.assertRaises(ValueError):
                validate_task_result(call, changed)
