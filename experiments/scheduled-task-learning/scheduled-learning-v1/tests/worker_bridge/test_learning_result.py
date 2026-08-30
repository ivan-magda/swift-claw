from __future__ import annotations

import hashlib
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import cast

from benchmark_core.canonical import canonical_sha256
from scheduled_learning_v1.worker_bridge import LearningCall, validate_learning_result

from .support import learning_core, learning_result, write_authorized_request


class LearningResultTests(unittest.TestCase):
    def test_rejects_wrong_kind_and_cross_operation_and_enforces_exact_completion_caps(
        self,
    ) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            call = LearningCall("evaluator", core, root / "request.json", root / "result.json")
            request = write_authorized_request(call.request_path, core)
            request_digest = canonical_sha256(request)

            # when / then
            wrong_kind = learning_result(core, request_sha256=request_digest)
            wrong_kind["kind"] = "reflector"
            with self.assertRaises(ValueError):
                validate_learning_result(call, wrong_kind)
            cross_operation = learning_result(core, request_sha256=request_digest)
            cross_operation["operation_id"] = "other"
            with self.assertRaises(ValueError):
                validate_learning_result(call, cross_operation)
            self.assertEqual(
                validate_learning_result(
                    call, learning_result(core, request_sha256=request_digest)
                )["kind"],
                "evaluator",
            )
            too_large = learning_result(core, request_sha256=request_digest)
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
            request = write_authorized_request(call.request_path, core)
            request_digest = canonical_sha256(request)

            # when / then
            self.assertEqual(
                validate_learning_result(
                    call, learning_result(core, request_sha256=request_digest)
                )["kind"],
                "reflector",
            )
            too_large = learning_result(core, request_sha256=request_digest)
            too_large["usage"]["completion_tokens"] = 769  # type: ignore[index]
            too_large["usage"]["reported_total_tokens"] = 779  # type: ignore[index]
            too_large["usage"]["accounted_tokens"] = 779  # type: ignore[index]
            with self.assertRaises(ValueError):
                validate_learning_result(call, too_large)

    def test_binds_final_request_provenance_output_and_outcome_shape(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            call = LearningCall("evaluator", core, root / "request.json", root / "result.json")
            request = write_authorized_request(call.request_path, core)
            valid = learning_result(core, request_sha256=canonical_sha256(request))

            # when / then
            self.assertEqual(validate_learning_result(call, valid)["status"], "response")
            for key, value in (
                ("request_sha256", "0" * 64),
                ("freeze_commit", "0" * 40),
                ("executable_sha256", "0" * 64),
            ):
                changed = {
                    **valid,
                    "provenance": {**cast(dict[str, object], valid["provenance"]), key: value},
                }
                with self.subTest(key=key), self.assertRaises(ValueError):
                    validate_learning_result(call, changed)
            changed = {**valid, "output_sha256": "0" * 64}
            with self.assertRaises(ValueError):
                validate_learning_result(call, changed)
            changed = {**valid, "failure_code": "provider_failure"}
            with self.assertRaises(ValueError):
                validate_learning_result(call, changed)

    def test_enforces_output_byte_and_grapheme_limits_and_exact_result_keys(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            call = LearningCall("evaluator", core, root / "request.json", root / "result.json")
            request = write_authorized_request(call.request_path, core)
            valid = learning_result(core, request_sha256=canonical_sha256(request))

            # when / then
            for output in ("é" * 2049, "x" * 4097):
                changed = {
                    **valid,
                    "output": output,
                    "output_sha256": hashlib.sha256(output.encode()).hexdigest(),
                }
                with self.subTest(length=len(output)), self.assertRaises(ValueError):
                    validate_learning_result(call, changed)
            with self.assertRaises(ValueError):
                validate_learning_result(call, {**valid, "invented": True})

    def test_failed_result_accepts_zero_sends_but_response_still_requires_a_send(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            call = LearningCall("evaluator", core, root / "request.json", root / "result.json")
            request = write_authorized_request(call.request_path, core)
            request_sha256 = canonical_sha256(request)
            zero_send_usage = {
                "provider_call_id": core["provider_call_id"],
                "responses_sends": 0,
                "proven_not_started_responses_sends": 0,
                "prompt_tokens": None,
                "completion_tokens": None,
                "reported_total_tokens": None,
                "accounted_tokens": 0,
                "is_estimated": False,
            }
            failed = {
                **learning_result(core, "failed", request_sha256=request_sha256),
                "usage": zero_send_usage,
            }
            response = {
                **learning_result(core, request_sha256=request_sha256),
                "usage": zero_send_usage,
            }

            # when / then
            self.assertEqual(validate_learning_result(call, failed)["accounted_tokens"], 0)
            with self.assertRaises(ValueError):
                validate_learning_result(call, response)

    def test_rejects_zero_send_failed_usage_with_reported_terminal_row(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            call = LearningCall("evaluator", core, root / "request.json", root / "result.json")
            request = write_authorized_request(call.request_path, core)
            reported_usage = {
                "provider_call_id": core["provider_call_id"],
                "responses_sends": 0,
                "proven_not_started_responses_sends": 0,
                "prompt_tokens": 132_256,
                "completion_tokens": 512,
                "reported_total_tokens": 132_768,
                "accounted_tokens": 0,
                "is_estimated": False,
            }
            changed = {
                **learning_result(core, "failed", request_sha256=canonical_sha256(request)),
                "usage": reported_usage,
            }

            # when / then
            with self.assertRaises(ValueError):
                validate_learning_result(call, changed)
