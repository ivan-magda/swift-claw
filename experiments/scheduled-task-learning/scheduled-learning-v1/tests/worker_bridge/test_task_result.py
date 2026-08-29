from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

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
            self.assertEqual(validate_task_result(call, task_result(core))["raw_output"], "result")
