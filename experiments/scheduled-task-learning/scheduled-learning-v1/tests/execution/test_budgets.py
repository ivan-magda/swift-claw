"""Aggregate budget guards are all pre-dispatch."""

from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Literal, cast

from scheduled_learning_v1.execution.budgets import AggregateBudget, BudgetExceededError

from .support import learning_call, recording_operations


class AggregateBudgetTests(unittest.TestCase):
    def test_next_operation_must_fit_worst_case_token_accounting_before_dispatch(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            operations, bridge = recording_operations(
                root,
                AggregateBudget(accounted_tokens=100_000),
                missing_usage_token_proxy=132_768,
            )

            # when
            with self.assertRaises(BudgetExceededError) as raised:
                operations.dispatch_task(object())

            # then
            self.assertIsInstance(raised.exception, BudgetExceededError)
            self.assertEqual(bridge.calls, 0)

    def test_operation_caps_reject_the_next_dispatch(self) -> None:
        # given
        for kind, allowed in (("task", 10), ("evaluator", 5), ("reflector", 1)):
            with self.subTest(kind=kind), TemporaryDirectory() as temporary:
                root = Path(temporary)
                operations, bridge = recording_operations(root, AggregateBudget())
                for _ in range(allowed):
                    if kind == "task":
                        operations.dispatch_task(object())
                    else:
                        learning_kind = cast(Literal["evaluator", "reflector"], kind)
                        operations.dispatch_learning(learning_call(root, learning_kind))
                dispatched_at_limit = bridge.calls

                # when
                with self.assertRaises(BudgetExceededError) as raised:
                    if kind == "task":
                        operations.dispatch_task(object())
                    else:
                        learning_kind = cast(Literal["evaluator", "reflector"], kind)
                        operations.dispatch_learning(learning_call(root, learning_kind))

                # then
                self.assertIsInstance(raised.exception, BudgetExceededError)
                self.assertEqual(dispatched_at_limit, allowed)
                self.assertEqual(bridge.calls, dispatched_at_limit)

    def test_usage_caps_reject_send_39_and_token_120001_before_dispatch(self) -> None:
        # given
        for name, budget in (
            ("send 39", AggregateBudget(responses_sends=38)),
            ("token 120001", AggregateBudget(accounted_tokens=120_000)),
        ):
            with self.subTest(name=name), TemporaryDirectory() as temporary:
                root = Path(temporary)
                operations, bridge = recording_operations(root, budget)

                # when
                with self.assertRaises(BudgetExceededError) as raised:
                    operations.dispatch_task(object())

                # then
                self.assertIsInstance(raised.exception, BudgetExceededError)
                self.assertEqual(bridge.calls, 0)

    def test_two_send_task_is_rejected_with_only_one_authorized_send_remaining(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            operations, bridge = recording_operations(
                root,
                AggregateBudget(responses_sends=37),
            )

            # when
            with self.assertRaises(BudgetExceededError) as raised:
                operations.dispatch_task(object())

            # then
            self.assertIsInstance(raised.exception, BudgetExceededError)
            self.assertEqual(bridge.calls, 0)


if __name__ == "__main__":
    unittest.main()
