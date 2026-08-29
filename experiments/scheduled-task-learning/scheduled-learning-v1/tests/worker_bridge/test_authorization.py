from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from scheduled_learning_v1.replay_controller import EventJournal
from scheduled_learning_v1.worker_bridge import LearningCall, WorkerBridge

from .support import learning_core, learning_result, write_worker


class AuthorizationTests(unittest.TestCase):
    def test_writes_only_the_committed_start_event_path_and_sha_as_authorization(self) -> None:
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
            bridge.run_learning(call)
            request = json.loads(call.request_path.read_text(encoding="utf-8"))
            started = bridge.journal.load()[0]

            # then
            committed_path = sorted(bridge.journal.root.iterdir())[0]
            self.assertEqual(request["authorization"]["event_path"], str(committed_path))
            self.assertEqual(
                request["authorization"]["event_sha256"], committed_path.stem.split("-", 1)[1]
            )
            self.assertEqual(started.kind, "operation_started")
