"""Canonical M3 freeze-manifest construction, verification, and CLI."""

from __future__ import annotations

import argparse
import copy
import hashlib
import os
import re
import stat
import subprocess
from collections.abc import Sequence
from pathlib import Path, PurePosixPath
from typing import cast

from benchmark_core.canonical import canonical_sha256, dumps, load_object, loads_object, write

from scheduled_learning_v1 import ALGORITHM_ID

_EXPERIMENT_PATH = Path("experiments/scheduled-task-learning/scheduled-learning-v1")
_MANIFEST_INPUT_PATH = _EXPERIMENT_PATH / "freeze" / "manifest-input.json"
_PROTOCOL_PATH = Path("docs/research/172-validation-protocol.md")
_MANIFEST_KIND = "scheduled-learning-v1-freeze"
_PROTOCOL_ID = "issue-172-m3"
_PROTOCOL_VERSION = "1.0"
_SHA256 = re.compile(r"^[0-9a-f]{64}$")

_BUDGETS: dict[str, int] = {
    "task_attempts": 10,
    "evaluator_calls": 5,
    "reflector_calls": 1,
    "responses_sends": 38,
    "accounted_tokens": 120_000,
}
_GATES: dict[str, object] = {
    "schema_version": 1,
    "adapter_pass_rule": {
        "minimum_valid_pairs": 2,
        "maximum_valid_pairs": 3,
        "minimum_candidate_score": 90,
        "minimum_mean_delta": 10,
        "allow_critical_result": False,
        "allow_negative_delta": False,
    },
    "active_and_restart_gates": {
        "minimum_active_score": 90,
        "minimum_restart_active_score": 90,
    },
    "aggregate_budgets": dict(_BUDGETS),
    "responses_sends_per_operation": {
        "task": 2,
        "evaluator": 3,
        "reflector": 3,
    },
}
_TASK_ROUTE: dict[str, object] = {
    "provider_reference": "openai-chatgpt/gpt-5.6-sol",
    "wire_model": "gpt-5.6-sol",
    "retry_budget": 1,
    "max_output_tokens": 4_096,
    "max_output_utf8_bytes": 32_768,
    "max_output_graphemes": 16_384,
}
_EVALUATOR_ROUTE: dict[str, object] = {
    "provider_reference": "openai-chatgpt/gpt-5.6-sol",
    "wire_model": "gpt-5.6-sol",
    "retry_budget": 3,
    "max_output_tokens": 512,
    "max_output_utf8_bytes": 4_096,
    "max_output_graphemes": 4_096,
}
_REFLECTOR_ROUTE: dict[str, object] = {**_EVALUATOR_ROUTE, "max_output_tokens": 768}
_MISSING_USAGE_TOKEN_PROXY = 132_768

_FIXTURE_SPLIT: dict[str, object] = {
    "schema_version": 1,
    "development": ["pc-development-07", "pc-development-08"],
    "regression": ["pc-regression-04", "pc-regression-05", "pc-regression-06"],
    "sealed": ["pc-sealed-05", "pc-sealed-06"],
}
_RUN_ORDER: tuple[dict[str, object], ...] = (
    {
        "order_index": 0,
        "stage": "development",
        "condition": "clean",
        "fixture_id": "pc-development-07",
    },
    {
        "order_index": 1,
        "stage": "development",
        "condition": "clean",
        "fixture_id": "pc-development-08",
    },
    {
        "order_index": 2,
        "stage": "regression",
        "condition": "clean_control",
        "fixture_id": "pc-regression-04",
    },
    {
        "order_index": 3,
        "stage": "regression",
        "condition": "candidate_trial",
        "fixture_id": "pc-regression-04",
    },
    {
        "order_index": 4,
        "stage": "regression",
        "condition": "clean_control",
        "fixture_id": "pc-regression-05",
    },
    {
        "order_index": 5,
        "stage": "regression",
        "condition": "candidate_trial",
        "fixture_id": "pc-regression-05",
    },
    {
        "order_index": 6,
        "stage": "regression",
        "condition": "clean_control",
        "fixture_id": "pc-regression-06",
    },
    {
        "order_index": 7,
        "stage": "regression",
        "condition": "candidate_trial",
        "fixture_id": "pc-regression-06",
    },
    {
        "order_index": 8,
        "stage": "active",
        "condition": "active",
        "fixture_id": "pc-sealed-05",
    },
    {
        "order_index": 9,
        "stage": "restart",
        "condition": "post_restart_active",
        "fixture_id": "pc-sealed-06",
    },
)

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
    str(_EXPERIMENT_PATH / "conformance" / "coverage.json"),
    str(_EXPERIMENT_PATH / "conformance" / "replay-cases.json"),
)
_PROMPT_SCHEMA_PATHS = (
    str(_EXPERIMENT_PATH / "prompts" / "evaluator.md"),
    str(_EXPERIMENT_PATH / "prompts" / "reflector.md"),
    str(_EXPERIMENT_PATH / "prompts" / "task.md"),
    str(_EXPERIMENT_PATH / "schemas" / "evaluator-carrier.schema.json"),
    str(_EXPERIMENT_PATH / "schemas" / "evaluator-output.schema.json"),
    str(_EXPERIMENT_PATH / "schemas" / "final-report.schema.json"),
    str(_EXPERIMENT_PATH / "schemas" / "page-adapter-receipt.schema.json"),
    str(_EXPERIMENT_PATH / "schemas" / "reflector-carrier.schema.json"),
    str(_EXPERIMENT_PATH / "schemas" / "reflector-output.schema.json"),
    str(_EXPERIMENT_PATH / "schemas" / "task-carrier.schema.json"),
)
_CONTRACT_PATHS = (
    str(_EXPERIMENT_PATH / "contracts" / "adapter-identity.json"),
    str(_EXPERIMENT_PATH / "contracts" / "gates.json"),
    str(_EXPERIMENT_PATH / "contracts" / "splits.json"),
)
_FIXTURE_PATHS = tuple(
    str(_EXPERIMENT_PATH / kind / split / f"{fixture_id}.{suffix}.json")
    for kind, suffix in (("corpus", "source"), ("gold", "gold"))
    for split, fixture_ids in (
        ("development", ("pc-development-07", "pc-development-08")),
        ("regression", ("pc-regression-04", "pc-regression-05", "pc-regression-06")),
        ("sealed", ("pc-sealed-05", "pc-sealed-06")),
    )
    for fixture_id in fixture_ids
)
_BINDING_NAMES = (
    "algorithm_id",
    "protocol",
    "fixture_split",
    "gates",
    "identities",
    "budgets",
    "run_order",
    "swift_execution",
    "inputs",
)


def build_manifest(root: Path) -> dict[str, object]:
    """Build the canonical manifest and publish its non-self-referential input descriptor."""

    _, repository_root = _roots(root)
    groups = _discover_groups(repository_root)
    descriptor: dict[str, object] = {"schema_version": 1, "groups": groups}
    descriptor_path = repository_root / _MANIFEST_INPUT_PATH
    _write_canonical_output(descriptor_path, descriptor)
    return _manifest(repository_root, descriptor)


def verify_manifest(root: Path, manifest: dict[str, object]) -> None:
    """Verify manifest semantics, exact closure membership, and current file bytes."""

    _, repository_root = _roots(root)
    _require_manifest_shape(manifest)
    _verify_binding_digests(manifest)

    descriptor = _load_canonical_object(repository_root / _MANIFEST_INPUT_PATH)
    _require_exact_keys(descriptor, {"schema_version", "groups"}, "manifest input")
    if descriptor.get("schema_version") != 1:
        raise ValueError("manifest input schema is invalid")
    stored_groups = _groups(descriptor.get("groups"), "manifest input groups")
    observed_groups = _discover_groups(repository_root)
    for name, observed in observed_groups.items():
        if stored_groups.get(name) != observed:
            raise ValueError(f"{name} closure membership changed")
    if set(stored_groups) != set(observed_groups):
        raise ValueError("manifest input closure set changed")

    _verify_inputs(repository_root, manifest, descriptor)
    _verify_semantics(repository_root, manifest)


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description="Build or verify the scheduled-learning v1 freeze."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="build canonical manifest inputs and manifest")
    build.add_argument("root", nargs="?", default=".")
    verify = commands.add_parser("verify", help="verify one experiment root")
    verify.add_argument("root")
    arguments = parser.parse_args(argv)
    root = Path(cast(str, arguments.root))

    if arguments.command == "build":
        manifest = build_manifest(root)
        experiment_root, _ = _roots(root)
        _write_canonical_output(experiment_root / "freeze" / "manifest.json", manifest)
        print(f"manifest_sha256={canonical_sha256(manifest)}")
        return

    manifest = _load_canonical_object(root / "freeze" / "manifest.json")
    verify_manifest(root, manifest)
    approval_path = root / "freeze" / "owner-budget-approval.json"
    if approval_path.is_symlink():
        raise ValueError("owner approval may not be a symlink")
    if approval_path.is_file():
        # The preflight module imports this verifier; defer the reverse edge to CLI execution.
        from scheduled_learning_v1.preflight import verify_pre_run  # noqa: PLC0415

        verify_pre_run(root, _load_canonical_object(approval_path))
        owner_status = "verified"
    else:
        owner_status = "absent"
    print(f"manifest_sha256={canonical_sha256(manifest)} owner_approval={owner_status}")


def _manifest(repository_root: Path, descriptor: dict[str, object]) -> dict[str, object]:
    groups = _groups(descriptor["groups"], "manifest input groups")
    all_groups = {"manifest_input": [str(_MANIFEST_INPUT_PATH)], **groups}
    paths = sorted({path for members in all_groups.values() for path in members})
    records = [_file_record(repository_root, path) for path in paths]
    by_path = {cast(str, item["path"]): item for item in records}

    protocol: dict[str, object] = {
        "protocol_id": _PROTOCOL_ID,
        "version": _PROTOCOL_VERSION,
        "artifact": by_path[str(_PROTOCOL_PATH)],
    }
    inputs: dict[str, object] = {"groups": all_groups, "files": records}
    executable_path = groups["executable"][0]
    swift_execution: dict[str, object] = {
        "task_route": copy.deepcopy(_TASK_ROUTE),
        "evaluator_route": copy.deepcopy(_EVALUATOR_ROUTE),
        "reflector_route": copy.deepcopy(_REFLECTOR_ROUTE),
        "executable_sha256": by_path[executable_path]["sha256"],
        "missing_usage_token_proxy": _MISSING_USAGE_TOKEN_PROXY,
    }
    manifest: dict[str, object] = {
        "schema_version": 1,
        "manifest_kind": _MANIFEST_KIND,
        "algorithm_id": ALGORITHM_ID,
        "protocol": protocol,
        "fixture_split": copy.deepcopy(_FIXTURE_SPLIT),
        "gates": _gates(repository_root),
        "identities": _identities(repository_root),
        "budgets": dict(_BUDGETS),
        "run_order": [dict(item) for item in _RUN_ORDER],
        "swift_execution": swift_execution,
        "inputs": inputs,
    }
    manifest["binding_sha256"] = {name: canonical_sha256(manifest[name]) for name in _BINDING_NAMES}
    return manifest


def _verify_inputs(
    repository_root: Path,
    manifest: dict[str, object],
    descriptor: dict[str, object],
) -> None:
    inputs = _object(manifest.get("inputs"), "manifest inputs")
    _require_exact_keys(inputs, {"groups", "files"}, "manifest inputs")
    stored_groups = _groups(inputs.get("groups"), "manifest input groups")
    descriptor_groups = _groups(descriptor.get("groups"), "manifest input descriptor groups")
    expected_groups = {"manifest_input": [str(_MANIFEST_INPUT_PATH)], **descriptor_groups}
    if stored_groups != expected_groups:
        raise ValueError("manifest input group binding changed")

    raw_files = inputs.get("files")
    if not isinstance(raw_files, list):
        raise ValueError("manifest input files must be an array")
    stored_records = [
        _record(item, f"manifest input files[{index}]") for index, item in enumerate(raw_files)
    ]
    if stored_records != sorted(stored_records, key=lambda item: cast(str, item["path"])):
        raise ValueError("manifest input files must be sorted")
    if len({item["path"] for item in stored_records}) != len(stored_records):
        raise ValueError("manifest input files contain duplicate paths")

    expected_paths = sorted({path for paths in expected_groups.values() for path in paths})
    if [item["path"] for item in stored_records] != expected_paths:
        raise ValueError("manifest input file membership changed")
    observed = [_file_record(repository_root, path) for path in expected_paths]
    for stored, current in zip(stored_records, observed, strict=True):
        if stored != current:
            raise ValueError(f"input file changed: {stored['path']}")


def _verify_semantics(repository_root: Path, manifest: dict[str, object]) -> None:
    if manifest.get("schema_version") != 1 or manifest.get("manifest_kind") != _MANIFEST_KIND:
        raise ValueError("manifest schema or kind is invalid")
    if manifest.get("algorithm_id") != ALGORITHM_ID:
        raise ValueError("manifest algorithm identity changed")
    if manifest.get("fixture_split") != _FIXTURE_SPLIT:
        raise ValueError("manifest fixture split changed")
    if manifest.get("gates") != _gates(repository_root):
        raise ValueError("manifest gates changed")
    if manifest.get("budgets") != _BUDGETS:
        raise ValueError("manifest aggregate budgets changed")
    if manifest.get("run_order") != list(_RUN_ORDER):
        raise ValueError("manifest run order changed")
    if manifest.get("identities") != _identities(repository_root):
        raise ValueError("manifest adapter identities changed")

    protocol = _object(manifest.get("protocol"), "manifest protocol")
    inputs = _object(manifest.get("inputs"), "manifest inputs")
    files = inputs.get("files")
    if not isinstance(files, list):
        raise ValueError("manifest input files must be an array")
    by_path = {
        cast(str, record["path"]): record
        for index, item in enumerate(files)
        for record in [_record(item, f"manifest input files[{index}]")]
    }
    expected_protocol = {
        "protocol_id": _PROTOCOL_ID,
        "version": _PROTOCOL_VERSION,
        "artifact": by_path[str(_PROTOCOL_PATH)],
    }
    if protocol != expected_protocol:
        raise ValueError("manifest protocol binding changed")

    execution = _object(manifest.get("swift_execution"), "manifest swift_execution")
    _require_exact_keys(
        execution,
        {
            "task_route",
            "evaluator_route",
            "reflector_route",
            "executable_sha256",
            "missing_usage_token_proxy",
        },
        "manifest swift_execution",
    )
    if execution.get("task_route") != _TASK_ROUTE:
        raise ValueError("manifest task route changed")
    if execution.get("evaluator_route") != _EVALUATOR_ROUTE:
        raise ValueError("manifest evaluator route changed")
    if execution.get("reflector_route") != _REFLECTOR_ROUTE:
        raise ValueError("manifest reflector route changed")
    if execution.get("missing_usage_token_proxy") != _MISSING_USAGE_TOKEN_PROXY:
        raise ValueError("manifest missing-usage proxy changed")
    groups = _groups(inputs.get("groups"), "manifest input groups")
    executable_path = groups["executable"][0]
    if execution.get("executable_sha256") != by_path[executable_path]["sha256"]:
        raise ValueError("manifest executable identity changed")


def _require_manifest_shape(manifest: dict[str, object]) -> None:
    _require_exact_keys(
        manifest,
        {
            "schema_version",
            "manifest_kind",
            "algorithm_id",
            "protocol",
            "fixture_split",
            "gates",
            "identities",
            "budgets",
            "run_order",
            "swift_execution",
            "inputs",
            "binding_sha256",
        },
        "manifest",
    )


def _verify_binding_digests(manifest: dict[str, object]) -> None:
    bindings = _object(manifest.get("binding_sha256"), "manifest binding_sha256")
    _require_exact_keys(bindings, set(_BINDING_NAMES), "manifest binding_sha256")
    for name in _BINDING_NAMES:
        digest = bindings.get(name)
        if not isinstance(digest, str) or _SHA256.fullmatch(digest) is None:
            raise ValueError(f"manifest {name} binding digest is invalid")
        if digest != canonical_sha256(manifest[name]):
            raise ValueError(f"manifest {name} binding digest changed")


def _identities(repository_root: Path) -> dict[str, object]:
    adapter = load_object(
        repository_root / _EXPERIMENT_PATH / "contracts" / "adapter-identity.json"
    )
    gates = _gates(repository_root)
    split = load_object(repository_root / _EXPERIMENT_PATH / "contracts" / "splits.json")
    if split != _FIXTURE_SPLIT:
        raise ValueError("split contract differs from the frozen 2/3/2 proposal")
    dataset = {
        "splits": {
            "development": tuple(cast(list[str], split["development"])),
            "regression": tuple(cast(list[str], split["regression"])),
            "sealed": tuple(cast(list[str], split["sealed"])),
        },
        "sources": [
            load_object(repository_root / path)
            for path in _FIXTURE_PATHS
            if path.endswith(".source.json")
        ],
        "gold": [
            load_object(repository_root / path)
            for path in _FIXTURE_PATHS
            if path.endswith(".gold.json")
        ],
    }
    scorer_root = _EXPERIMENT_PATH.parent / "page-change" / "page_benchmark"
    oracle = {
        "scorer": canonical_sha256(
            (repository_root / scorer_root / "scorer.py").read_text(encoding="utf-8")
        ),
        "records": canonical_sha256(
            (repository_root / scorer_root / "records.py").read_text(encoding="utf-8")
        ),
    }
    execution_surface = {
        name: canonical_sha256(
            (repository_root / _EXPERIMENT_PATH / "page_change_m3" / f"{name}.py").read_text(
                encoding="utf-8"
            )
        )
        for name in ("adapter", "oracle", "receipt")
    }
    return {
        "adapter_id": adapter.get("adapter_id"),
        "adapter_version": adapter.get("adapter_version"),
        "adapter_digest": canonical_sha256(adapter),
        "dataset_digest": canonical_sha256(dataset),
        "oracle_digest": canonical_sha256(oracle),
        "gates_digest": canonical_sha256(gates),
        "execution_surface_digest": canonical_sha256(execution_surface),
    }


def _gates(repository_root: Path) -> dict[str, object]:
    gates = load_object(repository_root / _EXPERIMENT_PATH / "contracts" / "gates.json")
    if gates != _GATES:
        raise ValueError("gate contract differs from the frozen M3 proposal")
    return copy.deepcopy(_GATES)


def _discover_groups(repository_root: Path) -> dict[str, list[str]]:
    prompt_schema = _discover_many(
        repository_root,
        (
            (_EXPERIMENT_PATH / "prompts", {".md"}),
            (_EXPERIMENT_PATH / "schemas", {".json"}),
        ),
    )
    _require_inventory("prompt_schema", prompt_schema, _PROMPT_SCHEMA_PATHS)
    fixtures = _discover_many(
        repository_root,
        (
            (_EXPERIMENT_PATH / "contracts", {".json"}),
            (_EXPERIMENT_PATH / "corpus", {".json"}),
            (_EXPERIMENT_PATH / "gold", {".json"}),
        ),
    )
    _require_inventory("fixture_inputs", fixtures, (*_CONTRACT_PATHS, *_FIXTURE_PATHS))
    conformance = _discover_files(repository_root, _EXPERIMENT_PATH / "conformance", {".json"})
    _require_inventory("conformance", conformance, _CONFORMANCE_PATHS)

    learning_root = Path("experiments/scheduled-task-learning/benchmark-core/benchmark_learning")
    learning = [str(learning_root / "__init__.py")]
    learning.extend(_discover_files(repository_root, learning_root / "learning_contract", {".py"}))
    learning.extend(_discover_files(repository_root, learning_root / "learning_replay", {".py"}))
    harness = _discover_many(
        repository_root,
        (
            (_EXPERIMENT_PATH / "scheduled_learning_v1", {".py"}),
            (_EXPERIMENT_PATH / "page_change_m3", {".py"}),
        ),
    )
    swift = _discover_many(
        repository_root,
        ((Path("Sources/ClawEvaluation"), {".swift"}), (Path("Sources/claw-eval"), {".swift"})),
    )
    executable = _executable_path(repository_root)
    groups = {
        "protocol": [str(_PROTOCOL_PATH)],
        "prompt_schema": prompt_schema,
        "fixture_inputs": fixtures,
        "conformance": conformance,
        "benchmark_core": sorted(_CANONICAL_CONFORMANCE_PATHS),
        "benchmark_learning": sorted(learning),
        "harness_sources": harness,
        "reused_scorer": sorted(_REUSED_SCORER_PATHS),
        "swift_evaluation": swift,
        "swift_package": ["Package.resolved", "Package.swift"],
        "executable": [executable],
    }
    for paths in groups.values():
        for path in paths:
            _rooted_regular_file(repository_root, path)
    return groups


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
    relative = ".build/release/claw-eval"
    candidate = _rooted_regular_file(repository_root, relative)
    mode = candidate.stat().st_mode
    if not stat.S_ISREG(mode) or mode & stat.S_IXUSR == 0:
        raise ValueError("the release claw-eval artifact must be an owner-executable regular file")
    return relative


def _file_record(repository_root: Path, relative_path: str) -> dict[str, object]:
    path = _rooted_regular_file(repository_root, relative_path)
    data = path.read_bytes()
    return {
        "path": relative_path,
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
    }


def _rooted_regular_file(repository_root: Path, relative_path: str) -> Path:
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
    item = _object(value, location)
    _require_exact_keys(item, {"path", "sha256", "bytes"}, location)
    path = item.get("path")
    digest = item.get("sha256")
    size = item.get("bytes")
    if not isinstance(path, str) or not path or PurePosixPath(path).as_posix() != path:
        raise ValueError(f"{location}.path is invalid")
    if not isinstance(digest, str) or _SHA256.fullmatch(digest) is None:
        raise ValueError(f"{location}.sha256 is invalid")
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        raise ValueError(f"{location}.bytes is invalid")
    return {"path": path, "sha256": digest, "bytes": size}


def _groups(value: object, location: str) -> dict[str, list[str]]:
    raw = _object(value, location)
    groups: dict[str, list[str]] = {}
    for name, members in raw.items():
        if not isinstance(name, str) or not name:
            raise ValueError(f"{location} has an invalid name")
        if (
            not isinstance(members, list)
            or any(not isinstance(path, str) or not path for path in members)
            or members != sorted(set(members))
        ):
            raise ValueError(f"{location}.{name} must contain sorted unique paths")
        groups[name] = cast(list[str], members)
    return groups


def _object(value: object, location: str) -> dict[str, object]:
    if not isinstance(value, dict) or any(not isinstance(key, str) for key in value):
        raise ValueError(f"{location} must be an object")
    return cast(dict[str, object], value)


def _require_exact_keys(value: dict[str, object], expected: set[str], location: str) -> None:
    if set(value) != expected:
        raise ValueError(f"{location} has wrong keys")


def _load_canonical_object(path: Path) -> dict[str, object]:
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


def _write_canonical_output(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink() or path.is_symlink():
        raise ValueError(f"freeze output may not be a symlink: {path}")
    write(path, value)


def _roots(root: Path) -> tuple[Path, Path]:
    experiment_root = Path(root).resolve(strict=True)
    completed = subprocess.run(  # noqa: S603 -- fixed Git operation with an absolute root
        ["git", "-C", str(experiment_root), "rev-parse", "--show-toplevel"],  # noqa: S607
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise ValueError("experiment root must be inside a Git repository")
    repository_root = Path(completed.stdout.strip()).resolve(strict=True)
    if experiment_root != repository_root / _EXPERIMENT_PATH:
        raise ValueError("root is not the scheduled-learning-v1 experiment directory")
    return experiment_root, repository_root


if __name__ == "__main__":
    main()
