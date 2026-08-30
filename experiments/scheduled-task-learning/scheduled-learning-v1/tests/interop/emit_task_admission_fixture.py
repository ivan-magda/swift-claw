"""Reproduce the committed Python-to-Swift task admission fixture."""

from __future__ import annotations

import fcntl
import hashlib
import os
import shutil
import stat
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any, cast
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from benchmark_core.canonical import canonical_sha256, load_object, write
from scheduled_learning_v1.execution.budgets import AggregateBudget
from scheduled_learning_v1.execution.operations import Operations
from scheduled_learning_v1.frozen_contract import AGGREGATE_BUDGETS
from scheduled_learning_v1.replay_controller import EventJournal
from scheduled_learning_v1.worker_bridge import WorkerBridge

from tests.freeze.support import approval_for_commit

_RUNTIME_REPOSITORY = Path(
    "/tmp/swift-claw-scheduled-learning-v1-task-admission-v1"  # noqa: S108 -- flocked fixture
)
_RUNTIME_LOCK = Path(
    "/tmp/swift-claw-scheduled-learning-v1-task-admission-v1.lock"  # noqa: S108 -- lock
)
_EXPERIMENT_PATH = Path("experiments/scheduled-task-learning/scheduled-learning-v1")
_FIXED_TIME = "2026-08-30T00:00:00Z"
_STUB_BYTES = b"#!/bin/sh\nexit 7\n"
# Keep the exact-byte fixture independent of unrelated test-only commits.
_TEST_FREEZE_COMMIT = "f" * 40


def emit_fixture(source_repository: Path, output: Path) -> None:
    """Emit artifacts through Operations and WorkerBridge, then snapshot admission inputs."""

    source_repository = source_repository.resolve(strict=True)
    runtime_repository = _RUNTIME_REPOSITORY
    runtime_root = runtime_repository / _EXPERIMENT_PATH
    output = output.resolve()
    with _locked_runtime():
        shutil.rmtree(runtime_repository, ignore_errors=True)
        shutil.rmtree(output, ignore_errors=True)
        try:
            _copy_inputs(source_repository, runtime_repository)
            manifest = _fixture_manifest(source_repository)
            approval = _fixture_approval(manifest)
            write(runtime_root / "freeze" / "manifest.json", manifest)
            write(runtime_root / "freeze" / "owner-budget-approval.json", approval)
            executable = _write_stub_executable(runtime_root, manifest)
            journal = EventJournal(runtime_root / "results" / "events")
            journal.append(
                "controller_started",
                _FIXED_TIME,
                {"controller_generation": 2},
            )
            operations = Operations(
                runtime_root,
                manifest,
                approval,
                AggregateBudget(),
                journal=journal,
                bridge=WorkerBridge(executable, journal, runtime_root.resolve()),
                verify=_verified_without_io,
                dispatch_bounds=lambda kind: (1, 1),
            )
            rows = cast(list[dict[str, object]], manifest["run_order"])
            with patch(
                "scheduled_learning_v1.worker_bridge.bridge._utc_now",
                return_value=_FIXED_TIME,
            ):
                try:
                    operations.run_task(rows[0], [])
                except ValueError as error:
                    if str(error) != "task terminal HTTP evidence must be an object":
                        raise
            _snapshot(runtime_repository, runtime_root, manifest, output)
        finally:
            shutil.rmtree(runtime_repository, ignore_errors=True)


@contextmanager
def _locked_runtime() -> Iterator[None]:
    descriptor = os.open(_RUNTIME_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _copy_inputs(source_repository: Path, runtime_repository: Path) -> None:
    source_root = source_repository / _EXPERIMENT_PATH
    runtime_root = runtime_repository / _EXPERIMENT_PATH
    system_prompt = Path("Sources/ClawAgent/Context/SystemPrompt.swift")
    target = runtime_repository / system_prompt
    target.parent.mkdir(parents=True)
    shutil.copy2(source_repository / system_prompt, target)
    for directory in ("corpus", "gold", "prompts"):
        shutil.copytree(source_root / directory, runtime_root / directory)
    (runtime_root / "freeze").mkdir(parents=True)


def _fixture_manifest(source_repository: Path) -> dict[str, object]:
    source = source_repository / _EXPERIMENT_PATH / "freeze" / "manifest.json"
    manifest = load_object(source)
    manifest["budgets"] = dict(AGGREGATE_BUDGETS)
    execution = _object(manifest["swift_execution"], "swift execution")
    execution["executable_sha256"] = hashlib.sha256(_STUB_BYTES).hexdigest()
    bindings = _object(manifest["binding_sha256"], "binding digests")
    bindings["budgets"] = canonical_sha256(manifest["budgets"])
    bindings["swift_execution"] = canonical_sha256(execution)
    executable = _executable_relative_path(manifest)
    inputs = _object(manifest["inputs"], "inputs")
    records = cast(list[dict[str, object]], inputs["files"])
    for record in records:
        if record.get("path") == str(executable):
            record["bytes"] = len(_STUB_BYTES)
            record["sha256"] = hashlib.sha256(_STUB_BYTES).hexdigest()
            break
    bindings["inputs"] = canonical_sha256(inputs)
    return manifest


def _fixture_approval(manifest: dict[str, object]) -> dict[str, object]:
    return approval_for_commit(manifest, expected_commit=_TEST_FREEZE_COMMIT)


def _write_stub_executable(root: Path, manifest: dict[str, object]) -> Path:
    path = root.parents[2] / _executable_relative_path(manifest)
    path.parent.mkdir(parents=True)
    path.write_bytes(_STUB_BYTES)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path.resolve(strict=True)


def _snapshot(
    runtime_repository: Path,
    runtime_root: Path,
    manifest: dict[str, object],
    output: Path,
) -> None:
    invocation_path = runtime_root / "results" / "task-attempts" / "task-0" / "invocation.json"
    invocation = load_object(invocation_path)
    authorization = _object(invocation["authorization"], "authorization")
    event = Path(str(authorization["event_path"]))
    relative_files = (
        _EXPERIMENT_PATH / "freeze" / "manifest.json",
        _EXPERIMENT_PATH / "freeze" / "owner-budget-approval.json",
        event.relative_to(runtime_repository),
        _EXPERIMENT_PATH / "results" / "task-attempts" / "task-0" / "carrier.json",
        _EXPERIMENT_PATH / "results" / "task-attempts" / "task-0" / "configuration.json",
        _EXPERIMENT_PATH / "results" / "task-attempts" / "task-0" / "invocation.json",
    )
    for relative in relative_files:
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(runtime_repository / relative, target)
    executable = _executable_relative_path(manifest)
    (output / "executable-path.txt").write_text(f"{executable}\n", encoding="utf-8")
    (output / "claw-eval-stub").write_bytes(_STUB_BYTES)


def _executable_relative_path(manifest: dict[str, object]) -> Path:
    inputs = _object(manifest["inputs"], "inputs")
    groups = _object(inputs["groups"], "input groups")
    members = groups.get("executable")
    if not isinstance(members, list) or len(members) != 1 or not isinstance(members[0], str):
        raise AssertionError("fixture manifest must bind one executable")
    return Path(members[0])


def _object(value: object, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AssertionError(f"fixture {name} must be an object")
    return cast(dict[str, Any], value)


def _verified_without_io(root: Path, approval: dict[str, object]) -> dict[str, object]:
    return {"status": "verified"}


def main() -> None:
    emit_fixture(Path(sys.argv[1]), Path(sys.argv[2]))


if __name__ == "__main__":
    main()
