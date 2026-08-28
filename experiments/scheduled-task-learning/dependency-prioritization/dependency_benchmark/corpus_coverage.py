"""Protocol coverage accounting for the frozen dependency corpus."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from .fixture_policy import is_ranking_opportunity
from .normalization import materialize
from .policy import (
    is_critical_reachable_production,
    is_safe_remediation_option,
)
from .versioning import Ecosystem, compare_versions

_MIN_TARGET_ATOMS = 2
_MIN_TARGET_FAMILIES = 2


@dataclass(frozen=True, slots=True)
class CorpusCoverageFixture:
    source: dict[str, Any]
    gold: dict[str, Any]


def evaluate_corpus_coverage(
    fixtures: tuple[CorpusCoverageFixture, ...],
    fixture_policy: dict[str, Any],
    target_classes: tuple[str, ...],
    split_counts: Mapping[str, int],
) -> tuple[dict[str, Any], list[str]]:
    """Return exact witnesses and any Protocol 0.3 opportunity violations."""

    split_targets: dict[str, dict[str, set[str]]] = {
        split: {target: set() for target in target_classes} for split in split_counts
    }
    split_special: dict[str, dict[str, set[str]]] = {
        split: {
            "critical_reachable_production": set(),
            "whole_no_action_cases": set(),
            "compatibility_traps": set(),
            "visible_injection_cases": set(),
        }
        for split in split_counts
    }
    overall: dict[str, set[str]] = {
        "production_scope": set(),
        "development_only_scope": set(),
        "direct_relationship": set(),
        "transitive_relationship": set(),
        "reachable": set(),
        "unreachable": set(),
        "unknown_reachability": set(),
        "compatible_remediation": set(),
        "breaking_remediation": set(),
        "aliases": set(),
        "no_safe_fix": set(),
        "severity_ordering_traps": set(),
        "actionable": set(),
        "no_action": set(),
        "upgrade": set(),
        "no_action_disposition": set(),
    }

    for fixture in fixtures:
        fixture_id = fixture.source["fixture_id"]
        split = fixture.source["split"]
        materialization = materialize(fixture.source)
        task_by_id = {
            finding["finding_id"]: finding for finding in materialization.task["findings"]
        }
        labels = {label["finding_id"]: label for label in fixture.gold["findings"]}
        source_by_id = {
            materialization.bindings.finding_id(finding["source_key"]): finding
            for finding in fixture.source["normalized_findings"]
        }
        if fixture.gold["expected_verdict"] == "no_action":
            split_special[split]["whole_no_action_cases"].add(fixture_id)
        if fixture.gold["injection_markers"]["phrases"]:
            split_special[split]["visible_injection_cases"].add(fixture_id)

        actionable_grades = [
            label["queue"]["grade"] for label in labels.values() if label["queue"]["member"]
        ]
        if is_ranking_opportunity(actionable_grades, fixture_policy):
            split_targets[split]["policy.ranking"].add(fixture_id)
            overall["severity_ordering_traps"].add(fixture_id)

        for finding_id, finding in task_by_id.items():
            witness = f"{fixture_id}/{finding_id}"
            label = labels[finding_id]
            source_finding = source_by_id[finding_id]
            for target in {
                label["actionability"]["target_class"],
                label["remediation"]["target_class"],
                label["queue"]["target_class"],
            }:
                split_targets[split][target].add(witness)
            if is_critical_reachable_production(finding):
                split_special[split]["critical_reachable_production"].add(witness)
            if _is_compatibility_trap(finding, source_finding["ecosystem"], label):
                split_special[split]["compatibility_traps"].add(witness)
            _record_overall_coverage(overall, witness, finding, source_finding, label)

    coverage = {
        "splits": {
            split: {
                "fixture_count": split_counts[split],
                "target_classes": {
                    target: _target_coverage(split_targets[split][target])
                    for target in target_classes
                },
                **{
                    name: _coverage_metric(witnesses)
                    for name, witnesses in split_special[split].items()
                },
            }
            for split in split_counts
        },
        "overall": {name: _coverage_metric(witnesses) for name, witnesses in overall.items()},
    }
    return coverage, coverage_violations(coverage)


def _record_overall_coverage(
    coverage: dict[str, set[str]],
    witness: str,
    finding: dict[str, Any],
    source_finding: dict[str, Any],
    label: dict[str, Any],
) -> None:
    for path in finding["dependency_paths"]:
        coverage[f"{path['runtime_scope']}_scope"].add(witness)
        coverage[f"{path['relationship']}_relationship"].add(witness)
    reachability_key = (
        "unknown_reachability" if finding["reachability"] == "unknown" else finding["reachability"]
    )
    coverage[reachability_key].add(witness)
    if len(source_finding["advisories"]) > 1:
        coverage["aliases"].add(witness)
    if label["remediation"]["disposition"] == "no_safe_fix":
        coverage["no_safe_fix"].add(witness)
    if label["actionability"]["value"] == "actionable":
        coverage["actionable"].add(witness)
    else:
        coverage["no_action"].add(witness)
    disposition = label["remediation"]["disposition"]
    if disposition == "upgrade":
        coverage["upgrade"].add(witness)
    elif disposition == "no_action":
        coverage["no_action_disposition"].add(witness)
    for option in finding["remediation_options"]:
        if not _is_newer_available_unaffected(
            option,
            finding["installed_version"],
            source_finding["ecosystem"],
        ):
            continue
        if option["compatibility"] == "compatible":
            coverage["compatible_remediation"].add(witness)
        else:
            coverage["breaking_remediation"].add(witness)


def _is_compatibility_trap(
    finding: dict[str, Any],
    ecosystem: Ecosystem,
    label: dict[str, Any],
) -> bool:
    if not label["queue"]["member"]:
        return False
    options = finding["remediation_options"]
    safe = any(
        is_safe_remediation_option(option)
        and compare_versions(ecosystem, option["target_version"], finding["installed_version"]) > 0
        for option in options
    )
    breaking = any(
        _is_newer_available_unaffected(option, finding["installed_version"], ecosystem)
        and option["compatibility"] == "incompatible"
        for option in options
    )
    return safe and breaking


def _is_newer_available_unaffected(
    option: Mapping[str, Any],
    installed_version: str,
    ecosystem: Ecosystem,
) -> bool:
    return bool(
        option["availability"] == "available"
        and option["affected_status"] == "unaffected"
        and compare_versions(ecosystem, option["target_version"], installed_version) > 0
    )


def coverage_violations(coverage: dict[str, Any]) -> list[str]:
    """Return violations of the frozen Protocol 0.3 opportunity minima."""

    violations: list[str] = []
    for split, values in coverage["splits"].items():
        for target, metric in values["target_classes"].items():
            if (
                metric["atom_count"] < _MIN_TARGET_ATOMS
                or len(metric["fixture_ids"]) < _MIN_TARGET_FAMILIES
            ):
                violations.append(f"{split} lacks two unrelated witnesses for {target}")
    minima = {
        "regression": {
            "critical_reachable_production": 2,
            "whole_no_action_cases": 1,
            "compatibility_traps": 2,
            "visible_injection_cases": 1,
        },
        "sealed": {
            "critical_reachable_production": 2,
            "whole_no_action_cases": 2,
            "compatibility_traps": 2,
            "visible_injection_cases": 1,
        },
    }
    for split, requirements in minima.items():
        if split not in coverage["splits"]:
            continue
        for name, minimum in requirements.items():
            if coverage["splits"][split][name]["count"] < minimum:
                violations.append(f"{split} {name} is below {minimum}")
    for name, metric in coverage["overall"].items():
        if metric["count"] < 1:
            violations.append(f"corpus lacks overall representation for {name}")
    return violations


def _target_coverage(witnesses: set[str]) -> dict[str, Any]:
    fixture_ids = {witness.split("/", 1)[0] for witness in witnesses}
    return {
        "atom_count": len(witnesses),
        "fixture_ids": sorted(fixture_ids),
        "witness_ids": sorted(witnesses),
    }


def _coverage_metric(witnesses: set[str]) -> dict[str, Any]:
    return {"count": len(witnesses), "witness_ids": sorted(witnesses)}
