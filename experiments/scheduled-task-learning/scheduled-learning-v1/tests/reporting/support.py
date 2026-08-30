"""Durable result trees for report construction and offline verification."""

from __future__ import annotations

from pathlib import Path
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256, load_object, write

from tests.execution.support import run_fake_scored


def result_tree(root: Path, *, complete: bool = True) -> dict[str, object]:
    """Publish one semantically replayed complete or early no-candidate evidence tree."""

    if complete:
        report, _, _ = run_fake_scored(root)
    else:
        report, _, _ = run_fake_scored(root, lessons=[])
    if complete and report["status"] != "complete":
        raise AssertionError("report support failed to build a complete replay tree")
    return load_object(root / "freeze" / "manifest.json")


def result_tree_with_nondefault_thresholds(root: Path) -> dict[str, object]:
    """Publish a complete tree whose report thresholds differ from frozen module defaults."""

    manifest = result_tree(root)
    gates = _object(manifest.get("gates"), "gates")
    gates["adapter_pass_rule"] = {
        "minimum_candidate_score": 91,
        "minimum_mean_delta": 11,
        "require_zero_candidate_critical_failures": True,
    }
    gates["active_and_restart_gates"] = {
        "minimum_active_score": 94,
        "minimum_restart_active_score": 95,
        "require_zero_active_critical_failures": True,
        "require_zero_restart_critical_failures": True,
    }
    write(root / "freeze" / "manifest.json", manifest)
    approval = load_object(root / "freeze" / "owner-budget-approval.json")
    approval["manifest_sha256"] = canonical_sha256(manifest)
    write(root / "freeze" / "owner-budget-approval.json", approval)
    return manifest


def _object(value: object, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AssertionError(f"report support {name} must be an object")
    return cast(dict[str, Any], value)
