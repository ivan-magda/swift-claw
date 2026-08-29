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
