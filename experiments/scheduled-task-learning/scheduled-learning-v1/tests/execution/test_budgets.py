"""Aggregate budget guards are all pre-dispatch."""

from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Literal, cast

from scheduled_learning_v1.execution.budgets import AggregateBudget, BudgetExceededError
from scheduled_learning_v1.frozen_contract import (
    AGGREGATE_BUDGETS,
    MISSING_USAGE_TOKEN_PROXY,
)

from .support import learning_call, recording_operations


class AggregateBudgetTests(unittest.TestCase):
    def test_next_operation_must_fit_worst_case_token_accounting_before_dispatch(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            operations, bridge = recording_operations(
                root,
                AggregateBudget(
                    accounted_tokens=(
                        AGGREGATE_BUDGETS["accounted_tokens"] - (2 * MISSING_USAGE_TOKEN_PROXY) + 1
                    )
                ),
                missing_usage_token_proxy=MISSING_USAGE_TOKEN_PROXY,
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

    def test_complete_frozen_order_fits_the_exact_missing_usage_ceiling(self) -> None:
        # given
        operation_order = (
            "task",
            "evaluator",
            "task",
            "evaluator",
            "reflector",
            "task",
            "task",
            "evaluator",
            "task",
            "task",
            "evaluator",
            "task",
            "task",
            "evaluator",
            "task",
            "task",
        )
        sends_by_kind = {"task": 2, "evaluator": 3, "reflector": 3}
        active_index = len(operation_order) - 2
        restart_index = len(operation_order) - 1
        manifest: dict[str, object] = {"budgets": dict(AGGREGATE_BUDGETS)}
        approval: dict[str, object] = {"budgets": dict(AGGREGATE_BUDGETS)}
        budget = AggregateBudget()
        active_snapshot: dict[str, int] | None = None
        restart_snapshot: dict[str, int] | None = None

        # when
        for index, kind in enumerate(operation_order):
            if index == active_index:
                active_snapshot = budget.task_snapshot(manifest, approval)
            if index == restart_index:
                restart_snapshot = budget.task_snapshot(manifest, approval)
            maximum_sends = sends_by_kind[kind]
            maximum_tokens = maximum_sends * MISSING_USAGE_TOKEN_PROXY
            budget.reserve(
                kind,
                maximum_responses_sends=maximum_sends,
                maximum_accounted_tokens=maximum_tokens,
            )
            budget.record(
                {
                    "responses_sends": maximum_sends,
                    "accounted_tokens": maximum_tokens,
                }
            )

        # then
        self.assertEqual(budget.task_attempts, 10)
        self.assertEqual(budget.evaluator_calls, 5)
        self.assertEqual(budget.reflector_calls, 1)
        self.assertEqual(budget.responses_sends, 38)
        self.assertEqual(budget.accounted_tokens, 5_045_184)
        self.assertIsNotNone(active_snapshot)
        self.assertIsNotNone(restart_snapshot)
        active = cast(dict[str, int], active_snapshot)
        restart = cast(dict[str, int], restart_snapshot)
        self.assertEqual(active["stage_responses_sends"], 34)
        self.assertEqual(active["stage_accounted_tokens"], 4_514_112)
        self.assertEqual(restart["stage_responses_sends"], 36)
        self.assertEqual(restart["stage_accounted_tokens"], 4_779_648)

    def test_task_snapshot_requires_equal_manifest_and_approval_caps(self) -> None:
        # given
        manifest: dict[str, object] = {"budgets": dict(AGGREGATE_BUDGETS)}
        approval: dict[str, object] = {"budgets": dict(AGGREGATE_BUDGETS)}
        budget = AggregateBudget(responses_sends=34, accounted_tokens=4_514_112)

        # when
        snapshot = budget.task_snapshot(manifest, approval)

        # then
        self.assertEqual(snapshot["stage_accounted_token_threshold"], 5_045_184)
        self.assertEqual(snapshot["global_accounted_token_threshold"], 5_045_184)
        self.assertEqual(snapshot["stage_responses_send_cap"], 38)
        self.assertEqual(snapshot["global_responses_send_cap"], 38)
        for source in (manifest, approval):
            changed_budgets = dict(AGGREGATE_BUDGETS)
            changed_budgets["accounted_tokens"] -= 1
            changed: dict[str, object] = {"budgets": changed_budgets}
            with self.subTest(source=source), self.assertRaises(ValueError):
                budget.task_snapshot(
                    changed if source is manifest else manifest,
                    changed if source is approval else approval,
                )

    def test_usage_caps_reject_one_additional_send_or_token_before_dispatch(self) -> None:
        # given
        for name, budget in (
            ("send 39", AggregateBudget(responses_sends=38)),
            ("token 5045185", AggregateBudget(accounted_tokens=5_045_184)),
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
