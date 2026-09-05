"""Dependency score-ledger construction and invalid-result primitives."""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from benchmark_core.contract_validation import ValidationIssue

POLICY_SCALE = 100.0 / 90.0


def rounded(value: float) -> float:
    return round(value, 6)


def definitions(error_contract: dict[str, Any]) -> dict[str, dict[str, bool]]:
    codes = error_contract.get("codes")
    if not isinstance(codes, dict):
        raise ValueError("error-code contract is malformed")
    return codes


def entry(
    error_contract: dict[str, Any],
    code: str,
    component: str,
    *,
    points_lost: float = 0.0,
    policy_points_lost: float = 0.0,
    finding_id: str | None = None,
    reference_id: str | None = None,
    decision: str | None = None,
    requirement: str | None = None,
) -> dict[str, Any]:
    definition = definitions(error_contract).get(code)
    if not isinstance(definition, dict) or set(definition) != {"addressable", "critical"}:
        raise ValueError(f"error-code definition is missing or malformed: {code}")
    value: dict[str, Any] = {
        "code": code,
        "critical": definition["critical"],
        "addressable": definition["addressable"],
        "component": component,
        "points_lost": rounded(points_lost),
        "policy_points_lost": rounded(policy_points_lost),
    }
    if definition["addressable"]:
        value["target_class"] = code
    if finding_id is not None:
        value["finding_id"] = finding_id
    if reference_id is not None:
        value["reference_id"] = reference_id
    if decision is not None:
        value["decision"] = decision
    if requirement is not None:
        value["requirement"] = requirement
    return value


def critical_codes(
    ledger: list[dict[str, Any]],
    error_contract: dict[str, Any],
) -> list[str]:
    order = error_contract.get("critical_order")
    if not isinstance(order, list) or any(not isinstance(code, str) for code in order):
        raise ValueError("error-code critical order is malformed")
    observed = {item["code"] for item in ledger if item["critical"]}
    if not observed.issubset(order):
        raise ValueError("critical error code is absent from the frozen order")
    return [code for code in order if code in observed]


def empty_counts(target_classes: list[str]) -> dict[str, Any]:
    return {
        "actionability": {"correct": 0, "total": 0},
        "remediation": {"correct": 0, "total": 0},
        "evidence": {"tp": 0, "fp": 0, "fn": 0},
        "critical_reachable_production": {"recalled": 0, "total": 0},
        "compatible_selection": {"safe": 0, "total_selected": 0},
        "no_action": {"correct": 0, "total": 0},
        "target_classes": {
            code: {"correct": 0, "total": 0, "policy_points_lost": 0.0} for code in target_classes
        },
    }


def invalid_result(
    task_id: str,
    ledger: list[dict[str, Any]],
    requirement_hits: set[str],
    error_contract: dict[str, Any],
    target_classes: list[str],
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "task_id": task_id,
        "schema_valid": False,
        "score": 0.0,
        "policy_score": 0.0,
        "components": {
            "actionability_accuracy": None,
            "remediation_accuracy": None,
            "ranking_ndcg": None,
            "evidence_micro_f1": None,
        },
        "component_points": {
            "actionability": 0.0,
            "remediation": 0.0,
            "ranking": 0.0,
            "evidence": 0.0,
        },
        "atomic_counts": empty_counts(target_classes),
        "unsafe_remediation_count": 0,
        "success": False,
        "critical_codes": critical_codes(ledger, error_contract),
        "error_ledger": ledger,
        "requirement_hits": sorted(requirement_hits),
    }


def contract_failure(
    task_id: str,
    failures: Iterable[tuple[str, str]],
    error_contract: dict[str, Any],
    target_classes: list[str],
    *,
    existing_ledger: Iterable[dict[str, Any]] = (),
    existing_hits: Iterable[str] = (),
) -> dict[str, Any]:
    """Build one deterministic ledger atom per distinct contract failure."""

    ledger = list(existing_ledger)
    hits = set(existing_hits)
    seen = {(item["code"], item.get("requirement")) for item in ledger}
    for code, requirement in failures:
        hits.add(requirement)
        identity = (code, requirement)
        if identity in seen:
            continue
        seen.add(identity)
        ledger.append(
            entry(
                error_contract,
                code,
                "contract",
                points_lost=100.0,
                policy_points_lost=100.0,
                requirement=requirement,
            )
        )
    if not ledger:
        ledger.append(
            entry(
                error_contract,
                "schema.invalid",
                "contract",
                points_lost=100.0,
                policy_points_lost=100.0,
            )
        )
    hits.add("critical.schema_or_identity")
    return invalid_result(task_id, ledger, hits, error_contract, target_classes)


def output_failure_code(issue: ValidationIssue) -> str:
    if issue.requirement == "schema.exact_version_identity" and "task_id" in issue.message:
        return "identity.mismatch"
    return "schema.invalid"
