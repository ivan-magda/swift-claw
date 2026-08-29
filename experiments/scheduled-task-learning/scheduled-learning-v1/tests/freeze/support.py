"""Isolated repository mechanics for freeze and preflight scenarios."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from benchmark_core.canonical import canonical_sha256, write

PROJECT_PATH = Path("experiments/scheduled-task-learning/scheduled-learning-v1")
REAL_REPOSITORY_ROOT = Path(__file__).resolve().parents[5]

_COPY_DIRECTORIES = (
    "Sources/ClawEvaluation",
    "Sources/claw-eval",
    "experiments/scheduled-task-learning/benchmark-core/benchmark_core",
    "experiments/scheduled-task-learning/benchmark-core/benchmark_learning",
    "experiments/scheduled-task-learning/page-change/page_benchmark",
    str(PROJECT_PATH / "conformance"),
    str(PROJECT_PATH / "contracts"),
    str(PROJECT_PATH / "corpus"),
    str(PROJECT_PATH / "gold"),
    str(PROJECT_PATH / "page_change_m3"),
    str(PROJECT_PATH / "prompts"),
    str(PROJECT_PATH / "scheduled_learning_v1"),
    str(PROJECT_PATH / "schemas"),
)
_COPY_FILES = (
    "Package.resolved",
    "Package.swift",
    "docs/research/172-validation-protocol.md",
)


@dataclass
class FreezeTestRepository:
    temporary: tempfile.TemporaryDirectory[str]
    repository_root: Path
    experiment_root: Path

    def cleanup(self) -> None:
        self.temporary.cleanup()

    def git(self, *arguments: str) -> str:
        completed = subprocess.run(  # noqa: S603 -- isolated test repository helper
            ["git", "-C", str(self.repository_root), *arguments],  # noqa: S607
            check=True,
            capture_output=True,
            text=True,
        )
        return completed.stdout.strip()

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-m", message)
        return self.git("rev-parse", "HEAD")


def create_repository() -> FreezeTestRepository:
    temporary = tempfile.TemporaryDirectory()
    repository_root = Path(temporary.name) / "repository"
    repository_root.mkdir()
    for relative in _COPY_FILES:
        source = REAL_REPOSITORY_ROOT / relative
        target = repository_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    for relative in _COPY_DIRECTORIES:
        shutil.copytree(
            REAL_REPOSITORY_ROOT / relative,
            repository_root / relative,
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo"),
        )
    executable = repository_root / ".build" / "release" / "claw-eval"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"test-claw-eval\n")
    executable.chmod(executable.stat().st_mode | stat.S_IXUSR)

    repository = FreezeTestRepository(
        temporary=temporary,
        repository_root=repository_root,
        experiment_root=repository_root / PROJECT_PATH,
    )
    repository.git("init", "-q")
    repository.git("config", "user.email", "freeze@example.invalid")
    repository.git("config", "user.name", "Freeze Test")
    repository.commit("test: initialize freeze inputs")
    return repository


def publish_manifest(repository: FreezeTestRepository, manifest: dict[str, object]) -> str:
    manifest_path = repository.experiment_root / "freeze" / "manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    write(manifest_path, manifest)
    return repository.commit("test: freeze inputs")


def approval_for(
    repository: FreezeTestRepository,
    manifest: dict[str, object],
    *,
    expected_commit: str | None = None,
) -> dict[str, object]:
    budgets = manifest["budgets"]
    if not isinstance(budgets, dict):
        raise AssertionError("test manifest budgets must be an object")
    return {
        "schema_version": 1,
        "manifest_sha256": canonical_sha256(manifest),
        "expected_freeze_commit": expected_commit or repository.git("rev-parse", "HEAD"),
        "budgets": dict(budgets),
        "owner_identity": "owner:test",
        "approved_at": "2026-08-30T00:00:00Z",
    }


def rehash_binding(manifest: dict[str, object], name: str) -> None:
    bindings = manifest["binding_sha256"]
    if not isinstance(bindings, dict):
        raise AssertionError("test manifest binding digests must be an object")
    bindings[name] = canonical_sha256(manifest[name])


def run_module(*arguments: str) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return subprocess.run(  # noqa: S603 -- current interpreter executes the tested module
        [sys.executable, "-B", "-m", "scheduled_learning_v1.freeze", *arguments],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )
