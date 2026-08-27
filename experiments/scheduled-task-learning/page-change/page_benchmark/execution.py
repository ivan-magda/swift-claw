"""Manifest-bound run-order verification and aggregate record consumption."""

from __future__ import annotations

import importlib
import importlib.util
from pathlib import Path
import sys
from types import ModuleType
from typing import Any

from .canonical import canonical_sha256
from .manifest_artifacts import verified_manifest_artifact


_FREEZE_PACKAGE_ROOT = Path("tools/page_change_freeze")
_FREEZE_INIT_PATH = str(_FREEZE_PACKAGE_ROOT / "__init__.py")
_FREEZE_RUN_ORDER_PATH = str(_FREEZE_PACKAGE_ROOT / "run_order.py")
_FREEZE_SOURCE_ROLE = "freeze_verifier_source"
_REQUIRED_DERIVATION_MODULES = {
    _FREEZE_INIT_PATH,
    str(_FREEZE_PACKAGE_ROOT / "artifacts.py"),
    str(_FREEZE_PACKAGE_ROOT / "contract.py"),
    _FREEZE_RUN_ORDER_PATH,
}


def _freeze_source_records(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    categories = manifest.get("categories")
    configuration = (
        categories.get("configuration") if isinstance(categories, dict) else None
    )
    artifacts = (
        configuration.get("artifacts") if isinstance(configuration, dict) else None
    )
    if not isinstance(artifacts, list):
        raise ValueError("manifest configuration artifacts are absent or malformed")
    records = [
        item
        for item in artifacts
        if isinstance(item, dict) and item.get("role") == _FREEZE_SOURCE_ROLE
    ]
    paths = [item.get("path") for item in records]
    if (
        any(not isinstance(path, str) for path in paths)
        or len(paths) != len(set(paths))
        or not _REQUIRED_DERIVATION_MODULES.issubset(set(paths))
        or any(Path(path).parent != _FREEZE_PACKAGE_ROOT for path in paths)
    ):
        raise ValueError("manifest freeze verifier source closure is incomplete")
    return sorted(records, key=lambda item: item["path"])


def _load_canonical_run_order(
    repository_root: Path,
    manifest: dict[str, Any],
) -> ModuleType:
    """Load only the exact manifest-bound freeze implementation under a unique name."""

    records = _freeze_source_records(manifest)
    for record in records:
        verified_manifest_artifact(
            repository_root,
            manifest,
            "configuration",
            record["path"],
            _FREEZE_SOURCE_ROLE,
        )
    closure_digest = canonical_sha256(
        [
            {"path": item["path"], "sha256": item["sha256"]}
            for item in records
        ]
    )
    package_name = (
        "_swift_claw_page_change_freeze_for_page_benchmark_"
        f"{closure_digest[:16]}"
    )
    module_name = f"{package_name}.run_order"
    cached = sys.modules.get(module_name)
    if isinstance(cached, ModuleType):
        return cached

    package_root = repository_root / _FREEZE_PACKAGE_ROOT
    package_spec = importlib.util.spec_from_file_location(
        package_name,
        package_root / "__init__.py",
        submodule_search_locations=[str(package_root)],
    )
    if package_spec is None or package_spec.loader is None:
        raise ValueError("cannot load the manifest-bound freeze package")
    package = importlib.util.module_from_spec(package_spec)
    sys.modules[package_name] = package
    sys.dont_write_bytecode = True
    try:
        package_spec.loader.exec_module(package)
        module = importlib.import_module(module_name)
    except Exception as error:
        for name in tuple(sys.modules):
            if name == package_name or name.startswith(f"{package_name}."):
                del sys.modules[name]
        raise ValueError("cannot import the manifest-bound run-order module") from error
    return module


def _validate_fixture_projection(
    manifest: dict[str, Any],
    fixture_ids_by_split: dict[str, set[str]],
) -> None:
    """Bind canonical order inputs to the exact manifest-bound benchmark fixtures."""

    categories = manifest.get("categories")
    run_order = categories.get("run_order") if isinstance(categories, dict) else None
    values = run_order.get("values") if isinstance(run_order, dict) else None
    if not isinstance(values, dict):
        raise ValueError("manifest run-order values are absent or malformed")
    blocks = values.get("blocks")
    replicates = values.get("replicate_indices")
    if (
        not isinstance(blocks, list)
        or not isinstance(replicates, list)
        or any(
            not isinstance(item, int) or isinstance(item, bool)
            for item in replicates
        )
    ):
        raise ValueError("manifest run-order fixture projection is malformed")
    expected = [
        {
            "split": split,
            "fixture_id": fixture_id,
            "replicate_index": replicate,
        }
        for split in ("development", "regression", "sealed")
        for fixture_id in sorted(fixture_ids_by_split.get(split, set()))
        for replicate in replicates
    ]
    if blocks != expected:
        raise ValueError("manifest run-order blocks differ from manifest-bound fixtures")


def validate_run_order(
    repository_root: Path,
    manifest: dict[str, Any],
    manifest_sha256: str,
    fixture_ids_by_split: dict[str, set[str]],
    observed: Any,
) -> str:
    """Validate the complete projection using the sole canonical freeze derivation."""

    _validate_fixture_projection(manifest, fixture_ids_by_split)
    canonical = _load_canonical_run_order(repository_root, manifest)
    try:
        expected = canonical.derive(manifest, manifest_sha256)
    except Exception as error:
        raise ValueError("canonical run-order derivation failed") from error
    if observed != expected:
        raise ValueError("run-order artifact differs from approved deterministic derivation")
    return canonical_sha256(expected)


def stage_attempts(run_order: dict[str, Any], stage: str) -> list[dict[str, Any]]:
    """Return attempts for one aggregate stage in their frozen sequence."""

    names = {
        "development": ("development",),
        "regression": ("regression",),
        "sealed": ("sealed-pre-restart", "sealed-post-restart"),
    }
    if stage not in names:
        raise ValueError(f"unknown aggregate stage: {stage}")
    result: list[dict[str, Any]] = []
    for item in run_order["stages"]:
        if item.get("name") in names[stage]:
            result.extend(item["attempts"])
    return result


def validate_record_order(
    records: list[dict[str, Any]],
    run_order: dict[str, Any],
    stage: str,
) -> None:
    """Require aggregate records to be the exact frozen task-attempt sequence."""

    expected = stage_attempts(run_order, stage)
    if len(records) != len(expected):
        raise ValueError(f"{stage} records differ from the frozen attempt count")
    for index, (record, attempt) in enumerate(zip(records, expected)):
        expected_fields = {
            "stage": (
                "sealed-pre-restart"
                if stage == "sealed"
                and attempt["condition"] != "post-restart lesson-conditioned"
                else "sealed-post-restart"
                if stage == "sealed"
                else stage
            ),
            "frozen_order_index": attempt["order_index"],
            "frozen_order_key": attempt["attempt_order_key"],
            "block_index": attempt["block_index"],
            "block_order_key": attempt["block_order_key"],
            "condition": attempt["condition"],
            "fixture_id": attempt["fixture_id"],
            "replicate": attempt["replicate_index"],
        }
        if any(record.get(key) != value for key, value in expected_fields.items()):
            raise ValueError(
                f"{stage} record {index} differs from its frozen order identity"
            )
        carrier = record.get("carrier_receipt")
        if (
            not isinstance(carrier, dict)
            or carrier.get("lesson_source") != attempt["lesson_source"]
        ):
            raise ValueError(
                f"{stage} record {index} differs from its frozen lesson source"
            )
