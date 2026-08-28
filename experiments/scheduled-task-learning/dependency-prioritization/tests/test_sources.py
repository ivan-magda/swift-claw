from __future__ import annotations

import re
import shutil
import tempfile
import unittest
from collections import Counter
from pathlib import Path

from benchmark_core.canonical import dumps, load_object
from dependency_benchmark.advisory_records import (
    AdvisorySourceError,
    verify_frozen_source_catalog,
)

from support import ROOT


class DependencySourceIntegrityTests(unittest.TestCase):
    def test_source_index_uses_the_core_fixture_identity_contract(self) -> None:
        # Given
        index = load_object(ROOT / "sources/index.json")
        source_schema = load_object(ROOT / "schemas/source.schema.json")
        gold_schema = load_object(ROOT / "schemas/gold.schema.json")
        source_pattern = source_schema["properties"]["fixture_id"]["pattern"]
        gold_pattern = gold_schema["properties"]["fixture_id"]["pattern"]
        expected_ids = {
            "development": [f"dp-development-{ordinal:02d}" for ordinal in range(1, 11)],
            "regression": [f"dp-regression-{ordinal:02d}" for ordinal in range(1, 5)],
            "sealed": [f"dp-sealed-{ordinal:02d}" for ordinal in range(1, 7)],
        }

        # When
        indexed_ids = {
            split: [
                fixture["fixture_id"] for fixture in index["fixtures"] if fixture["split"] == split
            ]
            for split in expected_ids
        }

        # Then
        self.assertEqual(source_pattern, gold_pattern)
        self.assertEqual(indexed_ids, expected_ids)
        for fixture_id in (fixture["fixture_id"] for fixture in index["fixtures"]):
            with self.subTest(fixture_id=fixture_id):
                self.assertIsNotNone(re.fullmatch(source_pattern, fixture_id))

    def test_frozen_source_files_match_their_canonical_catalog(self) -> None:
        # Given
        index_path = ROOT / "sources/index.json"
        provenance_path = ROOT / "sources/provenance.json"
        index = load_object(index_path)
        provenance = load_object(provenance_path)

        # When
        verify_frozen_source_catalog(ROOT / "sources")

        # Then
        for catalog_path, catalog in ((index_path, index), (provenance_path, provenance)):
            with self.subTest(catalog_path=catalog_path):
                self.assertEqual(catalog_path.read_text(encoding="utf-8"), dumps(catalog))
        for mutation in ("bytes", "sha256", "closure", "catalog_symlink"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                copied_sources = shutil.copytree(ROOT / "sources", Path(directory) / "sources")
                if mutation == "bytes":
                    record = provenance["records"][0]
                    snapshot = copied_sources / record["snapshot_path"].split("/sources/", 1)[1]
                    snapshot.write_bytes(snapshot.read_bytes() + b"\n")
                elif mutation == "sha256":
                    record = provenance["records"][0]
                    snapshot = copied_sources / record["snapshot_path"].split("/sources/", 1)[1]
                    content = snapshot.read_bytes()
                    snapshot.write_bytes(bytes([content[0] ^ 1]) + content[1:])
                elif mutation == "closure":
                    (copied_sources / "snapshots/orphan").write_text("orphan", encoding="utf-8")
                else:
                    index_copy = copied_sources / "index-copy.json"
                    (copied_sources / "index.json").rename(index_copy)
                    (copied_sources / "index.json").symlink_to(index_copy)
                with self.assertRaises(AdvisorySourceError):
                    verify_frozen_source_catalog(copied_sources)

    def test_source_index_preserves_the_exact_record_allocation(self) -> None:
        # Given
        index = load_object(ROOT / "sources/index.json")
        provenance = load_object(ROOT / "sources/provenance.json")
        expected_allocation = {
            "dp-development-01": ["GHSA-4hjh-wcwx-xvwj", "GHSA-cxjh-pqwp-8mfp"],
            "dp-development-02": ["GHSA-xvch-5gv4-984h"],
            "dp-development-03": ["GHSA-72xf-g2v4-qvf3"],
            "dp-development-04": ["GHSA-grv7-fg5c-xmjg"],
            "dp-development-05": ["GHSA-qwph-4952-7xr6"],
            "dp-development-06": ["PYSEC-2023-212", "PYSEC-2026-1873"],
            "dp-development-07": ["PYSEC-2026-1794"],
            "dp-development-08": ["PYSEC-2023-254"],
            "dp-development-09": ["PYSEC-2026-1918"],
            "dp-development-10": ["PYSEC-2026-1975"],
            "dp-regression-01": ["GHSA-4w2j-2rg4-5mjw", "GHSA-3h5v-q93c-6h6q"],
            "dp-regression-02": ["GHSA-fjxv-7rqg-78g4"],
            "dp-regression-03": ["PYSEC-2026-2222", "PYSEC-2026-1473"],
            "dp-regression-04": ["PYSEC-2026-366"],
            "dp-sealed-01": ["GHSA-23hp-3jrh-7fpw", "GHSA-c2qf-rxjj-qqgw"],
            "dp-sealed-02": ["GHSA-66mm-25pp-rfff"],
            "dp-sealed-03": ["GHSA-rg76-677x-56q9"],
            "dp-sealed-04": [
                "GHSA-2gwj-7jmv-h26r",
                "PYSEC-2022-190",
                "PYSEC-2024-24",
            ],
            "dp-sealed-05": ["PYSEC-2026-226"],
            "dp-sealed-06": ["PYSEC-2023-138"],
        }

        # When
        actual_allocation = {
            fixture["fixture_id"]: fixture["record_ids"] for fixture in index["fixtures"]
        }
        allocation_counts = Counter(
            record_id for record_ids in actual_allocation.values() for record_id in record_ids
        )
        provenance_ids = {record["record_id"] for record in provenance["records"]}

        # Then
        self.assertEqual(actual_allocation, expected_allocation)
        self.assertEqual(set(allocation_counts), provenance_ids)
        self.assertTrue(all(count == 1 for count in allocation_counts.values()))


if __name__ == "__main__":
    unittest.main()
