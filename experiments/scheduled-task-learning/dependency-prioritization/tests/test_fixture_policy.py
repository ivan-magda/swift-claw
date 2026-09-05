from __future__ import annotations

import copy
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
    graph_template_digest,
    is_ranking_opportunity,
    manifest_structure_digest,
    validate_fixture_policy,
)
from dependency_benchmark.normalization import materialize_task

from support import ROOT, fixture


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

    def test_identity_free_digests_ignore_opaque_ids_and_literal_values(self) -> None:
        # Given
        task = materialize_task(copy.deepcopy(fixture("dp-development-01")["source"]))
        relabeled = copy.deepcopy(task)
        finding_ids: dict[str, str] = {}
        subject_ids: dict[str, str] = {}
        for finding_index, finding in enumerate(relabeled["findings"]):
            old_finding_id = finding["finding_id"]
            finding["finding_id"] = f"renamed-finding-{finding_index}"
            finding_ids[old_finding_id] = finding["finding_id"]
            finding["alias_cluster_id"] = f"renamed-alias-{finding_index}"
            finding["package_id"] = f"renamed-package-{finding_index}"
            finding["installed_version"] = f"installed-{finding_index}"
            for path_index, path in enumerate(finding["dependency_paths"]):
                old_path_id = path["path_id"]
                path["path_id"] = f"renamed-path-{finding_index}-{path_index}"
                subject_ids[old_path_id] = path["path_id"]
            for option_index, option in enumerate(finding["remediation_options"]):
                old_option_id = option["option_id"]
                option["option_id"] = f"renamed-option-{finding_index}-{option_index}"
                option["target_version"] = f"target-{finding_index}-{option_index}"
                subject_ids[old_option_id] = option["option_id"]
            subject_ids[old_finding_id] = finding["finding_id"]
        for evidence_index, evidence in enumerate(relabeled["evidence_references"]):
            evidence["evidence_reference_id"] = f"renamed-evidence-{evidence_index}"
            evidence["finding_id"] = finding_ids[evidence["finding_id"]]
            evidence["subject_id"] = subject_ids[evidence["subject_id"]]
            evidence["snippet"] = f"renamed snippet {evidence_index}"

        # When / Then
        self.assertEqual(graph_template_digest(task), graph_template_digest(relabeled))
        self.assertEqual(manifest_structure_digest(task), manifest_structure_digest(relabeled))

    def test_identity_free_digests_cover_each_model_visible_structure_field(self) -> None:
        # Given
        task = materialize_task(copy.deepcopy(fixture("dp-development-01")["source"]))
        topology_mutations: list[tuple[str, dict[str, Any]]] = []
        relationship_changed = copy.deepcopy(task)
        relationship_changed["findings"][0]["dependency_paths"][0]["relationship"] = "transitive"
        topology_mutations.append(("relationship", relationship_changed))
        scope_changed = copy.deepcopy(task)
        scope_changed["findings"][0]["dependency_paths"][0]["runtime_scope"] = "development_only"
        topology_mutations.append(("runtime_scope", scope_changed))
        path_count_changed = copy.deepcopy(task)
        extra_path = copy.deepcopy(path_count_changed["findings"][0]["dependency_paths"][0])
        extra_path["path_id"] = "renamed-extra-path"
        path_count_changed["findings"][0]["dependency_paths"].append(extra_path)
        topology_mutations.append(("path_count", path_count_changed))

        manifest_mutations: list[tuple[str, dict[str, Any]]] = []
        for field, replacement in (
            ("affected_status", "unaffected"),
            ("reachability", "unreachable"),
            ("severity", "low"),
        ):
            changed = copy.deepcopy(task)
            changed["findings"][0][field] = replacement
            manifest_mutations.append((field, changed))
        evidence_changed = copy.deepcopy(task)
        evidence = evidence_changed["evidence_references"][0]
        evidence["subject_type"] = (
            "finding" if evidence["subject_type"] != "finding" else "dependency_path"
        )
        manifest_mutations.append(("evidence_subject_type", evidence_changed))
        for field, replacement in (
            ("availability", "unavailable"),
            ("affected_status", "affected"),
            ("compatibility", "incompatible"),
        ):
            changed = copy.deepcopy(task)
            changed["findings"][0]["remediation_options"][0][field] = replacement
            manifest_mutations.append((f"option_{field}", changed))

        # When / Then
        for field, changed in topology_mutations:
            with self.subTest(topology_field=field):
                self.assertNotEqual(graph_template_digest(task), graph_template_digest(changed))
        for field, changed in manifest_mutations:
            with self.subTest(manifest_field=field):
                self.assertEqual(graph_template_digest(task), graph_template_digest(changed))
                self.assertNotEqual(
                    manifest_structure_digest(task),
                    manifest_structure_digest(changed),
                )

    def test_unrelated_family_contract_rejects_each_unsupported_dimension_rule(self) -> None:
        # Given
        policy = _policy()
        mutations = (
            ("all_pair_dimensions", "all_pair_disjoint_dimensions", ["record_alias_components"]),
            ("cross_split_dimensions", "cross_split_disjoint_dimensions", ["generator_seeds"]),
            ("graph_digest", "graph_template_digest", "identity_free_source_structure"),
            ("manifest_digest", "manifest_digest", "identity_free_source_structure"),
            ("alias_identity", "record_alias_identity", "record_id"),
        )

        # When / Then
        for label, field, value in mutations:
            with self.subTest(rule=label):
                changed = copy.deepcopy(policy)
                changed["unrelated_family"][field] = value
                with self.assertRaisesRegex(ValueError, "unrelated-family policy is unsupported"):
                    validate_fixture_policy(changed)

    def test_unrelated_families_separate_packages_and_cross_split_content(self) -> None:
        # Given
        policy = _policy()
        left = FixtureFamilyFingerprint(
            split="development",
            project_packages=frozenset({"npm:left"}),
            record_alias_components=frozenset({"alias:left"}),
            graph_template_ids=frozenset({"graph:left"}),
            graph_template_digests=frozenset({"topology:left"}),
            generator_seeds=frozenset({"seed:left"}),
            manifest_digests=frozenset({"manifest:left"}),
        )
        right = FixtureFamilyFingerprint(
            split="development",
            project_packages=frozenset({"npm:right"}),
            record_alias_components=frozenset({"alias:right"}),
            graph_template_ids=frozenset({"graph:right"}),
            graph_template_digests=frozenset({"topology:right"}),
            generator_seeds=frozenset({"seed:right"}),
            manifest_digests=frozenset({"manifest:right"}),
        )
        family_dimensions = policy["unrelated_family"]["all_pair_disjoint_dimensions"]
        split_dimensions = policy["unrelated_family"]["cross_split_disjoint_dimensions"]

        # When / Then
        self.assertTrue(are_unrelated_families(left, right, policy))
        for dimension in family_dimensions:
            with self.subTest(dimension=dimension):
                overlapping = replace(right, **{dimension: getattr(left, dimension)})
                self.assertFalse(are_unrelated_families(left, overlapping, policy))
        for dimension in split_dimensions:
            with self.subTest(cross_split_dimension=dimension):
                same_split_overlap = replace(
                    right,
                    **{dimension: getattr(left, dimension)},
                )
                self.assertTrue(are_unrelated_families(left, same_split_overlap, policy))
                self.assertFalse(
                    are_unrelated_families(
                        left,
                        replace(same_split_overlap, split="sealed"),
                        policy,
                    )
                )

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
