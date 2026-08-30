"""Durable result trees for report construction and offline verification."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256, load_object, write
from benchmark_learning.learning_contract import parse_event, replay_receipt

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
    adapter = _object(gates.get("adapter_pass_rule"), "adapter pass rule")
    adapter["minimum_valid_pairs"] = 3
    adapter["maximum_valid_pairs"] = 4
    adapter["minimum_candidate_score"] = 92
    adapter["minimum_mean_delta"] = 12
    adapter["allow_critical_result"] = True
    adapter["allow_negative_delta"] = True
    active = _object(gates.get("active_and_restart_gates"), "active and restart gates")
    active["minimum_active_score"] = 94
    active["minimum_restart_active_score"] = 95
    write(root / "freeze" / "manifest.json", manifest)
    approval = load_object(root / "freeze" / "owner-budget-approval.json")
    approval["manifest_sha256"] = canonical_sha256(manifest)
    write(root / "freeze" / "owner-budget-approval.json", approval)
    return manifest


def result_tree_with_rebound_negative_delta(root: Path) -> dict[str, object]:
    """Publish a hash-consistent pass receipt with one policy-disallowed negative delta."""

    manifest = result_tree_with_nondefault_thresholds(root)
    gates = _object(manifest.get("gates"), "gates")
    adapter_gate = _object(gates.get("adapter_pass_rule"), "adapter pass rule")
    adapter_gate["allow_negative_delta"] = False
    write(root / "freeze" / "manifest.json", manifest)
    approval = load_object(root / "freeze" / "owner-budget-approval.json")
    approval["manifest_sha256"] = canonical_sha256(manifest)
    write(root / "freeze" / "owner-budget-approval.json", approval)
    adapter = load_object(root / "results" / "page-adapter-receipt.json")
    pairs = cast(list[dict[str, object]], adapter["pairs"])
    clean_score = _object(pairs[0].get("clean"), "clean pair score")
    clean_score["score"] = 98
    adapter["mean_delta"] = 47 / 3
    publish_rebound_adapter(root, adapter)
    return manifest


def publish_rebound_adapter(root: Path, adapter: dict[str, object]) -> None:
    """Publish a changed full adapter receipt through its promotion/replay bindings."""

    adapter_path = root / "results" / "page-adapter-receipt.json"
    promotion_path = root / "results" / "promotion-receipt.json"
    decisions_path = root / "results" / "decision-receipts.json"
    replay_path = root / "results" / "replay-receipt.json"
    write(adapter_path, adapter)
    promotion = load_object(promotion_path)
    identities = _object(promotion.get("artifact_identities"), "promotion identities")
    envelope = _object(identities.get("adapter_receipt"), "promotion adapter envelope")
    envelope["receipt_digest"] = canonical_sha256(adapter)
    decisions = json.loads(decisions_path.read_text(encoding="utf-8"))
    if not isinstance(decisions, list):
        raise AssertionError("report support decisions must be a list")
    rebound = False
    for index, decision in enumerate(decisions):
        if isinstance(decision, dict) and decision.get("decision") == "promoted":
            decisions[index] = promotion
            rebound = True
            break
    if not rebound:
        raise AssertionError("report support promotion decision is unavailable")
    write(promotion_path, promotion)
    write(decisions_path, decisions)
    replay = load_object(replay_path)
    replay["decision_receipt_sha256s"] = [canonical_sha256(item) for item in decisions]
    write(replay_path, replay)


def publish_hash_consistent_replay(
    root: Path,
    state: dict[str, object],
    decisions: list[dict[str, object]],
) -> None:
    """Publish mutable replay projections whose cross-file hashes remain self-consistent."""

    events = [
        parse_event(load_object(path))
        for path in sorted((root / "results" / "events").glob("*.json"))
        if path.name[:6].isdigit()
    ]
    receipt = replay_receipt(
        algorithm_id="scheduled-learning/v1",
        events=events,
        decisions=decisions,
        final_state=state,
    )
    write(root / "results" / "state.json", state)
    write(root / "results" / "decision-receipts.json", decisions)
    write(root / "results" / "replay-receipt.json", receipt)


def _object(value: object, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AssertionError(f"report support {name} must be an object")
    return cast(dict[str, Any], value)
