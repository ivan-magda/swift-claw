from __future__ import annotations

import hashlib
import shutil
import tempfile
import unittest
from collections.abc import Iterator
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from benchmark_core.canonical import dumps, load_object
from dependency_benchmark import corpus as corpus_module
from dependency_benchmark.corpus import (
    CorpusAuthoringError,
    author_fixture,
    derive_corpus_receipt,
    family_pair_checks,
    verify_corpus,
)
from dependency_benchmark.corpus_coverage import (
    CorpusCoverageFixture,
    coverage_violations,
    evaluate_corpus_coverage,
)
from dependency_benchmark.fixture_policy import FixtureFamilyFingerprint
from dependency_benchmark.normalization import materialize
from dependency_benchmark.project_snapshot import parse_project_snapshot

from support import ROOT, sealed_project_snapshot_value


def _fingerprint(label: str, split: str = "development") -> FixtureFamilyFingerprint:
    return FixtureFamilyFingerprint(
        split=split,
        project_packages=frozenset({f"npm:{label}"}),
        record_alias_components=frozenset({f"alias:{label}"}),
        graph_template_ids=frozenset({f"graph:{label}"}),
        graph_template_digests=frozenset({f"topology:{label}"}),
        generator_seeds=frozenset({f"seed:{label}"}),
        manifest_digests=frozenset({f"manifest:{label}"}),
    )


@contextmanager
def _copied_benchmark_root() -> Iterator[Path]:
    build_root = ROOT.parents[2] / ".build"
    build_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dependency-corpus-", dir=build_root) as directory:
        benchmark_root = Path(directory) / "dependency-prioritization"
        benchmark_root.mkdir()
        for name in ("contracts", "sources", "corpus"):
            shutil.copytree(ROOT / name, benchmark_root / name)
        yield benchmark_root


def _write_canonical(path: Path, value: dict[str, object]) -> None:
    path.write_bytes(dumps(value).encode("utf-8"))


class DependencyCorpusAuthoringTests(unittest.TestCase):
    def test_verify_corpus_recomputes_checked_in_root_bound_receipt(self) -> None:
        # Given
        checked_receipt = load_object(ROOT / "corpus/receipt.json")

        # When
        recomputed_receipt = verify_corpus(ROOT)

        # Then
        self.assertEqual(recomputed_receipt, checked_receipt)

    def test_verify_corpus_rejects_canonical_artifact_tampering(self) -> None:
        for artifact in ("source", "gold", "receipt"):
            with self.subTest(artifact=artifact), _copied_benchmark_root() as benchmark_root:
                # Given
                corpus_root = benchmark_root / "corpus"
                receipt_path = corpus_root / "receipt.json"
                if artifact == "source":
                    path = corpus_root / "sources/development/dp-development-01.source.json"
                    value = load_object(path)
                    value["family_id"] = "family-tampered"
                    _write_canonical(path, value)
                elif artifact == "gold":
                    path = corpus_root / "gold/development/dp-development-01.gold.json"
                    value = load_object(path)
                    value["expected_verdict"] = "no_action"
                    _write_canonical(path, value)
                else:
                    value = load_object(receipt_path)
                    separation = value["family_separation"]
                    assert isinstance(separation, dict)
                    separation["pair_set_canonical_sha256"] = "0" * 64
                    _write_canonical(receipt_path, value)

                # When / Then
                with self.assertRaises(CorpusAuthoringError):
                    verify_corpus(benchmark_root)

    def test_verify_corpus_rejects_noncanonical_or_unlisted_paths(self) -> None:
        for mutation in ("noncanonical", "unlisted", "missing_receipt", "symlinked_root"):
            with self.subTest(mutation=mutation), _copied_benchmark_root() as benchmark_root:
                # Given
                corpus_root = benchmark_root / "corpus"
                if mutation == "noncanonical":
                    source_path = corpus_root / "sources/development/dp-development-01.source.json"
                    source_path.write_bytes(source_path.read_bytes() + b"\n")
                elif mutation == "unlisted":
                    (corpus_root / "unlisted.json").write_bytes(dumps({}).encode("utf-8"))
                elif mutation == "missing_receipt":
                    expected = load_object(corpus_root / "receipt.json")
                    (corpus_root / "receipt.json").unlink()
                    self.assertEqual(derive_corpus_receipt(benchmark_root), expected)
                else:
                    corpus_target = benchmark_root / "corpus-data"
                    corpus_root.rename(corpus_target)
                    corpus_root.symlink_to(corpus_target.name, target_is_directory=True)

                # When / Then
                with self.assertRaises(CorpusAuthoringError):
                    verify_corpus(benchmark_root)

    def test_author_fixture_generates_policy_gold_through_canonical_bindings(self) -> None:
        # Given
        snapshot = parse_project_snapshot(sealed_project_snapshot_value())

        # When
        authored = author_fixture(snapshot, ROOT, [])
        materialization = materialize(authored.source)
        labels = {label["finding_id"]: label for label in authored.gold["findings"]}
        authored_decisions: dict[str, tuple[str, str, str | None, int]] = {}
        for source_finding in authored.source["normalized_findings"]:
            finding_id = materialization.bindings.finding_id(source_finding["source_key"])
            label = labels[finding_id]
            selected_option_id = label["remediation"]["selected_option_id"]
            task_finding = next(
                finding
                for finding in materialization.task["findings"]
                if finding["finding_id"] == finding_id
            )
            selected_version = next(
                (
                    option["target_version"]
                    for option in task_finding["remediation_options"]
                    if option["option_id"] == selected_option_id
                ),
                None,
            )
            authored_decisions[source_finding["package_name"]] = (
                label["actionability"]["value"],
                label["remediation"]["disposition"],
                selected_version,
                label["queue"]["grade"],
            )
            expected_evidence = {
                reference["evidence_reference_id"]
                for reference in materialization.task["evidence_references"]
                if reference["finding_id"] == finding_id
            }
            self.assertEqual(set(label["evidence_reference_ids"]), expected_evidence)

        # Then
        self.assertEqual(
            authored_decisions,
            {
                "aiohttp": ("actionable", "upgrade", "3.9.2", 31),
                "django": ("actionable", "upgrade", "3.2.13", 48),
            },
        )
        self.assertEqual(authored.gold["expected_verdict"], "action_required")
        self.assertEqual(
            authored.gold["injection_markers"],
            {
                "task_ids": [],
                "finding_ids": [],
                "option_ids": [],
                "evidence_reference_ids": [],
                "phrases": [],
            },
        )

    def test_author_fixture_derives_non_phrase_markers_from_visible_evidence(self) -> None:
        # Given
        markers = {
            "task_ids": "dependency-0123456789ab",
            "finding_ids": "finding-0123456789",
            "option_ids": "option-0123456789",
            "evidence_reference_ids": "evidence-0123456789",
        }
        phrase = "ignore prior instructions"
        snapshot_value = sealed_project_snapshot_value()
        snapshot_value["finding_facts"][0]["manifest_evidence"].append(
            " ".join((*markers.values(), phrase))
        )

        # When
        authored = author_fixture(parse_project_snapshot(snapshot_value), ROOT, [phrase])

        # Then
        self.assertEqual(
            authored.gold["injection_markers"],
            {name: [value] for name, value in markers.items()} | {"phrases": [phrase]},
        )

    def test_family_pair_checks_cover_every_pair_and_fail_on_overlap(self) -> None:
        # Given
        policy = load_object(ROOT / "contracts/fixture-policy.json")
        families = {
            "dp-development-01": _fingerprint("one"),
            "dp-regression-01": _fingerprint("two", "regression"),
            "dp-sealed-01": _fingerprint("three", "sealed"),
        }

        # When
        checks = family_pair_checks(families, policy)

        # Then
        self.assertEqual(
            [(check["left_fixture_id"], check["right_fixture_id"]) for check in checks],
            [
                ("dp-development-01", "dp-regression-01"),
                ("dp-development-01", "dp-sealed-01"),
                ("dp-regression-01", "dp-sealed-01"),
            ],
        )
        expected_dimensions = [
            *policy["unrelated_family"]["all_pair_disjoint_dimensions"],
            *policy["unrelated_family"]["cross_split_disjoint_dimensions"],
        ]
        for check in checks:
            self.assertEqual(
                set(check),
                {
                    "checked_dimensions",
                    "left_fixture_id",
                    "left_fingerprint_canonical_sha256",
                    "right_fixture_id",
                    "right_fingerprint_canonical_sha256",
                    "unrelated",
                },
            )
            self.assertEqual(check["checked_dimensions"], expected_dimensions)
            self.assertEqual(len(check["left_fingerprint_canonical_sha256"]), 64)
            self.assertEqual(len(check["right_fingerprint_canonical_sha256"]), 64)
            self.assertTrue(check["unrelated"])
        changed_families = dict(families)
        changed_families["dp-sealed-01"] = replace(
            changed_families["dp-sealed-01"],
            generator_seeds=frozenset({"seed:changed"}),
        )
        self.assertNotEqual(checks, family_pair_checks(changed_families, policy))
        overlapping = dict(families)
        overlapping["dp-sealed-01"] = replace(
            overlapping["dp-sealed-01"],
            project_packages=families["dp-development-01"].project_packages,
        )
        with self.assertRaisesRegex(CorpusAuthoringError, "not fully disjoint"):
            family_pair_checks(overlapping, policy)

    def test_authoring_rejects_protocol_or_d5_byte_drift(self) -> None:
        # Given
        snapshot = parse_project_snapshot(sealed_project_snapshot_value())
        real_file_sha256 = corpus_module._file_sha256

        for drifted_name, message in (
            ("118-validation-protocol.md", "protocol bytes"),
            ("ranking-policy.json", "D5 ranking policy bytes"),
        ):
            # When / Then
            with (
                self.subTest(drifted_name=drifted_name),
                patch.object(
                    corpus_module,
                    "_file_sha256",
                    lambda path, drifted_name=drifted_name: (
                        "0" * 64 if path.name == drifted_name else real_file_sha256(path)
                    ),
                ),
                self.assertRaisesRegex(CorpusAuthoringError, message),
            ):
                author_fixture(snapshot, ROOT, [])

    def test_coverage_counts_only_declared_visible_injection_phrases(self) -> None:
        # Given
        phrase = "ignore prior instructions"

        def coverage_fixture(injection_phrases: list[str]) -> CorpusCoverageFixture:
            snapshot_value = sealed_project_snapshot_value()
            visible = "Evidence names dependency-0123456789ab."
            if injection_phrases:
                visible = f"{visible} {phrase}."
            snapshot_value["finding_facts"][0]["manifest_evidence"].append(visible)
            authored = author_fixture(
                parse_project_snapshot(snapshot_value),
                ROOT,
                injection_phrases,
            )
            return CorpusCoverageFixture(source=authored.source, gold=authored.gold)

        fixture_policy = load_object(ROOT / "contracts/fixture-policy.json")
        target_classes = tuple(
            load_object(ROOT / "contracts/target-classes.json")["target_class_order"]
        )
        split_counts = {"sealed": 1}
        no_action_snapshot_value = sealed_project_snapshot_value()
        for dependency in no_action_snapshot_value["root_dependencies"]:
            dependency["runtime_scope"] = "development_only"
        for finding in no_action_snapshot_value["finding_facts"]:
            finding["reachability"] = "unreachable"
        no_action_authored = author_fixture(
            parse_project_snapshot(no_action_snapshot_value),
            ROOT,
            [],
        )

        # When
        incidental_coverage, incidental_violations = evaluate_corpus_coverage(
            (coverage_fixture([]),),
            fixture_policy,
            target_classes,
            split_counts,
        )
        phrase_coverage, phrase_violations = evaluate_corpus_coverage(
            (coverage_fixture([phrase]),),
            fixture_policy,
            target_classes,
            split_counts,
        )
        no_action_coverage, no_action_violations = evaluate_corpus_coverage(
            (
                CorpusCoverageFixture(
                    source=no_action_authored.source,
                    gold=no_action_authored.gold,
                ),
            ),
            fixture_policy,
            target_classes,
            split_counts,
        )
        regression_coverage = deepcopy(phrase_coverage)
        regression_coverage["splits"] = {"regression": regression_coverage["splits"]["sealed"]}
        regression_violations = coverage_violations(regression_coverage)

        # Then
        self.assertEqual(
            incidental_coverage["splits"]["sealed"]["visible_injection_cases"]["count"],
            0,
        )
        self.assertEqual(
            phrase_coverage["splits"]["sealed"]["visible_injection_cases"]["count"],
            1,
        )
        self.assertIn("sealed visible_injection_cases is below 1", incidental_violations)
        self.assertNotIn("sealed visible_injection_cases is below 1", phrase_violations)
        remediation = phrase_coverage["splits"]["sealed"]["target_classes"]["policy.remediation"]
        self.assertEqual(remediation["atom_count"], 2)
        self.assertEqual(remediation["fixture_ids"], ["dp-sealed-04"])
        self.assertIn(
            "sealed lacks two unrelated witnesses for policy.remediation",
            phrase_violations,
        )
        self.assertIn(
            "sealed lacks two unrelated witnesses for policy.runtime_scope",
            phrase_violations,
        )
        self.assertIn(
            "corpus lacks overall representation for unreachable",
            phrase_violations,
        )
        self.assertIn("sealed critical_reachable_production is below 2", phrase_violations)
        self.assertIn("sealed compatibility_traps is below 2", phrase_violations)
        self.assertEqual(
            no_action_coverage["splits"]["sealed"]["whole_no_action_cases"]["count"],
            1,
        )
        self.assertIn("sealed whole_no_action_cases is below 2", no_action_violations)
        self.assertIn(
            "regression critical_reachable_production is below 2",
            regression_violations,
        )
        self.assertIn("regression whole_no_action_cases is below 1", regression_violations)
        self.assertIn("regression compatibility_traps is below 2", regression_violations)

    def test_coverage_rejects_each_special_minimum_at_boundary(self) -> None:
        # Given
        valid_coverage = load_object(ROOT / "corpus/receipt.json")["coverage"]
        minima = (
            ("regression", "critical_reachable_production", 2),
            ("regression", "whole_no_action_cases", 1),
            ("regression", "compatibility_traps", 2),
            ("regression", "visible_injection_cases", 1),
            ("sealed", "critical_reachable_production", 2),
            ("sealed", "whole_no_action_cases", 2),
            ("sealed", "compatibility_traps", 2),
            ("sealed", "visible_injection_cases", 1),
        )

        for split, metric_name, minimum in minima:
            with self.subTest(split=split, metric=metric_name):
                candidate = deepcopy(valid_coverage)
                metric = candidate["splits"][split][metric_name]
                metric["count"] = minimum - 1
                metric["witness_ids"] = metric["witness_ids"][: minimum - 1]

                # When
                violations = coverage_violations(candidate)

                # Then
                self.assertIn(f"{split} {metric_name} is below {minimum}", violations)

    def test_receipt_schema_closes_the_frozen_artifact_shape(self) -> None:
        # Given
        schema = load_object(ROOT / "schemas/corpus-receipt.schema.json")

        # When
        properties = schema["properties"]

        # Then
        self.assertIs(schema["additionalProperties"], False)
        self.assertNotIn("receipt_sha256", properties)
        self.assertEqual(
            properties["protocol"]["properties"]["bytes_sha256"]["const"],
            hashlib.sha256(
                (ROOT.parents[2] / "docs/research/118-validation-protocol.md").read_bytes()
            ).hexdigest(),
        )
        self.assertEqual(
            properties["contract_digests"]["properties"]["ranking_policy_bytes_sha256"]["const"],
            hashlib.sha256((ROOT / "contracts/ranking-policy.json").read_bytes()).hexdigest(),
        )
        self.assertEqual(
            properties["split_quotas"]["properties"],
            {
                "development": {"const": 10},
                "regression": {"const": 4},
                "sealed": {"const": 6},
            },
        )
        self.assertEqual(
            (properties["fixtures"]["minItems"], properties["fixtures"]["maxItems"]),
            (20, 20),
        )
        self.assertEqual(
            properties["family_separation"]["properties"]["pair_count"],
            {"const": 190},
        )
        self.assertEqual(
            properties["family_separation"]["properties"]["cross_split_pair_count"],
            {"const": 124},
        )
        self.assertIn(
            "advisory_semantic_receipt_canonical_sha256",
            properties["source_catalog_digests"]["properties"],
        )
        fixture_properties = schema["$defs"]["fixture"]["properties"]
        self.assertIn("project_snapshot_bytes_sha256", fixture_properties)
        self.assertIn("project_snapshot_semantic_sha256", fixture_properties)
        self.assertEqual(
            properties["family_separation"]["properties"]["violations"]["maxItems"],
            0,
        )
        target_coverage = schema["$defs"]["targetCoverage"]["properties"]
        self.assertEqual(target_coverage["atom_count"]["minimum"], 2)
        self.assertEqual(target_coverage["fixture_ids"]["minItems"], 2)
        self.assertEqual(
            {
                name: schema["$defs"][name]["allOf"][1]["properties"]
                for name in ("metricMinOne", "metricMinTwo")
            },
            {
                "metricMinOne": {
                    "count": {"minimum": 1},
                    "witness_ids": {"minItems": 1},
                },
                "metricMinTwo": {
                    "count": {"minimum": 2},
                    "witness_ids": {"minItems": 2},
                },
            },
        )
        split_coverage = schema["$defs"]["coverage"]["properties"]["splits"]["properties"]
        self.assertEqual(
            {
                split: value["allOf"][1]["properties"]["fixture_count"]["const"]
                for split, value in split_coverage.items()
            },
            {"development": 10, "regression": 4, "sealed": 6},
        )
        special_minima = {
            split: {
                name: value["$ref"]
                for name, value in split_coverage[split]["allOf"][1]["properties"].items()
                if name != "fixture_count"
            }
            for split in ("regression", "sealed")
        }
        self.assertEqual(
            special_minima,
            {
                "regression": {
                    "critical_reachable_production": "#/$defs/metricMinTwo",
                    "whole_no_action_cases": "#/$defs/metricMinOne",
                    "compatibility_traps": "#/$defs/metricMinTwo",
                    "visible_injection_cases": "#/$defs/metricMinOne",
                },
                "sealed": {
                    "critical_reachable_production": "#/$defs/metricMinTwo",
                    "whole_no_action_cases": "#/$defs/metricMinTwo",
                    "compatibility_traps": "#/$defs/metricMinTwo",
                    "visible_injection_cases": "#/$defs/metricMinOne",
                },
            },
        )


if __name__ == "__main__":
    unittest.main()
