"""Frozen dependency fixture-policy interpretation."""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from functools import cmp_to_key
from itertools import pairwise
from typing import Any, TypedDict, cast

from benchmark_core.canonical import canonical_sha256, dumps

from .policy import is_safe_remediation_option

VersionComparator = Callable[[str, str], int]

_ACTIONABILITY_VALUES = {"actionable", "no_action"}
_ACTIONABILITY_TARGETS = {
    "policy.abstention",
    "policy.reachability",
    "policy.runtime_scope",
}
_FAMILY_DIMENSIONS = {
    "project_packages",
    "record_alias_components",
}
_CROSS_SPLIT_DIMENSIONS = {
    "graph_template_ids",
    "graph_template_digests",
    "generator_seeds",
    "manifest_digests",
}
_CANDIDATE_FIELDS = {
    "target_version",
    "origin_id",
    "source_key",
    "availability",
    "affected_status",
    "compatibility",
}


class RemediationCandidate(TypedDict):
    """Pre-materialization release with stable provenance and canonical safety facts."""

    target_version: str
    origin_id: str
    source_key: str
    availability: str
    affected_status: str
    compatibility: str


@dataclass(frozen=True, slots=True)
class FixtureFamilyFingerprint:
    """Semantic identities that must not overlap between unrelated fixture families."""

    split: str
    project_packages: frozenset[str]
    record_alias_components: frozenset[str]
    graph_template_ids: frozenset[str]
    graph_template_digests: frozenset[str]
    generator_seeds: frozenset[str]
    manifest_digests: frozenset[str]


def validate_fixture_policy(value: Any) -> None:
    policy = _object(
        value,
        {
            "schema_version",
            "runtime_scope",
            "reachability",
            "actionability",
            "remediation",
            "queue",
            "evidence",
            "ranking_opportunity",
            "unrelated_family",
        },
        "fixture policy",
    )
    if type(policy["schema_version"]) is not int or policy["schema_version"] != 1:
        raise ValueError("fixture policy schema version is unsupported")
    _validate_aggregation(
        policy["runtime_scope"],
        ["production", "development_only"],
        "runtime-scope policy",
    )
    _validate_aggregation(
        policy["reachability"],
        ["reachable", "unknown", "unreachable"],
        "reachability policy",
    )
    _validate_actionability(policy["actionability"])
    _validate_remediation(policy["remediation"])
    if policy["queue"] != {
        "membership": "exactly_actionable_findings",
        "target_class": "actionability_target_class",
    }:
        raise ValueError("queue policy is unsupported")
    if policy["evidence"] != {
        "gold_reference_set": "all_model_visible_references_owned_by_finding"
    }:
        raise ValueError("evidence policy is unsupported")
    ranking = _object(
        policy["ranking_opportunity"],
        {"minimum_actionable_findings", "requires_unequal_grades"},
        "ranking-opportunity policy",
    )
    minimum = ranking["minimum_actionable_findings"]
    if type(minimum) is not int or minimum <= 1:
        raise ValueError("ranking-opportunity minimum is unsupported")
    if not isinstance(ranking["requires_unequal_grades"], bool):
        raise ValueError("ranking-opportunity grade rule is malformed")
    unrelated = _object(
        policy["unrelated_family"],
        {
            "all_pair_disjoint_dimensions",
            "cross_split_disjoint_dimensions",
            "graph_template_digest",
            "record_alias_identity",
            "manifest_digest",
        },
        "unrelated-family policy",
    )
    if (
        unrelated["record_alias_identity"] != "transitive_component"
        or unrelated["graph_template_digest"] != "identity_free_model_visible_task_path_structure"
        or unrelated["manifest_digest"] != "identity_free_model_visible_decision_structure"
        or not _exact_string_list(
            unrelated["all_pair_disjoint_dimensions"],
            _FAMILY_DIMENSIONS,
        )
        or not _exact_string_list(
            unrelated["cross_split_disjoint_dimensions"],
            _CROSS_SPLIT_DIMENSIONS,
        )
    ):
        raise ValueError("unrelated-family policy is unsupported")


def graph_template_digest(task: Mapping[str, Any]) -> str:
    """Hash model-visible dependency path structure without fixture identities."""

    finding_shapes = [
        sorted(
            (_path_shape(path) for path in finding["dependency_paths"]),
            key=dumps,
        )
        for finding in task["findings"]
    ]
    return canonical_sha256({"finding_path_shapes": sorted(finding_shapes, key=dumps)})


def manifest_structure_digest(task: Mapping[str, Any]) -> str:
    """Hash model-visible decision structure without opaque IDs or literal values."""

    evidence_by_finding: dict[str, list[str]] = {}
    for evidence in task["evidence_references"]:
        evidence_by_finding.setdefault(evidence["finding_id"], []).append(evidence["subject_type"])
    finding_shapes: list[dict[str, Any]] = []
    for finding in task["findings"]:
        option_shapes = [
            {
                "affected_status": option["affected_status"],
                "availability": option["availability"],
                "compatibility": option["compatibility"],
            }
            for option in finding["remediation_options"]
        ]
        finding_shapes.append(
            {
                "affected_status": finding["affected_status"],
                "evidence_subject_types": sorted(
                    evidence_by_finding.get(finding["finding_id"], [])
                ),
                "path_shapes": sorted(
                    (_path_shape(path) for path in finding["dependency_paths"]),
                    key=dumps,
                ),
                "reachability": finding["reachability"],
                "remediation_option_shapes": sorted(option_shapes, key=dumps),
                "severity": finding["severity"],
            }
        )
    return canonical_sha256({"finding_shapes": sorted(finding_shapes, key=dumps)})


def aggregate_runtime_scope(values: Iterable[str], policy: dict[str, Any]) -> str:
    """Return production when any frozen path is production-scoped."""

    validate_fixture_policy(policy)
    return _aggregate(values, policy["runtime_scope"], "runtime scope")


def aggregate_reachability(values: Iterable[str], policy: dict[str, Any]) -> str:
    """Return the strongest frozen reachability observation."""

    validate_fixture_policy(policy)
    return _aggregate(values, policy["reachability"], "reachability")


def derive_actionability(
    affected_status: str,
    runtime_scope: str,
    reachability: str,
    policy: dict[str, Any],
) -> dict[str, str]:
    validate_fixture_policy(policy)
    affected = policy["actionability"]["affected"]
    if runtime_scope not in affected or reachability not in affected[runtime_scope]:
        raise ValueError("actionability inputs are outside the frozen fixture policy")
    if affected_status == "unaffected":
        return dict(policy["actionability"]["unaffected"])
    if affected_status != "affected":
        raise ValueError("affected status is outside the frozen fixture policy")
    return dict(affected[runtime_scope][reachability])


def derive_remediation(
    actionability: str,
    installed_version: str,
    candidates: list[RemediationCandidate],
    compare_versions: VersionComparator,
    policy: dict[str, Any],
) -> dict[str, str | None]:
    validate_fixture_policy(policy)
    if not installed_version:
        raise ValueError("installed version must be non-empty")
    for candidate in candidates:
        _validate_candidate(candidate)
    ordered_candidates = _ordered_candidates(candidates, compare_versions)
    if any(
        _compare_candidates(left, right, compare_versions) == 0
        for left, right in pairwise(ordered_candidates)
    ):
        raise ValueError("remediation candidates have a duplicate selection key")
    source_keys = [candidate["source_key"] for candidate in candidates]
    if len(source_keys) != len(set(source_keys)):
        raise ValueError("remediation candidate source keys must be unique")
    remediation = policy["remediation"]
    if actionability == "no_action":
        return {
            "disposition": remediation["dispositions"]["no_action"],
            "selected_source_key": None,
            "target_class": remediation["target_classes"]["no_action"],
        }
    if actionability != "actionable":
        raise ValueError("actionability is outside the frozen remediation policy")
    safe_candidates = [
        candidate
        for candidate in candidates
        if is_safe_remediation_option(candidate)
        and _compare_versions(candidate["target_version"], installed_version, compare_versions) > 0
    ]
    if not safe_candidates:
        return {
            "disposition": remediation["dispositions"]["actionable_without_safe_option"],
            "selected_source_key": None,
            "target_class": remediation["target_classes"]["actionable"],
        }

    ordered = _ordered_candidates(safe_candidates, compare_versions)
    return {
        "disposition": remediation["dispositions"]["actionable_with_safe_option"],
        "selected_source_key": ordered[0]["source_key"],
        "target_class": remediation["target_classes"]["actionable"],
    }


def expected_evidence_reference_ids(
    finding_id: str,
    references: list[dict[str, Any]],
    policy: dict[str, Any],
) -> list[str]:
    validate_fixture_policy(policy)
    return sorted(
        str(reference["evidence_reference_id"])
        for reference in references
        if reference["finding_id"] == finding_id
    )


def is_ranking_opportunity(grades: list[int], policy: dict[str, Any]) -> bool:
    validate_fixture_policy(policy)
    if any(type(grade) is not int or grade < 0 for grade in grades):
        raise ValueError("ranking grades must be non-negative integers")
    ranking = policy["ranking_opportunity"]
    if len(grades) < ranking["minimum_actionable_findings"]:
        return False
    return not ranking["requires_unequal_grades"] or len(set(grades)) > 1


def are_unrelated_families(
    left: FixtureFamilyFingerprint,
    right: FixtureFamilyFingerprint,
    policy: dict[str, Any],
) -> bool:
    validate_fixture_policy(policy)
    family_dimensions = policy["unrelated_family"]["all_pair_disjoint_dimensions"]
    if not all(
        getattr(left, dimension).isdisjoint(getattr(right, dimension))
        for dimension in family_dimensions
    ):
        return False
    if left.split == right.split:
        return True
    split_dimensions = policy["unrelated_family"]["cross_split_disjoint_dimensions"]
    return all(
        getattr(left, dimension).isdisjoint(getattr(right, dimension))
        for dimension in split_dimensions
    )


def _path_shape(path: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "relationship": path["relationship"],
        "runtime_scope": path["runtime_scope"],
    }


def _object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError(f"{label} has the wrong shape")
    return value


def _validate_aggregation(value: Any, precedence: list[str], label: str) -> None:
    contract = _object(value, {"precedence", "empty"}, label)
    if contract["precedence"] != precedence or contract["empty"] != "invalid":
        raise ValueError(f"{label} is unsupported")


def _validate_actionability(value: Any) -> None:
    contract = _object(value, {"unaffected", "affected"}, "actionability policy")
    _validate_decision(contract["unaffected"])
    affected = _object(
        contract["affected"],
        {"production", "development_only"},
        "affected actionability policy",
    )
    for scope in affected.values():
        by_reachability = _object(
            scope,
            {"reachable", "unknown", "unreachable"},
            "affected reachability policy",
        )
        for decision in by_reachability.values():
            _validate_decision(decision)


def _validate_decision(value: Any) -> None:
    decision = _object(value, {"value", "target_class"}, "actionability decision")
    if (
        decision["value"] not in _ACTIONABILITY_VALUES
        or decision["target_class"] not in _ACTIONABILITY_TARGETS
    ):
        raise ValueError("actionability decision is unsupported")


def _validate_remediation(value: Any) -> None:
    contract = _object(
        value,
        {
            "candidate_versions",
            "candidate_identity",
            "safe_option",
            "selection_order",
            "dispositions",
            "target_classes",
        },
        "remediation policy",
    )
    if contract["candidate_versions"] != {
        "sources": ["advisory_fixed_events", "frozen_release_inventory"],
        "combination": "union",
        "advisory_fixed_event_availability": "available",
        "invalid_fixed_version": "fixture_invalid",
    }:
        raise ValueError("remediation candidate sources are unsupported")
    if contract["candidate_identity"] != {
        "required_fields": [
            "target_version",
            "origin_id",
            "source_key",
            "availability",
            "affected_status",
            "compatibility",
        ],
        "stage": "pre_materialization",
        "origin_id": "advisory_record_id_or_reserved_release_inventory_origin",
        "source_key": "unique_per_finding",
        "equivalent_version_resolution": "origin_id_then_source_key",
        "materialization_binding": (
            "source_key_to_canonical_option_id_from_authoritative_normalization_binding"
        ),
        "duplicate_selection_key": "fixture_invalid",
    }:
        raise ValueError("remediation candidate identity is unsupported")
    if contract["safe_option"] != {
        "availability": "available",
        "affected_status": "unaffected",
        "compatibility": "compatible",
        "version_relation": "greater_than_installed",
    }:
        raise ValueError("safe-option policy is unsupported")
    if contract["selection_order"] != [
        "ecosystem_version_ascending",
        "origin_id_ascending",
        "source_key_ascending",
    ]:
        raise ValueError("remediation selection order is unsupported")
    if contract["dispositions"] != {
        "actionable_with_safe_option": "upgrade",
        "actionable_without_safe_option": "no_safe_fix",
        "no_action": "no_action",
    }:
        raise ValueError("remediation dispositions are unsupported")
    if contract["target_classes"] != {
        "actionable": "policy.remediation",
        "no_action": "policy.abstention",
    }:
        raise ValueError("remediation target classes are unsupported")


def _exact_string_list(value: Any, expected: set[str]) -> bool:
    return (
        isinstance(value, list)
        and all(isinstance(item, str) for item in value)
        and len(value) == len(expected)
        and set(value) == expected
    )


def _aggregate(values: Iterable[str], contract: dict[str, Any], label: str) -> str:
    observed = set(values)
    precedence = cast(list[str], contract["precedence"])
    if not observed or not observed.issubset(precedence):
        raise ValueError(f"{label} observations are empty or unsupported")
    return next(value for value in precedence if value in observed)


def _compare_candidates(
    left: RemediationCandidate,
    right: RemediationCandidate,
    compare_versions: VersionComparator,
) -> int:
    version_order = _compare_versions(
        left["target_version"],
        right["target_version"],
        compare_versions,
    )
    if version_order != 0:
        return version_order
    left_tie = (left["origin_id"], left["source_key"])
    right_tie = (right["origin_id"], right["source_key"])
    return (left_tie > right_tie) - (left_tie < right_tie)


def _ordered_candidates(
    candidates: list[RemediationCandidate],
    compare_versions: VersionComparator,
) -> list[RemediationCandidate]:
    def candidate_order(left: RemediationCandidate, right: RemediationCandidate) -> int:
        return _compare_candidates(left, right, compare_versions)

    return sorted(candidates, key=cmp_to_key(candidate_order))


def _compare_versions(left: str, right: str, compare_versions: VersionComparator) -> int:
    result = compare_versions(left, right)
    if type(result) is not int:
        raise ValueError("version comparator must return an integer")
    return (result > 0) - (result < 0)


def _validate_candidate(value: Any) -> None:
    candidate = _object(value, _CANDIDATE_FIELDS, "remediation candidate")
    for field in ("target_version", "origin_id", "source_key"):
        if not isinstance(candidate[field], str) or not candidate[field]:
            raise ValueError(f"remediation candidate {field} must be non-empty text")
    if candidate["availability"] not in {"available", "unavailable"}:
        raise ValueError("remediation candidate availability is unsupported")
    if candidate["affected_status"] not in {"affected", "unaffected"}:
        raise ValueError("remediation candidate affected status is unsupported")
    if candidate["compatibility"] not in {"compatible", "incompatible"}:
        raise ValueError("remediation candidate compatibility is unsupported")
