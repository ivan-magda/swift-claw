"""Frozen dependency policy primitives and D5 ranking interpretation."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any


def is_safe_remediation_option(option: Mapping[str, Any]) -> bool:
    """Return whether canonical option facts permit selection."""

    return bool(
        option["availability"] == "available"
        and option["affected_status"] == "unaffected"
        and option["compatibility"] == "compatible"
    )


def is_critical_reachable_production(finding: Mapping[str, Any]) -> bool:
    """Return whether one canonical finding is a mandatory critical-recall case."""

    return bool(
        finding["affected_status"] == "affected"
        and finding["severity"] == "critical"
        and finding["reachability"] == "reachable"
        and any(path["runtime_scope"] == "production" for path in finding["dependency_paths"])
    )


def validate_ranking_policy(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {
        "schema_version",
        "grade_scope",
        "grade",
        "normalization",
        "ndcg_gain",
    }:
        raise ValueError("ranking policy has the wrong top-level shape")
    if (
        value["schema_version"] != 1
        or value["grade_scope"] != "frozen_gold_remediation_queue"
        or value["ndcg_gain"] != "linear_grade"
    ):
        raise ValueError("ranking policy identity is unsupported")
    grade = value["grade"]
    if not isinstance(grade, dict) or set(grade) != {"non_queue", "queue"}:
        raise ValueError("ranking grade contract is malformed")
    if grade["non_queue"] != 0:
        raise ValueError("non-queue findings must have zero grade")
    queue = grade["queue"]
    if not isinstance(queue, dict) or set(queue) != {"calculation", "base", "terms"}:
        raise ValueError("queue grade contract is malformed")
    if (
        queue["calculation"] != "base_plus_one_term_per_factor"
        or type(queue["base"]) is not int
        or queue["base"] < 0
    ):
        raise ValueError("queue grade calculation is unsupported")
    expected_terms = {
        "reachability": {"unreachable", "unknown", "reachable"},
        "runtime_scope": {"development_only", "production"},
        "compatible_remediation": {"absent", "available"},
        "severity": {"low", "moderate", "high", "critical"},
    }
    terms = queue["terms"]
    if not isinstance(terms, dict) or set(terms) != set(expected_terms):
        raise ValueError("ranking policy factors are malformed")
    for factor, choices in expected_terms.items():
        weights = terms[factor]
        if (
            not isinstance(weights, dict)
            or set(weights) != choices
            or any(type(weight) is not int or weight < 0 for weight in weights.values())
        ):
            raise ValueError(f"ranking policy factor is malformed: {factor}")
    expected_normalization = {
        "reachability": "frozen_canonical_finding_value",
        "runtime_scope": "production_if_any_canonical_path_is_runtime_otherwise_development_only",
        "compatible_remediation": (
            "available_if_any_option_is_available_unaffected_and_compatible_otherwise_absent"
        ),
        "severity": "maximum_frozen_normalized_band_across_alias_cluster",
        "missing_or_unmapped_severity": "fixture_ineligible",
    }
    if value["normalization"] != expected_normalization:
        raise ValueError("ranking policy normalization is unsupported")


def finding_grade(
    finding: dict[str, Any],
    queue_member: bool,
    ranking_policy: dict[str, Any],
) -> int:
    validate_ranking_policy(ranking_policy)
    grade = ranking_policy["grade"]
    if not queue_member:
        return int(grade["non_queue"])
    queue = grade["queue"]
    terms = queue["terms"]
    runtime_scope = (
        "production"
        if any(path["runtime_scope"] == "production" for path in finding["dependency_paths"])
        else "development_only"
    )
    compatible = (
        "available"
        if any(is_safe_remediation_option(option) for option in finding["remediation_options"])
        else "absent"
    )
    return int(
        queue["base"]
        + terms["reachability"][finding["reachability"]]
        + terms["runtime_scope"][runtime_scope]
        + terms["compatible_remediation"][compatible]
        + terms["severity"][finding["severity"]]
    )
