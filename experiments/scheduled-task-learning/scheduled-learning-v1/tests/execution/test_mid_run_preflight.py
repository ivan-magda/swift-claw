"""Every real bridge and trusted score boundary repeats preflight."""

from __future__ import annotations

import unittest
from pathlib import Path
from typing import cast

from benchmark_core.canonical import load_object, write
from scheduled_learning_v1.execution.budgets import AggregateBudget
from scheduled_learning_v1.execution.operations import Operations
from scheduled_learning_v1.execution.task_configuration import swift_runtime_identity
from scheduled_learning_v1.freeze import build_manifest
from scheduled_learning_v1.preflight import verify_pre_run
from scheduled_learning_v1.worker_bridge import TaskAttemptCall
from scheduled_learning_v1.worker_bridge.requests import bound_contract

from tests.execution.support import RecordingBridge
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
