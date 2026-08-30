"""Every real bridge and trusted score boundary repeats preflight."""

from __future__ import annotations

import unittest
from pathlib import Path
from typing import cast
from unittest.mock import patch

from benchmark_core.canonical import load_object, write
from scheduled_learning_v1.execution.budgets import AggregateBudget
from scheduled_learning_v1.execution.operations import Operations
from scheduled_learning_v1.execution.task_configuration import swift_runtime_identity
from scheduled_learning_v1.freeze import build_manifest
from scheduled_learning_v1.preflight import verify_pre_run
from scheduled_learning_v1.worker_bridge import TaskAttemptCall
from scheduled_learning_v1.worker_bridge.requests import bound_contract

from page_change_m3 import build_adapter_receipt
from tests.execution.support import RecordingBridge, learning_call
from tests.freeze.support import (
    REAL_REPOSITORY_ROOT,
    FreezeTestRepository,
    approval_for,
    create_repository,
    publish_manifest,
)


class MidRunPreflightTests(unittest.TestCase):
    def test_task_configuration_binds_carrier_and_exact_swift_runtime_identity(self) -> None:
        # given
        repository, manifest, approval = self._authorized_repository()
        bridge = RecordingBridge()
        operations = Operations(
            repository.experiment_root,
            manifest,
            approval,
            AggregateBudget(),
            bridge=bridge,
            verify=verify_pre_run,
        )
        rows = manifest["run_order"]
        self.assertIsInstance(rows, list)
        row = cast(dict[str, object], cast(list[object], rows)[0])

        # when
        operations.run_task(row, [])
        call = bridge.attempt_calls[0]
        self.assertIsInstance(call, TaskAttemptCall)
        call = cast(TaskAttemptCall, call)
        configuration = load_object(Path(str(call.invocation_core["configuration_path"])))
        admitted = bound_contract(call.invocation_core, "task")
        identity = swift_runtime_identity(
            repository.repository_root,
            Path(str(configuration["evaluation_root"])),
        )
        reference = swift_runtime_identity(
            REAL_REPOSITORY_ROOT,
            Path("/private/tmp/swift-claw-evaluation/scheduled-task-learning/page-change"),
        )
        provenance = cast(dict[str, object], configuration["provenance"])

        # then
        self.assertEqual(configuration["carrier_sha256"], configuration["input_sha256"])
        self.assertEqual(admitted["configuration"], configuration)
        self.assertEqual(configuration["expected_policy_version"], identity["policy_version"])
        self.assertEqual(
            provenance["system_prompt_sha256"],
            identity["system_prompt_sha256"],
        )
        self.assertEqual(reference["policy_version"], "8a200c3628c88bf8")

    def test_bound_prompt_mutation_stops_before_bridge_reentry(self) -> None:
        # given
        repository, manifest, approval = self._authorized_repository()
        bridge = RecordingBridge()
        operations = Operations(
            repository.experiment_root,
            manifest,
            approval,
            AggregateBudget(),
            bridge=bridge,
            verify=verify_pre_run,
        )
        operations.dispatch_task(object())
        prompt = repository.experiment_root / "prompts" / "task.md"
        prompt.write_text(prompt.read_text(encoding="utf-8") + "changed\n", encoding="utf-8")

        # when / then
        with self.assertRaises(ValueError):
            operations.dispatch_task(object())
        self.assertEqual(bridge.calls, 1)

    def test_bound_prompt_mutation_stops_before_scorer_entry(self) -> None:
        # given
        repository, manifest, approval = self._authorized_repository()
        bridge = RecordingBridge()
        scores = 0

        def scorer(clean: dict[str, object], candidate: dict[str, object]) -> dict[str, object]:
            nonlocal scores
            scores += 1
            return {"delta": 10}

        operations = Operations(
            repository.experiment_root,
            manifest,
            approval,
            AggregateBudget(),
            bridge=bridge,
            verify=verify_pre_run,
            pair_scorer=scorer,
        )
        operations.dispatch_task(object())
        prompt = repository.experiment_root / "prompts" / "evaluator.md"
        prompt.write_text(prompt.read_text(encoding="utf-8") + "changed\n", encoding="utf-8")

        # when / then
        with self.assertRaises(ValueError):
            operations.score_pair({"attempt": {}}, {"attempt": {}})
        self.assertEqual(bridge.calls, 1)
        self.assertEqual(scores, 0)

    def test_owner_approval_drift_stops_every_next_boundary(self) -> None:
        # given
        repository, manifest, approval = self._authorized_repository()
        bridge = RecordingBridge()
        pair_scores = 0
        active_scores = 0
        adapter_entries = 0

        def pair_scorer(
            clean: dict[str, object], candidate: dict[str, object]
        ) -> dict[str, object]:
            nonlocal pair_scores
            pair_scores += 1
            return {"delta": 10}

        def active_scorer(attempt: dict[str, object], stage: str) -> dict[str, object]:
            nonlocal active_scores
            active_scores += 1
            return {"score": 95}

        def observed_adapter(
            lessons: list[str],
            pairs: list[dict[str, object]],
            identities: dict[str, str],
        ) -> tuple[dict[str, object], dict[str, object]]:
            nonlocal adapter_entries
            adapter_entries += 1
            return build_adapter_receipt(lessons, pairs, identities)

        operations = Operations(
            repository.experiment_root,
            manifest,
            approval,
            AggregateBudget(),
            bridge=bridge,
            verify=verify_pre_run,
            pair_scorer=pair_scorer,
            active_scorer=active_scorer,
        )
        rows = cast(list[dict[str, object]], manifest["run_order"])
        first_task = operations.run_task(rows[0], [])
        changed = dict(approval)
        changed["owner_identity"] = "owner:substituted"
        write(
            repository.experiment_root / "freeze" / "owner-budget-approval.json",
            changed,
        )
        boundaries = (
            ("task bridge", lambda: operations.run_task(rows[1], [])),
            ("learning bridge", lambda: operations.run_evaluator(first_task)),
            (
                "pair scorer",
                lambda: operations.score_pair({"attempt": {}}, {"attempt": {}}),
            ),
            ("adapter", lambda: operations.build_adapter([], [])),
            ("active scorer", lambda: operations.score_active({"attempt": {}}, restart=False)),
        )

        # when / then
        with patch(
            "scheduled_learning_v1.execution.operations.build_adapter_receipt",
            side_effect=observed_adapter,
        ):
            for name, boundary in boundaries:
                with self.subTest(boundary=name), self.assertRaises(ValueError):
                    boundary()
        self.assertEqual(bridge.calls, 1)
        self.assertEqual(pair_scores, 0)
        self.assertEqual(adapter_entries, 0)
        self.assertEqual(active_scores, 0)

    def test_equal_valued_numeric_approval_type_drift_stops_direct_dispatch(self) -> None:
        # given
        for kind in ("task", "learning"):
            with self.subTest(boundary=kind):
                repository, manifest, approval = self._authorized_repository()
                bridge = RecordingBridge()
                operations = Operations(
                    repository.experiment_root,
                    manifest,
                    approval,
                    AggregateBudget(),
                    bridge=bridge,
                    verify=lambda root, current: {"status": "verified"},
                )
                changed = dict(approval)
                changed["schema_version"] = 1.0
                write(
                    repository.experiment_root / "freeze" / "owner-budget-approval.json",
                    changed,
                )

                # when / then
                with self.assertRaises(ValueError):
                    if kind == "task":
                        operations.dispatch_task(object())
                    else:
                        operations.dispatch_learning(
                            learning_call(repository.experiment_root, "evaluator")
                        )
                self.assertEqual(bridge.calls, 0)

    def _authorized_repository(
        self,
    ) -> tuple[FreezeTestRepository, dict[str, object], dict[str, object]]:
        repository = create_repository()
        self.addCleanup(repository.cleanup)
        manifest = build_manifest(repository.experiment_root)
        publish_manifest(repository, manifest)
        approval = approval_for(repository, manifest)
        write(repository.experiment_root / "freeze" / "owner-budget-approval.json", approval)
        return repository, manifest, approval


if __name__ == "__main__":
    unittest.main()
