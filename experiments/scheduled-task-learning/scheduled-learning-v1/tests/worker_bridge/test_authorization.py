from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256
from benchmark_learning.learning_contract import ReplayEvent, ReplayEventKind
from scheduled_learning_v1.replay_controller import CommittedEvent, EventJournal
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
            journal = ReturnedCommittedJournal(root / "evaluation" / "events")
            bridge = WorkerBridge(executable, cast(EventJournal, journal))
            call = LearningCall("evaluator", core, root / "request.json", result_path)

            # when
            bridge.run_learning(call)
            request = json.loads(call.request_path.read_text(encoding="utf-8"))

            # then
            self.assertEqual(request["authorization"]["event_path"], str(journal.returned_path))
            self.assertEqual(request["authorization"]["event_sha256"], "9" * 64)
            self.assertTrue(journal.returned_path.is_file())
            durable_result = json.loads(result_path.read_text(encoding="utf-8"))
            self.assertEqual(
                journal.appended[1][2]["result_digest"],
                canonical_sha256(durable_result),
            )

    def test_reflector_start_uses_trigger_as_operation_id_and_exact_shared_payload(self) -> None:
        # given
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = learning_core(root, "reflector")
            result_path = root / "result.json"
            executable = root / "claw-eval"
            write_worker(executable, result_path, learning_result(core))
            journal = ReturnedCommittedJournal(root / "evaluation" / "events")
            bridge = WorkerBridge(executable, cast(EventJournal, journal))
            call = LearningCall("reflector", core, root / "request.json", result_path)

            # when
            bridge.run_learning(call)

            # then
            kind, _, payload = journal.appended[0]
            self.assertEqual(kind, "operation_started")
            self.assertEqual(payload["operation_id"], core["operation_id"])
            self.assertEqual(
                set(payload),
                {
                    "attempt_generation",
                    "carrier_digest",
                    "freeze_commit",
                    "invocation_core_digest",
                    "job_id",
                    "manifest_digest",
                    "operation_id",
                    "operation_kind",
                    "provider_call_id",
                    "route_digest",
                },
            )


class ReturnedCommittedJournal:
    """Journal spy whose returned authorization cannot be inferred from a naming convention."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True)
        self.returned_path = root / "durable-start.authorization"
        self.appended: list[tuple[str, str, dict[str, Any]]] = []

    def append(self, kind: str, occurred_at: str, payload: dict[str, Any]) -> CommittedEvent:
        self.appended.append((kind, occurred_at, payload))
        event = ReplayEvent(len(self.appended), occurred_at, ReplayEventKind(kind), payload)
        path = self.returned_path if len(self.appended) == 1 else self.root / "durable-finish.event"
        path.write_text(json.dumps({"kind": kind, "payload": payload}), encoding="utf-8")
        return CommittedEvent(event, path, "9" * 64)
