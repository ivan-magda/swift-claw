from __future__ import annotations

import unittest

from scheduled_learning_v1.worker_bridge.accounting import validate_usage


class AccountingTests(unittest.TestCase):
    def test_recomputes_reported_and_missing_usage_without_a_second_subtraction(self) -> None:
        # given
        usage = {
            "provider_call_id": "123e4567-e89b-12d3-a456-426614174000",
            "responses_sends": 3,
            "proven_not_started_responses_sends": 1,
            "prompt_tokens": 11,
            "completion_tokens": 7,
            "reported_total_tokens": 18,
            "accounted_tokens": 118,
            "is_estimated": True,
        }

        # when
        accounted = validate_usage(usage, "123e4567-e89b-12d3-a456-426614174000", 3, 100, 768)

        # then
        self.assertEqual(accounted, 118)

    def test_failed_no_call_is_zero_sends_and_handed_off_usage_is_bounded(self) -> None:
        # given
        no_call: dict[str, object] = {"responses_sends": 0, "proven_not_started_responses_sends": 0}
        too_many: dict[str, object] = {
            "responses_sends": 4,
            "proven_not_started_responses_sends": 0,
        }

        # when / then
        self.assertEqual(validate_usage(no_call, "id", 3, 100, 768, allow_no_usage=True), 0)
        with self.assertRaises(ValueError):
            validate_usage(too_many, "id", 3, 100, 768, allow_no_usage=True)
