from __future__ import annotations

import unittest
from typing import Any

from benchmark_core.canonical import canonical_sha256, dumps
from benchmark_learning.learning_contract import (
    LearningContractError,
    adapter_envelope_json,
    canonical_event_log,
    decision_receipt,
    event_json,
    parse_adapter_envelope,
    parse_event,
    replay_receipt,
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

    def test_replay_receipt_is_byte_identical_for_identical_inputs(self) -> None:
        # given
        event = parse_event(
            {
                "schema_version": 1,
                "sequence": 1,
                "occurred_at": "2026-01-01T00:00:00Z",
                "kind": "clock_advanced",
                "payload": {},
            }
        )
        state = {"schema_version": 1, "jobs": {}, "controlled_clock": "2026-01-01T00:00:00Z"}
        decision = decision_receipt(
            algorithm_id="scheduled-learning/v1",
            decision="fallback",
            reason="deadline",
            triggering_event_sha256=canonical_sha256(event_json(event)),
            before_state_sha256=canonical_sha256(state),
            after_state_sha256=canonical_sha256(state),
            artifact_identities={"adapter": None},
        )

        # when
        first = replay_receipt(
            algorithm_id="scheduled-learning/v1",
            events=[event],
            decisions=[decision],
            final_state=state,
        )
        second = replay_receipt(
            algorithm_id="scheduled-learning/v1",
            events=[event],
            decisions=[decision],
            final_state=state,
        )

        # then
        self.assertEqual(dumps(first), dumps(second))
        self.assertEqual(first["decision_receipt_sha256s"], [canonical_sha256(decision)])

    def test_replay_receipt_events_sha256_changes_with_event_payload(self) -> None:
        # given
        base_event = parse_event(
            {
                "schema_version": 1,
                "sequence": 1,
                "occurred_at": "2026-01-01T00:00:00Z",
                "kind": "controller_started",
                "payload": {"controller_generation": 1},
            }
        )
        changed_event = parse_event(
            {
                "schema_version": 1,
                "sequence": 1,
                "occurred_at": "2026-01-01T00:00:00Z",
                "kind": "controller_started",
                "payload": {"controller_generation": 2},
            }
        )
        state = {"schema_version": 1, "jobs": {}, "controlled_clock": "2026-01-01T00:00:00Z"}

        # when
        base_receipt = replay_receipt(
            algorithm_id="scheduled-learning/v1",
            events=[base_event],
            decisions=[],
            final_state=state,
        )
        changed_receipt = replay_receipt(
            algorithm_id="scheduled-learning/v1",
            events=[changed_event],
            decisions=[],
            final_state=state,
        )

        # then
        self.assertNotEqual(base_receipt["events_sha256"], changed_receipt["events_sha256"])
        self.assertNotEqual(base_receipt["receipt_id"], changed_receipt["receipt_id"])

    def test_decision_receipt_rejects_malformed_artifact_identities(self) -> None:
        # given
        baseline: dict[str, Any] = {
            "algorithm_id": "scheduled-learning/v1",
            "decision": "fallback",
            "reason": "deadline",
            "triggering_event_sha256": "a" * 64,
            "before_state_sha256": "b" * 64,
            "after_state_sha256": "c" * 64,
        }
        malformed_shapes: list[Any] = [
            ["adapter", None],
            "adapter",
            {1: "adapter"},
            {"adapter": {1, 2, 3}},
            {"adapter": float("nan")},
        ]

        # when / then
        for artifact_identities in malformed_shapes:
            with (
                self.subTest(artifact_identities=artifact_identities),
                self.assertRaises(LearningContractError),
            ):
                decision_receipt(**baseline, artifact_identities=artifact_identities)

        # a `None` value inside an otherwise valid object stays legal
        receipt = decision_receipt(**baseline, artifact_identities={"adapter": None})
        self.assertEqual(receipt["artifact_identities"], {"adapter": None})

    def test_decision_receipt_id_changes_with_each_bound_input(self) -> None:
        # given
        baseline: dict[str, Any] = {
            "algorithm_id": "scheduled-learning/v1",
            "decision": "fallback",
            "reason": "deadline",
            "triggering_event_sha256": "a" * 64,
            "before_state_sha256": "b" * 64,
            "after_state_sha256": "c" * 64,
            "artifact_identities": {"adapter": None},
        }
        baseline_id = decision_receipt(**baseline)["decision_id"]
        variants: dict[str, Any] = {
            "triggering_event_sha256": "d" * 64,
            "before_state_sha256": "e" * 64,
            "after_state_sha256": "f" * 64,
            "artifact_identities": {"adapter": "page-change-m3"},
        }

        # when / then
        for field, changed_value in variants.items():
            with self.subTest(field=field):
                changed_id = decision_receipt(**{**baseline, field: changed_value})["decision_id"]
                self.assertNotEqual(changed_id, baseline_id)

    def test_decision_receipt_id_excludes_itself_from_hash_core(self) -> None:
        # given
        receipt = decision_receipt(
            algorithm_id="scheduled-learning/v1",
            decision="fallback",
            reason="deadline",
            triggering_event_sha256="a" * 64,
            before_state_sha256="b" * 64,
            after_state_sha256="c" * 64,
            artifact_identities={"adapter": None},
        )

        # when
        core = {key: value for key, value in receipt.items() if key != "decision_id"}
        recomputed_hash = canonical_sha256(
            {"domain": "scheduled-learning/v1/decision", "value": core}
        )

        # then
        self.assertEqual(receipt["decision_id"], f"decision-{recomputed_hash[:12]}")

    def test_replay_receipt_id_excludes_itself_from_hash_core(self) -> None:
        # given
        event = parse_event(
            {
                "schema_version": 1,
                "sequence": 1,
                "occurred_at": "2026-01-01T00:00:00Z",
                "kind": "clock_advanced",
                "payload": {},
            }
        )
        state = {"schema_version": 1, "jobs": {}, "controlled_clock": "2026-01-01T00:00:00Z"}
        receipt = replay_receipt(
            algorithm_id="scheduled-learning/v1",
            events=[event],
            decisions=[],
            final_state=state,
        )

        # when
        core = {key: value for key, value in receipt.items() if key != "receipt_id"}
        recomputed_hash = canonical_sha256(
            {"domain": "scheduled-learning/v1/replay", "value": core}
        )

        # then
        self.assertEqual(receipt["receipt_id"], f"replay-{recomputed_hash[:12]}")


if __name__ == "__main__":
    unittest.main()
