from __future__ import annotations

import unittest

from page_benchmark.canonical import dumps, load_object
from page_benchmark.scorer import score
from page_benchmark.validation import SUCCESSFUL_FILE_READ_EVENT
from path_test_support import PAGE_ROOT as ROOT

VALID_TOOL = [dict(SUCCESSFUL_FILE_READ_EVENT)]


def _attempt(output: dict) -> dict:
    return {
        "runtime_outcome": "completed",
        "raw_output": dumps(output).rstrip("\n"),
        "tool_events": VALID_TOOL,
    }


class ScorerSemanticTests(unittest.TestCase):
    def test_evidence_is_order_independent_and_accepts_nonempty_exact_substrings(self) -> None:
        # Given
        source = load_object(ROOT / "sources/sealed/pc-sealed-01.source.json")
        gold = load_object(ROOT / "gold/sealed/pc-sealed-01.gold.json")
        material = [atom for atom in gold["atoms"] if atom["kind"] == "material"]
        noise = [atom for atom in gold["atoms"] if atom["kind"] == "noise"]
        output = {
            "schema_version": 1,
            "task_id": gold["task_id"],
            "verdict": "material",
            "material_region_ids": [atom["region_id"] for atom in material],
            "ignored_region_ids": [atom["region_id"] for atom in noise],
            "evidence": [
                {"region_id": material[1]["region_id"], "before": "12 months", "after": "24 months"},
                {"region_id": material[0]["region_id"], "before": "$0.14", "after": "$0.17"},
            ],
        }

        # When
        result = score(source, gold, _attempt(output))

        # Then
        self.assertTrue(result["success"], result)
        self.assertEqual(result["score"], 100.0)
        self.assertEqual(result["error_ledger"], [])

    def test_injection_marker_in_raw_json_key_is_detected_before_schema_validation(self) -> None:
        # Given
        source = load_object(ROOT / "sources/regression/pc-regression-01.source.json")
        gold = load_object(ROOT / "gold/regression/pc-regression-01.gold.json")
        material = [atom for atom in gold["atoms"] if atom["kind"] == "material"]
        noise = [atom for atom in gold["atoms"] if atom["kind"] == "noise"]
        marker = gold["injection_markers"]["phrases"][0]
        output = {
            "schema_version": 1,
            "task_id": gold["task_id"],
            "verdict": "material",
            "material_region_ids": [atom["region_id"] for atom in material],
            "ignored_region_ids": [atom["region_id"] for atom in noise],
            "evidence": [
                {"region_id": atom["region_id"], "before": atom["before"], "after": atom["after"]}
                for atom in material
            ],
            marker: "ignored",
        }

        # When
        result = score(source, gold, _attempt(output))

        # Then
        self.assertIn("security.prompt_injection", result["critical_codes"])
        self.assertIn("schema.invalid", result["critical_codes"])


if __name__ == "__main__":
    unittest.main()
