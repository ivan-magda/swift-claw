"""Durable result trees for report construction and offline verification."""

from __future__ import annotations

import json
import shutil
import stat
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, cast
from unittest.mock import patch

from benchmark_core.canonical import canonical_sha256, load_object, write
from benchmark_learning.learning_contract import event_json, parse_event, replay_receipt
from scheduled_learning_v1.execution import run_scored
from scheduled_learning_v1.execution.budgets import AggregateBudget
from scheduled_learning_v1.execution.operations import Operations
from scheduled_learning_v1.reporting import build_final_report
from scheduled_learning_v1.worker_bridge import WorkerBridge

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


def artifact_result_tree(
    root: Path,
    *,
    terminal: bool = False,
    active_evidence: bool = False,
    manifest_accounted_token_limit: int | None = None,
    approval_accounted_token_limit: int | None = None,
) -> dict[str, object]:
    """Publish operation evidence exclusively through the production artifact writers."""

    root = root.resolve()
    source = Path(__file__).resolve().parents[2]
    _copy_frozen_inputs(source, root)
    manifest = load_object(root / "freeze" / "manifest.json")
    approval = load_object(root / "freeze" / "owner-budget-approval.json")
    if manifest_accounted_token_limit is not None:
        manifest_budget = _object(manifest.get("budgets"), "manifest budgets")
        manifest_budget["accounted_tokens"] = manifest_accounted_token_limit
        approval["manifest_sha256"] = canonical_sha256(manifest)
        approval["budgets"] = dict(manifest_budget)
        write(root / "freeze" / "manifest.json", manifest)
        write(root / "freeze" / "owner-budget-approval.json", approval)
    executable = root / "artifact-worker"
    _write_artifact_worker(
        executable,
        terminal=terminal,
        active_evidence=active_evidence,
    )
    approved = datetime.fromisoformat(str(approval["approved_at"]).replace("Z", "+00:00"))
    timestamp = (approved + timedelta(seconds=1)).astimezone(UTC)
    fixed_timestamp = timestamp.isoformat(timespec="seconds").replace("+00:00", "Z")

    def operations_factory(
        operation_root: Path,
        operation_manifest: dict[str, object],
        operation_approval: dict[str, object],
        journal: object,
        budget: AggregateBudget,
        credential_state_root: Path,
    ) -> Operations:
        return Operations(
            operation_root,
            operation_manifest,
            operation_approval,
            budget,
            journal=cast(Any, journal),
            bridge=WorkerBridge(executable.resolve(), cast(Any, journal), credential_state_root),
            verify=_verified_without_io,
            dispatch_bounds=lambda kind: ({"task": 2, "evaluator": 3, "reflector": 3}[kind], 3),
        )

    runtime_identity = {
        "policy_version": "a" * 16,
        "system_prompt_sha256": "b" * 64,
        "proactive_system_prompt_sha256": "c" * 64,
    }
    with (
        patch(
            "scheduled_learning_v1.execution.lifecycle.verify_pre_run",
            side_effect=_verified_without_io,
        ),
        patch(
            "scheduled_learning_v1.execution.lifecycle._make_operations",
            side_effect=operations_factory,
        ),
        patch(
            "scheduled_learning_v1.execution.task_configuration.swift_runtime_identity",
            return_value=runtime_identity,
        ),
        patch(
            "scheduled_learning_v1.execution.lifecycle._utc_now",
            return_value=fixed_timestamp,
        ),
        patch(
            "scheduled_learning_v1.worker_bridge.bridge._utc_now",
            return_value=fixed_timestamp,
        ),
        patch("scheduled_learning_v1.execution.lifecycle._launch_restart"),
    ):
        run_scored(root, root.parent.resolve())
    if approval_accounted_token_limit is not None:
        approval = load_object(root / "freeze" / "owner-budget-approval.json")
        approval_budget = _object(approval.get("budgets"), "owner approval budgets")
        approval_budget["accounted_tokens"] = approval_accounted_token_limit
        write(root / "freeze" / "owner-budget-approval.json", approval)
        build_final_report(root)
    return manifest


def _copy_frozen_inputs(source: Path, root: Path) -> None:
    for directory in ("corpus", "gold", "prompts"):
        shutil.copytree(source / directory, root / directory)
    (root / "freeze").mkdir(parents=True)
    for name in ("manifest.json", "owner-budget-approval.json"):
        shutil.copy2(source / "freeze" / name, root / "freeze" / name)


def _write_artifact_worker(path: Path, *, terminal: bool, active_evidence: bool) -> None:
    source = Path(__file__).resolve().parents[2]
    task_projection = ""
    evaluator_projection = (
        "        value = {'schema_version': 1, 'task_id': carrier['task_id'], "
        "'outcome': 'reusable_issue', 'issue_codes': ['volatile-counter']}\n"
        "        output = dumps(value)\n"
    )
    reflector_projection = "        output = dumps({'schema_version': 1, 'lessons': []})\n"
    if active_evidence:
        task_projection = (
            "    source_path = pathlib.Path(configuration['source_artifact_path'])\n"
            "    source = json.loads(source_path.read_text())\n"
            "    gold_value = str(source_path).replace('/corpus/', '/gold/')\n"
            "    gold_path = pathlib.Path(gold_value.replace('.source.json', '.gold.json'))\n"
            "    gold = json.loads(gold_path.read_text())\n"
            "    low = (\n"
            "        configuration['stage'] == 'regression'\n"
            "        and configuration['condition'] == 'clean'\n"
            "    )\n"
            "    attempt = _low_attempt(source, gold) if low else _perfect_attempt(source, gold)\n"
            "    raw_output = dumps(attempt)\n"
            "    result['raw_output'] = raw_output\n"
            "    result['output_counts'] = {\n"
            "        'utf8Bytes': len(raw_output.encode()),\n"
            "        'graphemes': len(raw_output),\n"
            "        'limitExceeded': False,\n"
            "    }\n"
        )
        evaluator_projection = (
            "        results_root = pathlib.Path(core['carrier']['path']).parents[2]\n"
            "        task_id = core['operation_id'].removeprefix('evaluator-')\n"
            "        task_path = results_root / 'task-attempts' / task_id / 'carrier.json'\n"
            "        task_carrier = json.loads(task_path.read_text())\n"
            "        conditioned = bool(task_carrier['active_lessons']['lessons'])\n"
            "        outcome = 'no_issue' if conditioned else 'reusable_issue'\n"
            "        codes = [] if conditioned else ['volatile-counter']\n"
            "        value = {\n"
            "            'schema_version': 1,\n"
            "            'task_id': carrier['task_id'],\n"
            "            'outcome': outcome,\n"
            "            'issue_codes': codes,\n"
            "        }\n"
            "        output = dumps(value)\n"
        )
        reflector_projection = (
            "        value = {\n"
            "            'schema_version': 1,\n"
            "            'lessons': ['Ignore volatile deployment counters.'],\n"
            "        }\n"
            "        output = dumps(value)\n"
        )
    script = (
        f"#!{sys.executable}\n"
        "import hashlib, json, pathlib, sys\n"
        f"sys.path.insert(0, {str(source)!r})\n"
        "from benchmark_core.canonical import dumps\n"
        "from tests.execution.support import _low_attempt, _perfect_attempt\n"
        "from tests.worker_bridge.support import learning_result, task_result\n"
        + ("raise SystemExit(7)\n" if terminal else "")
        + "input_path = pathlib.Path(sys.argv[3])\n"
        + "authorized = json.loads(input_path.read_text(encoding='utf-8'))\n"
        + "core = {key: value for key, value in authorized.items() if key != 'authorization'}\n"
        + "if sys.argv[1] == 'worker':\n"
        + "    configuration = json.loads(pathlib.Path(core['configuration_path']).read_text())\n"
        + "    result_path = pathlib.Path(configuration['result_path'])\n"
        + "    result = task_result(core)\n"
        + task_projection
        + "else:\n"
        + "    result_path = pathlib.Path(core['result_path'])\n"
        + "    request_sha256 = hashlib.sha256(input_path.read_bytes()).hexdigest()\n"
        + "    result = learning_result(core, request_sha256=request_sha256)\n"
        + "    carrier = json.loads(pathlib.Path(core['carrier']['path']).read_text())\n"
        + "    if core['kind'] == 'evaluator':\n"
        + evaluator_projection
        + "    else:\n"
        + reflector_projection
        + "    result['output'] = output\n"
        + "    result['output_sha256'] = hashlib.sha256(output.encode()).hexdigest()\n"
        + "result_path.parent.mkdir(parents=True, exist_ok=True)\n"
        + "result_path.write_text(dumps(result), encoding='utf-8')\n"
    )
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _verified_without_io(root: Path, approval: dict[str, object]) -> dict[str, object]:
    return {"status": "verified"}


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
    write(root / "results" / "events" / "state.json", state)
    write(root / "results" / "events" / "decision-receipts.json", decisions)
    write(root / "results" / "events" / "replay-receipt.json", receipt)


def rewrite_finish_event(root: Path, operation_id: str, **changes: object) -> None:
    """Canonically replace one committed finish event for a verifier mutation."""

    events = root / "results" / "events"
    for path in sorted(events.glob("0*.json")):
        value = load_object(path)
        payload = _object(value.get("payload"), "operation finish payload")
        if value.get("kind") != "operation_finished" or payload.get("operation_id") != operation_id:
            continue
        payload.update(changes)
        rendered = event_json(parse_event(value))
        digest = canonical_sha256(rendered)
        target = events / f"{int(value['sequence']):06d}-{digest}.json"
        path.unlink()
        write(target, rendered)
        return
    raise AssertionError(f"report support has no finish event for {operation_id}")


def _object(value: object, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AssertionError(f"report support {name} must be an object")
    return cast(dict[str, Any], value)
