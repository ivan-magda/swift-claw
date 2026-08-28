from __future__ import annotations

import unittest
from dataclasses import replace
from typing import Any

from benchmark_core.canonical import load_object
from dependency_benchmark.fixture_policy import (
    FixtureFamilyFingerprint,
    RemediationCandidate,
    aggregate_reachability,
    aggregate_runtime_scope,
    are_unrelated_families,
    derive_actionability,
    derive_remediation,
    expected_evidence_reference_ids,
    is_ranking_opportunity,
)

from support import ROOT


def _policy() -> dict[str, Any]:
    return load_object(ROOT / "contracts/fixture-policy.json")


def _compare_versions(left: str, right: str) -> int:
    left_parts = tuple(int(part) for part in left.split("."))
    right_parts = tuple(int(part) for part in right.split("."))
    width = max(len(left_parts), len(right_parts))
    normalized_left = left_parts + (0,) * (width - len(left_parts))
    normalized_right = right_parts + (0,) * (width - len(right_parts))
    return (normalized_left > normalized_right) - (normalized_left < normalized_right)


def _candidate(
    target_version: str,
    origin_id: str,
    source_key: str,
    *,
    availability: str = "available",
    affected_status: str = "unaffected",
    compatibility: str = "compatible",
) -> RemediationCandidate:
    return {
        "target_version": target_version,
        "origin_id": origin_id,
        "source_key": source_key,
        "availability": availability,
        "affected_status": affected_status,
        "compatibility": compatibility,
    }


class DependencyFixturePolicyTests(unittest.TestCase):
    def test_actionability_uses_the_frozen_scope_and_reachability_truth_table(self) -> None:
        # Given
        policy = _policy()
        cases = (
            ("unaffected", "production", "reachable", "no_action", "policy.abstention"),
            ("affected", "development_only", "unreachable", "no_action", "policy.reachability"),
            ("affected", "development_only", "unknown", "no_action", "policy.runtime_scope"),
            ("affected", "development_only", "reachable", "actionable", "policy.reachability"),
            ("affected", "production", "unreachable", "no_action", "policy.reachability"),
            ("affected", "production", "unknown", "actionable", "policy.runtime_scope"),
            ("affected", "production", "reachable", "actionable", "policy.reachability"),
        )

        # When / Then
        self.assertEqual(
            aggregate_runtime_scope(["development_only", "production"], policy),
            "production",
        )
        self.assertEqual(
            aggregate_reachability(["unreachable", "unknown"], policy),
            "unknown",
        )
        self.assertEqual(
            aggregate_reachability(["unreachable", "unknown", "reachable"], policy),
            "reachable",
        )
        for affected, scope, reachability, value, target_class in cases:
            with self.subTest(
                affected_status=affected,
                runtime_scope=scope,
                reachability=reachability,
            ):
                self.assertEqual(
                    derive_actionability(affected, scope, reachability, policy),
                    {"value": value, "target_class": target_class},
                )

    def test_remediation_filters_and_orders_safe_upgrades(self) -> None:
        # Given
        policy = _policy()
        candidates = [
            _candidate("1.9", "record-a", "older"),
            _candidate(
                "2.1",
                "record-a",
                "affected",
                affected_status="affected",
            ),
            _candidate(
                "2.2",
                "record-a",
                "incompatible",
                compatibility="incompatible",
            ),
            _candidate(
                "2.3",
                "record-a",
                "unavailable",
                availability="unavailable",
            ),
            _candidate("2.4.0", "record-z", "candidate-z"),
            _candidate("2.4", "record-a", "candidate-a-z"),
            _candidate("2.4.00", "record-a", "candidate-a-a"),
            _candidate("3.0", "record-a", "later"),
        ]

        # When
        upgrade = derive_remediation(
            "actionable",
            "2.0",
            candidates,
            _compare_versions,
            policy,
        )
        no_safe_fix = derive_remediation(
            "actionable",
            "2.0",
            candidates[:4],
            _compare_versions,
            policy,
        )
        no_action = derive_remediation(
            "no_action",
            "2.0",
            candidates,
            _compare_versions,
            policy,
        )

        # Then
        self.assertEqual(
            upgrade,
            {
                "disposition": "upgrade",
                "selected_source_key": "candidate-a-a",
                "target_class": "policy.remediation",
            },
        )
        self.assertEqual(
            no_safe_fix,
            {
                "disposition": "no_safe_fix",
                "selected_source_key": None,
                "target_class": "policy.remediation",
            },
        )
        self.assertEqual(
            no_action,
            {
                "disposition": "no_action",
                "selected_source_key": None,
                "target_class": "policy.abstention",
            },
        )
        with self.assertRaisesRegex(ValueError, "duplicate selection key"):
            derive_remediation(
                "actionable",
                "2.0",
                [
                    _candidate("2.4", "record-a", "candidate-a"),
                    _candidate("2.4.0", "record-a", "candidate-a"),
                ],
                _compare_versions,
                policy,
            )
        with self.assertRaisesRegex(ValueError, "source keys must be unique"):
            derive_remediation(
                "actionable",
                "2.0",
                [
                    _candidate("2.4", "record-a", "candidate-a"),
                    _candidate("2.5", "record-b", "candidate-a"),
                ],
                _compare_versions,
                policy,
            )

    def test_ranking_opportunity_requires_two_unequal_actionable_grades(self) -> None:
        # Given
        policy = _policy()

        # When / Then
        self.assertFalse(is_ranking_opportunity([24], policy))
        self.assertFalse(is_ranking_opportunity([24, 24], policy))
        self.assertTrue(is_ranking_opportunity([24, 32], policy))

    def test_unrelated_families_require_every_semantic_dimension_to_be_disjoint(self) -> None:
        # Given
        policy = _policy()
        left = FixtureFamilyFingerprint(
            family_id="family-left",
            normalized_packages=frozenset({"npm:left"}),
            record_alias_components=frozenset({"alias:left"}),
            root_helper_nodes=frozenset({"node:left"}),
            graph_template_ids=frozenset({"graph:left"}),
            generator_seeds=frozenset({"seed:left"}),
            manifest_digests=frozenset({"manifest:left"}),
        )
        right = FixtureFamilyFingerprint(
            family_id="family-right",
            normalized_packages=frozenset({"npm:right"}),
            record_alias_components=frozenset({"alias:right"}),
            root_helper_nodes=frozenset({"node:right"}),
            graph_template_ids=frozenset({"graph:right"}),
            generator_seeds=frozenset({"seed:right"}),
            manifest_digests=frozenset({"manifest:right"}),
        )
        dimensions = policy["unrelated_family"]["disjoint_dimensions"]

        # When / Then
        self.assertTrue(are_unrelated_families(left, right, policy))
        self.assertFalse(
            are_unrelated_families(left, replace(right, family_id=left.family_id), policy)
        )
        for dimension in dimensions:
            with self.subTest(dimension=dimension):
                overlapping = replace(right, **{dimension: getattr(left, dimension)})
                self.assertFalse(are_unrelated_families(left, overlapping, policy))

    def test_evidence_gold_contains_every_visible_reference_owned_by_the_finding(self) -> None:
        # Given
        policy = _policy()
        references = [
            {"finding_id": "finding-a", "evidence_reference_id": "evidence-z"},
            {"finding_id": "finding-b", "evidence_reference_id": "evidence-b"},
            {"finding_id": "finding-a", "evidence_reference_id": "evidence-a"},
        ]

        # When
        evidence_ids = expected_evidence_reference_ids("finding-a", references, policy)

        # Then
        self.assertEqual(evidence_ids, ["evidence-a", "evidence-z"])


if __name__ == "__main__":
    unittest.main()
