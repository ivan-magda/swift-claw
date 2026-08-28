from __future__ import annotations

import copy
import hashlib
import shutil
import tempfile
import unittest
from pathlib import Path

from benchmark_core.canonical import dumps, load_object
from dependency_benchmark.derivation import (
    DependencyDerivationError,
    derive_normalized_source,
)
from dependency_benchmark.fixture_policy import (
    FixtureFamilyFingerprint,
    derive_remediation,
    graph_template_digest,
    manifest_structure_digest,
)
from dependency_benchmark.normalization import materialize
from dependency_benchmark.project_snapshot import parse_project_snapshot
from dependency_benchmark.versioning import compare_versions

from support import ROOT, sealed_project_snapshot_value


class DependencyDerivationTests(unittest.TestCase):
    def test_derivation_joins_complete_aliases_and_binds_deterministic_options(self) -> None:
        # Given
        snapshot = parse_project_snapshot(sealed_project_snapshot_value())

        # When
        derived = derive_normalized_source(snapshot, ROOT / "sources")
        source_finding = next(
            finding
            for finding in derived.source["normalized_findings"]
            if finding["package_name"] == "django"
        )
        materialization = materialize(derived.source)
        task_finding_id = materialization.bindings.finding_id(source_finding["source_key"])
        task_finding = next(
            finding
            for finding in materialization.task["findings"]
            if finding["finding_id"] == task_finding_id
        )
        options_by_version = {
            option["target_version"]: option for option in source_finding["remediation_options"]
        }

        # Then
        self.assertEqual(source_finding["affected_status"], "affected")
        self.assertEqual(
            source_finding["advisories"],
            [
                {"advisory_id": "GHSA-2gwj-7jmv-h26r", "severity": "critical"},
                {"advisory_id": "PYSEC-2022-190", "severity": None},
            ],
        )
        self.assertEqual(
            set(options_by_version),
            {"2.2.28", "3.2.13", "3.2.14", "4.0", "4.0.4"},
        )
        self.assertEqual(
            {
                key: options_by_version["3.2.13"][key]
                for key in ("availability", "affected_status", "compatibility")
            },
            {
                "availability": "available",
                "affected_status": "unaffected",
                "compatibility": "compatible",
            },
        )
        self.assertEqual(options_by_version["4.0"]["affected_status"], "affected")
        self.assertEqual(options_by_version["4.0.4"]["compatibility"], "incompatible")
        self.assertEqual(task_finding["severity"], "critical")
        candidates = derived.remediation_candidates_by_finding[source_finding["source_key"]]
        remediation = derive_remediation(
            "actionable",
            source_finding["installed_version"],
            list(candidates),
            lambda left, right: compare_versions(snapshot.ecosystem, left, right),
            load_object(ROOT / "contracts/fixture-policy.json"),
        )
        selected_source_key = remediation["selected_source_key"]
        if selected_source_key is None:
            self.fail("expected the retained candidates to select a remediation source key")
        self.assertEqual(
            [
                (candidate["origin_id"], candidate["source_key"] == selected_source_key)
                for candidate in candidates
                if candidate["target_version"] == "3.2.13"
            ],
            [
                ("GHSA-2gwj-7jmv-h26r", True),
                ("PYSEC-2022-190", False),
                ("release-inventory", False),
            ],
        )
        selected_option_id = materialization.bindings.option_id(
            source_finding["source_key"], selected_source_key
        )
        selected_option = next(
            option
            for option in task_finding["remediation_options"]
            if option["option_id"] == selected_option_id
        )
        self.assertEqual(
            {
                key: selected_option[key]
                for key in (
                    "target_version",
                    "availability",
                    "affected_status",
                    "compatibility",
                )
            },
            {
                "target_version": "3.2.13",
                "availability": "available",
                "affected_status": "unaffected",
                "compatibility": "compatible",
            },
        )
        self.assertEqual(derived.snapshot_sha256, snapshot.semantic_sha256)
        self.assertEqual(
            derived.selected_record_ids,
            ("GHSA-2gwj-7jmv-h26r", "PYSEC-2022-190", "PYSEC-2024-24"),
        )
        self.assertEqual(
            derived.family_fingerprint,
            FixtureFamilyFingerprint(
                split="sealed",
                project_packages=frozenset(
                    {
                        "pypi:aiohttp",
                        "pypi:django",
                        "pypi:fixture-app",
                        "pypi:fixture-helper",
                    }
                ),
                record_alias_components=frozenset(
                    {"alias-component-33477110112e", "alias-component-b0787ec317c8"}
                ),
                graph_template_ids=frozenset({"diamond-paths"}),
                graph_template_digests=frozenset({graph_template_digest(materialization.task)}),
                generator_seeds=frozenset({"django-seed"}),
                manifest_digests=frozenset({manifest_structure_digest(materialization.task)}),
            ),
        )
        changed_value = copy.deepcopy(sealed_project_snapshot_value())
        changed_value["finding_facts"][0]["manifest_evidence"] = ["Different frozen evidence."]
        changed_snapshot = derive_normalized_source(
            parse_project_snapshot(changed_value),
            ROOT / "sources",
        )
        self.assertNotEqual(derived.source["task_id"], changed_snapshot.source["task_id"])
        with tempfile.TemporaryDirectory() as directory:
            copied_sources = shutil.copytree(ROOT / "sources", Path(directory) / "sources")
            provenance_path = copied_sources / "provenance.json"
            provenance = load_object(provenance_path)
            record = next(
                item for item in provenance["records"] if item["record_id"] == "GHSA-2gwj-7jmv-h26r"
            )
            source_path = copied_sources / record["snapshot_path"].split("/sources/", 1)[1]
            source = load_object(source_path)
            source["summary"] = "Authenticated changed advisory evidence."
            source_path.write_text(dumps(source), encoding="utf-8")
            raw_source = source_path.read_bytes()
            record["bytes"] = len(raw_source)
            record["sha256"] = hashlib.sha256(raw_source).hexdigest()
            provenance_path.write_text(dumps(provenance), encoding="utf-8")
            changed_provenance = derive_normalized_source(snapshot, copied_sources)
        self.assertNotEqual(derived.source["task_id"], changed_provenance.source["task_id"])

    def test_safe_equivalent_candidate_preserves_materialization_binding(self) -> None:
        # Given
        value = sealed_project_snapshot_value()
        value["root_dependencies"][0]["requirement"] = ">=3.2,<3.3,!=3.2.13"
        value["dependency_edges"][0]["requirement"] = ">=3.2,<3.3,!=3.2.13"
        releases = value["release_inventories"][0]["releases"]
        releases[1]["availability"] = "unavailable"
        releases.append({"version": "3.2.14.0", "availability": "available"})
        snapshot = parse_project_snapshot(value)
        derived = derive_normalized_source(snapshot, ROOT / "sources")
        finding = next(
            finding
            for finding in derived.source["normalized_findings"]
            if finding["package_name"] == "django"
        )
        candidates = derived.remediation_candidates_by_finding[finding["source_key"]]

        # When
        remediation = derive_remediation(
            "actionable",
            finding["installed_version"],
            list(candidates),
            lambda left, right: compare_versions(snapshot.ecosystem, left, right),
            load_object(ROOT / "contracts/fixture-policy.json"),
        )
        selected_source_key = remediation["selected_source_key"]
        if selected_source_key is None:
            self.fail("expected an available compatible equivalent candidate")
        materialization = materialize(derived.source)
        selected_option_id = materialization.bindings.option_id(
            finding["source_key"],
            selected_source_key,
        )
        selected_candidate = next(
            candidate for candidate in candidates if candidate["source_key"] == selected_source_key
        )
        task_finding_id = materialization.bindings.finding_id(finding["source_key"])
        task_finding = next(
            item
            for item in materialization.task["findings"]
            if item["finding_id"] == task_finding_id
        )

        # Then
        self.assertEqual(
            (
                selected_candidate["target_version"],
                selected_option_id
                in {option["option_id"] for option in task_finding["remediation_options"]},
            ),
            ("3.2.14.0", True),
        )

    def test_catalog_allocation_and_selected_package_closure_fail_closed(self) -> None:
        # Given
        swapped_allocation = sealed_project_snapshot_value()
        swapped_allocation["fixture_id"] = "dp-sealed-05"
        orphan_inventory = sealed_project_snapshot_value()
        orphan_inventory["dependencies"] = [
            item for item in orphan_inventory["dependencies"] if item["node_key"] != "aiohttp"
        ]
        orphan_inventory["root_dependencies"] = [
            item
            for item in orphan_inventory["root_dependencies"]
            if item["child_node_key"] != "aiohttp"
        ]
        orphan_inventory["finding_facts"] = [
            item for item in orphan_inventory["finding_facts"] if item["node_key"] != "aiohttp"
        ]

        # When / Then
        for label, value in (
            ("same-ecosystem fixture allocation", swapped_allocation),
            ("selected package missing from graph", orphan_inventory),
        ):
            with (
                self.subTest(invalid_binding=label),
                self.assertRaisesRegex(
                    DependencyDerivationError,
                    "selected-advisory packages must all exist",
                ),
            ):
                derive_normalized_source(
                    parse_project_snapshot(value),
                    ROOT / "sources",
                )


if __name__ == "__main__":
    unittest.main()
