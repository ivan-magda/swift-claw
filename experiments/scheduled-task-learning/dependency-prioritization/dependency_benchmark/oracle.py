"""Mechanical policy-only transforms and headroom primitives."""

from __future__ import annotations

from copy import deepcopy
from statistics import median
from typing import Any

from benchmark_core.attempt import SUCCESSFUL_FILE_READ_EVENT
from benchmark_core.canonical import dumps

from .queue_policy import set_queue_membership, sort_gold_matched_queue
from .scorer import policy_score_counterfactual, score
from .validation import validate_output

_MIN_STABLE_REPLICATES = 2
_MIN_STABLE_FAMILIES = 2


def transform_output(
    output: dict[str, Any],
    gold: dict[str, Any],
    target_codes: list[str],
) -> dict[str, Any]:
    """Apply only fields owned by the selected frozen target codes."""

    transformed = deepcopy(output)
    gold_by_id = {finding["finding_id"]: finding for finding in gold["findings"]}
    queue = transformed["remediation_queue"]
    for finding_output in transformed["findings"]:
        finding_id = finding_output["finding_id"]
        label = gold_by_id.get(finding_id)
        if label is None:
            continue
        for code in target_codes:
            if code in {"policy.runtime_scope", "policy.reachability"}:
                if label["actionability"]["target_class"] == code:
                    finding_output["actionability"] = label["actionability"]["value"]
                if label["queue"]["target_class"] == code:
                    queue = set_queue_membership(queue, finding_id, label["queue"]["member"])
            elif code == "policy.remediation" and label["remediation"]["target_class"] == code:
                finding_output["remediation_disposition"] = label["remediation"]["disposition"]
                finding_output["selected_option_id"] = label["remediation"]["selected_option_id"]
            elif code == "policy.abstention":
                if label["actionability"]["target_class"] == code:
                    finding_output["actionability"] = label["actionability"]["value"]
                if label["remediation"]["target_class"] == code:
                    finding_output["remediation_disposition"] = label["remediation"]["disposition"]
                    finding_output["selected_option_id"] = label["remediation"][
                        "selected_option_id"
                    ]
                if label["queue"]["target_class"] == code:
                    queue = set_queue_membership(queue, finding_id, label["queue"]["member"])
    transformed["remediation_queue"] = queue
    if "policy.ranking" in target_codes:
        grades = {finding_id: label["queue"]["grade"] for finding_id, label in gold_by_id.items()}
        transformed["remediation_queue"] = sort_gold_matched_queue(queue, grades)
    return transformed


def score_output(
    source: dict[str, Any],
    gold: dict[str, Any],
    output: dict[str, Any],
    ranking_policy: dict[str, Any],
    target_contract: dict[str, Any],
    error_contract: dict[str, Any],
) -> dict[str, Any]:
    attempt = {
        "runtime_outcome": "completed",
        "raw_output": dumps(output).rstrip("\n"),
        "tool_events": [dict(SUCCESSFUL_FILE_READ_EVENT)],
    }
    return score(
        source,
        gold,
        attempt,
        ranking_policy,
        target_contract,
        error_contract,
    )


def recoverable_gain(
    source: dict[str, Any],
    gold: dict[str, Any],
    output: dict[str, Any],
    target_codes: list[str],
    ranking_policy: dict[str, Any],
    target_contract: dict[str, Any],
    error_contract: dict[str, Any],
) -> float:
    if validate_output(output, source["task_id"]):
        return 0.0
    baseline = score_output(
        source,
        gold,
        output,
        ranking_policy,
        target_contract,
        error_contract,
    )["policy_score"]
    transformed = transform_output(output, gold, target_codes)
    oracle = policy_score_counterfactual(
        source,
        gold,
        transformed,
        ranking_policy,
        target_contract,
        error_contract,
    )
    return max(0.0, oracle - float(baseline))


def select_target_codes(
    runs: list[dict[str, Any]],
    target_order: list[str],
    *,
    maximum: int = 3,
) -> list[str]:
    """Select recurring classes by recoverable loss, then frozen taxonomy order."""

    losses: dict[str, float] = dict.fromkeys(target_order, 0.0)
    recurrence: dict[str, dict[str, set[int]]] = {code: {} for code in target_order}
    for run in runs:
        family_id = run["family_id"]
        replicate = run["replicate"]
        per_code = dict.fromkeys(target_order, 0.0)
        for entry in run["score_result"]["error_ledger"]:
            code = entry["code"]
            if code in per_code:
                per_code[code] += float(entry["policy_points_lost"])
        for code, points_lost in per_code.items():
            losses[code] += points_lost
            if points_lost > 0:
                recurrence[code].setdefault(family_id, set()).add(replicate)
    qualified = [
        code
        for code in target_order
        if sum(
            len(replicates) >= _MIN_STABLE_REPLICATES for replicates in recurrence[code].values()
        )
        >= _MIN_STABLE_FAMILIES
    ]
    order_index = {code: index for index, code in enumerate(target_order)}
    qualified.sort(key=lambda code: (-losses[code], order_index[code]))
    return qualified[:maximum]


def split_headroom(gains: list[dict[str, Any]]) -> float:
    """Return mean fixture-median paired recovery from replicate-level gains."""

    by_fixture: dict[str, list[float]] = {}
    for item in gains:
        by_fixture.setdefault(item["fixture_id"], []).append(float(item["gain"]))
    if not by_fixture:
        return 0.0
    return sum(median(values) for values in by_fixture.values()) / len(by_fixture)
