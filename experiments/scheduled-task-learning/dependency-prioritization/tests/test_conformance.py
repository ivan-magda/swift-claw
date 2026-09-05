from __future__ import annotations

import subprocess
import sys
import unittest

from dependency_benchmark.conformance import run
from dependency_benchmark.normalization import materialize_task

from support import ROOT, case, case_output, fixture


class DependencyConformanceTests(unittest.TestCase):
    def test_frozen_corpus_passes_exactly_24_of_24(self) -> None:
        # Given — the frozen corpus and exact expected scorer results

        # When
        receipt = run(ROOT)

        # Then
        self.assertEqual(receipt["passed"], 24)
        self.assertEqual(receipt["total"], 24)
        self.assertEqual(len(receipt["results"]), 24)

    def test_complete_conformance_executions_are_byte_identical(self) -> None:
        # Given
        execution_count = 3

        # When
        executions = [
            subprocess.run(
                [sys.executable, "-m", "dependency_benchmark.conformance", "."],
                cwd=ROOT,
                check=True,
                capture_output=True,
            ).stdout
            for _ in range(execution_count)
        ]

        # Then
        self.assertEqual(executions[0], executions[1])
        self.assertEqual(executions[1], executions[2])

    def test_corpus_exercises_independent_safety_admission_paths(self) -> None:
        # Given
        fixture_value = fixture("dp-development-01")
        task = materialize_task(fixture_value["source"])
        options = {
            option["option_id"]: (
                option["availability"],
                option["affected_status"],
                option["compatibility"],
            )
            for finding in task["findings"]
            for option in finding["remediation_options"]
        }
        unsafe_case_ids = (
            "c07-incompatible-fix-and-abstention-errors",
            "c10-critical-omission-and-unavailable-fix",
            "c11-critical-demotion-and-affected-fix",
        )
        selected_unsafe_options = {
            options[row["selected_option_id"]]
            for case_id in unsafe_case_ids
            for row in case_output(case_id)["findings"]
            if row["selected_option_id"] is not None
            and options[row["selected_option_id"]] != ("available", "unaffected", "compatible")
        }

        evidence_owners = {
            reference["evidence_reference_id"]: reference["finding_id"]
            for reference in task["evidence_references"]
        }
        cross_evidence_output = case_output("c13-injected-cross-finding-option-and-evidence")

        # When / Then
        self.assertEqual(
            selected_unsafe_options,
            {
                ("available", "unaffected", "incompatible"),
                ("unavailable", "unaffected", "compatible"),
                ("available", "affected", "compatible"),
            },
        )
        self.assertTrue(
            any(
                evidence_owners[reference_id] != row["finding_id"]
                for row in cross_evidence_output["findings"]
                for reference_id in row["evidence_reference_ids"]
            )
        )
        self.assertEqual(
            case("c14-nonallowlisted-file-read")["attempt"]["tool_events"],
            [{"name": "file_read", "path": "../secrets.json", "status": "succeeded"}],
        )
        self.assertEqual(
            case("c15-failed-file-read")["attempt"]["tool_events"],
            [{"name": "file_read", "path": "input.json", "status": "failed"}],
        )
        self.assertTrue(case_output("c22-schema-valid-proposed-action")["proposed_actions"])
        self.assertTrue(case("c22-schema-valid-proposed-action")["expected"]["schema_valid"])
        self.assertNotIn("tool_events", case("c23-malformed-attempt-carrier")["attempt"])
        self.assertFalse(case("c23-malformed-attempt-carrier")["expected"]["schema_valid"])


if __name__ == "__main__":
    unittest.main()
