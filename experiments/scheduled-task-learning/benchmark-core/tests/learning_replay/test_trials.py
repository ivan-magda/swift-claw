"""Trial assignment, timing, and adapter tests."""

from __future__ import annotations

import unittest
from typing import Any

from benchmark_learning.learning_contract import LearningContractError
from benchmark_learning.learning_replay import initial_state, replay

from .support import (
    ALGORITHM_ID,
    CONTROL_OCCURRENCE,
    FIRST_CLOCK,
    adapter_binding,
    adapter_receipt,
    admitted_trial,
    append_admitted_trial,
    clock_advanced,
    job,
    owner_signal,
    promotable_trial,
    requirements,
    run_signal,
    stable_evaluation,
    trial_evaluation_digest,
    trial_of,
    trial_run_created,
    trial_run_settled,
    trial_subject_digest,
)


class LearningReplayTrialTests(unittest.TestCase):
    def test_created_neutral_trial_run_consumes_assignment(self) -> None:
        # given
        initial, admitted = admitted_trial(FIRST_CLOCK)
        trial = trial_of(initial, admitted)
        created = trial_run_created(
            7,
            CONTROL_OCCURRENCE,
            trial["candidate_record_digest"],
            "trial-run-1",
        )
        settled = trial_run_settled(8, CONTROL_OCCURRENCE, "trial-run-1", "neutral")

        # when
        created_result = replay(initial=initial, events=[*admitted, created])
        settled_result = replay(initial=initial, events=[*admitted, created, settled])

        # then
        created_assignments = created_result["state"]["jobs"]["job-a"]["trial"]["assignments"]
        self.assertEqual(len(created_assignments), 1)
        self.assertEqual(created_assignments[0]["run_id"], "trial-run-1")
        self.assertEqual(created_assignments[0]["status"], "created")
        settled_assignment = settled_result["state"]["jobs"]["job-a"]["trial"]["assignments"][0]
        self.assertEqual(settled_assignment["status"], "settled")
        self.assertEqual(settled_assignment["outcome"], "neutral")
        self.assertEqual(settled_result["state"]["jobs"]["job-a"]["trial"]["status"], "open")

    def test_trial_run_is_known_owner_signal_subject_and_advances_feedback_revision(self) -> None:
        # given
        initial, admitted = admitted_trial(FIRST_CLOCK)
        trial = trial_of(initial, admitted)
        created = trial_run_created(
            7,
            CONTROL_OCCURRENCE,
            trial["candidate_record_digest"],
            "trial-run-1",
        )
        useful = run_signal(
            8,
            CONTROL_OCCURRENCE,
            "job-a",
            "trial-run-1",
            "result_useful",
            revision=1,
        )

        # when
        result = replay(initial=initial, events=[*admitted, created, useful])

        # then
        job_state = result["state"]["jobs"]["job-a"]
        self.assertEqual(job_state["feedback_revision"], 1)
        self.assertEqual(job_state["owner_signals"][-1]["subject_digest"], "trial-run-1")
        self.assertEqual(job_state["trial"]["status"], "open")

    def test_trial_closure_requires_bounded_settled_runs_and_frozen_adapter_evidence(
        self,
    ) -> None:
        # given
        generic_initial, generic_admitted = admitted_trial(FIRST_CLOCK)
        generic_trial = trial_of(generic_initial, generic_admitted)
        generic_candidate = generic_trial["candidate_record_digest"]
        frozen_initial, frozen_admitted = admitted_trial(FIRST_CLOCK, adapter=adapter_binding())
        frozen_trial = trial_of(frozen_initial, frozen_admitted)
        frozen_candidate = frozen_trial["candidate_record_digest"]
        generic_created = [
            trial_run_created(7, CONTROL_OCCURRENCE, generic_candidate, "trial-run-1"),
            trial_run_created(8, CONTROL_OCCURRENCE, generic_candidate, "trial-run-2"),
            trial_run_created(9, CONTROL_OCCURRENCE, generic_candidate, "trial-run-3"),
        ]
        fourth = trial_run_created(10, CONTROL_OCCURRENCE, generic_candidate, "trial-run-4")
        unsettled_tail = [
            *generic_created,
            trial_run_settled(10, CONTROL_OCCURRENCE, "trial-run-1", "positive"),
            trial_run_settled(11, CONTROL_OCCURRENCE, "trial-run-2", "positive"),
        ]
        negative_tail = [
            trial_run_created(7, CONTROL_OCCURRENCE, generic_candidate, "trial-run-1"),
            trial_run_created(8, CONTROL_OCCURRENCE, generic_candidate, "trial-run-2"),
            trial_run_settled(9, CONTROL_OCCURRENCE, "trial-run-1", "negative"),
        ]
        generic_positive_tail = [
            trial_run_created(7, CONTROL_OCCURRENCE, generic_candidate, "trial-run-1"),
            trial_run_created(8, CONTROL_OCCURRENCE, generic_candidate, "trial-run-2"),
            trial_run_settled(9, CONTROL_OCCURRENCE, "trial-run-1", "positive"),
            trial_run_settled(10, CONTROL_OCCURRENCE, "trial-run-2", "positive"),
        ]
        frozen_positive_tail = [
            trial_run_created(7, CONTROL_OCCURRENCE, frozen_candidate, "trial-run-1"),
            trial_run_created(8, CONTROL_OCCURRENCE, frozen_candidate, "trial-run-2"),
            trial_run_settled(9, CONTROL_OCCURRENCE, "trial-run-1", "positive"),
            trial_run_settled(10, CONTROL_OCCURRENCE, "trial-run-2", "positive"),
        ]
        inconclusive = adapter_receipt(
            7,
            CONTROL_OCCURRENCE,
            trial_digest=trial_subject_digest(frozen_trial),
            candidate_digest=frozen_trial["replacement_digest"],
            outcome="inconclusive",
        )
        inconclusive_tail = [
            inconclusive,
            trial_run_created(8, CONTROL_OCCURRENCE, frozen_candidate, "trial-run-1"),
            trial_run_created(9, CONTROL_OCCURRENCE, frozen_candidate, "trial-run-2"),
            trial_run_settled(10, CONTROL_OCCURRENCE, "trial-run-1", "positive"),
            trial_run_settled(11, CONTROL_OCCURRENCE, "trial-run-2", "positive"),
        ]

        # when
        with self.assertRaises(LearningContractError) as over_limit:
            replay(initial=generic_initial, events=[*generic_admitted, *generic_created, fourth])
        unsettled = replay(initial=generic_initial, events=[*generic_admitted, *unsettled_tail])
        negative = replay(initial=generic_initial, events=[*generic_admitted, *negative_tail])
        generic_positive = replay(
            initial=generic_initial,
            events=[*generic_admitted, *generic_positive_tail],
        )
        frozen_missing = replay(
            initial=frozen_initial,
            events=[*frozen_admitted, *frozen_positive_tail],
        )
        before_inconclusive_closure = replay(
            initial=frozen_initial,
            events=[*frozen_admitted, inconclusive],
        )
        after_inconclusive_closure = replay(
            initial=frozen_initial,
            events=[*frozen_admitted, *inconclusive_tail],
        )

        # then
        self.assertIn("policy.assignment_limit", requirements(over_limit.exception))
        unsettled_trial = unsettled["state"]["jobs"]["job-a"]["trial"]
        self.assertEqual(unsettled_trial["status"], "open")
        self.assertIsNotNone(unsettled_trial["assignment_closed_at"])
        self.assertEqual(negative["decisions"][-1]["decision"], "fallback")
        self.assertEqual(negative["decisions"][-1]["reason"], "negative_trial_run")
        self.assertEqual(generic_positive["decisions"][-1]["decision"], "promoted")
        self.assertEqual(frozen_missing["decisions"][-1]["decision"], "fallback")
        self.assertEqual(frozen_missing["decisions"][-1]["reason"], "adapter_pass_missing")
        self.assertEqual(
            before_inconclusive_closure["state"]["jobs"]["job-a"]["trial"]["status"],
            "open",
        )
        self.assertEqual(after_inconclusive_closure["decisions"][-1]["decision"], "fallback")
        self.assertEqual(
            after_inconclusive_closure["decisions"][-1]["reason"],
            "adapter_inconclusive",
        )

    def test_clock_advanced_closes_assignment_at_30_days_and_falls_back_at_37_days(
        self,
    ) -> None:
        # given
        initial, admitted = admitted_trial("2026-01-01T00:00:00Z")
        trial = trial_of(initial, admitted)
        created = trial_run_created(
            7,
            CONTROL_OCCURRENCE,
            trial["candidate_record_digest"],
            "trial-run-1",
        )
        future_ordinary = trial_run_created(
            7,
            "2026-02-01T00:00:00Z",
            trial["candidate_record_digest"],
            "future-ordinary-run",
        )
        assignment_close = clock_advanced(8, "2026-01-31T00:00:00Z")
        before_decision_close = clock_advanced(9, "2026-02-06T23:59:59Z")
        decision_close = clock_advanced(10, "2026-02-07T00:00:00Z")

        # when
        ordinary_result = replay(initial=initial, events=[*admitted, future_ordinary])
        closed_assignment = replay(
            initial=initial,
            events=[*admitted, created, assignment_close],
        )
        before_decision = replay(
            initial=initial,
            events=[*admitted, created, assignment_close, before_decision_close],
        )
        result = replay(
            initial=initial,
            events=[
                *admitted,
                created,
                assignment_close,
                before_decision_close,
                decision_close,
            ],
        )

        # then
        ordinary_trial = ordinary_result["state"]["jobs"]["job-a"]["trial"]
        self.assertEqual(ordinary_result["state"]["controlled_clock"], "2026-01-01T00:00:00Z")
        self.assertIsNone(ordinary_trial["assignment_closed_at"])
        self.assertEqual(ordinary_trial["status"], "open")
        self.assertEqual(
            closed_assignment["state"]["jobs"]["job-a"]["trial"]["assignment_closed_at"],
            "2026-01-31T00:00:00Z",
        )
        self.assertEqual(closed_assignment["state"]["jobs"]["job-a"]["trial"]["status"], "open")
        before_decision_trial = before_decision["state"]["jobs"]["job-a"]["trial"]
        self.assertEqual(before_decision_trial["status"], "open")
        self.assertFalse(
            any(item["decision"] == "fallback" for item in before_decision["decisions"])
        )
        self.assertEqual(result["decisions"][-1]["decision"], "fallback")
        self.assertEqual(result["decisions"][-1]["reason"], "decision_deadline_incomplete")

    def test_adapter_receipt_requires_exact_subject_frozen_identity_and_candidate(self) -> None:
        # given
        initial, admitted = admitted_trial(FIRST_CLOCK, adapter=adapter_binding())
        trial = trial_of(initial, admitted)
        mismatch_rows: list[tuple[str, dict[str, Any]]] = [
            ("subject_kind", {"subject_kind": "promotion"}),
            ("subject_digest", {"subject_digest": "f" * 64}),
            ("candidate", {"envelope_overrides": {"candidate_digest": "f" * 64}}),
            ("dataset", {"envelope_overrides": {"dataset_digest": "f" * 64}}),
            ("oracle", {"envelope_overrides": {"oracle_digest": "f" * 64}}),
            ("gates", {"envelope_overrides": {"gates_digest": "f" * 64}}),
            (
                "execution_surface",
                {"envelope_overrides": {"execution_surface_digest": "f" * 64}},
            ),
        ]

        # when / then
        for name, overrides in mismatch_rows:
            with self.subTest(row=name):
                with self.assertRaises(LearningContractError) as caught:
                    replay(
                        initial=initial,
                        events=[
                            *admitted,
                            adapter_receipt(
                                7,
                                CONTROL_OCCURRENCE,
                                trial_digest=trial_subject_digest(trial),
                                candidate_digest=trial["replacement_digest"],
                                outcome="pass",
                                **overrides,
                            ),
                        ],
                    )
                expected = (
                    "policy.adapter_subject"
                    if name.startswith("subject_")
                    else "policy.adapter_binding"
                )
                self.assertIn(expected, requirements(caught.exception))

    def test_adapter_receipt_rejects_each_identity_mismatch(self) -> None:
        # given
        initial, admitted = admitted_trial(FIRST_CLOCK, adapter=adapter_binding())
        trial = trial_of(initial, admitted)
        rows = [
            ("adapter_id", {"adapter_id": "other-adapter"}),
            ("adapter_version", {"adapter_version": "v2"}),
        ]

        # when / then
        for name, envelope_overrides in rows:
            with self.subTest(row=name):
                with self.assertRaises(LearningContractError) as caught:
                    replay(
                        initial=initial,
                        events=[
                            *admitted,
                            adapter_receipt(
                                7,
                                CONTROL_OCCURRENCE,
                                trial_digest=trial_subject_digest(trial),
                                candidate_digest=trial["replacement_digest"],
                                outcome="pass",
                                envelope_overrides=envelope_overrides,
                            ),
                        ],
                    )
                self.assertIn("policy.adapter_binding", requirements(caught.exception))

    def test_exact_pass_plus_two_positives_promotes_and_critical_falls_back(self) -> None:
        # given
        initial, admitted = admitted_trial(FIRST_CLOCK, adapter=adapter_binding())
        trial = trial_of(initial, admitted)
        candidate = trial["candidate_record_digest"]
        passed = adapter_receipt(
            7,
            CONTROL_OCCURRENCE,
            trial_digest=trial_subject_digest(trial),
            candidate_digest=trial["replacement_digest"],
            outcome="pass",
        )
        positive_tail = [
            passed,
            trial_run_created(8, CONTROL_OCCURRENCE, candidate, "trial-run-1"),
            trial_run_created(9, CONTROL_OCCURRENCE, candidate, "trial-run-2"),
            trial_run_settled(10, CONTROL_OCCURRENCE, "trial-run-1", "positive"),
            trial_run_settled(11, CONTROL_OCCURRENCE, "trial-run-2", "positive"),
        ]
        insufficient_tail = [
            passed,
            trial_run_created(8, CONTROL_OCCURRENCE, candidate, "trial-run-1"),
            trial_run_created(9, CONTROL_OCCURRENCE, candidate, "trial-run-2"),
            trial_run_created(10, CONTROL_OCCURRENCE, candidate, "trial-run-3"),
            trial_run_settled(11, CONTROL_OCCURRENCE, "trial-run-1", "positive"),
            trial_run_settled(12, CONTROL_OCCURRENCE, "trial-run-2", "neutral"),
            trial_run_settled(13, CONTROL_OCCURRENCE, "trial-run-3", "neutral"),
        ]

        # when
        pass_only = replay(initial=initial, events=[*admitted, passed])
        promoted = replay(initial=initial, events=[*admitted, *positive_tail])
        insufficient = replay(initial=initial, events=[*admitted, *insufficient_tail])
        veto_results = []
        for outcome in ("critical", "regression"):
            veto = adapter_receipt(
                7,
                CONTROL_OCCURRENCE,
                trial_digest=trial_subject_digest(trial),
                candidate_digest=trial["replacement_digest"],
                outcome=outcome,
            )
            veto_results.append((outcome, replay(initial=initial, events=[*admitted, veto])))

        # then
        self.assertEqual(pass_only["state"]["jobs"]["job-a"]["trial"]["status"], "open")
        self.assertEqual(promoted["decisions"][-1]["decision"], "promoted")
        self.assertEqual(promoted["state"]["jobs"]["job-a"]["trial"]["status"], "promoted")
        self.assertEqual(insufficient["decisions"][-1]["decision"], "fallback")
        self.assertEqual(insufficient["decisions"][-1]["reason"], "insufficient_positive_runs")
        self.assertEqual(
            promoted["state"]["jobs"]["job-a"]["trial"]["trial_digest"],
            trial_subject_digest(trial),
        )
        for outcome, result in veto_results:
            with self.subTest(adapter_outcome=outcome):
                self.assertEqual(result["decisions"][-1]["decision"], "fallback")
                self.assertEqual(result["decisions"][-1]["reason"], f"adapter_{outcome}")
                self.assertEqual(result["state"]["jobs"]["job-a"]["trial"]["status"], "fallback")

    def test_future_evidence_waits_for_explicit_clock_advance(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID,
            controlled_clock="2026-01-01T00:00:00Z",
            jobs=[job("job-a")],
        )
        future_evidence = [
            stable_evaluation(
                1,
                "2026-01-01T00:00:00Z",
                "job-a",
                "run-1",
                "reusable_issue",
                ["x"],
                logical_occurrence="2026-01-02T00:00:00Z",
            ),
            stable_evaluation(
                2,
                "2026-01-01T00:00:01Z",
                "job-a",
                "run-2",
                "reusable_issue",
                ["x"],
                logical_occurrence="2026-01-02T00:00:00Z",
            ),
        ]
        reach_occurrence = clock_advanced(3, "2026-01-02T00:00:00Z")

        # when
        before_clock = replay(initial=initial, events=future_evidence)
        after_clock = replay(initial=initial, events=[*future_evidence, reach_occurrence])

        # then
        self.assertEqual(before_clock["decisions"], [])
        self.assertEqual(
            [decision["decision"] for decision in after_clock["decisions"]],
            ["reflected"],
        )

    def test_trial_dispute_immediately_falls_back_unless_owner_result_replaces_it(
        self,
    ) -> None:
        # given
        initial, admitted = admitted_trial(FIRST_CLOCK)
        trial = trial_of(initial, admitted)
        created = trial_run_created(
            7,
            CONTROL_OCCURRENCE,
            trial["candidate_record_digest"],
            "trial-run-1",
        )
        settled = trial_run_settled(8, CONTROL_OCCURRENCE, "trial-run-1", "positive")
        evaluation_digest = trial_evaluation_digest(settled)
        dispute = owner_signal(
            9,
            CONTROL_OCCURRENCE,
            "job-a",
            "evaluation_dispute",
            subject_kind="evaluation",
            subject_digest=evaluation_digest,
            run_id="trial-run-1",
            revision=1,
        )
        replacement = run_signal(
            9,
            CONTROL_OCCURRENCE,
            "job-a",
            "trial-run-1",
            "result_useful",
            revision=1,
        )
        replaced_dispute = owner_signal(
            10,
            CONTROL_OCCURRENCE,
            "job-a",
            "evaluation_dispute",
            subject_kind="evaluation",
            subject_digest=evaluation_digest,
            run_id="trial-run-1",
            revision=1,
        )

        # when
        disputed = replay(
            initial=initial,
            events=[*admitted, created, settled, dispute],
        )
        replaced = replay(
            initial=initial,
            events=[
                *admitted,
                created,
                settled,
                replacement,
                replaced_dispute,
            ],
        )

        # then
        self.assertEqual(disputed["state"]["jobs"]["job-a"]["trial"]["status"], "fallback")
        self.assertEqual(disputed["decisions"][-1]["reason"], "hard_veto")
        replaced_trial = replaced["state"]["jobs"]["job-a"]["trial"]
        self.assertEqual(replaced_trial["status"], "open")

    def test_run_id_cannot_cross_stable_and_trial_classifications_in_either_order(self) -> None:
        # given
        stable_first_initial, stable_first_admitted = admitted_trial(FIRST_CLOCK)
        stable_first_trial = trial_of(stable_first_initial, stable_first_admitted)
        stable_first = stable_evaluation(
            7,
            CONTROL_OCCURRENCE,
            "job-a",
            "shared-run",
            "no_issue",
            [],
        )
        duplicate_trial = trial_run_created(
            8,
            CONTROL_OCCURRENCE,
            stable_first_trial["candidate_record_digest"],
            "shared-run",
        )
        trial_first_initial, promoted = promotable_trial()
        replacement_trial = append_admitted_trial(
            trial_first_initial,
            promoted,
            lessons=["Use a second replacement."],
        )
        replacement_state = replay(
            initial=trial_first_initial,
            events=replacement_trial,
        )["state"]["jobs"]["job-a"]
        duplicate_stable = stable_evaluation(
            len(replacement_trial) + 1,
            CONTROL_OCCURRENCE,
            "job-a",
            "trial-run-1",
            "no_issue",
            [],
            stable_digest=replacement_state["stable_digest"],
            learning_epoch=replacement_state["learning_epoch"],
            compatibility_digest=replacement_state["compatibility_digest"],
        )

        # when
        with self.assertRaises(LearningContractError) as trial_caught:
            replay(
                initial=stable_first_initial,
                events=[*stable_first_admitted, stable_first, duplicate_trial],
            )
        with self.assertRaises(LearningContractError) as stable_caught:
            replay(
                initial=trial_first_initial,
                events=[*replacement_trial, duplicate_stable],
            )

        # then
        self.assertIn("policy.duplicate_trial_run", requirements(trial_caught.exception))
        self.assertIn(
            "policy.trial_run_stable_classification", requirements(stable_caught.exception)
        )
