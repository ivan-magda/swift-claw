"""Pure dependency benchmark score components."""

from __future__ import annotations

import math
from typing import Any

from .queue_policy import correct_queue_membership, sort_gold_matched_queue
from .score_ledger import POLICY_SCALE, entry

_FLOAT_TOLERANCE = 1e-9
_QUEUE_MEMBERSHIP_ORDER = (
    "policy.runtime_scope",
    "policy.reachability",
    "policy.abstention",
)


def classification(
    findings_by_id: dict[str, dict[str, Any]],
    gold_by_id: dict[str, dict[str, Any]],
    output_by_id: dict[str, dict[str, Any]],
    queue: list[str],
    target_classes: list[str],
    error_contract: dict[str, Any],
) -> dict[str, Any]:
    total = len(findings_by_id)
    actionability_loss = 35.0 / total if total else 0.0
    remediation_loss = 25.0 / total if total else 0.0
    target_counts = {
        code: {"correct": 0, "total": 0, "policy_points_lost": 0.0} for code in target_classes
    }
    result: dict[str, Any] = {
        "actionability_correct": 0,
        "remediation_correct": 0,
        "no_action_correct": 0,
        "no_action_total": 0,
        "target_counts": target_counts,
        "ledger": [],
        "hits": set(),
    }
    for finding_id in sorted(findings_by_id):
        label = gold_by_id[finding_id]
        finding_output = output_by_id.get(finding_id)
        action_code = label["actionability"]["target_class"]
        remediation_code = label["remediation"]["target_class"]
        target_counts[action_code]["total"] += 1
        target_counts[remediation_code]["total"] += 1
        expected_actionability = label["actionability"]["value"]
        expected_remediation = (
            label["remediation"]["disposition"],
            label["remediation"]["selected_option_id"],
        )
        if expected_actionability == "no_action":
            result["no_action_total"] += 1
        if finding_output is None:
            for component, points_lost in (
                ("actionability", actionability_loss),
                ("remediation", remediation_loss),
            ):
                result["ledger"].append(
                    entry(
                        error_contract,
                        "policy.non_addressable",
                        component,
                        points_lost=points_lost,
                        policy_points_lost=points_lost * POLICY_SCALE,
                        finding_id=finding_id,
                        decision="missing_finding",
                    )
                )
            result["hits"].add("ledger.policy.non_addressable")
            continue
        if finding_output["actionability"] == expected_actionability:
            result["actionability_correct"] += 1
            target_counts[action_code]["correct"] += 1
        else:
            result["ledger"].append(
                entry(
                    error_contract,
                    action_code,
                    "actionability",
                    points_lost=actionability_loss,
                    policy_points_lost=actionability_loss * POLICY_SCALE,
                    finding_id=finding_id,
                    decision="actionability",
                )
            )
            result["hits"].add(f"ledger.{action_code}")
        observed_remediation = (
            finding_output["remediation_disposition"],
            finding_output["selected_option_id"],
        )
        if observed_remediation == expected_remediation:
            result["remediation_correct"] += 1
            target_counts[remediation_code]["correct"] += 1
        else:
            result["ledger"].append(
                entry(
                    error_contract,
                    remediation_code,
                    "remediation",
                    points_lost=remediation_loss,
                    policy_points_lost=remediation_loss * POLICY_SCALE,
                    finding_id=finding_id,
                    decision="remediation",
                )
            )
            result["hits"].add(f"ledger.{remediation_code}")
        if expected_actionability == "no_action" and (
            finding_output["actionability"] == "no_action"
            and finding_output["remediation_disposition"] == "no_action"
            and finding_id not in queue
        ):
            result["no_action_correct"] += 1
    return result


def ranking(
    queue: list[str],
    output_ids: set[str],
    gold_by_id: dict[str, dict[str, Any]],
    target_counts: dict[str, dict[str, Any]],
    error_contract: dict[str, Any],
) -> dict[str, Any]:
    ledger: list[dict[str, Any]] = []
    hits: set[str] = set()
    grades = {finding_id: label["queue"]["grade"] for finding_id, label in gold_by_id.items()}
    observed_ndcg = _ndcg(queue, grades)
    if not any(grades.values()):
        hits.add("score.empty_queue")
    working_queue = list(queue)
    working_ndcg = observed_ndcg
    for code in _QUEUE_MEMBERSHIP_ORDER:
        labels = {
            finding_id: label
            for finding_id, label in gold_by_id.items()
            if label["queue"]["target_class"] == code
        }
        target_counts[code]["total"] += len(labels)
        target_counts[code]["correct"] += sum(
            finding_id in output_ids and ((finding_id in queue) == bool(label["queue"]["member"]))
            for finding_id, label in labels.items()
        )
        corrected = correct_queue_membership(working_queue, output_ids, gold_by_id, code)
        corrected_ndcg = _ndcg(corrected, grades)
        improvement = max(0.0, corrected_ndcg - working_ndcg)
        if improvement > _FLOAT_TOLERANCE:
            points_lost = 30.0 * improvement
            ledger.append(
                entry(
                    error_contract,
                    code,
                    "ranking",
                    points_lost=points_lost,
                    policy_points_lost=points_lost * POLICY_SCALE,
                    decision="queue_membership",
                )
            )
            hits.add(f"ledger.{code}")
        working_queue = corrected
        working_ndcg = corrected_ndcg
    ranked_queue = sort_gold_matched_queue(working_queue, grades)
    ranked_ndcg = _ndcg(ranked_queue, grades)
    ranking_improvement = max(0.0, ranked_ndcg - working_ndcg)
    target_counts["policy.ranking"]["total"] += 1
    if ranking_improvement > _FLOAT_TOLERANCE:
        points_lost = 30.0 * ranking_improvement
        ledger.append(
            entry(
                error_contract,
                "policy.ranking",
                "ranking",
                points_lost=points_lost,
                policy_points_lost=points_lost * POLICY_SCALE,
                decision="queue_order",
            )
        )
        hits.add("ledger.policy.ranking")
    else:
        target_counts["policy.ranking"]["correct"] += 1
    remaining_loss = max(0.0, 30.0 * (1.0 - ranked_ndcg))
    if remaining_loss > _FLOAT_TOLERANCE:
        ledger.append(
            entry(
                error_contract,
                "policy.non_addressable",
                "ranking",
                points_lost=remaining_loss,
                policy_points_lost=remaining_loss * POLICY_SCALE,
                decision="missing_or_noncanonical_queue_entry",
            )
        )
        hits.add("ledger.policy.non_addressable")
    return {"ndcg": observed_ndcg, "ledger": ledger, "hits": hits}


def evidence(
    output_by_id: dict[str, dict[str, Any]],
    gold_by_id: dict[str, dict[str, Any]],
    error_contract: dict[str, Any],
) -> dict[str, Any]:
    expected = {
        (finding_id, reference_id)
        for finding_id, label in gold_by_id.items()
        for reference_id in label["evidence_reference_ids"]
    }
    observed = {
        (finding_id, reference_id)
        for finding_id, finding_output in output_by_id.items()
        for reference_id in finding_output["evidence_reference_ids"]
    }
    tp = len(expected & observed)
    fp = len(observed - expected)
    fn = len(expected - observed)
    denominator = 2 * tp + fp + fn
    f1 = 1.0 if denominator == 0 else 2 * tp / denominator
    ledger: list[dict[str, Any]] = []
    hits: set[str] = set()
    loss = 10.0 * (1.0 - f1)
    if loss > _FLOAT_TOLERANCE:
        ledger.append(
            entry(
                error_contract,
                "evidence.selection",
                "evidence",
                points_lost=loss,
                decision="evidence_set",
            )
        )
        hits.add("ledger.evidence.selection")
    return {"tp": tp, "fp": fp, "fn": fn, "f1": f1, "ledger": ledger, "hits": hits}


def _ndcg(queue: list[str], grades: dict[str, int]) -> float:
    ideal = sorted((grade for grade in grades.values() if grade > 0), reverse=True)
    if not ideal:
        return 1.0 if not queue else 0.0
    ideal_dcg = sum(grade / math.log2(index + 2) for index, grade in enumerate(ideal))
    observed_dcg = sum(
        grades.get(finding_id, 0) / math.log2(index + 2) for index, finding_id in enumerate(queue)
    )
    return min(1.0, observed_dcg / ideal_dcg)
