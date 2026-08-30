"""Exact source-closure discovery and file-record verification for M3 freezes."""

from __future__ import annotations

import hashlib
import os
import stat
from collections.abc import Sequence
from pathlib import Path, PurePosixPath
from typing import cast

from benchmark_core.canonical import SHA256_HEX, dumps, loads_object

from .frozen_contract import json_exactly_matches

EXPERIMENT_PATH = Path("experiments/scheduled-task-learning/scheduled-learning-v1")
MANIFEST_INPUT_PATH = EXPERIMENT_PATH / "freeze" / "manifest-input.json"
PROTOCOL_PATH = Path("docs/research/172-validation-protocol.md")

_CANONICAL_CONFORMANCE_PATHS = (
    "experiments/scheduled-task-learning/benchmark-core/benchmark_core/__init__.py",
    "experiments/scheduled-task-learning/benchmark-core/benchmark_core/canonical.py",
    "experiments/scheduled-task-learning/benchmark-core/benchmark_core/conformance.py",
)
_REUSED_SCORER_PATHS = (
    "experiments/scheduled-task-learning/page-change/page_benchmark/canonical.py",
    "experiments/scheduled-task-learning/page-change/page_benchmark/fixtures.py",
    "experiments/scheduled-task-learning/page-change/page_benchmark/manifest_artifacts.py",
    "experiments/scheduled-task-learning/page-change/page_benchmark/records.py",
    "experiments/scheduled-task-learning/page-change/page_benchmark/scorer.py",
    "experiments/scheduled-task-learning/page-change/page_benchmark/validation.py",
)
_CONFORMANCE_PATHS = (
    str(EXPERIMENT_PATH / "conformance" / "coverage.json"),
    str(EXPERIMENT_PATH / "conformance" / "replay-cases.json"),
)
_PROMPT_SCHEMA_PATHS = (
    str(EXPERIMENT_PATH / "prompts" / "evaluator.md"),
    str(EXPERIMENT_PATH / "prompts" / "reflector.md"),
    str(EXPERIMENT_PATH / "prompts" / "task.md"),
    str(EXPERIMENT_PATH / "schemas" / "evaluator-carrier.schema.json"),
    str(EXPERIMENT_PATH / "schemas" / "evaluator-output.schema.json"),
    str(EXPERIMENT_PATH / "schemas" / "final-report.schema.json"),
    str(EXPERIMENT_PATH / "schemas" / "page-adapter-receipt.schema.json"),
    str(EXPERIMENT_PATH / "schemas" / "reflector-carrier.schema.json"),
    str(EXPERIMENT_PATH / "schemas" / "reflector-output.schema.json"),
    str(EXPERIMENT_PATH / "schemas" / "task-carrier.schema.json"),
)
_CONTRACT_PATHS = (
    str(EXPERIMENT_PATH / "contracts" / "adapter-identity.json"),
    str(EXPERIMENT_PATH / "contracts" / "gates.json"),
    str(EXPERIMENT_PATH / "contracts" / "splits.json"),
)
_FIXTURE_PATHS = tuple(
    str(EXPERIMENT_PATH / kind / split / f"{fixture_id}.{suffix}.json")
    for kind, suffix in (("corpus", "source"), ("gold", "gold"))
    for split, fixture_ids in (
        ("development", ("pc-development-07", "pc-development-08")),
        ("regression", ("pc-regression-04", "pc-regression-05", "pc-regression-06")),
        ("sealed", ("pc-sealed-05", "pc-sealed-06")),
    )
    for fixture_id in fixture_ids
)


def discover_groups(repository_root: Path) -> dict[str, list[str]]:
    prompt_schema = _discover_many(
        repository_root,
        (
            (EXPERIMENT_PATH / "prompts", {".md"}),
            (EXPERIMENT_PATH / "schemas", {".json"}),
        ),
    )
    _require_inventory("prompt_schema", prompt_schema, _PROMPT_SCHEMA_PATHS)
    fixtures = _discover_many(
        repository_root,
        (
            (EXPERIMENT_PATH / "contracts", {".json"}),
            (EXPERIMENT_PATH / "corpus", {".json"}),
            (EXPERIMENT_PATH / "gold", {".json"}),
        ),
    )
    _require_inventory("fixture_inputs", fixtures, (*_CONTRACT_PATHS, *_FIXTURE_PATHS))
    conformance = _discover_files(repository_root, EXPERIMENT_PATH / "conformance", {".json"})
    _require_inventory("conformance", conformance, _CONFORMANCE_PATHS)

    learning_root = Path("experiments/scheduled-task-learning/benchmark-core/benchmark_learning")
    learning = [str(learning_root / "__init__.py")]
    learning.extend(_discover_files(repository_root, learning_root / "learning_contract", {".py"}))
    learning.extend(_discover_files(repository_root, learning_root / "learning_replay", {".py"}))
    harness = _discover_many(
        repository_root,
        (
            (EXPERIMENT_PATH / "scheduled_learning_v1", {".py"}),
            (EXPERIMENT_PATH / "page_change_m3", {".py"}),
        ),
    )
    swift = _discover_many(
        repository_root,
        ((Path("Sources/ClawEvaluation"), {".swift"}), (Path("Sources/claw-eval"), {".swift"})),
    )
    result = {
        "protocol": [str(PROTOCOL_PATH)],
        "prompt_schema": prompt_schema,
        "fixture_inputs": fixtures,
        "conformance": conformance,
        "benchmark_core": sorted(_CANONICAL_CONFORMANCE_PATHS),
        "benchmark_learning": sorted(learning),
        "harness_sources": harness,
        "reused_scorer": sorted(_REUSED_SCORER_PATHS),
        "swift_evaluation": swift,
        "swift_package": ["Package.resolved", "Package.swift"],
        "executable": [_executable_path(repository_root)],
    }
    for paths in result.values():
        for path in paths:
            rooted_regular_file(repository_root, path)
    return result


def verify_inputs(
    repository_root: Path,
    manifest: dict[str, object],
    descriptor: dict[str, object],
) -> None:
    inputs = object_value(manifest.get("inputs"), "manifest inputs")
    require_exact_keys(inputs, {"groups", "files"}, "manifest inputs")
    stored_groups = groups(inputs.get("groups"), "manifest input groups")
    descriptor_groups = groups(descriptor.get("groups"), "manifest input descriptor groups")
    expected_groups = {"manifest_input": [str(MANIFEST_INPUT_PATH)], **descriptor_groups}
    if not json_exactly_matches(stored_groups, expected_groups):
        raise ValueError("manifest input group binding changed")

    stored_records = file_records(inputs.get("files"), "manifest input files")
    if stored_records != sorted(stored_records, key=lambda item: cast(str, item["path"])):
        raise ValueError("manifest input files must be sorted")
    if len({item["path"] for item in stored_records}) != len(stored_records):
        raise ValueError("manifest input files contain duplicate paths")

    expected_paths = sorted({path for paths in expected_groups.values() for path in paths})
    if [item["path"] for item in stored_records] != expected_paths:
        raise ValueError("manifest input file membership changed")
    observed = [file_record(repository_root, path) for path in expected_paths]
    for stored, current in zip(stored_records, observed, strict=True):
        if not json_exactly_matches(stored, current):
            raise ValueError(f"input file changed: {stored['path']}")


def file_record(repository_root: Path, relative_path: str) -> dict[str, object]:
    path = rooted_regular_file(repository_root, relative_path)
    data = path.read_bytes()
    return {
        "path": relative_path,
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
    }


def file_records(value: object, location: str) -> list[dict[str, object]]:
    if not isinstance(value, list):
        raise ValueError(f"{location} must be an array")
    return [_record(item, f"{location}[{index}]") for index, item in enumerate(value)]


def groups(value: object, location: str) -> dict[str, list[str]]:
    raw = object_value(value, location)
    result: dict[str, list[str]] = {}
    for name, members in raw.items():
        if not isinstance(name, str) or not name:
            raise ValueError(f"{location} has an invalid name")
        if (
            not isinstance(members, list)
            or any(not isinstance(path, str) or not path for path in members)
            or members != sorted(set(members))
        ):
            raise ValueError(f"{location}.{name} must contain sorted unique paths")
        result[name] = cast(list[str], members)
    return result


def object_value(value: object, location: str) -> dict[str, object]:
    if not isinstance(value, dict) or any(not isinstance(key, str) for key in value):
        raise ValueError(f"{location} must be an object")
    return cast(dict[str, object], value)


def require_exact_keys(value: dict[str, object], expected: set[str], location: str) -> None:
    if set(value) != expected:
        raise ValueError(f"{location} has wrong keys")


def load_canonical_object(path: Path) -> dict[str, object]:
    if path.is_symlink():
        raise ValueError(f"canonical input may not be a symlink: {path}")
    raw = path.read_bytes()
    try:
        value = loads_object(raw.decode("utf-8"))
    except UnicodeDecodeError as error:
        raise ValueError(f"canonical JSON is not UTF-8: {path}") from error
    if raw != dumps(value).encode("utf-8"):
        raise ValueError(f"JSON is not canonical: {path}")
    return cast(dict[str, object], value)


def rooted_regular_file(repository_root: Path, relative_path: str) -> Path:
    pure = PurePosixPath(relative_path)
    if pure.is_absolute() or ".." in pure.parts or pure.as_posix() != relative_path:
        raise ValueError(f"input path is not canonical: {relative_path}")
    current = repository_root
    for part in pure.parts:
        current /= part
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            raise ValueError(f"input file is missing: {relative_path}") from error
        if stat.S_ISLNK(mode):
            raise ValueError(f"input path may not contain a symlink: {relative_path}")
    if not stat.S_ISREG(current.stat().st_mode):
        raise ValueError(f"input path is not a regular file: {relative_path}")
    return current


def _record(value: object, location: str) -> dict[str, object]:
    item = object_value(value, location)
    require_exact_keys(item, {"path", "sha256", "bytes"}, location)
    path = item.get("path")
    digest = item.get("sha256")
    size = item.get("bytes")
    if not isinstance(path, str) or not path or PurePosixPath(path).as_posix() != path:
        raise ValueError(f"{location}.path is invalid")
    if not isinstance(digest, str) or SHA256_HEX.fullmatch(digest) is None:
        raise ValueError(f"{location}.sha256 is invalid")
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        raise ValueError(f"{location}.bytes is invalid")
    return {"path": path, "sha256": digest, "bytes": size}


def _discover_many(
    repository_root: Path,
    specifications: Sequence[tuple[Path, set[str]]],
) -> list[str]:
    return sorted(
        path
        for directory, suffixes in specifications
        for path in _discover_files(repository_root, directory, suffixes)
    )


def _discover_files(repository_root: Path, directory: Path, suffixes: set[str]) -> list[str]:
    root = repository_root / directory
    try:
        mode = root.lstat().st_mode
    except OSError as error:
        raise ValueError(f"cannot inspect source closure {directory}: {error}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
        raise ValueError(f"source closure directory may not be a symlink: {directory}")
    found: list[str] = []
    for current_text, directory_names, file_names in os.walk(root, followlinks=False):
        current = Path(current_text)
        for name in list(directory_names):
            child = current / name
            if name == "__pycache__":
                directory_names.remove(name)
            elif child.is_symlink():
                raise ValueError(f"source closure directory may not be a symlink: {child}")
        for name in file_names:
            child = current / name
            if child.is_symlink():
                raise ValueError(f"source closure input may not be a symlink: {child}")
            if child.suffix in suffixes:
                found.append(child.relative_to(repository_root).as_posix())
    return sorted(found)


def _require_inventory(name: str, observed: list[str], expected: Sequence[str]) -> None:
    expected_list = sorted(expected)
    if observed != expected_list:
        missing = sorted(set(expected_list) - set(observed))
        extra = sorted(set(observed) - set(expected_list))
        raise ValueError(f"{name} closure membership changed; missing={missing}, extra={extra}")


def _executable_path(repository_root: Path) -> str:
    alias = repository_root / ".build" / "release" / "claw-eval"
    try:
        physical = alias.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ValueError("cannot resolve the release claw-eval artifact") from error
    try:
        relative = physical.relative_to(repository_root).as_posix()
    except ValueError as error:
        raise ValueError(
            "the release claw-eval artifact must remain inside the repository"
        ) from error
    candidate = rooted_regular_file(repository_root, relative)
    mode = candidate.stat().st_mode
    if not stat.S_ISREG(mode) or mode & stat.S_IXUSR == 0:
        raise ValueError("the release claw-eval artifact must be an owner-executable regular file")
    return relative
