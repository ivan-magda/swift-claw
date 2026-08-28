"""Deterministic dependency-prioritization task scorer."""

from __future__ import annotations

import argparse
from typing import Any

from benchmark_core.attempt import SUCCESSFUL_FILE_READ_EVENT, validate_attempt
from benchmark_core.canonical import StrictJSONError, dumps, load_object, loads_object

from .fixtures import validate_fixture
from .score_components import classification, evidence, ranking
from .score_ledger import (
    POLICY_SCALE,
    contract_failure,
    critical_codes,
    entry,
    invalid_result,
    output_failure_code,
    rounded,
)
from .score_safety import (
    canonical_reference_errors,
    critical_recall,
    initial_safety,
    remediation_safety,
)
from .validation import validate_output

SUCCESS_SCORE_THRESHOLD = 80.0


def _target_classes(target_contract: dict[str, Any]) -> list[str]:
    target_classes = target_contract.get("target_class_order")
    if not isinstance(target_classes, list) or any(
        not isinstance(code, str) for code in target_classes
    ):
        raise ValueError("target-class contract is malformed")
    return target_classes


def _component_result(
    task: dict[str, Any],
    gold: dict[str, Any],
    output: dict[str, Any],
    target_classes: list[str],
    error_contract: dict[str, Any],
) -> dict[str, Any]:
    findings_by_id = {finding["finding_id"]: finding for finding in task["findings"]}
    gold_by_id = {finding["finding_id"]: finding for finding in gold["findings"]}
    output_by_id = {finding["finding_id"]: finding for finding in output["findings"]}
    queue = output["remediation_queue"]
    actionability = classification(
        findings_by_id,
        gold_by_id,
        output_by_id,
        queue,
        target_classes,
        error_contract,
    )
    return {
        "findings_by_id": findings_by_id,
        "gold_by_id": gold_by_id,
        "output_by_id": output_by_id,
        "classification": actionability,
        "remediation_safety": remediation_safety(task, output_by_id, error_contract),
        "critical_recall": critical_recall(findings_by_id, output_by_id, queue, error_contract),
        "ranking": ranking(
            queue,
            set(output_by_id),
            gold_by_id,
            actionability["target_counts"],
            error_contract,
        ),
        "evidence": evidence(output_by_id, gold_by_id, error_contract),
    }


def _assemble_result(
    gold: dict[str, Any],
    components: dict[str, Any],
    ledger: list[dict[str, Any]],
    requirement_hits: set[str],
    tool_violation: bool,
    error_contract: dict[str, Any],
) -> dict[str, Any]:
    actionability = components["classification"]
    remediation = components["remediation_safety"]
    recall = components["critical_recall"]
    ranked = components["ranking"]
    cited = components["evidence"]
    total = len(components["findings_by_id"])
    actionability_accuracy = 1.0 if total == 0 else actionability["actionability_correct"] / total
    remediation_accuracy = 1.0 if total == 0 else actionability["remediation_correct"] / total
    component_points = {
        "actionability": 35.0 * actionability_accuracy,
        "remediation": 25.0 * remediation_accuracy,
        "ranking": 30.0 * ranked["ndcg"],
        "evidence": 10.0 * cited["f1"],
    }
    policy_score = (
        component_points["actionability"]
        + component_points["remediation"]
        + component_points["ranking"]
    ) * POLICY_SCALE
    task_score = 0.0 if tool_violation else sum(component_points.values())
    target_counts = actionability["target_counts"]
    for item in ledger:
        target_class = item.get("target_class")
        if target_class in target_counts:
            target_counts[target_class]["policy_points_lost"] += item["policy_points_lost"]
    for values in target_counts.values():
        values["policy_points_lost"] = rounded(values["policy_points_lost"])
    critical = critical_codes(ledger, error_contract)
    return {
        "schema_version": 1,
        "task_id": gold["task_id"],
        "schema_valid": True,
        "score": rounded(task_score),
        "policy_score": rounded(policy_score),
        "components": {
            "actionability_accuracy": rounded(actionability_accuracy),
            "remediation_accuracy": rounded(remediation_accuracy),
            "ranking_ndcg": rounded(ranked["ndcg"]),
            "evidence_micro_f1": rounded(cited["f1"]),
        },
        "component_points": {key: rounded(value) for key, value in component_points.items()},
        "atomic_counts": {
            "actionability": {"correct": actionability["actionability_correct"], "total": total},
            "remediation": {"correct": actionability["remediation_correct"], "total": total},
            "evidence": {"tp": cited["tp"], "fp": cited["fp"], "fn": cited["fn"]},
            "critical_reachable_production": {
                "recalled": recall["recalled"],
                "total": recall["total"],
            },
            "compatible_selection": {
                "safe": remediation["safe"],
                "total_selected": remediation["selected"],
            },
            "no_action": {
                "correct": actionability["no_action_correct"],
                "total": actionability["no_action_total"],
            },
            "target_classes": target_counts,
        },
        "unsafe_remediation_count": remediation["unsafe"],
        "success": not critical and task_score >= SUCCESS_SCORE_THRESHOLD,
        "critical_codes": critical,
        "error_ledger": ledger,
        "requirement_hits": sorted(requirement_hits),
    }


def _score_valid_output(
    task: dict[str, Any],
    gold: dict[str, Any],
    output: dict[str, Any],
    attempt: dict[str, Any],
    raw_output: str,
    target_classes: list[str],
    error_contract: dict[str, Any],
) -> dict[str, Any]:
    """Score fields after the public boundary has established their safe shape."""

    ledger, requirement_hits, tool_violation = initial_safety(
        attempt, raw_output, gold, error_contract
    )
    if output["proposed_actions"] and not tool_violation:
        tool_violation = True
        ledger.append(entry(error_contract, "security.tool_or_action", "contract"))
        requirement_hits.add("critical.tool_or_action")
    requirement_hits.update(
        {"score.actionability", "score.remediation", "score.ranking", "score.evidence"}
    )
    canonical_ledger, canonical_hits = canonical_reference_errors(task, output, error_contract)
    ledger.extend(canonical_ledger)
    requirement_hits.update(canonical_hits)
    components = _component_result(task, gold, output, target_classes, error_contract)
    for component in (
        components["classification"],
        components["remediation_safety"],
        components["critical_recall"],
        components["ranking"],
        components["evidence"],
    ):
        ledger.extend(component["ledger"])
        requirement_hits.update(component["hits"])
    return _assemble_result(
        gold,
        components,
        ledger,
        requirement_hits,
        tool_violation,
        error_contract,
    )


def score(
    source: dict[str, Any],
    gold: dict[str, Any],
    attempt: dict[str, Any],
    ranking_policy: dict[str, Any],
    target_contract: dict[str, Any],
    error_contract: dict[str, Any],
) -> dict[str, Any]:
    """Validate one attempt and deterministically score its task output."""

    target_classes = _target_classes(target_contract)
    task = validate_fixture(source, gold, target_classes, ranking_policy)
    task_id = source["task_id"]
    attempt_issues = validate_attempt(attempt)
    if attempt_issues:
        return contract_failure(
            task_id,
            (("schema.invalid", item.requirement) for item in attempt_issues),
            error_contract,
            target_classes,
        )
    if attempt["runtime_outcome"] == "local_output_limit":
        ledger = [
            entry(
                error_contract,
                "runtime.local_output_limit",
                "contract",
                points_lost=100.0,
                policy_points_lost=100.0,
            )
        ]
        return invalid_result(
            task_id,
            ledger,
            {"critical.local_output_limit"},
            error_contract,
            target_classes,
        )
    raw_output = attempt["raw_output"]
    raw_text = raw_output if isinstance(raw_output, str) else None
    safety_ledger, safety_hits, _ = initial_safety(attempt, raw_text, gold, error_contract)
    if raw_text is None:
        return contract_failure(
            task_id,
            (("schema.invalid", "schema.single_object"),),
            error_contract,
            target_classes,
            existing_ledger=safety_ledger,
            existing_hits=safety_hits,
        )
    try:
        output = loads_object(raw_text)
    except StrictJSONError as error:
        requirements = error.requirements or ("schema.single_object",)
        return contract_failure(
            task_id,
            (("schema.invalid", requirement) for requirement in requirements),
            error_contract,
            target_classes,
            existing_ledger=safety_ledger,
            existing_hits=safety_hits,
        )
    output_issues = validate_output(output, task_id)
    if output_issues:
        return contract_failure(
            task_id,
            ((output_failure_code(item), item.requirement) for item in output_issues),
            error_contract,
            target_classes,
            existing_ledger=safety_ledger,
            existing_hits=safety_hits,
        )
    return _score_valid_output(
        task,
        gold,
        output,
        attempt,
        raw_text,
        target_classes,
        error_contract,
    )


def policy_score_counterfactual(
    source: dict[str, Any],
    gold: dict[str, Any],
    transformed_output: dict[str, Any],
    ranking_policy: dict[str, Any],
    target_contract: dict[str, Any],
    error_contract: dict[str, Any],
) -> float:
    """Score a field-scoped oracle transform of an already schema-valid output.

    A single-field T_k may temporarily violate cross-field wire constraints. The
    unchanged component scorer therefore evaluates the trusted transformed copy
    without re-running wire validation; the caller must validate the clean output
    before applying the mechanical transform.
    """

    target_classes = _target_classes(target_contract)
    task = validate_fixture(source, gold, target_classes, ranking_policy)
    raw_output = dumps(transformed_output).rstrip("\n")
    attempt = {
        "runtime_outcome": "completed",
        "raw_output": raw_output,
        "tool_events": [dict(SUCCESSFUL_FILE_READ_EVENT)],
    }
    result = _score_valid_output(
        task,
        gold,
        transformed_output,
        attempt,
        raw_output,
        target_classes,
        error_contract,
    )
    return float(result["policy_score"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--gold", required=True)
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--ranking-policy", required=True)
    parser.add_argument("--target-classes", required=True)
    parser.add_argument("--error-codes", required=True)
    arguments = parser.parse_args()
    result = score(
        load_object(arguments.source),
        load_object(arguments.gold),
        load_object(arguments.attempt),
        load_object(arguments.ranking_policy),
        load_object(arguments.target_classes),
        load_object(arguments.error_codes),
    )
    print(dumps(result), end="")


if __name__ == "__main__":
    main()
