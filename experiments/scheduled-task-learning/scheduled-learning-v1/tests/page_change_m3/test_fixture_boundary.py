"""Fresh fixture split-count and Protocol 0.6/M0 independence boundary."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from page_change_m3.fixtures import (
    FRESH_SPLIT_FIXTURE_IDS,
    load_fresh_golds,
    load_fresh_sources,
    verify_fixture_independence,
)
from page_change_m3.validation import ContractError

from . import support


def _seed_valid_fresh_corpus(root: Path) -> None:
    for split, fixture_ids in FRESH_SPLIT_FIXTURE_IDS.items():
        for fixture_id in fixture_ids:
            source = support.real_fresh_source(fixture_id, split)
            gold = support.real_fresh_gold(fixture_id, split)
            source_path = root / "corpus" / split / f"{fixture_id}.source.json"
            gold_path = root / "gold" / split / f"{fixture_id}.gold.json"
            source_path.parent.mkdir(parents=True, exist_ok=True)
            gold_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.write_text(json.dumps(source), encoding="utf-8")
            gold_path.write_text(json.dumps(gold), encoding="utf-8")


class FixtureBoundaryTests(unittest.TestCase):
    def test_frozen_split_has_exactly_two_three_two_fixtures(self) -> None:
        # given / when
        counts = {split: len(ids) for split, ids in FRESH_SPLIT_FIXTURE_IDS.items()}

        # then
        self.assertEqual(counts, {"development": 2, "regression": 3, "sealed": 2})

    def test_the_committed_fresh_corpus_loads_exactly_seven_source_and_gold_pairs(self) -> None:
        # given / when
        sources = load_fresh_sources(support.PROJECT_ROOT)
        golds = load_fresh_golds(support.PROJECT_ROOT)

        # then
        self.assertEqual(len(sources), 7)
        self.assertEqual(len(golds), 7)
        self.assertEqual(
            {source["fixture_id"] for source in sources}, {gold["fixture_id"] for gold in golds}
        )

    def test_the_committed_fresh_corpus_is_independent_of_protocol_06_and_m0(self) -> None:
        # given / when / then (must not raise)
        verify_fixture_independence(support.PROJECT_ROOT)

    def test_a_fresh_source_reusing_protocol_06_task_content_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as root:
            _seed_valid_fresh_corpus(Path(root))
            reused_task = support.protocol_06_source("pc-development-01", "development")["task"]
            path = Path(root) / "corpus" / "development" / "pc-development-07.source.json"
            polluted = json.loads(path.read_text(encoding="utf-8"))
            polluted["task"] = reused_task
            path.write_text(json.dumps(polluted), encoding="utf-8")

            # when / then
            with self.assertRaises(ContractError) as raised:
                verify_fixture_independence(Path(root))
            self.assertIn(
                "fixtures.digest_overlap", {issue.requirement for issue in raised.exception.issues}
            )

    def test_an_incomplete_fresh_corpus_fails_the_exact_split_count_check(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as root:
            _seed_valid_fresh_corpus(Path(root))
            missing = Path(root) / "corpus" / "sealed" / "pc-sealed-06.source.json"
            missing.unlink()

            # when / then
            with self.assertRaises(ContractError) as raised:
                verify_fixture_independence(Path(root))
            self.assertIn(
                "fixtures.exact_split_counts",
                {issue.requirement for issue in raised.exception.issues},
            )

    def test_an_extra_fresh_fixture_fails_the_exact_split_inventory_check(self) -> None:
        # given
        extras = (
            ("corpus", "pc-development-99.source.json", support.real_fresh_source),
            ("gold", "pc-development-99.gold.json", support.real_fresh_gold),
        )

        for directory, filename, loader in extras:
            with self.subTest(directory=directory), tempfile.TemporaryDirectory() as root:
                root_path = Path(root)
                _seed_valid_fresh_corpus(root_path)
                extra = root_path / directory / "development" / filename
                extra.write_text(json.dumps(loader("pc-development-07", "development")))

                # when / then
                with self.assertRaises(ContractError) as raised:
                    verify_fixture_independence(root_path)
                self.assertIn(
                    "fixtures.exact_split_counts",
                    {issue.requirement for issue in raised.exception.issues},
                )


if __name__ == "__main__":
    unittest.main()
