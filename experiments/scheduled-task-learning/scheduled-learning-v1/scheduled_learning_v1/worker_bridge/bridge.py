"""One-shot subprocess launch and journal binding for Swift workers."""

from __future__ import annotations

import json
import shutil
import subprocess
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import cast

from benchmark_core.canonical import canonical_sha256, dumps, write

from scheduled_learning_v1.evidence_contract import (
    publish_terminal,
    redact_credential_state_root,
)
from scheduled_learning_v1.replay_controller import EventJournal

from .learning_results import validate_learning_result
from .requests import (
    LearningCall,
    TaskAttemptCall,
    bind_authorization,
    bound_contract,
    core_digest,
    write_closed_input,
)
from .task_results import validate_task_result

_DIAGNOSTIC_LIMIT = 1024


class WorkerBridge:
    """Bridge already-materialized calls to one Swift process each."""

    def __init__(
        self, executable: Path, journal: EventJournal, credential_state_root: Path
    ) -> None:
        executable = Path(executable)
        if not executable.is_absolute():
            raise ValueError("claw-eval executable must be absolute")
        credential_state_root = Path(credential_state_root)
        resolved_credential_root = credential_state_root.resolve(strict=True)
        if (
            not credential_state_root.is_absolute()
            or credential_state_root != resolved_credential_root
            or not resolved_credential_root.is_dir()
        ):
            raise ValueError("credential state root must be an existing canonical directory")
        self._executable = executable
        self._credential_state_root = resolved_credential_root
        self.journal = journal

    def run_task(self, call: TaskAttemptCall) -> dict[str, object]:
        """Authorize, launch once, and close one task-worker terminal record."""

        return self._run(
            core=call.invocation_core,
            input_path=call.invocation_path,
            result_path=call.result_path,
            command=("worker", "--invocation"),
            operation_kind="task",
            validate=lambda result: validate_task_result(call, result),
        )

    def run_learning(self, call: LearningCall) -> dict[str, object]:
        """Authorize, launch once, and close one evaluator/reflector terminal record."""

        result_value = call.request_core.get("result_path")
        state_value = call.request_core.get("state_root")
        if not isinstance(result_value, str) or not isinstance(state_value, str):
            raise ValueError("learning state and result paths must be strings")
        published_result_path = Path(result_value)
        private_state_root = Path(state_value)
        if not published_result_path.is_absolute() or not private_state_root.is_absolute():
            raise ValueError("learning state and result paths must be absolute")
        try:
            return self._run(
                core=call.request_core,
                input_path=call.request_path,
                result_path=call.result_path,
                published_result_path=published_result_path,
                command=("learning-call", "--request"),
                operation_kind=call.kind,
                validate=lambda result: validate_learning_result(call, result),
            )
        finally:
            _remove_private_state(private_state_root)

    def _run(
        self,
        *,
        core: dict[str, object],
        input_path: Path,
        result_path: Path,
        published_result_path: Path | None = None,
        command: tuple[str, str],
        operation_kind: str,
        validate: Callable[[dict[str, object]], dict[str, object]],
    ) -> dict[str, object]:
        publication = result_path if published_result_path is None else published_result_path
        if (
            not input_path.is_absolute()
            or not result_path.is_absolute()
            or not publication.is_absolute()
        ):
            raise ValueError("worker input and result paths must be absolute")
        contract = bound_contract(core, operation_kind)
        start = self.journal.append(
            "operation_started",
            _utc_now(),
            _start_payload(core, operation_kind, contract),
        )
        write_closed_input(input_path, bind_authorization(core, start.path, start.sha256))
        completed = subprocess.run(  # noqa: S603 -- executable and sole input path are absolute bindings
            [
                str(self._executable),
                *command,
                str(input_path),
                "--credential-state-root",
                str(self._credential_state_root),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        diagnostics = _bounded_diagnostics(
            completed.stdout,
            completed.stderr,
            self._credential_state_root,
        )
        if completed.returncode != 0:
            terminal = {
                "status": "process_failed",
                "exit_code": completed.returncode,
                "diagnostics": diagnostics,
            }
            publication.unlink(missing_ok=True)
            publish_terminal(result_path, terminal)
            self._finish(core, operation_kind, terminal, canonical_sha256(terminal))
            return terminal
        result: dict[str, object] | None = None
        try:
            result = _load_result(publication)
            terminal = validate(result)
            if publication != result_path:
                if result_path.exists():
                    raise ValueError("durable learning result already exists")
                result_path.parent.mkdir(parents=True, exist_ok=True)
                write(result_path, result)
                if result_path.read_bytes() != publication.read_bytes():
                    raise ValueError("durable learning result differs from accepted bytes")
        except (OSError, ValueError, json.JSONDecodeError) as error:
            publication.unlink(missing_ok=True)
            result_path.unlink(missing_ok=True)
            result = None
            terminal = {
                "status": "schema_invalid",
                "diagnostics": _bounded_diagnostics(
                    diagnostics,
                    str(error),
                    self._credential_state_root,
                ),
            }
        terminal = {**terminal, "diagnostics": diagnostics}
        if result is None:
            publish_terminal(result_path, terminal)
        result_digest = canonical_sha256(result if result is not None else terminal)
        self._finish(core, operation_kind, terminal, result_digest)
        return terminal

    def _finish(
        self,
        core: dict[str, object],
        operation_kind: str,
        terminal: dict[str, object],
        result_digest: str,
    ) -> None:
        usage_digest = (
            None if terminal.get("status") == "failed_no_call" else _usage_digest(terminal)
        )
        self.journal.append(
            "operation_finished",
            _utc_now(),
            {
                "job_id": core.get("job_id"),
                "operation_id": core.get("operation_id"),
                "operation_kind": operation_kind,
                "attempt_generation": core.get("attempt_generation"),
                "status": _event_status(str(terminal.get("status"))),
                "result_digest": result_digest,
                "usage_digest": usage_digest,
            },
        )


def _start_payload(
    core: dict[str, object], operation_kind: str, contract: dict[str, object]
) -> dict[str, object]:
    manifest = _object(core.get("manifest"))
    carrier = _object(core.get("carrier"))
    configuration = _object(contract.get("configuration"))
    route = _object(contract.get("route"))
    return {
        "attempt_generation": core.get("attempt_generation"),
        "carrier_digest": carrier.get("sha256", configuration.get("carrier_sha256")),
        "freeze_commit": contract.get("freeze_commit"),
        "invocation_core_digest": core_digest(core),
        "job_id": core.get("job_id"),
        "manifest_digest": manifest.get("manifest_sha256", core.get("manifest_digest")),
        "operation_id": core.get("operation_id"),
        "operation_kind": operation_kind,
        "provider_call_id": core.get("provider_call_id"),
        "route_digest": canonical_sha256(route),
    }


def _object(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def _load_result(path: Path) -> dict[str, object]:
    raw = path.read_bytes()
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("worker result must be one JSON object")
    result = cast(dict[str, object], value)
    if raw != dumps(result).encode("utf-8"):
        raise ValueError("worker result must be canonical JSON")
    return result


def _remove_private_state(path: Path | None) -> None:
    if path is not None and path.exists():
        shutil.rmtree(path)
        parent = path.parent
        if parent.name == ".private-learning-state" and not any(parent.iterdir()):
            parent.rmdir()


def _usage_digest(terminal: dict[str, object]) -> str:
    usage = terminal.get("usage")
    if usage is None:
        return canonical_sha256({"status": terminal.get("status")})
    return canonical_sha256(usage)


def _event_status(status: str) -> str:
    if status == "failed_no_call":
        return status
    if status in {"response", "completed"}:
        return "succeeded"
    return "failed"


def _bounded_diagnostics(stdout: str, stderr: str, credential_state_root: Path) -> str:
    value = "\n".join(part for part in (stdout, stderr) if part).strip()
    return redact_credential_state_root(value, credential_state_root)[:_DIAGNOSTIC_LIMIT]


def _utc_now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
