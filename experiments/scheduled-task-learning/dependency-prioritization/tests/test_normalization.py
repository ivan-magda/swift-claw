from __future__ import annotations

import copy
import unittest
from typing import Any

from dependency_benchmark.normalization import materialize_task

from support import fixture


def _object_keys(value: Any) -> set[str]:
    if isinstance(value, dict):
        return set(value) | {key for item in value.values() for key in _object_keys(item)}
    if isinstance(value, list):
        return {key for item in value for key in _object_keys(item)}
    return set()


class DependencyNormalizationTests(unittest.TestCase):
    def test_materialization_is_order_independent_and_hides_source_keys(self) -> None:
        # Given
        source = fixture("dp-development-01")["source"]
        reordered = copy.deepcopy(source)
        for finding_index, finding in enumerate(reordered["normalized_findings"]):
            finding_key = finding["source_key"]
            renamed_finding_key = f"renamed-finding-{finding_index}"
            finding["source_key"] = renamed_finding_key
            path_keys: dict[str, str] = {}
            for path_index, path in enumerate(finding["dependency_paths"]):
                renamed_path_key = f"renamed-path-{finding_index}-{path_index}"
                path_keys[path["source_key"]] = renamed_path_key
                path["source_key"] = renamed_path_key
            for option_index, option in enumerate(finding["remediation_options"]):
                option["source_key"] = f"renamed-option-{finding_index}-{option_index}"
            for evidence_index, evidence in enumerate(finding["evidence_references"]):
                evidence["source_key"] = f"renamed-evidence-{finding_index}-{evidence_index}"
                if evidence["subject_key"] == finding_key:
                    evidence["subject_key"] = renamed_finding_key
                elif evidence["subject_key"] in path_keys:
                    evidence["subject_key"] = path_keys[evidence["subject_key"]]
            finding["advisories"].reverse()
            finding["dependency_paths"].reverse()
            finding["remediation_options"].reverse()
            finding["evidence_references"].reverse()
        reordered["normalized_findings"].reverse()
        author_only_keys = {
            "source_key",
            "ecosystem",
            "package_name",
            "advisories",
            "advisory_id",
            "package_chain",
        }

        # When
        task = materialize_task(source)
        reordered_task = materialize_task(reordered)

        # Then
        self.assertEqual(task, reordered_task)
        self.assertTrue(author_only_keys.isdisjoint(_object_keys(task)))
        self.assertEqual(len(task["findings"]), len(source["normalized_findings"]))


if __name__ == "__main__":
    unittest.main()
