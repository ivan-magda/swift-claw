from __future__ import annotations

import unittest
from typing import Any

from benchmark_learning.learning_contract import (
    LearningContractError,
    adapter_envelope_json,
    canonical_event_log,
    parse_adapter_envelope,
    parse_event,
)


class LearningContractTests(unittest.TestCase):
    def test_event_log_rejects_gap_time_reversal_and_unknown_field(self) -> None:
        # given
        first = {
            "schema_version": 1,
            "sequence": 1,
            "occurred_at": "2026-01-01T00:00:00Z",
            "kind": "clock_advanced",
            "payload": {},
        }
        starts_at_two = {**first, "sequence": 2}
        gap = {**first, "sequence": 3, "occurred_at": "2026-01-02T00:00:00Z"}
        reversed_time = {**first, "sequence": 2, "occurred_at": "2025-12-31T23:59:59Z"}
        unknown = {**first, "extra": True}

        # when / then
        # `parse_event` accepts a sequence other than 1 in isolation; only the ordered log
        # requires the first entry to start at 1. This assertion sits outside every
        # `assertRaises` block below so a mutant that moved the start-at-1 check into
        # `parse_event` would surface here instead of being masked by the nested calls.
        self.assertEqual(parse_event(starts_at_two).sequence, 2)
        with self.assertRaises(LearningContractError):
            canonical_event_log([parse_event(starts_at_two)])
        with self.assertRaises(LearningContractError):
            canonical_event_log([parse_event(first), parse_event(gap)])
        with self.assertRaises(LearningContractError):
            canonical_event_log([parse_event(first), parse_event(reversed_time)])
        with self.assertRaises(LearningContractError):
            parse_event(unknown)

    def test_adapter_envelope_rejects_invalid_digest_unknown_key_and_unknown_outcome(
        self,
    ) -> None:
        # given
        digest = "a" * 64
        valid: dict[str, Any] = {
            "adapter_id": "page-change-m3",
            "adapter_version": "v1",
            "candidate_digest": digest,
            "dataset_digest": digest,
            "oracle_digest": digest,
            "gates_digest": digest,
            "execution_surface_digest": digest,
            "outcome": "pass",
            "receipt_digest": digest,
        }
        invalid_digest = {**valid, "candidate_digest": "not-a-sha256-digest"}
        unknown_key = {**valid, "extra": True}
        unknown_outcome = {**valid, "outcome": "maybe"}

        # when / then
        with self.assertRaises(LearningContractError):
            parse_adapter_envelope(invalid_digest)
        with self.assertRaises(LearningContractError):
            parse_adapter_envelope(unknown_key)
        with self.assertRaises(LearningContractError):
            parse_adapter_envelope(unknown_outcome)

        envelope = parse_adapter_envelope(valid)
        self.assertEqual(adapter_envelope_json(envelope), valid)


if __name__ == "__main__":
    unittest.main()
