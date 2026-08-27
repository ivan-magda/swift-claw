from __future__ import annotations

import copy
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any

from page_benchmark.canonical import load_object
from page_benchmark.fixtures import validate_fixture, validate_repository
from page_benchmark.materialize import materialize
from page_benchmark.validation import ContractError

from path_test_support import PAGE_ROOT as ROOT


class FixtureContractTests(unittest.TestCase):
    def _copy_root(self, directory: str) -> Path:
        destination = Path(directory) / "page-change"
        shutil.copytree(ROOT, destination, ignore=shutil.ignore_patterns("__pycache__"))
        return destination

    def _write_json(self, path: Path, value: dict) -> None:
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    def test_all_fixtures_and_split_quotas_are_valid(self) -> None:
        # Given
        root = ROOT

        # When
        result = validate_repository(root)

        # Then
        self.assertEqual(result["status"], "valid")
        self.assertEqual(result["fixture_count"], 13)
        self.assertEqual(result["family_count"], 13)

        mutations = (
            ("fixture_count", "development fixture count"),
            ("target_atoms", "target atoms"),
            ("unrelated_families", "unrelated families"),
            ("required_injection", "required regression/sealed injection"),
        )
        for mutation, message in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = self._copy_root(directory)
                split_path = root / "contracts/splits.json"
                splits = load_object(split_path)
                if mutation == "fixture_count":
                    splits["fixture_counts"]["development"] = 5
                elif mutation == "target_atoms":
                    splits["minimum_target_atoms_per_class_per_split"] = 99
                elif mutation == "unrelated_families":
                    splits["minimum_unrelated_families_per_class_per_split"] = 99
                else:
                    splits["required_injection_splits"].append("development")
                self._write_json(split_path, splits)
                with self.assertRaisesRegex(ContractError, message):
                    validate_repository(root)

    def test_gold_must_exhaustively_match_changed_regions(self) -> None:
        # Given
        source = load_object(ROOT / "sources/development/pc-development-01.source.json")
        gold = load_object(ROOT / "gold/development/pc-development-01.gold.json")
        broken_gold = copy.deepcopy(gold)
        broken_gold["atoms"].pop()

        # When
        with self.assertRaises(ContractError) as raised:
            validate_fixture(source, broken_gold)

        # Then
        self.assertRegex(str(raised.exception), "not exhaustive")

    def test_materializer_exposes_only_task_and_active_lessons(self) -> None:
        # Given
        source = load_object(ROOT / "sources/development/pc-development-01.source.json")
        clean = {"schema_version": 1, "lesson_set_id": "empty", "lessons": []}

        # When
        carrier = materialize(source, clean)

        # Then
        self.assertEqual(set(carrier), {"schema_version", "task_id", "task", "active_lessons"})
        self.assertEqual(carrier["task"], source["task"])
        self.assertEqual(carrier["task_id"], source["task_id"])

    def test_materializer_carries_nonempty_active_lessons_unchanged(self) -> None:
        # Given
        source = load_object(ROOT / "sources/development/pc-development-01.source.json")
        active = {
            "schema_version": 1,
            "lesson_set_id": "set-example",
            "lessons": [
                {
                    "lesson_id": "lesson-example",
                    "target_class": "noise.volatile_value",
                    "text": "Treat volatile counters as cosmetic when meaning is preserved.",
                }
            ],
        }

        # When
        carrier = materialize(source, active)

        # Then
        self.assertEqual(carrier["active_lessons"], active)

    def test_materializer_rejects_duplicate_lesson_classes(self) -> None:
        # Given
        source = load_object(ROOT / "sources/development/pc-development-01.source.json")
        lessons = {
            "schema_version": 1,
            "lesson_set_id": "candidate",
            "lessons": [
                {
                    "lesson_id": "one",
                    "target_class": "noise.volatile_value",
                    "text": "Treat volatile counters as cosmetic.",
                },
                {
                    "lesson_id": "two",
                    "target_class": "noise.volatile_value",
                    "text": "Ignore rotating telemetry.",
                },
            ],
        }

        # When
        with self.assertRaises(ContractError) as raised:
            materialize(source, lessons)

        # Then
        self.assertRegex(str(raised.exception), "lesson target classes must be unique")

    def test_materializer_rejects_non_string_lesson_identity_without_crashing(self) -> None:
        # Given
        source = load_object(ROOT / "sources/development/pc-development-01.source.json")
        lessons: dict[str, Any] = {
            "schema_version": 1,
            "lesson_set_id": "set-example",
            "lessons": [
                {
                    "lesson_id": "lesson-example",
                    "target_class": "noise.volatile_value",
                    "text": "Treat volatile changes as cosmetic.",
                }
            ],
        }

        errors = {}
        for field in ("lesson_id", "target_class"):
            with self.subTest(field=field):
                malformed = copy.deepcopy(lessons)
                malformed["lessons"][0][field] = {"nested": True}

                # When
                with self.assertRaises(ContractError) as raised:
                    materialize(source, malformed)
                errors[field] = str(raised.exception)

        # Then
        self.assertRegex(errors["lesson_id"], "invalid ID")
        self.assertRegex(errors["target_class"], "invalid target class")

    def test_all_injection_marker_types_must_exist_in_html(self) -> None:
        # Given
        source = load_object(ROOT / "sources/regression/pc-regression-01.source.json")
        gold = load_object(ROOT / "gold/regression/pc-regression-01.gold.json")
        for marker_type in ("task_ids", "region_ids", "phrases"):
            with self.subTest(marker_type=marker_type):
                broken = copy.deepcopy(gold)
                broken["injection_markers"][marker_type] = ["absent-marker"]

                # When
                with self.assertRaises(ContractError) as raised:
                    validate_fixture(source, broken)

                # Then
                self.assertRegex(str(raised.exception), "marker is absent")

    def test_cross_split_family_template_selector_literal_and_mechanism_guards(self) -> None:
        # Given
        expected_errors = {
            "family": "family subscription-pricing crosses or repeats splits",
            "template": "DOM template signature crosses splits: pc-regression-02",
            "selector": "selector value crosses splits: class=docs-grid",
            "literal": "changed literal value crosses splits: \\$19 monthly",
            "mechanism": "concrete mechanism repeats: monthly-price-change",
        }
        for mutation, expected_error in expected_errors.items():
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = self._copy_root(directory)
                split_path = root / "contracts/splits.json"
                splits = load_object(split_path)
                source_path = root / "sources/regression/pc-regression-02.source.json"
                gold_path = root / "gold/regression/pc-regression-02.gold.json"
                source = load_object(source_path)
                gold = load_object(gold_path)
                if mutation == "family":
                    source["family_id"] = "subscription-pricing"
                    splits["splits"]["regression"][1]["family_id"] = "subscription-pricing"
                    self._write_json(split_path, splits)
                elif mutation == "template":
                    atoms = {atom["region_id"]: atom for atom in gold["atoms"]}
                    region_ids = source["task"]["region_ids"]

                    def render(
                        side: str,
                        atoms: dict[str, Any] = atoms,
                        region_ids: list[str] = region_ids,
                    ) -> str:
                        values = [atoms[region_id][side] for region_id in region_ids]
                        return (
                            f'<main class="unrelated"><h1>Rail</h1>'
                            f'<section data-region-id="{region_ids[0]}">'
                            f"<span>{values[0]}</span></section>"
                            f'<aside data-region-id="{region_ids[1]}">{values[1]}</aside>'
                            f'<footer data-region-id="{region_ids[2]}">{values[2]}</footer>'
                            f'<p data-region-id="{region_ids[3]}">{values[3]}</p></main>'
                        )

                    source["task"]["before_html"] = render("before")
                    source["task"]["after_html"] = render("after")
                elif mutation == "selector":
                    source["task"]["before_html"] = source["task"]["before_html"].replace(
                        "<table>", '<table class="docs-grid">'
                    )
                    source["task"]["after_html"] = source["task"]["after_html"].replace(
                        "<table>", '<table class="docs-grid">'
                    )
                elif mutation == "literal":
                    atom = gold["atoms"][0]
                    source["task"]["before_html"] = source["task"]["before_html"].replace(
                        "<th>Departure</th><td>08:10</td>",
                        "<td>$19 monthly</td>",
                    )
                    source["task"]["after_html"] = source["task"]["after_html"].replace(
                        "<th>Departure</th><td>08:25</td>",
                        "<td>$24 monthly</td>",
                    )
                    atom["before"] = "$19 monthly"
                    atom["after"] = "$24 monthly"
                else:
                    gold["atoms"][0]["mechanism_id"] = "monthly-price-change"
                self._write_json(source_path, source)
                self._write_json(gold_path, gold)

                # When
                with self.assertRaises(ContractError) as raised:
                    validate_repository(root)

                # Then
                self.assertRegex(str(raised.exception), expected_error)

    def test_sealed_atom_and_verdict_quotas_are_enforced(self) -> None:
        # Given
        for mutation, message in (
            ("atom_counts", "sealed atom counts"),
            ("verdict_counts", "sealed verdict counts"),
        ):
            with self.subTest(mutant=mutation), tempfile.TemporaryDirectory() as directory:
                root = self._copy_root(directory)
                split_path = root / "contracts/splits.json"
                splits = load_object(split_path)
                if mutation == "atom_counts":
                    splits["sealed_contract"]["noise_atoms"] += 1
                else:
                    splits["sealed_contract"]["verdict_counts"] = {
                        "material": 1,
                        "cosmetic": 2,
                        "none": 1,
                    }
                self._write_json(split_path, splits)

                # When
                with self.assertRaises(ContractError) as raised:
                    validate_repository(root)

                # Then
                self.assertRegex(str(raised.exception), message)

    def test_model_facing_source_rejects_any_split_marker(self) -> None:
        # Given
        markers = (
            "development",
            "regression",
            "sealed",
            "dv1-fixture",
            "rg1-fixture",
            "sl1-fixture",
        )
        for marker in markers:
            with self.subTest(marker=marker), tempfile.TemporaryDirectory() as directory:
                root = self._copy_root(directory)
                source_path = root / "sources/development/pc-development-01.source.json"
                source = load_object(source_path)
                source["task"]["before_html"] += f"<p>{marker}</p>"
                source["task"]["after_html"] += f"<p>{marker}</p>"
                self._write_json(source_path, source)

                # When
                with self.assertRaises(ContractError) as raised:
                    validate_repository(root)

                # Then
                self.assertRegex(
                    str(raised.exception),
                    "model-facing source leaks a split marker",
                )


if __name__ == "__main__":
    unittest.main()
