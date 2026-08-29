"""Post-promotion rollback tests."""

from __future__ import annotations

import unittest
from typing import Any

from benchmark_learning.learning_contract import LearningContractError, event_json
from benchmark_learning.learning_replay import replay

from .support import (
    CONTROL_OCCURRENCE,
    STABLE_DIGEST,
    adapter_binding,
    adapter_receipt,
    append_admitted_trial,
    append_promotable_trial,
    candidate_signal,
    hard_veto_receipt,
    owner_signal,
    promotable_trial,
    promotion_signal,
    requirements,
    run_signal,
    stable_evaluation,
    trial_run_created,
)


class LearningReplayRollbackTests(unittest.TestCase):
    def test_exact_owner_controls_roll_back_only_the_active_promotion(self) -> None:
        # given
        rows = ("candidate_reject", "promotion_rollback")

        # when / then
        for signal in rows:
            with self.subTest(signal=signal):
                initial, promoted_events = promotable_trial()
                promoted = replay(initial=initial, events=promoted_events)
                promotion = promoted["state"]["jobs"]["job-a"]["promotion"]
                next_sequence = len(promoted_events) + 1
                trigger = (
                    candidate_signal(
                        next_sequence,
                        CONTROL_OCCURRENCE,
                        "job-a",
                        promotion["candidate_record_digest"],
                        "candidate_reject",
                        revision=1,
                    )
                    if signal == "candidate_reject"
                    else promotion_signal(
                        next_sequence,
                        CONTROL_OCCURRENCE,
                        "job-a",
                        promotion["promotion_digest"],
                        revision=1,
                    )
                )
                result = replay(initial=initial, events=[*promoted_events, trigger])
                job_state = result["state"]["jobs"]["job-a"]
                self.assertEqual(job_state["stable_digest"], STABLE_DIGEST)
                self.assertEqual(job_state["stable_revision"], 2)
                self.assertEqual(job_state["promotion"]["status"], "rolled_back")
                self.assertEqual(result["decisions"][-1]["decision"], "rollback")
                identities = result["decisions"][-1]["artifact_identities"]
                self.assertEqual(identities["promotion_digest"], promotion["promotion_digest"])
                self.assertEqual(identities["base_digest"], STABLE_DIGEST)
                self.assertEqual(identities["before_stable_revision"], 1)
                self.assertEqual(identities["after_stable_revision"], 2)

    def test_rejecting_successor_trial_candidate_falls_back_without_rolling_back_active_promotion(
        self,
    ) -> None:
        # given
        initial, promoted_events = promotable_trial()
        promoted = replay(initial=initial, events=promoted_events)
        promotion = promoted["state"]["jobs"]["job-a"]["promotion"]
        successor_events = append_admitted_trial(
            initial,
            promoted_events,
            lessons=["Keep the promoted deadline format while adding the direct source."],
        )
        successor = replay(initial=initial, events=successor_events)
        successor_trial = successor["state"]["jobs"]["job-a"]["trial"]
        rejection = candidate_signal(
            len(successor_events) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            successor_trial["candidate_record_digest"],
            "candidate_reject",
            revision=1,
        )

        # when
        result = replay(initial=initial, events=[*successor_events, rejection])

        # then
        job_state = result["state"]["jobs"]["job-a"]
        self.assertEqual(job_state["stable_digest"], promotion["replacement_digest"])
        self.assertEqual(job_state["stable_revision"], 1)
        self.assertEqual(job_state["promotion"]["status"], "active")
        self.assertEqual(job_state["trial"]["status"], "fallback")
        self.assertEqual(job_state["trial"]["trial_digest"], successor_trial["trial_digest"])
        new_decisions = result["decisions"][len(successor["decisions"]) :]
        self.assertEqual([decision["decision"] for decision in new_decisions], ["fallback"])
        self.assertEqual(new_decisions[0]["reason"], "hard_veto")

        # given
        later_assignment = trial_run_created(
            len(successor_events) + 2,
            CONTROL_OCCURRENCE,
            successor_trial["candidate_record_digest"],
            "rejected-successor-run",
        )

        # when
        with self.assertRaises(LearningContractError) as caught:
            replay(
                initial=initial,
                events=[*successor_events, rejection, later_assignment],
            )

        # then
        self.assertIn("policy.no_open_trial", requirements(caught.exception))

    def test_rollback_atomically_falls_back_dependent_trial_and_blocks_assignment(self) -> None:
        # given
        initial, promoted_events = promotable_trial()
        promoted = replay(initial=initial, events=promoted_events)
        promotion = promoted["state"]["jobs"]["job-a"]["promotion"]
        successor_events = append_admitted_trial(
            initial,
            promoted_events,
            lessons=["Keep the promoted deadline format and add one bounded example."],
        )
        successor = replay(initial=initial, events=successor_events)
        successor_trial = successor["state"]["jobs"]["job-a"]["trial"]
        rollback = promotion_signal(
            len(successor_events) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            promotion["promotion_digest"],
            revision=1,
        )

        # when
        result = replay(initial=initial, events=[*successor_events, rollback])

        # then
        job_state = result["state"]["jobs"]["job-a"]
        self.assertEqual(job_state["stable_digest"], STABLE_DIGEST)
        self.assertEqual(job_state["stable_revision"], 2)
        self.assertEqual(job_state["promotion"]["status"], "rolled_back")
        self.assertEqual(job_state["trial"]["status"], "fallback")
        self.assertEqual(job_state["trial"]["trial_digest"], successor_trial["trial_digest"])
        new_decisions = result["decisions"][len(successor["decisions"]) :]
        self.assertEqual(
            [decision["decision"] for decision in new_decisions],
            ["fallback", "rollback"],
        )
        fallback = new_decisions[0]
        rollback_decision = new_decisions[1]
        self.assertEqual(fallback["reason"], "promotion_rollback_invalidated_base")
        self.assertEqual(
            fallback["artifact_identities"]["invalidating_promotion_digest"],
            promotion["promotion_digest"],
        )
        self.assertEqual(fallback["before_state_sha256"], rollback_decision["before_state_sha256"])
        self.assertEqual(fallback["after_state_sha256"], rollback_decision["after_state_sha256"])

        # given
        later_assignment = trial_run_created(
            len(successor_events) + 2,
            CONTROL_OCCURRENCE,
            successor_trial["candidate_record_digest"],
            "obsolete-successor-run",
        )

        # when
        with self.assertRaises(LearningContractError) as caught:
            replay(initial=initial, events=[*successor_events, rollback, later_assignment])

        # then
        self.assertIn("policy.no_open_trial", requirements(caught.exception))

    def test_owner_rollback_distinguishes_historical_from_unknown_promotion_subject(self) -> None:
        # given
        initial, promoted_events = promotable_trial()
        first = replay(initial=initial, events=promoted_events)
        first_promotion = first["state"]["jobs"]["job-a"]["promotion"]
        second_events = append_promotable_trial(
            initial,
            promoted_events,
            lessons=["Keep the exact promoted deadline and add the retained source."],
        )
        second = replay(initial=initial, events=second_events)
        second_promotion = second["state"]["jobs"]["job-a"]["promotion"]
        historical = promotion_signal(
            len(second_events) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            first_promotion["promotion_digest"],
            revision=1,
        )
        unknown = promotion_signal(
            len(second_events) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            "0" * 64,
            revision=1,
        )

        # when
        historical_result = replay(initial=initial, events=[*second_events, historical])
        with self.assertRaises(LearningContractError) as caught:
            replay(initial=initial, events=[*second_events, unknown])

        # then
        historical_job = historical_result["state"]["jobs"]["job-a"]
        self.assertEqual(historical_job["stable_digest"], second_promotion["replacement_digest"])
        self.assertEqual(historical_job["stable_revision"], 2)
        self.assertEqual(historical_job["promotion"]["status"], "active")
        self.assertEqual(historical_result["decisions"][-1]["decision"], "stale_rollback")
        self.assertIn(
            "trigger_identity",
            historical_result["decisions"][-1]["artifact_identities"]["failed_predicates"],
        )
        self.assertIn("policy.unknown_subject", requirements(caught.exception))

    def test_rollback_restores_only_direct_promoted_base_and_increments_revision(self) -> None:
        # given
        initial, first_events = promotable_trial()
        first = replay(initial=initial, events=first_events)
        first_promotion = first["state"]["jobs"]["job-a"]["promotion"]
        second_events = append_promotable_trial(
            initial,
            first_events,
            lessons=["Keep the exact deadline and retain the immediately promoted source."],
        )
        second = replay(initial=initial, events=second_events)
        second_promotion = second["state"]["jobs"]["job-a"]["promotion"]
        rollback = promotion_signal(
            len(second_events) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            second_promotion["promotion_digest"],
            revision=1,
        )

        # when
        result = replay(initial=initial, events=[*second_events, rollback])

        # then
        job_state = result["state"]["jobs"]["job-a"]
        self.assertNotEqual(first_promotion["replacement_digest"], STABLE_DIGEST)
        self.assertEqual(second_promotion["base_digest"], first_promotion["replacement_digest"])
        self.assertEqual(job_state["stable_digest"], first_promotion["replacement_digest"])
        self.assertEqual(job_state["stable_revision"], 3)
        self.assertEqual(job_state["promotion"]["status"], "rolled_back")
        self.assertEqual(result["decisions"][-1]["decision"], "rollback")
        self.assertEqual(
            result["decisions"][-1]["artifact_identities"]["after_stable_revision"],
            3,
        )

    def test_owner_feedback_rolls_back_only_below_two_exact_positive_supports(self) -> None:
        # given
        rows = ("result_not_useful", "result_correction", "evaluation_dispute")

        # when / then
        for signal in rows:
            with self.subTest(signal=signal):
                initial, promoted_events = promotable_trial()
                promoted = replay(initial=initial, events=promoted_events)
                promotion = promoted["state"]["jobs"]["job-a"]["promotion"]
                support = promotion["positive_supports"][1]
                next_sequence = len(promoted_events) + 1
                if signal == "evaluation_dispute":
                    trigger = owner_signal(
                        next_sequence,
                        CONTROL_OCCURRENCE,
                        "job-a",
                        signal,
                        subject_kind="evaluation",
                        subject_digest=support["evaluation_digest"],
                        run_id=support["run_id"],
                        revision=1,
                    )
                else:
                    trigger = run_signal(
                        next_sequence,
                        CONTROL_OCCURRENCE,
                        "job-a",
                        support["run_id"],
                        signal,
                        revision=1,
                        payload=(
                            {"correction_text": "The answer should name the retained deadline."}
                            if signal == "result_correction"
                            else None
                        ),
                    )
                try:
                    result = replay(initial=initial, events=[*promoted_events, trigger])
                except LearningContractError as error:
                    self.fail(f"exact retained support was rejected: {error}")
                job_state = result["state"]["jobs"]["job-a"]
                self.assertEqual(job_state["stable_digest"], STABLE_DIGEST)
                self.assertEqual(job_state["stable_revision"], 2)
                self.assertEqual(result["decisions"][-1]["decision"], "rollback")
                remaining = result["decisions"][-1]["artifact_identities"][
                    "remaining_positive_supports"
                ]
                self.assertEqual([entry["run_id"] for entry in remaining], ["trial-run-1"])

        # given
        three_initial, three_events = promotable_trial(positive_run_count=3)
        three_promoted = replay(initial=three_initial, events=three_events)
        three_promotion = three_promoted["state"]["jobs"]["job-a"]["promotion"]
        retained = run_signal(
            len(three_events) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            "trial-run-2",
            "result_not_useful",
            revision=1,
        )

        # when
        retained_result = replay(initial=three_initial, events=[*three_events, retained])

        # then
        retained_job = retained_result["state"]["jobs"]["job-a"]
        self.assertEqual(retained_job["stable_digest"], three_promotion["replacement_digest"])
        self.assertEqual(retained_job["stable_revision"], 1)
        self.assertEqual(retained_job["promotion"]["status"], "active")

        # given
        first_support_invalidated = run_signal(
            len(three_events) + 2,
            CONTROL_OCCURRENCE,
            "job-a",
            "trial-run-1",
            "result_not_useful",
            revision=1,
        )

        # when
        threshold_result = replay(
            initial=three_initial,
            events=[*three_events, retained, first_support_invalidated],
        )

        # then
        self.assertEqual(threshold_result["decisions"][-1]["decision"], "rollback")
        threshold_remaining = threshold_result["decisions"][-1]["artifact_identities"][
            "remaining_positive_supports"
        ]
        self.assertEqual([entry["run_id"] for entry in threshold_remaining], ["trial-run-3"])

    def test_post_promotion_adapter_requires_exact_critical_or_regression(self) -> None:
        # given
        binding = adapter_binding()
        initial, promoted_events = promotable_trial(adapter=binding)
        promoted = replay(initial=initial, events=promoted_events)
        promotion = promoted["state"]["jobs"]["job-a"]["promotion"]

        # when / then
        for outcome in ("pass", "inconclusive"):
            with self.subTest(non_veto_outcome=outcome):
                receipt = adapter_receipt(
                    len(promoted_events) + 1,
                    CONTROL_OCCURRENCE,
                    trial_digest=promotion["promotion_digest"],
                    candidate_digest=promotion["replacement_digest"],
                    outcome=outcome,
                    subject_kind="promotion",
                    binding=binding,
                )
                result = replay(initial=initial, events=[*promoted_events, receipt])
                job_state = result["state"]["jobs"]["job-a"]
                self.assertEqual(job_state["stable_digest"], promotion["replacement_digest"])
                self.assertEqual(job_state["stable_revision"], 1)
                self.assertEqual(job_state["promotion"]["status"], "active")

        for outcome in ("critical", "regression"):
            with self.subTest(veto_outcome=outcome):
                receipt = adapter_receipt(
                    len(promoted_events) + 1,
                    CONTROL_OCCURRENCE,
                    trial_digest=promotion["promotion_digest"],
                    candidate_digest=promotion["replacement_digest"],
                    outcome=outcome,
                    subject_kind="promotion",
                    binding=binding,
                )
                result = replay(initial=initial, events=[*promoted_events, receipt])
                job_state = result["state"]["jobs"]["job-a"]
                self.assertEqual(job_state["stable_digest"], STABLE_DIGEST)
                self.assertEqual(job_state["stable_revision"], 2)
                self.assertEqual(job_state["promotion"]["status"], "rolled_back")
                self.assertEqual(result["decisions"][-1]["decision"], "rollback")
                self.assertEqual(result["decisions"][-1]["reason"], f"adapter_{outcome}")

        mismatch_rows: list[tuple[str, dict[str, Any]]] = [
            ("subject_digest", {"subject_digest": "other-promotion"}),
            ("candidate_digest", {"envelope_overrides": {"candidate_digest": "f" * 64}}),
            ("adapter_id", {"envelope_overrides": {"adapter_id": "other-adapter"}}),
            ("adapter_version", {"envelope_overrides": {"adapter_version": "v2"}}),
            ("dataset_digest", {"envelope_overrides": {"dataset_digest": "f" * 64}}),
            ("oracle_digest", {"envelope_overrides": {"oracle_digest": "f" * 64}}),
            ("gates_digest", {"envelope_overrides": {"gates_digest": "f" * 64}}),
            (
                "execution_surface_digest",
                {"envelope_overrides": {"execution_surface_digest": "f" * 64}},
            ),
        ]
        for name, overrides in mismatch_rows:
            with self.subTest(stale_identity=name):
                receipt = adapter_receipt(
                    len(promoted_events) + 1,
                    CONTROL_OCCURRENCE,
                    trial_digest=promotion["promotion_digest"],
                    candidate_digest=promotion["replacement_digest"],
                    outcome="critical",
                    subject_kind="promotion",
                    binding=binding,
                    **overrides,
                )
                result = replay(initial=initial, events=[*promoted_events, receipt])
                job_state = result["state"]["jobs"]["job-a"]
                self.assertEqual(job_state["stable_digest"], promotion["replacement_digest"])
                self.assertEqual(job_state["stable_revision"], 1)
                self.assertEqual(job_state["promotion"]["status"], "active")
                self.assertEqual(result["decisions"][-1]["decision"], "stale_rollback")
                self.assertIn(
                    "trigger_identity",
                    result["decisions"][-1]["artifact_identities"]["failed_predicates"],
                )

    def test_adapter_receipt_is_stale_when_promotion_froze_no_adapter(self) -> None:
        # given
        initial, promoted_events = promotable_trial(adapter=None)
        promoted = replay(initial=initial, events=promoted_events)
        promotion = promoted["state"]["jobs"]["job-a"]["promotion"]
        receipt = adapter_receipt(
            len(promoted_events) + 1,
            CONTROL_OCCURRENCE,
            trial_digest=promotion["promotion_digest"],
            candidate_digest=promotion["replacement_digest"],
            outcome="critical",
            subject_kind="promotion",
        )

        # when
        result = replay(initial=initial, events=[*promoted_events, receipt])

        # then
        job_state = result["state"]["jobs"]["job-a"]
        self.assertEqual(job_state["stable_digest"], promotion["replacement_digest"])
        self.assertEqual(job_state["stable_revision"], 1)
        self.assertEqual(job_state["promotion"]["status"], "active")
        self.assertEqual(result["decisions"][-1]["decision"], "stale_rollback")
        self.assertEqual(
            result["decisions"][-1]["before_state_sha256"],
            result["decisions"][-1]["after_state_sha256"],
        )
        self.assertIn(
            "trigger_identity",
            result["decisions"][-1]["artifact_identities"]["failed_predicates"],
        )

    def test_exact_hard_veto_receipt_rolls_back_and_retains_trigger_identity(self) -> None:
        # given
        initial, promoted_events = promotable_trial()
        promoted = replay(initial=initial, events=promoted_events)
        promotion = promoted["state"]["jobs"]["job-a"]["promotion"]
        receipt = hard_veto_receipt(
            len(promoted_events) + 1,
            CONTROL_OCCURRENCE,
            promotion_digest=promotion["promotion_digest"],
            candidate_record_digest=promotion["candidate_record_digest"],
            replacement_digest=promotion["replacement_digest"],
            trigger_kind="corruption",
            receipt_digest="9" * 64,
            receipt_version="hard-veto/v1",
        )

        # when
        try:
            result = replay(initial=initial, events=[*promoted_events, receipt])
        except LearningContractError as error:
            self.fail(f"exact hard-veto receipt was rejected: {error}")

        # then
        job_state = result["state"]["jobs"]["job-a"]
        self.assertEqual(job_state["stable_digest"], STABLE_DIGEST)
        self.assertEqual(job_state["stable_revision"], 2)
        self.assertEqual(result["decisions"][-1]["decision"], "rollback")
        self.assertEqual(result["decisions"][-1]["reason"], "hard_veto_corruption")
        self.assertEqual(
            job_state["promotion"]["rollback"]["triggering_event"], event_json(receipt)
        )
        identities = result["decisions"][-1]["artifact_identities"]
        self.assertEqual(identities["source_kind"], "hard_veto_receipt")
        self.assertEqual(identities["triggering_event"], event_json(receipt))

    def test_stale_rollback_records_stale_decision_without_pointer_change(self) -> None:
        # given
        retained_base = "candidate-newer-than-request"
        initial, promoted_events = promotable_trial(stable_digest=retained_base)
        promoted = replay(initial=initial, events=promoted_events)
        promotion = promoted["state"]["jobs"]["job-a"]["promotion"]
        exact = promotion_signal(
            len(promoted_events) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            promotion["promotion_digest"],
            revision=1,
        )
        rolled_back_events = [*promoted_events, exact]
        stale = promotion_signal(
            len(rolled_back_events) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            promotion["promotion_digest"],
            revision=2,
            supersedes_revision=1,
        )

        # when
        result = replay(initial=initial, events=[*rolled_back_events, stale])

        # then
        job_state = result["state"]["jobs"]["job-a"]
        decision = result["decisions"][-1]
        self.assertEqual(job_state["stable_digest"], retained_base)
        self.assertEqual(job_state["stable_revision"], 2)
        self.assertEqual(decision["decision"], "stale_rollback")
        self.assertEqual(decision["before_state_sha256"], decision["after_state_sha256"])
        self.assertIn("promotion_status", decision["artifact_identities"]["failed_predicates"])
        self.assertIn("stable_digest", decision["artifact_identities"]["failed_predicates"])
        self.assertIn("stable_revision", decision["artifact_identities"]["failed_predicates"])

    def test_each_reachable_rollback_identity_mismatch_is_stale(self) -> None:
        # given
        initial, promoted_events = promotable_trial()
        promoted = replay(initial=initial, events=promoted_events)
        promotion = promoted["state"]["jobs"]["job-a"]["promotion"]
        mismatch_rows = [
            (
                "promotion",
                hard_veto_receipt(
                    len(promoted_events) + 1,
                    CONTROL_OCCURRENCE,
                    promotion_digest="other-promotion",
                    candidate_record_digest=promotion["candidate_record_digest"],
                    replacement_digest=promotion["replacement_digest"],
                ),
            ),
            (
                "candidate",
                hard_veto_receipt(
                    len(promoted_events) + 1,
                    CONTROL_OCCURRENCE,
                    promotion_digest=promotion["promotion_digest"],
                    candidate_record_digest="f" * 64,
                    replacement_digest=promotion["replacement_digest"],
                ),
            ),
            (
                "replacement",
                hard_veto_receipt(
                    len(promoted_events) + 1,
                    CONTROL_OCCURRENCE,
                    promotion_digest=promotion["promotion_digest"],
                    candidate_record_digest=promotion["candidate_record_digest"],
                    replacement_digest="f" * 64,
                ),
            ),
        ]

        # when / then
        for name, receipt in mismatch_rows:
            with self.subTest(identity=name):
                result = replay(initial=initial, events=[*promoted_events, receipt])
                job_state = result["state"]["jobs"]["job-a"]
                self.assertEqual(job_state["stable_digest"], promotion["replacement_digest"])
                self.assertEqual(job_state["stable_revision"], 1)
                self.assertEqual(result["decisions"][-1]["decision"], "stale_rollback")
                self.assertIn(
                    "trigger_identity",
                    result["decisions"][-1]["artifact_identities"]["failed_predicates"],
                )

        # given
        exact_rollback = promotion_signal(
            len(promoted_events) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            promotion["promotion_digest"],
            revision=1,
        )
        first_rollback_events = [*promoted_events, exact_rollback]
        second_events = append_promotable_trial(
            initial,
            first_rollback_events,
            lessons=["Retain the exact promotion identity before rollback."],
        )
        second_result = replay(initial=initial, events=second_events)
        second_promotion = second_result["state"]["jobs"]["job-a"]["promotion"]
        stale_prior_receipt = hard_veto_receipt(
            len(second_events) + 1,
            CONTROL_OCCURRENCE,
            promotion_digest=promotion["promotion_digest"],
            candidate_record_digest=promotion["candidate_record_digest"],
            replacement_digest=promotion["replacement_digest"],
        )

        # when
        result = replay(initial=initial, events=[*second_events, stale_prior_receipt])

        # then
        job_state = result["state"]["jobs"]["job-a"]
        self.assertNotEqual(second_promotion["promotion_digest"], promotion["promotion_digest"])
        self.assertEqual(job_state["stable_digest"], second_promotion["replacement_digest"])
        self.assertEqual(job_state["stable_revision"], second_promotion["promotion_revision"])
        self.assertEqual(result["decisions"][-1]["decision"], "stale_rollback")
        self.assertIn(
            "trigger_identity",
            result["decisions"][-1]["artifact_identities"]["failed_predicates"],
        )

    def test_post_promotion_reusable_issue_enters_new_window_without_rollback(self) -> None:
        # given
        initial, promoted_events = promotable_trial()
        promoted = replay(initial=initial, events=promoted_events)
        promotion = promoted["state"]["jobs"]["job-a"]["promotion"]
        ordinary = stable_evaluation(
            len(promoted_events) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            "post-promotion-run",
            "reusable_issue",
            ["x"],
            stable_digest=promotion["replacement_digest"],
        )

        # when
        result = replay(initial=initial, events=[*promoted_events, ordinary])

        # then
        job_state = result["state"]["jobs"]["job-a"]
        self.assertEqual(job_state["stable_digest"], promotion["replacement_digest"])
        self.assertEqual(job_state["stable_revision"], 1)
        self.assertEqual(job_state["promotion"]["status"], "active")
        self.assertEqual(job_state["evaluations"][-1]["run_id"], "post-promotion-run")


if __name__ == "__main__":
    unittest.main()
