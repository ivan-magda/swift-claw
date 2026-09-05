from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import cast

from benchmark_core.canonical import canonical_sha256, dumps, load_object
from scheduled_learning_v1.replay_controller import EventJournal
from scheduled_learning_v1.worker_bridge import LearningCall, TaskAttemptCall, WorkerBridge
from scheduled_learning_v1.worker_bridge.requests import bound_contract

from .support import (
    argv_records,
    learning_core,
    learning_result,
    task_core,
    task_result,
    write_malformed_result_worker,
    write_worker,
)


class ProcessLaunchTests(unittest.TestCase):
    def test_learning_result_is_admitted_from_private_state_then_archived_byte_exactly(
        self,
    ) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            private_state = root / "evaluation" / ".private-learning-state" / "evaluator-1"
            published_result = private_state / "result.json"
            archived_result = root / "evaluation" / "learning-calls" / "evaluator-1" / "result.json"
            private_state.mkdir(parents=True)
            archived_result.parent.mkdir(parents=True)
            core = {
                **learning_core(root),
                "operation_id": "evaluator-1",
                "state_root": str(private_state),
                "result_path": str(published_result),
            }
            executable = root / "claw-eval"
            write_worker(executable, published_result, learning_result(core))
            events = root / "evaluation" / "events"
            bridge = WorkerBridge(executable, EventJournal(events), root.resolve())
            call = LearningCall("evaluator", core, root / "request.json", archived_result)

            # when
            terminal = bridge.run_learning(call)

            # then
            self.assertEqual(terminal["status"], "response")
            self.assertEqual(
                archived_result.read_bytes(), dumps(load_object(archived_result)).encode()
            )
            self.assertFalse(private_state.exists())
            finish = load_object(sorted(events.glob("0*.json"))[-1])
            payload = cast(dict[str, object], finish["payload"])
            self.assertEqual(
                payload["result_digest"], canonical_sha256(load_object(archived_result))
            )

    def test_launches_one_exact_learning_command_and_bounds_stdout_diagnostics(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_worker(executable, result_path, learning_result(core))
            bridge = WorkerBridge(
                executable, EventJournal(root / "evaluation" / "events"), root.resolve()
            )
            call = LearningCall("evaluator", core, root / "request.json", result_path)

            # when
            terminal = bridge.run_learning(call)

            # then
            self.assertEqual(
                argv_records(executable),
                [
                    [
                        "learning-call",
                        "--request",
                        str(call.request_path),
                        "--credential-state-root",
                        str(root.resolve()),
                    ]
                ],
            )
            self.assertLessEqual(len(str(terminal["diagnostics"])), 1024)
            self.assertTrue(result_path.is_file())
            self.assertFalse((root / "terminal.json").exists())
            finish = load_object(sorted((root / "evaluation" / "events").glob("0*.json"))[-1])
            payload = cast(dict[str, object], finish["payload"])
            self.assertEqual(payload["result_digest"], canonical_sha256(load_object(result_path)))

    def test_launches_one_exact_task_command(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_worker(executable, result_path, task_result(core))
            bridge = WorkerBridge(
                executable, EventJournal(root / "evaluation" / "events"), root.resolve()
            )
            call = TaskAttemptCall(core, root / "invocation.json", result_path)

            # when
            terminal = bridge.run_task(call)

            # then
            self.assertEqual(
                argv_records(executable),
                [
                    [
                        "worker",
                        "--invocation",
                        str(call.invocation_path),
                        "--credential-state-root",
                        str(root.resolve()),
                    ]
                ],
            )
            self.assertEqual(terminal["status"], "completed")

    def test_task_evaluator_and_reflector_share_one_runtime_only_credential_root(self) -> None:
        # given
        with (
            TemporaryDirectory() as temporary,
            TemporaryDirectory() as credential_temporary,
        ):
            root = Path(temporary)
            credential_root = Path(credential_temporary).resolve()
            commands: list[list[str]] = []

            # when
            task_root = root / "task"
            task_root.mkdir()
            task_core_value = task_core(task_root)
            task_result_path = task_root / "result.json"
            task_executable = task_root / "claw-eval"
            write_worker(task_executable, task_result_path, task_result(task_core_value))
            task_call = TaskAttemptCall(
                task_core_value,
                task_root / "invocation.json",
                task_result_path,
            )
            WorkerBridge(
                task_executable,
                EventJournal(task_root / "evaluation" / "events"),
                credential_root,
            ).run_task(task_call)
            commands.extend(argv_records(task_executable))

            for kind in ("evaluator", "reflector"):
                learning_root = root / kind
                learning_root.mkdir()
                core = learning_core(learning_root, kind)
                result_path = learning_root / "result.json"
                executable = learning_root / "claw-eval"
                write_worker(executable, result_path, learning_result(core))
                call = LearningCall(kind, core, learning_root / "request.json", result_path)
                WorkerBridge(
                    executable,
                    EventJournal(learning_root / "evaluation" / "events"),
                    credential_root,
                ).run_learning(call)
                commands.extend(argv_records(executable))
                self.assertFalse(Path(str(core["state_root"])).exists())

            # then
            self.assertEqual(
                commands,
                [
                    [
                        "worker",
                        "--invocation",
                        str(task_call.invocation_path),
                        "--credential-state-root",
                        str(credential_root),
                    ],
                    [
                        "learning-call",
                        "--request",
                        str(root / "evaluator" / "request.json"),
                        "--credential-state-root",
                        str(credential_root),
                    ],
                    [
                        "learning-call",
                        "--request",
                        str(root / "reflector" / "request.json"),
                        "--credential-state-root",
                        str(credential_root),
                    ],
                ],
            )
            evidence = "\n".join(
                path.read_text(encoding="utf-8") for path in sorted(root.rglob("*.json"))
            )
            self.assertNotIn(str(credential_root), evidence)

    def test_nonzero_exit_is_a_closed_terminal_result(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_worker(
                executable,
                result_path,
                learning_result(core),
                exit_code=7,
                publish_result=False,
            )
            bridge = WorkerBridge(
                executable, EventJournal(root / "evaluation" / "events"), root.resolve()
            )
            call = LearningCall("evaluator", core, root / "request.json", result_path)

            # when
            terminal = bridge.run_learning(call)

            # then
            self.assertEqual(terminal["status"], "process_failed")

    def test_failed_worker_redacts_credential_root_from_committed_diagnostics(self) -> None:
        # given
        with (
            TemporaryDirectory() as temporary,
            TemporaryDirectory() as credential_temporary,
        ):
            root = Path(temporary)
            credential_root = Path(credential_temporary).resolve()
            core = task_core(root)
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_worker(
                executable,
                result_path,
                task_result(core),
                exit_code=7,
                publish_result=False,
                diagnostic="worker failed",
                diagnostic_stderr=str(credential_root),
            )
            events = root / "evaluation" / "events"
            bridge = WorkerBridge(executable, EventJournal(events), credential_root)
            call = TaskAttemptCall(core, root / "invocation.json", result_path)

            # when
            terminal = bridge.run_task(call)

            # then
            committed = "\n".join(
                path.read_text(encoding="utf-8")
                for path in [root / "terminal.json", *sorted(events.glob("*.json"))]
            )
            self.assertEqual(terminal["status"], "process_failed")
            self.assertIn("[credential-state-root]", committed)
            self.assertNotIn(str(credential_root), committed)

    def test_nonzero_exit_publishes_canonical_terminal_carrier(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_worker(executable, result_path, learning_result(core), exit_code=7)
            events = root / "evaluation" / "events"
            bridge = WorkerBridge(executable, EventJournal(events), root.resolve())
            call = LearningCall("evaluator", core, root / "request.json", result_path)

            # when
            terminal = bridge.run_learning(call)

            # then
            terminal_path = result_path.parent / "terminal.json"
            self.assertEqual(load_object(terminal_path), terminal)
            self.assertEqual(terminal_path.read_bytes(), dumps(terminal).encode("utf-8"))
            finish_path = sorted(events.glob("0*.json"))[-1]
            finish = load_object(finish_path)
            payload = cast(dict[str, object], finish["payload"])
            self.assertEqual(payload["result_digest"], canonical_sha256(terminal))

    def test_nonzero_exit_removes_unaccepted_result_before_terminal_publication(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_worker(executable, result_path, learning_result(core), exit_code=7)
            bridge = WorkerBridge(
                executable, EventJournal(root / "evaluation" / "events"), root.resolve()
            )
            call = LearningCall("evaluator", core, root / "request.json", result_path)

            # when
            bridge.run_learning(call)

            # then
            self.assertFalse(result_path.exists())
            self.assertTrue((root / "terminal.json").is_file())

    def test_zero_exit_without_result_publishes_reconstructable_terminal(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_worker(
                executable,
                result_path,
                learning_result(core),
                publish_result=False,
            )
            events = root / "evaluation" / "events"
            bridge = WorkerBridge(executable, EventJournal(events), root.resolve())
            call = LearningCall("evaluator", core, root / "request.json", result_path)

            # when
            terminal = bridge.run_learning(call)

            # then
            self.assertEqual(terminal["status"], "schema_invalid")
            self.assertEqual(load_object(root / "terminal.json"), terminal)
            finish = load_object(sorted(events.glob("0*.json"))[-1])
            payload = cast(dict[str, object], finish["payload"])
            self.assertEqual(payload["result_digest"], canonical_sha256(terminal))

    def test_zero_exit_removes_canonical_result_that_fails_validation(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            result_path = root / "result.json"
            invalid_result = {**learning_result(core), "operation_id": "other-operation"}
            executable = root / "claw-eval"
            write_worker(executable, result_path, invalid_result)
            events = root / "evaluation" / "events"
            bridge = WorkerBridge(executable, EventJournal(events), root.resolve())
            call = LearningCall("evaluator", core, root / "request.json", result_path)

            # when
            terminal = bridge.run_learning(call)

            # then
            self.assertEqual(terminal["status"], "schema_invalid")
            self.assertFalse(result_path.exists())
            terminal_path = root / "terminal.json"
            self.assertEqual(load_object(terminal_path), terminal)
            self.assertEqual(terminal_path.read_bytes(), dumps(terminal).encode("utf-8"))
            finish = load_object(sorted(events.glob("0*.json"))[-1])
            payload = cast(dict[str, object], finish["payload"])
            self.assertEqual(payload["result_digest"], canonical_sha256(terminal))

    def test_zero_exit_removes_malformed_result_before_terminal_publication(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_malformed_result_worker(executable, result_path)
            events = root / "evaluation" / "events"
            bridge = WorkerBridge(executable, EventJournal(events), root.resolve())
            call = LearningCall("evaluator", core, root / "request.json", result_path)

            # when
            terminal = bridge.run_learning(call)

            # then
            self.assertEqual(terminal["status"], "schema_invalid")
            self.assertFalse(result_path.exists())
            terminal_path = root / "terminal.json"
            self.assertEqual(load_object(terminal_path), terminal)
            self.assertEqual(terminal_path.read_bytes(), dumps(terminal).encode("utf-8"))
            finish = load_object(sorted(events.glob("0*.json"))[-1])
            payload = cast(dict[str, object], finish["payload"])
            self.assertEqual(payload["result_digest"], canonical_sha256(terminal))

    def test_rejects_noncanonical_task_and_learning_cores_before_launch(self) -> None:
        # given
        with (
            TemporaryDirectory() as task_temporary,
            TemporaryDirectory() as learning_temporary,
            TemporaryDirectory() as route_temporary,
        ):
            task_root = Path(task_temporary)
            task_executable = task_root / "claw-eval"
            task_call_core = task_core(task_root)
            write_worker(task_executable, task_root / "result.json", task_result(task_call_core))
            task_call = TaskAttemptCall(
                {**task_call_core, "invented": True},
                task_root / "invocation.json",
                task_root / "result.json",
            )
            task_budget = task_call_core["budget"]
            self.assertIsInstance(task_budget, dict)
            task_budget = cast(dict[str, object], task_budget)
            changed_budget_call = TaskAttemptCall(
                {
                    **task_call_core,
                    "budget": {**task_budget, "global_responses_send_cap": 453},
                },
                task_root / "invocation.json",
                task_root / "result.json",
            )
            learning_root = Path(learning_temporary)
            learning_executable = learning_root / "claw-eval"
            learning_call_core = learning_core(learning_root)
            write_worker(
                learning_executable,
                learning_root / "result.json",
                learning_result(learning_call_core),
            )
            learning_call = LearningCall(
                "evaluator",
                {**learning_call_core, "invented": True},
                learning_root / "request.json",
                learning_root / "result.json",
            )
            route_root = Path(route_temporary)
            route_executable = route_root / "claw-eval"
            route_core = task_core(route_root)
            manifest_binding = cast(dict[str, object], route_core["manifest"])
            manifest_path = Path(str(manifest_binding["manifest_path"]))
            manifest = cast(
                dict[str, object], json.loads(manifest_path.read_text(encoding="utf-8"))
            )
            execution = cast(dict[str, object], manifest["swift_execution"])
            task_route = cast(dict[str, object], execution["task_route"])
            execution["task_route"] = {**task_route, "retry_budget": 3}
            manifest_path.write_text(dumps(manifest), encoding="utf-8")
            manifest_sha256 = canonical_sha256(manifest)
            approval_binding = cast(dict[str, object], manifest_binding["owner_approval"])
            approval_path = Path(str(approval_binding["path"]))
            approval = cast(
                dict[str, object], json.loads(approval_path.read_text(encoding="utf-8"))
            )
            approval["manifest_sha256"] = manifest_sha256
            approval_path.write_text(dumps(approval), encoding="utf-8")
            changed_manifest_binding = {
                **manifest_binding,
                "manifest_sha256": manifest_sha256,
                "owner_approval": {
                    **approval_binding,
                    "sha256": canonical_sha256(approval),
                },
            }
            configuration_path = Path(str(route_core["configuration_path"]))
            configuration = cast(
                dict[str, object], json.loads(configuration_path.read_text(encoding="utf-8"))
            )
            configuration_approval = cast(dict[str, object], configuration["approval"])
            configuration["approval"] = {
                **configuration_approval,
                "manifest_sha256": manifest_sha256,
                "approved_manifest_sha256": manifest_sha256,
            }
            configuration_path.write_text(dumps(configuration), encoding="utf-8")
            changed_route_core = {
                **route_core,
                "configuration_sha256": canonical_sha256(configuration),
                "manifest": changed_manifest_binding,
            }
            write_worker(
                route_executable,
                route_root / "result.json",
                task_result(changed_route_core),
            )
            changed_route_call = TaskAttemptCall(
                changed_route_core,
                route_root / "invocation.json",
                route_root / "result.json",
            )

            # when / then
            with self.assertRaises(ValueError):
                WorkerBridge(
                    task_executable,
                    EventJournal(task_root / "evaluation" / "events"),
                    task_root.resolve(),
                ).run_task(task_call)
            with self.assertRaises(ValueError):
                WorkerBridge(
                    task_executable,
                    EventJournal(task_root / "evaluation" / "events"),
                    task_root.resolve(),
                ).run_task(changed_budget_call)
            with self.assertRaises(ValueError):
                WorkerBridge(
                    learning_executable,
                    EventJournal(learning_root / "evaluation" / "events"),
                    learning_root.resolve(),
                ).run_learning(learning_call)
            with self.assertRaises(ValueError):
                WorkerBridge(
                    route_executable,
                    EventJournal(route_root / "evaluation" / "events"),
                    route_root.resolve(),
                ).run_task(changed_route_call)
            self.assertFalse(task_executable.with_suffix(".argv.jsonl").exists())
            self.assertFalse(learning_executable.with_suffix(".argv.jsonl").exists())
            self.assertFalse(route_executable.with_suffix(".argv.jsonl").exists())

    def test_rejects_each_task_snapshot_cap_mismatch_before_launch(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = task_core(root)
            budget = cast(dict[str, object], core["budget"])

            # when
            admitted = bound_contract(core, "task")

            # then
            admitted_approval = cast(dict[str, object], admitted["approval"])
            self.assertEqual(
                admitted_approval["budgets"],
                {
                    "task_attempts": 10,
                    "evaluator_calls": 5,
                    "reflector_calls": 1,
                    "responses_sends": 38,
                    "accounted_tokens": 5_045_184,
                },
            )
            for field in (
                "stage_accounted_token_threshold",
                "global_accounted_token_threshold",
                "stage_responses_send_cap",
                "global_responses_send_cap",
            ):
                changed_budget = {**budget, field: cast(int, budget[field]) - 1}
                changed_core = {**core, "budget": changed_budget}
                with self.subTest(field=field), self.assertRaises(ValueError):
                    bound_contract(changed_core, "task")
