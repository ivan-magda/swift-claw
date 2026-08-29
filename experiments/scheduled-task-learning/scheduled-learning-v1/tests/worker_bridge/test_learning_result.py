from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from scheduled_learning_v1.worker_bridge import LearningCall, validate_learning_result

from .support import learning_core, learning_result


class LearningResultTests(unittest.TestCase):
    def test_rejects_wrong_kind_and_cross_operation_and_enforces_exact_completion_caps(
        self,
    ) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            call = LearningCall("evaluator", core, root / "request.json", root / "result.json")

            # when / then
            wrong_kind = learning_result(core)
            wrong_kind["kind"] = "reflector"
            with self.assertRaises(ValueError):
                validate_learning_result(call, wrong_kind)
            cross_operation = learning_result(core)
            cross_operation["operation_id"] = "other"
            with self.assertRaises(ValueError):
                validate_learning_result(call, cross_operation)
            self.assertEqual(
                validate_learning_result(call, learning_result(core))["kind"], "evaluator"
            )
            too_large = learning_result(core)
            too_large["usage"]["completion_tokens"] = 513  # type: ignore[index]
            too_large["usage"]["reported_total_tokens"] = 523  # type: ignore[index]
            too_large["usage"]["accounted_tokens"] = 523  # type: ignore[index]
            with self.assertRaises(ValueError):
                validate_learning_result(call, too_large)

    def test_reflector_accepts_768_and_rejects_769_completion_tokens(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root, "reflector")
            call = LearningCall("reflector", core, root / "request.json", root / "result.json")

            # when / then
            self.assertEqual(
                validate_learning_result(call, learning_result(core))["kind"], "reflector"
            )
            too_large = learning_result(core)
            too_large["usage"]["completion_tokens"] = 769  # type: ignore[index]
            too_large["usage"]["reported_total_tokens"] = 779  # type: ignore[index]
            too_large["usage"]["accounted_tokens"] = 779  # type: ignore[index]
            with self.assertRaises(ValueError):
                validate_learning_result(call, too_large)
