"""Promotion and replay receipt tests."""

from __future__ import annotations

import unittest

from benchmark_core.canonical import canonical_sha256, dumps
from benchmark_learning.learning_contract import event_json
from benchmark_learning.learning_replay import replay

from .support import (
    ALGORITHM_ID,
    COMPATIBILITY_DIGEST,
    CONTROL_OCCURRENCE,
    FIRST_CLOCK,
    PROMOTION_DOMAIN,
    STABLE_DIGEST,
    adapter_binding,
    admitted_trial,
    promotable_trial,
    run_signal,
    trial_evaluation_digest,
    trial_of,
    trial_run_created,
    trial_run_settled,
)


class LearningReplayPromotionTests(unittest.TestCase):
    def test_promotion_retains_exact_frozen_artifacts_and_advances_stable_revision(
        self,
    ) -> None:
        # given
        binding = adapter_binding()
        initial, events = promotable_trial(adapter=binding)
        trial = trial_of(initial, events[:6])
        settled_events = [event for event in events if event.kind.value == "trial_run_settled"]

        # when
        result = replay(initial=initial, events=events)

        # then
        job_state = result["state"]["jobs"]["job-a"]
        promotion = job_state["promotion"]
        self.assertEqual(job_state["stable_digest"], trial["replacement_digest"])
        self.assertEqual(job_state["stable_revision"], 1)
        self.assertEqual(job_state["trial"]["status"], "promoted")
        cohort = [
            {
                "run_id": f"trial-run-{index}",
                "outcome": "positive",
                "evaluation_digest": trial_evaluation_digest(settled),
                "effective_outcome": "positive",
                "evaluation_required": True,
                "owner_signal_event_digest": None,
            }
            for index, settled in enumerate(settled_events, start=1)
        ]
        promotion_core = {
            "schema_version": 1,
            "job_id": "job-a",
            "trial_digest": trial["trial_digest"],
            "candidate_record_digest": trial["candidate_record_digest"],
            "replacement_digest": trial["replacement_digest"],
            "source_manifest_digest": "source-manifest-1",
            "base_digest": STABLE_DIGEST,
            "base_revision": 0,
            "learning_epoch": 0,
            "feedback_revision": 0,
            "algorithm_id": ALGORITHM_ID,
            "job_definition_digest": "job-definition-0",
            "compatibility_digest": COMPATIBILITY_DIGEST,
            "adapter": binding,
            "adapter_receipt": trial_of(initial, events[:7])["adapter_receipt"],
            "settled_cohort": cohort,
            "positive_supports": cohort,
            "promotion_revision": 1,
            "activated_at": FIRST_CLOCK,
            "triggering_event": event_json(settled_events[-1]),
        }
        expected_digest = canonical_sha256({"domain": PROMOTION_DOMAIN, "value": promotion_core})
        self.assertEqual(
            {field: promotion[field] for field in promotion_core if field != "schema_version"},
            {field: value for field, value in promotion_core.items() if field != "schema_version"},
        )
        self.assertEqual(promotion["promotion_digest"], expected_digest)
        self.assertEqual(promotion["status"], "active")
        self.assertIsNone(promotion["rollback"])
        identities = result["decisions"][-1]["artifact_identities"]
        self.assertEqual(identities["promotion_digest"], expected_digest)
        self.assertEqual(identities["positive_supports"], cohort)

    def test_stale_promotion_records_nonmutating_pointer_decision(self) -> None:
        # given
        initial, admitted = admitted_trial(FIRST_CLOCK)
        trial = trial_of(initial, admitted)
        events = [
            *admitted,
            trial_run_created(
                7,
                CONTROL_OCCURRENCE,
                trial["candidate_record_digest"],
                "trial-run-1",
            ),
            trial_run_created(
                8,
                CONTROL_OCCURRENCE,
                trial["candidate_record_digest"],
                "trial-run-2",
            ),
            trial_run_settled(9, CONTROL_OCCURRENCE, "trial-run-1", "positive"),
            run_signal(
                10,
                CONTROL_OCCURRENCE,
                "job-a",
                "run-1",
                "result_useful",
                revision=1,
            ),
            trial_run_settled(11, CONTROL_OCCURRENCE, "trial-run-2", "positive"),
        ]

        # when
        result = replay(initial=initial, events=events)

        # then
        job_state = result["state"]["jobs"]["job-a"]
        self.assertEqual(job_state["stable_digest"], STABLE_DIGEST)
        self.assertEqual(job_state["stable_revision"], 0)
        self.assertIsNone(job_state["promotion"])
        self.assertEqual(job_state["trial"]["status"], "stale_promotion")
        self.assertEqual(result["decisions"][-1]["decision"], "stale_promotion")
        self.assertIn(
            "feedback_revision",
            result["decisions"][-1]["artifact_identities"]["failed_predicates"],
        )

    def test_same_initial_state_and_events_produce_identical_replay_receipt(self) -> None:
        # given
        initial, events = promotable_trial()

        # when
        first = replay(initial=initial, events=events)
        second = replay(initial=initial, events=events)

        # then
        self.assertEqual(set(first), {"state", "decisions", "receipt"})
        self.assertEqual(dumps(first["receipt"]), dumps(second["receipt"]))
        self.assertEqual(first["receipt"]["final_state_sha256"], canonical_sha256(first["state"]))
        self.assertEqual(
            first["receipt"]["decision_receipt_sha256s"],
            [canonical_sha256(decision) for decision in first["decisions"]],
        )
        promotion = first["state"]["jobs"]["job-a"]["promotion"]
        self.assertIsNotNone(promotion)
        self.assertEqual(
            first["decisions"][-1]["artifact_identities"]["promotion_digest"],
            promotion["promotion_digest"],
        )
