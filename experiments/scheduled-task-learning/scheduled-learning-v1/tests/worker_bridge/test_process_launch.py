from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from scheduled_learning_v1.replay_controller import EventJournal
from scheduled_learning_v1.worker_bridge import LearningCall, WorkerBridge

from .support import learning_core, learning_result, write_worker


class ProcessLaunchTests(unittest.TestCase):
    def test_launches_one_exact_learning_command_and_bounds_stdout_diagnostics(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_worker(executable, result_path, learning_result(core))
            bridge = WorkerBridge(executable, EventJournal(root / "evaluation" / "events"))
            call = LearningCall("evaluator", core, root / "request.json", result_path)

            # when
            terminal = bridge.run_learning(call)

            # then
            self.assertEqual(
                json.loads(executable.with_suffix(".argv.json").read_text()),
                ["learning-call", "--request", str(call.request_path)],
            )
            self.assertLessEqual(len(str(terminal["diagnostics"])), 1024)

    def test_nonzero_exit_is_a_closed_terminal_result(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root)
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_worker(executable, result_path, learning_result(core), exit_code=7)
            bridge = WorkerBridge(executable, EventJournal(root / "evaluation" / "events"))
            call = LearningCall("evaluator", core, root / "request.json", result_path)

            # when
            terminal = bridge.run_learning(call)

            # then
            self.assertEqual(terminal["status"], "process_failed")
