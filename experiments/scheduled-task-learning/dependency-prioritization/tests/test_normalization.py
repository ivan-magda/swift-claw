from __future__ import annotations

import copy
import unittest
from typing import Any

from dependency_benchmark.normalization import materialize

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
        source["normalized_findings"][0]["advisories"].append(
            {"advisory_id": "OSV-NO-CVSS", "severity": None}
        )
        shared_option_key = source["normalized_findings"][0]["remediation_options"][0]["source_key"]
        source["normalized_findings"][1]["remediation_options"][0]["source_key"] = shared_option_key
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
        materialization = materialize(source)
        reordered_materialization = materialize(reordered)
        task = materialization.task
        reordered_task = reordered_materialization.task

        # Then
        self.assertEqual(task, reordered_task)
        self.assertTrue(author_only_keys.isdisjoint(_object_keys(task)))
        self.assertEqual(len(task["findings"]), len(source["normalized_findings"]))
        self.assertEqual(
            {binding.finding_id for binding in materialization.bindings.findings},
            {finding["finding_id"] for finding in task["findings"]},
        )
        scoped_targets: list[str] = []
        for source_finding in source["normalized_findings"][:2]:
            finding_id = materialization.bindings.finding_id(source_finding["source_key"])
            option_id = materialization.bindings.option_id(
                source_finding["source_key"],
                shared_option_key,
            )
            canonical_finding = next(
                finding for finding in task["findings"] if finding["finding_id"] == finding_id
            )
            canonical_option = next(
                option
                for option in canonical_finding["remediation_options"]
                if option["option_id"] == option_id
            )
            scoped_targets.append(canonical_option["target_version"])
        self.assertEqual(
            scoped_targets,
            ["1.1.0", "2.0.0"],
        )


if __name__ == "__main__":
    unittest.main()
