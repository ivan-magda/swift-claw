from __future__ import annotations

import hashlib
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from typing import Any, ClassVar

from benchmark_core.canonical import dumps
from dependency_benchmark.advisory_records import (
    AdvisoryRecord,
    AdvisorySourceError,
    alias_components,
    fixed_versions,
    load_frozen_advisories,
    record_affects,
    semantic_receipt,
)

from support import ROOT


def _write_synthetic_source(root: Path, advisory: dict[str, Any]) -> None:
    repository_id = "github-advisory-database"
    prefix = Path("synthetic/sources")
    record_path = Path("advisories/GHSA-test.json")
    license_path = Path("LICENSE.md")
    record_bytes = dumps(advisory).encode("utf-8")
    license_bytes = b"synthetic license\n"
    record_snapshot = root / "snapshots" / repository_id / record_path
    license_snapshot = root / "snapshots" / repository_id / license_path
    record_snapshot.parent.mkdir(parents=True)
    license_snapshot.parent.mkdir(parents=True, exist_ok=True)
    record_snapshot.write_bytes(record_bytes)
    license_snapshot.write_bytes(license_bytes)
    provenance = {
        "schema_version": 1,
        "repositories": [
            {
                "repository_id": repository_id,
                "url": "https://example.invalid/advisories",
                "commit": "0" * 40,
                "license": {
                    "repository_path": str(license_path),
                    "snapshot_path": str(prefix / "snapshots" / repository_id / license_path),
                    "bytes": len(license_bytes),
                    "sha256": hashlib.sha256(license_bytes).hexdigest(),
                    "spdx_id": "CC-BY-4.0",
                },
            }
        ],
        "records": [
            {
                "record_id": "GHSA-test",
                "aliases": ["CVE-test"],
                "package": {"ecosystem": "npm", "name": "package"},
                "repository_id": repository_id,
                "repository_path": str(record_path),
                "snapshot_path": str(prefix / "snapshots" / repository_id / record_path),
                "bytes": len(record_bytes),
                "sha256": hashlib.sha256(record_bytes).hexdigest(),
            }
        ],
    }
    index = {
        "schema_version": 1,
        "fixtures": [],
        "provenance_path": str(prefix / "provenance.json"),
    }
    root.mkdir(exist_ok=True)
    (root / "index.json").write_text(dumps(index), encoding="utf-8")
    (root / "provenance.json").write_text(dumps(provenance), encoding="utf-8")


def _synthetic_advisory() -> dict[str, Any]:
    return {
        "id": "GHSA-test",
        "aliases": ["CVE-test"],
        "summary": "Synthetic advisory",
        "details": "Synthetic evidence",
        "severity": [
            {
                "type": "CVSS_V3",
                "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H",
            }
        ],
        "affected": [
            {
                "package": {"ecosystem": "npm", "name": "package"},
                "ranges": [
                    {
                        "type": "ECOSYSTEM",
                        "events": [{"introduced": "0"}, {"fixed": "1.2.3"}],
                    }
                ],
            }
        ],
    }


class DependencyAdvisoryRecordTests(unittest.TestCase):
    records: ClassVar[tuple[AdvisoryRecord, ...]]
    by_id: ClassVar[dict[str, AdvisoryRecord]]

    @classmethod
    def setUpClass(cls) -> None:
        cls.records = load_frozen_advisories(ROOT / "sources")
        cls.by_id = {record.record_id: record for record in cls.records}

    def test_frozen_sources_have_the_registered_semantic_receipt(self) -> None:
        # Given / When
        receipt = semantic_receipt(self.records)
        minimist = self.by_id["GHSA-xvch-5gv4-984h"]
        django = self.by_id["PYSEC-2022-190"]
        form_data = self.by_id["GHSA-fjxv-7rqg-78g4"]
        aiohttp = self.by_id["PYSEC-2024-24"]

        # Then
        self.assertEqual(
            receipt,
            {
                "schema_version": 1,
                "record_count": 27,
                "repository_counts": {
                    "github-advisory-database": 14,
                    "pypa-advisory-database": 13,
                },
                "total_bytes": 110253,
                "normalized_package_count": 26,
                "alias_component_count": 26,
                "affected_entry_count": 39,
                "ecosystem_interval_count": 42,
                "git_range_count": 3,
                "fixed_version_count": 42,
                "explicit_version_raw_count": 1873,
                "explicit_version_canonical_count": 1871,
                "cvss_type_counts": {"CVSS_V3": 23, "CVSS_V4": 7},
                "record_band_counts": {
                    "critical": 10,
                    "high": 10,
                    "missing": 1,
                    "moderate": 6,
                },
                "component_band_counts": {"critical": 10, "high": 10, "moderate": 6},
                "records_semantic_sha256": (
                    "d10a3f0e201a85815ad4e11137c6dec5cd76983ab43901899c1e50c745499b09"
                ),
                "alias_components_sha256": (
                    "cab748d32f95569a5d9c32c54dc02c32be318e4acbadd6158384ffbfdfcf4075"
                ),
            },
        )
        self.assertEqual(fixed_versions(minimist), ("0.2.4", "1.2.6"))
        self.assertEqual(minimist.summary, "Prototype Pollution in minimist")
        self.assertIn("1.2.6", minimist.details)
        self.assertTrue(record_affects(minimist, "1.2.5"))
        self.assertFalse(record_affects(minimist, "1.2.6"))
        self.assertEqual(django.package_name, "django")
        self.assertEqual(django.severity, None)
        self.assertEqual(len(django.explicit_versions), 45)
        self.assertEqual(form_data.cvss_vectors[0].kind, "CVSS_V4")
        self.assertEqual(form_data.severity, "critical")
        self.assertEqual(aiohttp.ignored_git_range_count, 1)

    def test_alias_closure_is_transitive_and_aggregates_component_severity(self) -> None:
        # Given
        base = self.by_id["GHSA-xvch-5gv4-984h"]
        records = (
            replace(base, record_id="A", aliases=("bridge-one",), severity="moderate"),
            replace(
                base,
                record_id="B",
                aliases=("A", "bridge-two"),
                severity=None,
            ),
            replace(base, record_id="C", aliases=("bridge-two",), severity="critical"),
        )

        # When
        components = alias_components(records)

        # Then
        self.assertEqual(len(components), 1)
        self.assertEqual(components[0].record_ids, ("A", "B", "C"))
        self.assertEqual(components[0].severity, "critical")
        with self.assertRaises(AdvisorySourceError):
            alias_components((*records[:2], replace(records[2], package_name="other")))
        with self.assertRaises(AdvisorySourceError):
            alias_components(tuple(replace(record, severity=None) for record in records))

    def test_loader_rejects_raw_catalog_and_osv_ambiguity(self) -> None:
        # Given
        invalid_advisories = []
        wrong_id = _synthetic_advisory()
        wrong_id["id"] = "GHSA-other"
        invalid_advisories.append(wrong_id)
        wrong_alias = _synthetic_advisory()
        wrong_alias["aliases"] = ["CVE-other"]
        invalid_advisories.append(wrong_alias)
        wrong_package = _synthetic_advisory()
        wrong_package["affected"][0]["package"]["name"] = "other"
        invalid_advisories.append(wrong_package)
        wrong_cvss = _synthetic_advisory()
        wrong_cvss["severity"][0]["score"] = (
            "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N"
        )
        invalid_advisories.append(wrong_cvss)
        noncanonical_cvss = _synthetic_advisory()
        noncanonical_cvss["severity"][0]["score"] = "CVSS:3.1/AC:L/AV:N/PR:N/UI:N/S:U/C:H/I:H/A:H"
        invalid_advisories.append(noncanonical_cvss)
        zero_cvss = _synthetic_advisory()
        zero_cvss["severity"][0]["score"] = "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N"
        invalid_advisories.append(zero_cvss)
        wrong_event = _synthetic_advisory()
        wrong_event["affected"][0]["ranges"][0]["events"][1] = {"last_affected": "1.2.2"}
        invalid_advisories.append(wrong_event)

        # When / Then
        for index, advisory in enumerate(invalid_advisories):
            with self.subTest(case=index), tempfile.TemporaryDirectory() as directory:
                source_root = Path(directory) / "sources"
                _write_synthetic_source(source_root, advisory)
                with self.assertRaises(AdvisorySourceError):
                    load_frozen_advisories(source_root)


if __name__ == "__main__":
    unittest.main()
