"""Canonical M3 freeze-manifest construction, verification, and CLI."""

from __future__ import annotations

import argparse
import copy
import subprocess
from collections.abc import Sequence
from pathlib import Path
from typing import cast

from benchmark_core.canonical import SHA256_HEX, canonical_sha256, load_object, write
from page_change_m3.fixtures import FRESH_SPLIT_FIXTURE_IDS
from page_change_m3.identities import calculate_page_identities

from scheduled_learning_v1 import ALGORITHM_ID

from .freeze_inputs import (
    EXPERIMENT_PATH,
    MANIFEST_INPUT_PATH,
    PROTOCOL_PATH,
    discover_groups,
    file_record,
    file_records,
    groups,
    load_canonical_object,
    object_value,
    require_exact_keys,
    verify_inputs,
)
from .frozen_contract import (
    AGGREGATE_BUDGETS,
    EVALUATOR_ROUTE,
    GATES,
    MISSING_USAGE_TOKEN_PROXY,
    REFLECTOR_ROUTE,
    SCHEMA_VERSION,
    TASK_ROUTE,
    json_exactly_matches,
)

_MANIFEST_KIND = "scheduled-learning-v1-freeze"
_PROTOCOL_ID = "issue-172-m3"
_PROTOCOL_VERSION = "1.0"

_FIXTURE_SPLIT: dict[str, object] = {
    "schema_version": SCHEMA_VERSION,
    **{name: list(fixture_ids) for name, fixture_ids in FRESH_SPLIT_FIXTURE_IDS.items()},
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
    discovered = discover_groups(repository_root)
    descriptor: dict[str, object] = {"schema_version": SCHEMA_VERSION, "groups": discovered}
    descriptor_path = repository_root / MANIFEST_INPUT_PATH
    _write_canonical_output(descriptor_path, descriptor)
    return _manifest(repository_root, descriptor)


def verify_manifest(root: Path, manifest: dict[str, object]) -> None:
    """Verify manifest semantics, exact closure membership, and current file bytes."""

    _, repository_root = _roots(root)
    _require_manifest_shape(manifest)
    _verify_binding_digests(manifest)

    descriptor = load_canonical_object(repository_root / MANIFEST_INPUT_PATH)
    require_exact_keys(descriptor, {"schema_version", "groups"}, "manifest input")
    if not json_exactly_matches(descriptor.get("schema_version"), SCHEMA_VERSION):
        raise ValueError("manifest input schema is invalid")
    stored_groups = groups(descriptor.get("groups"), "manifest input groups")
    observed_groups = discover_groups(repository_root)
    for name, observed in observed_groups.items():
        if not json_exactly_matches(stored_groups.get(name), observed):
            raise ValueError(f"{name} closure membership changed")
    if set(stored_groups) != set(observed_groups):
        raise ValueError("manifest input closure set changed")

    verify_inputs(repository_root, manifest, descriptor)
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

    manifest = load_canonical_object(root / "freeze" / "manifest.json")
    verify_manifest(root, manifest)
    approval_path = root / "freeze" / "owner-budget-approval.json"
    if approval_path.is_symlink():
        raise ValueError("owner approval may not be a symlink")
    if approval_path.is_file():
        # The preflight module imports this verifier; defer the reverse edge to CLI execution.
        from scheduled_learning_v1.preflight import verify_pre_run  # noqa: PLC0415

        verify_pre_run(root, load_canonical_object(approval_path))
        owner_status = "verified"
    else:
        owner_status = "absent"
    print(f"manifest_sha256={canonical_sha256(manifest)} owner_approval={owner_status}")


def _manifest(repository_root: Path, descriptor: dict[str, object]) -> dict[str, object]:
    input_groups = groups(descriptor["groups"], "manifest input groups")
    all_groups = {"manifest_input": [str(MANIFEST_INPUT_PATH)], **input_groups}
    paths = sorted({path for members in all_groups.values() for path in members})
    records = [file_record(repository_root, path) for path in paths]
    by_path = {cast(str, item["path"]): item for item in records}

    protocol: dict[str, object] = {
        "protocol_id": _PROTOCOL_ID,
        "version": _PROTOCOL_VERSION,
        "artifact": by_path[str(PROTOCOL_PATH)],
    }
    inputs: dict[str, object] = {"groups": all_groups, "files": records}
    executable_path = input_groups["executable"][0]
    swift_execution: dict[str, object] = {
        "task_route": copy.deepcopy(TASK_ROUTE),
        "evaluator_route": copy.deepcopy(EVALUATOR_ROUTE),
        "reflector_route": copy.deepcopy(REFLECTOR_ROUTE),
        "executable_sha256": by_path[executable_path]["sha256"],
        "missing_usage_token_proxy": MISSING_USAGE_TOKEN_PROXY,
    }
    manifest: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "manifest_kind": _MANIFEST_KIND,
        "algorithm_id": ALGORITHM_ID,
        "protocol": protocol,
        "fixture_split": copy.deepcopy(_FIXTURE_SPLIT),
        "gates": _gates(repository_root),
        "identities": _identities(repository_root),
        "budgets": dict(AGGREGATE_BUDGETS),
        "run_order": [dict(item) for item in _RUN_ORDER],
        "swift_execution": swift_execution,
        "inputs": inputs,
    }
    manifest["binding_sha256"] = {name: canonical_sha256(manifest[name]) for name in _BINDING_NAMES}
    return manifest


def _verify_semantics(repository_root: Path, manifest: dict[str, object]) -> None:
    if not json_exactly_matches(
        manifest.get("schema_version"), SCHEMA_VERSION
    ) or not json_exactly_matches(manifest.get("manifest_kind"), _MANIFEST_KIND):
        raise ValueError("manifest schema or kind is invalid")
    if not json_exactly_matches(manifest.get("algorithm_id"), ALGORITHM_ID):
        raise ValueError("manifest algorithm identity changed")
    if not json_exactly_matches(manifest.get("fixture_split"), _FIXTURE_SPLIT):
        raise ValueError("manifest fixture split changed")
    if not json_exactly_matches(manifest.get("gates"), _gates(repository_root)):
        raise ValueError("manifest gates changed")
    if not json_exactly_matches(manifest.get("budgets"), AGGREGATE_BUDGETS):
        raise ValueError("manifest aggregate budgets changed")
    if not json_exactly_matches(manifest.get("run_order"), list(_RUN_ORDER)):
        raise ValueError("manifest run order changed")
    if not json_exactly_matches(manifest.get("identities"), _identities(repository_root)):
        raise ValueError("manifest adapter identities changed")

    protocol = object_value(manifest.get("protocol"), "manifest protocol")
    inputs = object_value(manifest.get("inputs"), "manifest inputs")
    records = file_records(inputs.get("files"), "manifest input files")
    by_path = {cast(str, record["path"]): record for record in records}
    expected_protocol = {
        "protocol_id": _PROTOCOL_ID,
        "version": _PROTOCOL_VERSION,
        "artifact": by_path[str(PROTOCOL_PATH)],
    }
    if not json_exactly_matches(protocol, expected_protocol):
        raise ValueError("manifest protocol binding changed")

    execution = object_value(manifest.get("swift_execution"), "manifest swift_execution")
    require_exact_keys(
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
    if not json_exactly_matches(execution.get("task_route"), TASK_ROUTE):
        raise ValueError("manifest task route changed")
    if not json_exactly_matches(execution.get("evaluator_route"), EVALUATOR_ROUTE):
        raise ValueError("manifest evaluator route changed")
    if not json_exactly_matches(execution.get("reflector_route"), REFLECTOR_ROUTE):
        raise ValueError("manifest reflector route changed")
    if not json_exactly_matches(
        execution.get("missing_usage_token_proxy"), MISSING_USAGE_TOKEN_PROXY
    ):
        raise ValueError("manifest missing-usage proxy changed")
    input_groups = groups(inputs.get("groups"), "manifest input groups")
    executable_path = input_groups["executable"][0]
    if not json_exactly_matches(
        execution.get("executable_sha256"), by_path[executable_path]["sha256"]
    ):
        raise ValueError("manifest executable identity changed")


def _require_manifest_shape(manifest: dict[str, object]) -> None:
    require_exact_keys(
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
    bindings = object_value(manifest.get("binding_sha256"), "manifest binding_sha256")
    require_exact_keys(bindings, set(_BINDING_NAMES), "manifest binding_sha256")
    for name in _BINDING_NAMES:
        digest = bindings.get(name)
        if not isinstance(digest, str) or SHA256_HEX.fullmatch(digest) is None:
            raise ValueError(f"manifest {name} binding digest is invalid")
        if digest != canonical_sha256(manifest[name]):
            raise ValueError(f"manifest {name} binding digest changed")


def _identities(repository_root: Path) -> dict[str, str]:
    split = load_object(repository_root / EXPERIMENT_PATH / "contracts" / "splits.json")
    if not json_exactly_matches(split, _FIXTURE_SPLIT):
        raise ValueError("split contract differs from the frozen 2/3/2 proposal")
    return calculate_page_identities(repository_root / EXPERIMENT_PATH)


def _gates(repository_root: Path) -> dict[str, object]:
    gates = load_object(repository_root / EXPERIMENT_PATH / "contracts" / "gates.json")
    if not json_exactly_matches(gates, GATES):
        raise ValueError("gate contract differs from the frozen M3 proposal")
    return copy.deepcopy(GATES)


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
    if experiment_root != repository_root / EXPERIMENT_PATH:
        raise ValueError("root is not the scheduled-learning-v1 experiment directory")
    return experiment_root, repository_root


if __name__ == "__main__":
    main()
