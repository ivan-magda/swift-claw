"""Aggregate budget guards are all pre-dispatch."""

from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Literal, cast

from scheduled_learning_v1.execution.budgets import AggregateBudget, BudgetExceededError

from .support import learning_call, recording_operations


class AggregateBudgetTests(unittest.TestCase):
    def test_operation_caps_reject_the_next_dispatch(self) -> None:
        # given / when / then
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

                with self.assertRaises(BudgetExceededError):
                    if kind == "task":
                        operations.dispatch_task(object())
                    else:
                        learning_kind = cast(Literal["evaluator", "reflector"], kind)
                        operations.dispatch_learning(learning_call(root, learning_kind))

                self.assertEqual(dispatched_at_limit, allowed)
                self.assertEqual(bridge.calls, dispatched_at_limit)

    def test_usage_caps_reject_send_39_and_token_120001_before_dispatch(self) -> None:
        # given / when / then
        for name, budget in (
            ("send 39", AggregateBudget(responses_sends=38)),
            ("token 120001", AggregateBudget(accounted_tokens=120_000)),
        ):
            with self.subTest(name=name), TemporaryDirectory() as temporary:
                root = Path(temporary)
                operations, bridge = recording_operations(root, budget)

                with self.assertRaises(BudgetExceededError):
                    operations.dispatch_task(object())

                self.assertEqual(bridge.calls, 0)


if __name__ == "__main__":
    unittest.main()
