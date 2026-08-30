"""Filesystem-only immutable event journal tests."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from benchmark_core.canonical import canonical_sha256, dumps, load_object
from benchmark_learning.learning_contract import event_json, parse_event
from scheduled_learning_v1.replay_controller import EventJournal


class EventJournalTests(unittest.TestCase):
    def test_append_returns_the_exact_committed_path_and_canonical_sha256(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as root:
            journal = EventJournal(Path(root))

            # when
            committed = journal.append(
                "controller_started", "2030-01-01T00:00:00Z", {"controller_generation": 1}
            )

            # then
            expected_event = parse_event(
                {
                    "schema_version": 1,
                    "sequence": 1,
                    "occurred_at": "2030-01-01T00:00:00Z",
                    "kind": "controller_started",
                    "payload": {"controller_generation": 1},
                }
            )
            expected_digest = canonical_sha256(event_json(expected_event))
            expected_path = Path(root) / f"000001-{expected_digest}.json"
            self.assertEqual(committed.event, expected_event)
            self.assertEqual(committed.sha256, expected_digest)
            self.assertEqual(committed.path, expected_path)
            self.assertEqual(load_object(expected_path), event_json(expected_event))

    def test_append_orders_sequence_numbers_by_call_order(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as root:
            journal = EventJournal(Path(root))

            # when
            first = journal.append(
                "controller_started", "2030-01-01T00:00:00Z", {"controller_generation": 1}
            )
            second = journal.append("clock_advanced", "2030-01-02T00:00:00Z", {})
            third = journal.append("clock_advanced", "2030-01-03T00:00:00Z", {})

            # then
            self.assertEqual(
                [first.event.sequence, second.event.sequence, third.event.sequence], [1, 2, 3]
            )
            reopened = EventJournal(Path(root))
            self.assertEqual(
                [event.sequence for event in reopened.load()],
                [1, 2, 3],
            )
            self.assertEqual(reopened.load(), [first.event, second.event, third.event])

    def test_append_rejects_writing_to_an_already_committed_target(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as root:
            first_handle = EventJournal(Path(root))
            second_handle = EventJournal(Path(root))
            first_handle.append(
                "controller_started", "2030-01-01T00:00:00Z", {"controller_generation": 1}
            )

            # when / then
            with self.assertRaises(FileExistsError):
                second_handle.append(
                    "controller_started", "2030-01-01T00:00:00Z", {"controller_generation": 1}
                )

    def test_load_reflects_the_exact_bytes_currently_committed_to_disk(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as root:
            journal = EventJournal(Path(root))
            committed = journal.append(
                "controller_started", "2030-01-01T00:00:00Z", {"controller_generation": 1}
            )
            substituted_event = parse_event(
                {
                    "schema_version": 1,
                    "sequence": 1,
                    "occurred_at": "2030-01-01T00:00:00Z",
                    "kind": "controller_started",
                    "payload": {"controller_generation": 7},
                }
            )
            committed.path.write_text(dumps(event_json(substituted_event)), encoding="utf-8")

            # when
            reopened = EventJournal(Path(root))
            loaded = reopened.load()

            # then
            self.assertEqual(loaded, [substituted_event])
            self.assertNotEqual(loaded, [committed.event])


if __name__ == "__main__":
    unittest.main()
