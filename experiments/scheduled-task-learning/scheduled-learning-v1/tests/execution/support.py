"""Deterministic fake operations and frozen trees for lifecycle scenarios."""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any, Literal, cast
from unittest.mock import patch

from benchmark_core.canonical import canonical_sha256, dumps, load_object, loads_object, write
from page_change_m3.oracle import sealed_score
from scheduled_learning_v1.execution import run_scored
from scheduled_learning_v1.execution.budgets import AggregateBudget
from scheduled_learning_v1.execution.operations import Operations
from scheduled_learning_v1.frozen_contract import AGGREGATE_BUDGETS, GATES
from scheduled_learning_v1.replay_bootstrap import JOB_ID
from scheduled_learning_v1.worker_bridge import LearningCall

FIXED_TIME = "2026-08-30T00:00:00Z"
_TRIGGER_EVALUATION_COUNT = 2
_ACTIVE_SCORE_THRESHOLD = 90


class RecordingBridge:
    """Record the last external boundary while returning one complete terminal."""

    def __init__(self, terminal: dict[str, object] | None = None) -> None:
        self.attempt_calls: list[object] = []
        self.learning_calls: list[LearningCall] = []
        self.terminal = (
            {
                "status": "completed",
                "accounted_tokens": 0,
                "responses_sends": 0,
                "raw_output": "{}",
            }
            if terminal is None
            else terminal
        )

    @property
    def calls(self) -> int:
        return len(self.attempt_calls) + len(self.learning_calls)

    def run_task(self, call: object) -> dict[str, object]:
        self.attempt_calls.append(call)
        return dict(self.terminal)

    def run_learning(self, call: LearningCall) -> dict[str, object]:
        self.learning_calls.append(call)
        return dict(self.terminal)


def recording_operations(
    root: Path,
    budget: AggregateBudget,
    terminal: dict[str, object] | None = None,
    *,
    missing_usage_token_proxy: int = 1,
) -> tuple[Operations, RecordingBridge]:
    """Construct real operation dispatch around a recording external boundary."""

    (root / "freeze").mkdir(parents=True, exist_ok=True)
    write(root / "freeze" / "owner-budget-approval.json", {})
    bridge = RecordingBridge(terminal)
    manifest = {
        "swift_execution": {"missing_usage_token_proxy": missing_usage_token_proxy},
        "gates": {
            "responses_sends_per_operation": {
                "task": 2,
                "evaluator": 3,
                "reflector": 3,
            }
        },
    }
    operations = Operations(root, manifest, {}, budget, bridge=bridge, verify=_verified_without_io)
    return operations, bridge


def learning_call(root: Path, kind: Literal["evaluator", "reflector"]) -> LearningCall:
    """Construct the minimal call identity consumed by aggregate dispatch."""

    return LearningCall(
        kind=kind,
        request_core={},
        request_path=root / f"{kind}-request.json",
        result_path=root / f"{kind}-result.json",
    )


def _verified_without_io(root: Path, approval: dict[str, object]) -> dict[str, object]:
    return {"status": "verified"}


def frozen_tree(root: Path) -> tuple[dict[str, object], dict[str, object]]:
    (root / "freeze").mkdir(parents=True)
    source_root = Path(__file__).resolve().parents[2]
    for directory in ("corpus", "gold"):
        shutil.copytree(source_root / directory, root / directory)
    manifest: dict[str, object] = {
        "schema_version": 1,
        "algorithm_id": "scheduled-learning/v1",
        "protocol": {"protocol_id": "issue-172-m3", "version": "1.0"},
        "identities": {
            "adapter_id": "page-change-m3",
            "adapter_version": "1",
            "dataset_digest": "1" * 64,
            "oracle_digest": "2" * 64,
            "gates_digest": "3" * 64,
            "execution_surface_digest": "4" * 64,
            "adapter_digest": "5" * 64,
        },
        "gates": dict(GATES),
        "budgets": dict(AGGREGATE_BUDGETS),
        "run_order": _run_order(),
        "swift_execution": {
            "task_route": {"provider_reference": "openai-chatgpt/gpt-5.6-sol"},
        },
    }
    approval: dict[str, object] = {
        "schema_version": 1,
        "manifest_sha256": canonical_sha256(manifest),
        "expected_freeze_commit": "a" * 40,
        "budgets": dict(AGGREGATE_BUDGETS),
        "owner_identity": "owner:test",
        "approved_at": FIXED_TIME,
    }
    write(root / "freeze" / "manifest.json", manifest)
    write(root / "freeze" / "owner-budget-approval.json", approval)
    return manifest, approval


class FakeOperations:
    """High-level fake that preserves the bridge's operation-event ownership."""

    def __init__(
        self,
        root: Path,
        manifest: dict[str, object],
        journal: Any,
        *,
        lessons: list[str] | None = None,
        adapter_outcome: str = "pass",
        active_score: float = 100,
        restart_score: float = 100,
        generation: int = 2,
    ) -> None:
        self.root = root
        self.manifest = manifest
        self.journal = journal
        self.lessons = ["Ignore volatile deployment counters."] if lessons is None else lessons
        self.adapter_outcome = adapter_outcome
        self.active_score = active_score
        self.restart_score = restart_score
        self.generation = generation
        self.task_rows: list[dict[str, object]] = []
        self.task_inputs: list[dict[str, object]] = []
        self.evaluator_tasks: list[dict[str, object]] = []
        self.reflector_evaluations: list[dict[str, object]] = []
        self.reflector_calls = 0
        self.pair_scores = 0
        self.adapter_calls = 0
        self.active_scores = 0
        self._evaluation_index = 0

    def run_task(
        self,
        row: dict[str, object],
        lessons: list[str],
        promotion_receipt: Path | None = None,
    ) -> dict[str, object]:
        self.task_rows.append(dict(row))
        self.task_inputs.append(
            {
                "order_index": row["order_index"],
                "condition": row["condition"],
                "lessons": list(lessons),
                "promotion_receipt": (
                    str(promotion_receipt) if promotion_receipt is not None else None
                ),
            }
        )
        operation_id = f"task-{row['order_index']}"
        order_index = row["order_index"]
        if not isinstance(order_index, int) or isinstance(order_index, bool):
            raise AssertionError("fake row index must be an integer")
        split = "sealed" if row["stage"] in {"active", "restart"} else str(row["stage"])
        fixture_id = str(row["fixture_id"])
        source = load_object(self.root / "corpus" / split / f"{fixture_id}.source.json")
        gold = load_object(self.root / "gold" / split / f"{fixture_id}.gold.json")
        task_id = str(source["task_id"])
        requested_score = (
            self.restart_score
            if row["stage"] == "restart"
            else self.active_score
            if row["stage"] == "active"
            else 100
        )
        raw_attempt = (
            _low_attempt(source, gold)
            if requested_score < _ACTIVE_SCORE_THRESHOLD
            else _perfect_attempt(source, gold)
        )
        raw_output = dumps(raw_attempt)
        result = {"raw_output": raw_output}
        result_path = self.root / "results" / "task-attempts" / operation_id / "result.json"
        result_path.parent.mkdir(parents=True, exist_ok=True)
        write(result_path, result)
        result_digest = canonical_sha256(result)
        self._operation(operation_id, "task", result_digest=result_digest)
        return {
            "status": "completed",
            "operation_id": operation_id,
            "run_id": operation_id,
            "task_id": task_id,
            "fixture_id": fixture_id,
            "condition": row["condition"],
            "task_result_digest": result_digest,
            "raw_output": raw_output,
            "attempt": {
                "source": source,
                "gold": gold,
                "attempt": raw_attempt,
            },
        }

    def run_evaluator(self, task: dict[str, object]) -> dict[str, object]:
        self.evaluator_tasks.append(dict(task))
        operation_id = f"evaluator-{task['run_id']}"
        self._operation(operation_id, "evaluator")
        outcome = (
            "reusable_issue" if self._evaluation_index < _TRIGGER_EVALUATION_COUNT else "no_issue"
        )
        issue_codes = ["volatile-counter"] if outcome == "reusable_issue" else []
        self._evaluation_index += 1
        return {
            "status": "response",
            "operation_id": operation_id,
            "evaluation": {
                "schema_version": 1,
                "task_id": task["task_id"],
                "outcome": outcome,
                "issue_codes": issue_codes,
            },
        }

    def run_reflector(
        self,
        trigger_digest: str,
        evaluations: list[dict[str, object]],
        issue_codes: list[str],
    ) -> dict[str, object]:
        self.reflector_calls += 1
        self.reflector_evaluations = [dict(item) for item in evaluations]
        result_digest = self._operation(trigger_digest, "reflector")
        return {
            "status": "response",
            "operation_id": trigger_digest,
            "result_digest": result_digest,
            "lessons": list(self.lessons),
        }

    def score_pair(
        self, clean: dict[str, object], candidate: dict[str, object]
    ) -> dict[str, object]:
        self.pair_scores += 1
        return {
            "clean": {"score": 70, "critical_codes": []},
            "candidate": {"score": 95, "critical_codes": []},
            "delta": 25,
        }

    def build_adapter(
        self, lessons: list[str], pairs: list[dict[str, object]]
    ) -> tuple[dict[str, object], dict[str, object]]:
        self.adapter_calls += 1
        receipt: dict[str, object] = {
            "schema_version": 1,
            "outcome": self.adapter_outcome,
            "pairs": pairs,
            "pair_count": len(pairs),
            "valid_pair_count": len(pairs),
            "mean_delta": 25,
        }
        envelope: dict[str, object] = {
            "adapter_id": "page-change-m3",
            "adapter_version": "1",
            "candidate_digest": canonical_sha256({"schema_version": 1, "lessons": lessons}),
            "dataset_digest": "1" * 64,
            "oracle_digest": "2" * 64,
            "gates_digest": "3" * 64,
            "execution_surface_digest": "4" * 64,
            "outcome": self.adapter_outcome,
            "receipt_digest": canonical_sha256(receipt),
        }
        return receipt, envelope

    def score_active(self, attempt: dict[str, object], *, restart: bool) -> dict[str, object]:
        self.active_scores += 1
        trusted = attempt["attempt"]
        if not isinstance(trusted, dict):
            raise AssertionError("fake active attempt must be an object")
        source = trusted["source"]
        gold = trusted["gold"]
        raw_attempt = trusted["attempt"]
        identities = self.manifest["identities"]
        if not isinstance(identities, dict):
            raise AssertionError("fake manifest identities must be an object")
        sealed = sealed_score(
            trusted,
            "restart" if restart else "active",
        )
        return {
            **sealed,
            "operation_id": attempt["operation_id"],
            "task_id": attempt["task_id"],
            "task_result_digest": attempt["task_result_digest"],
            "fixture_id": attempt["fixture_id"],
            "condition": attempt["condition"],
            "scoring_condition": "restart" if restart else "active",
            "source_sha256": canonical_sha256(source),
            "gold_sha256": canonical_sha256(gold),
            "attempt_sha256": canonical_sha256(raw_attempt),
            "oracle_digest": identities["oracle_digest"],
        }

    def _operation(
        self,
        operation_id: str,
        kind: str,
        *,
        result_digest: str | None = None,
    ) -> str:
        shared = {
            "job_id": JOB_ID,
            "operation_id": operation_id,
            "operation_kind": kind,
            "attempt_generation": self.generation,
        }
        if result_digest is None:
            result_digest = canonical_sha256({"operation_id": operation_id})
        self.journal.append(
            "operation_started",
            FIXED_TIME,
            {
                **shared,
                "carrier_digest": "1" * 64,
                "route_digest": "2" * 64,
                "provider_call_id": "00000000-0000-0000-0000-000000000001",
                "manifest_digest": "3" * 64,
                "freeze_commit": "a" * 40,
                "invocation_core_digest": "4" * 64,
            },
        )
        self.journal.append(
            "operation_finished",
            FIXED_TIME,
            {
                **shared,
                "status": "succeeded",
                "result_digest": result_digest,
                "usage_digest": "5" * 64,
            },
        )
        return result_digest


def verified_receipt(manifest: dict[str, object]) -> dict[str, object]:
    return {
        "schema_version": 1,
        "status": "verified",
        "manifest_sha256": canonical_sha256(manifest),
        "freeze_commit": "a" * 40,
        "budgets": dict(AGGREGATE_BUDGETS),
        "owner_identity": "owner:test",
        "approved_at": FIXED_TIME,
    }


def run_fake_scored(
    root: Path,
    *,
    restart_boundary: bool = True,
    lessons: list[str] | None = None,
    adapter_outcome: str = "pass",
    active_score: float = 100,
) -> tuple[dict[str, object], FakeOperations, str | None]:
    manifest, _ = frozen_tree(root)
    captured: dict[str, object] = {}

    def factory(*args: object, **kwargs: object) -> FakeOperations:
        operations = FakeOperations(
            root,
            manifest,
            args[3],
            lessons=lessons,
            adapter_outcome=adapter_outcome,
            active_score=active_score,
        )
        captured["operations"] = operations
        return operations

    credential_state_root = root.parent.resolve()

    def restart_runner(path: Path, generation: int, digest: str, credential_root: Path) -> None:
        captured["restart_digest"] = digest
        captured["credential_state_root"] = credential_root
        if restart_boundary:
            write_restart(path, digest, 100)

    with (
        patch(
            "scheduled_learning_v1.execution.lifecycle.verify_pre_run",
            return_value=verified_receipt(manifest),
        ),
        patch("scheduled_learning_v1.execution.lifecycle._make_operations", factory),
        patch("scheduled_learning_v1.execution.lifecycle._utc_now", return_value=FIXED_TIME),
        patch("scheduled_learning_v1.execution.lifecycle._launch_restart", restart_runner),
    ):
        report = run_scored(root, credential_state_root)
    operations = captured["operations"]
    if not isinstance(operations, FakeOperations):
        raise AssertionError("fake lifecycle did not construct operations")
    restart_digest = captured.get("restart_digest")
    return report, operations, restart_digest if isinstance(restart_digest, str) else None


def write_restart(root: Path, digest: str, score: float) -> None:
    manifest = load_object(root / "freeze" / "manifest.json")
    rows = manifest["run_order"]
    identities = manifest["identities"]
    if not isinstance(rows, list) or not isinstance(identities, dict):
        raise AssertionError("fake restart manifest is malformed")
    row = rows[9]
    if not isinstance(row, dict):
        raise AssertionError("fake restart row is malformed")
    fixture_id = str(row["fixture_id"])
    source = load_object(root / "corpus" / "sealed" / f"{fixture_id}.source.json")
    gold = load_object(root / "gold" / "sealed" / f"{fixture_id}.gold.json")
    raw_attempt = _perfect_attempt(source, gold)
    result = {"raw_output": dumps(raw_attempt)}
    result_path = root / "results" / "task-attempts" / "task-9" / "result.json"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    write(result_path, result)
    sealed = sealed_score(
        {"source": source, "gold": gold, "attempt": raw_attempt},
        "restart",
    )
    write(
        root / "results" / "restart-evidence.json",
        {
            "schema_version": 1,
            **sealed,
            "score": score,
            "promoted_digest": digest,
            "operation_id": "task-9",
            "task_id": source["task_id"],
            "task_result_digest": canonical_sha256(result),
            "fixture_id": fixture_id,
            "condition": row["condition"],
            "scoring_condition": "restart",
            "source_sha256": canonical_sha256(source),
            "gold_sha256": canonical_sha256(gold),
            "attempt_sha256": canonical_sha256(raw_attempt),
            "oracle_digest": identities["oracle_digest"],
        },
    )


def _perfect_attempt(
    source: dict[str, object],
    gold: dict[str, object],
) -> dict[str, object]:
    atoms = gold["atoms"]
    if not isinstance(atoms, list):
        raise AssertionError("fake gold atoms must be a list")
    material = [item for item in atoms if isinstance(item, dict) and item.get("kind") == "material"]
    noise = [item for item in atoms if isinstance(item, dict) and item.get("kind") == "noise"]
    output = {
        "schema_version": 1,
        "task_id": source["task_id"],
        "verdict": gold["expected_verdict"],
        "material_region_ids": [item["region_id"] for item in material],
        "ignored_region_ids": [item["region_id"] for item in noise],
        "evidence": [
            {
                "region_id": item["region_id"],
                "before": item["before"],
                "after": item["after"],
            }
            for item in material
        ],
    }
    return {
        "runtime_outcome": "completed",
        "raw_output": dumps(output),
        "tool_events": [{"name": "file_read", "path": "input.json", "status": "succeeded"}],
    }


def _low_attempt(
    source: dict[str, object],
    gold: dict[str, object],
) -> dict[str, object]:
    attempt = _perfect_attempt(source, gold)
    raw_output = attempt["raw_output"]
    if not isinstance(raw_output, str):
        raise AssertionError("fake raw output must be text")
    output = loads_object(raw_output)
    atoms = gold["atoms"]
    if not isinstance(atoms, list) or any(not isinstance(item, dict) for item in atoms):
        raise AssertionError("fake gold atoms must be objects")
    typed_atoms = cast(list[dict[str, object]], atoms)
    output["material_region_ids"] = [item["region_id"] for item in typed_atoms]
    output["ignored_region_ids"] = []
    output["evidence"] = [
        {
            "region_id": item["region_id"],
            "before": item["before"],
            "after": item["after"],
        }
        for item in typed_atoms
    ]
    return {**attempt, "raw_output": dumps(output)}


def _run_order() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    definitions = (
        ("development", "clean", "pc-development-07"),
        ("development", "clean", "pc-development-08"),
        ("regression", "clean_control", "pc-regression-04"),
        ("regression", "candidate_trial", "pc-regression-04"),
        ("regression", "clean_control", "pc-regression-05"),
        ("regression", "candidate_trial", "pc-regression-05"),
        ("regression", "clean_control", "pc-regression-06"),
        ("regression", "candidate_trial", "pc-regression-06"),
        ("active", "active", "pc-sealed-05"),
        ("restart", "post_restart_active", "pc-sealed-06"),
    )
    for order_index, (stage, condition, fixture_id) in enumerate(definitions):
        rows.append(
            {
                "order_index": order_index,
                "stage": stage,
                "condition": condition,
                "fixture_id": fixture_id,
            }
        )
    return rows
