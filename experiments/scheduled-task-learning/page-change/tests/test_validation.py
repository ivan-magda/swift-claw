from __future__ import annotations

import copy
import unittest
from typing import Any

from page_benchmark.validation import (
    validate_gold,
    validate_lesson_candidate,
    validate_output,
)


class OutputValidationTests(unittest.TestCase):
    def test_object_array_uniqueness_ignores_property_order(self) -> None:
        # Given
        output = {
            "schema_version": 1,
            "task_id": "page-0123456789ab",
            "verdict": "material",
            "material_region_ids": ["region-0123456789"],
            "ignored_region_ids": [],
            "evidence": [
                {"region_id": "region-0123456789", "before": "before", "after": "after"},
                {"after": "after", "before": "before", "region_id": "region-0123456789"},
            ],
        }

        # When
        issues = validate_output(output, "page-0123456789ab")

        # Then
        self.assertIn("schema.unique_arrays", {issue.requirement for issue in issues})

    def test_protected_gold_and_lesson_ids_fail_as_schema_issues(self) -> None:
        # Given
        gold: dict[str, Any] = {
            "schema_version": 1,
            "fixture_id": "pc-development-01",
            "task_id": "page-0123456789ab",
            "expected_verdict": "material",
            "atoms": [
                {
                    "atom_id": "atom-example",
                    "region_id": "region-0123456789",
                    "kind": "material",
                    "mechanism_id": "mechanism",
                    "before": "before",
                    "after": "after",
                }
            ],
            "injection_markers": {"task_ids": [], "region_ids": [], "phrases": []},
        }
        candidate = {
            "schema_version": 1,
            "lessons": [{"target_class": {"nested": True}, "text": "text"}],
        }

        # When
        gold_requirements = {}
        for field in ("atom_id", "region_id"):
            with self.subTest(field=field):
                malformed_gold = copy.deepcopy(gold)
                malformed_gold["atoms"][0][field] = {"nested": True}
                gold_requirements[field] = {
                    issue.requirement for issue in validate_gold(malformed_gold)
                }
        lesson_issues = validate_lesson_candidate(candidate)

        # Then
        self.assertIn("schema.bounded_values", gold_requirements["atom_id"])
        self.assertIn("schema.bounded_values", gold_requirements["region_id"])
        self.assertIn(
            "schema.closed_enums",
            {issue.requirement for issue in lesson_issues},
        )


if __name__ == "__main__":
    unittest.main()
