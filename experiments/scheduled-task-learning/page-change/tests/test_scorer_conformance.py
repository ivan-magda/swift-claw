from __future__ import annotations

import copy
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from typing import Any, ClassVar

from page_benchmark.canonical import load_object, write
from page_benchmark.conformance import run
from page_benchmark.scorer import score

from path_test_support import PAGE_ROOT as ROOT


class ScorerConformanceTests(unittest.TestCase):
    corpus: ClassVar[dict[str, Any]]
    fixture_paths: ClassVar[dict[str, Any]]

    @classmethod
    def setUpClass(cls) -> None:
        cls.corpus = load_object(ROOT / "conformance/cases.json")
        split_contract = load_object(ROOT / "contracts/splits.json")
        cls.fixture_paths = {
            entry["fixture_id"]: entry
            for entries in split_contract["splits"].values()
            for entry in entries
        }

    def _run_corpus(self) -> None:
        for case in self.corpus["cases"]:
            entry = self.fixture_paths[case["fixture_id"]]
            result = score(
                load_object(ROOT / entry["source"]),
                load_object(ROOT / entry["gold"]),
                case["attempt"],
            )
            expected = case["expected"]
            self.assertEqual(result, expected, case["case_id"])
            self.assertTrue(
                set(case["covers"]).issubset(result["requirement_hits"]), case["case_id"]
            )

    @staticmethod
    def _copy_contract_root(directory: str) -> Path:
        temporary_root = Path(directory) / "page-change"
        temporary_root.mkdir()
        for name in ("conformance", "contracts", "sources", "gold"):
            shutil.copytree(ROOT / name, temporary_root / name)
        return temporary_root

    def test_exactly_24_cases_pass_24_of_24(self) -> None:
        # Given — the protected corpus loaded by setUp

        # When
        self._run_corpus()

        # Then
        self.assertEqual(len(self.corpus["cases"]), 24)

    def test_every_required_score_schema_and_critical_behavior_is_covered_twice(self) -> None:
        # Given
        coverage_contract = load_object(ROOT / "contracts/conformance-coverage.json")

        # When
        counts = Counter(
            requirement for case in self.corpus["cases"] for requirement in case["covers"]
        )

        # Then
        self.assertEqual(set(counts), set(coverage_contract["requirements"]))
        minimum = coverage_contract["minimum_cases_per_requirement"]
        self.assertTrue(
            all(counts[requirement] >= minimum for requirement in coverage_contract["requirements"])
        )

    def test_three_complete_scorer_executions_are_byte_identical(self) -> None:
        # Given
        execution_count = 3

        # When
        executions = [
            subprocess.run(
                [sys.executable, "-m", "page_benchmark.conformance", "."],
                cwd=ROOT,
                check=True,
                capture_output=True,
            ).stdout
            for _ in range(execution_count)
        ]

        # Then
        self.assertEqual(executions[0], executions[1])
        self.assertEqual(executions[1], executions[2])

    def test_case_ids_and_attempt_payloads_are_unique(self) -> None:
        # Given
        for mutation, message in (
            ("case_id", "case IDs"),
            ("attempt", "attempts"),
        ):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                temporary_root = self._copy_contract_root(directory)
                corpus = copy.deepcopy(self.corpus)
                corpus["cases"][1][mutation] = copy.deepcopy(corpus["cases"][0][mutation])
                write(temporary_root / "conformance/cases.json", corpus)

                # When
                with self.assertRaises(ValueError) as raised:
                    run(temporary_root)

                # Then
                self.assertRegex(str(raised.exception), message)

    def test_run_rejects_incomplete_coverage_contract(self) -> None:
        # Given
        with tempfile.TemporaryDirectory() as directory:
            temporary_root = self._copy_contract_root(directory)
            corpus = copy.deepcopy(self.corpus)
            omitted = "critical.local_output_limit"
            for case in corpus["cases"]:
                case["covers"] = [
                    requirement for requirement in case["covers"] if requirement != omitted
                ]
            write(temporary_root / "conformance/cases.json", corpus)

            # When
            with self.assertRaises(ValueError) as raised:
                run(temporary_root)

            # Then
            self.assertRegex(str(raised.exception), "coverage contract")


if __name__ == "__main__":
    unittest.main()
