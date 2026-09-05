"""Stable evidence and owner precedence tests."""

from __future__ import annotations

import unittest

from benchmark_learning.learning_contract import LearningContractError, ReplayEvent
from benchmark_learning.learning_replay import initial_state, replay

from .support import (
    ALGORITHM_ID,
    FIRST_CLOCK,
    FIRST_OCCURRENCE,
    SECOND_OCCURRENCE,
    evaluation_signal,
    job,
    owner_correction,
    owner_signal,
    requirements,
    run_signal,
    stable_evaluation,
)


class LearningReplayEvidenceTests(unittest.TestCase):
    def test_two_distinct_recent_compatible_negatives_trigger_once(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID,
            controlled_clock="2026-01-31T00:00:00Z",
            jobs=[job("job-a")],
        )
        events = [
            stable_evaluation(
                1, "2026-01-01T00:00:00Z", "job-a", "run-1", "reusable_issue", ["y", "x"]
            ),
            stable_evaluation(
                2, "2026-01-02T00:00:00Z", "job-a", "run-2", "reusable_issue", ["x", "y"]
            ),
        ]
        repeated_run = [
            stable_evaluation(1, "2026-01-01T00:00:00Z", "job-a", "run-1", "reusable_issue", ["x"]),
            stable_evaluation(
                2,
                "2026-01-02T00:00:00Z",
                "job-a",
                "run-1",
                "reusable_issue",
                ["x"],
                evaluation_digest="evaluation-run-1-retry",
            ),
        ]

        # when
        result = replay(initial=initial, events=events)
        duplicate_result = replay(initial=initial, events=repeated_run)

        # then
        self.assertEqual([item["decision"] for item in result["decisions"]], ["reflected"])
        self.assertEqual(result["decisions"][0]["artifact_identities"]["issue_codes"], ["x", "y"])
        self.assertEqual(duplicate_result["decisions"], [])

    def test_owner_correction_overrides_evaluator_and_triggers_reflection(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID,
            controlled_clock="2026-01-01T00:00:00Z",
            jobs=[job("job-a")],
        )
        events = [
            stable_evaluation(1, "2026-01-01T00:00:00Z", "job-a", "run-1", "no_issue", []),
            owner_correction(2, "2026-01-01T00:00:00Z", "job-a", "run-1", revision=1),
        ]

        # when
        result = replay(initial=initial, events=events)

        # then
        self.assertEqual(result["decisions"][-1]["reason"], "owner_correction")
        evidence = result["state"]["jobs"]["job-a"]["triggers"][0]["evidence"]
        self.assertFalse(evidence[0]["evaluation_required"])

    def test_run_owner_signal_requires_exact_recorded_run_identity(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID, controlled_clock=FIRST_CLOCK, jobs=[job("job-a")]
        )
        evaluation = stable_evaluation(1, FIRST_OCCURRENCE, "job-a", "run-1", "no_issue", [])
        forged = owner_signal(
            2,
            FIRST_OCCURRENCE,
            "job-a",
            "result_correction",
            subject_kind="run",
            subject_digest="another-run",
            run_id="run-1",
            revision=1,
            payload={"correction_text": "state the deadline"},
        )

        # when
        with self.assertRaises(LearningContractError) as caught:
            replay(initial=initial, events=[evaluation, forged])

        # then
        self.assertIn("policy.unknown_subject", requirements(caught.exception))

    def test_dispute_removes_evaluator_evidence_but_keeps_run_owner_result(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID, controlled_clock=FIRST_CLOCK, jobs=[job("job-a")]
        )
        events = [
            stable_evaluation(
                1,
                FIRST_OCCURRENCE,
                "job-a",
                "run-1",
                "reusable_issue",
                ["evaluator-only"],
            ),
            evaluation_signal(
                2, FIRST_OCCURRENCE, "job-a", "run-1", "evaluation_dispute", revision=1
            ),
            owner_correction(3, FIRST_OCCURRENCE, "job-a", "run-1", revision=1),
        ]

        # when
        result = replay(initial=initial, events=events)

        # then
        reflected = result["decisions"][-1]
        self.assertEqual(reflected["reason"], "owner_correction")
        self.assertEqual(reflected["artifact_identities"]["issue_codes"], [])

    def test_stable_window_selects_latest_five_compatible_recent_evaluations(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID, controlled_clock=FIRST_CLOCK, jobs=[job("job-a")]
        )
        latest_five = [
            stable_evaluation(
                index + 1,
                f"2026-01-0{index + 1}T00:00:00Z",
                "job-a",
                f"run-{index + 1}",
                "reusable_issue",
                ["x"],
            )
            for index in range(6)
        ]
        rows: list[tuple[str, list[ReplayEvent], int, list[str] | None]] = [
            (
                "retains_only_the_latest_five",
                latest_five,
                5,
                [f"evaluation-run-{index}" for index in range(2, 7)],
            ),
            (
                "excludes_a_31_day_old_occurrence",
                [
                    stable_evaluation(
                        1,
                        FIRST_OCCURRENCE,
                        "job-a",
                        "run-0",
                        "reusable_issue",
                        ["x"],
                        logical_occurrence="2025-12-31T00:00:00Z",
                    ),
                    stable_evaluation(
                        2, SECOND_OCCURRENCE, "job-a", "run-1", "reusable_issue", ["x"]
                    ),
                ],
                0,
                None,
            ),
            (
                "excludes_a_compatibility_mismatch",
                [
                    stable_evaluation(
                        1,
                        FIRST_OCCURRENCE,
                        "job-a",
                        "run-1",
                        "reusable_issue",
                        ["x"],
                        compatibility_digest="compatibility-1",
                    ),
                    stable_evaluation(
                        2, SECOND_OCCURRENCE, "job-a", "run-2", "reusable_issue", ["x"]
                    ),
                ],
                0,
                None,
            ),
            (
                "excludes_a_stable_base_mismatch",
                [
                    stable_evaluation(
                        1,
                        FIRST_OCCURRENCE,
                        "job-a",
                        "run-1",
                        "reusable_issue",
                        ["x"],
                        stable_digest="stable-1",
                    ),
                    stable_evaluation(
                        2, SECOND_OCCURRENCE, "job-a", "run-2", "reusable_issue", ["x"]
                    ),
                ],
                0,
                None,
            ),
            (
                "excludes_a_learning_epoch_mismatch",
                [
                    stable_evaluation(
                        1,
                        FIRST_OCCURRENCE,
                        "job-a",
                        "run-1",
                        "reusable_issue",
                        ["x"],
                        learning_epoch=1,
                    ),
                    stable_evaluation(
                        2, SECOND_OCCURRENCE, "job-a", "run-2", "reusable_issue", ["x"]
                    ),
                ],
                0,
                None,
            ),
            (
                "orders_by_logical_occurrence_not_completion",
                [
                    stable_evaluation(
                        1,
                        "2026-01-20T00:00:00Z",
                        "job-a",
                        "run-a",
                        "reusable_issue",
                        ["x"],
                        logical_occurrence="2026-01-10T00:00:00Z",
                    ),
                    stable_evaluation(
                        2,
                        "2026-01-21T00:00:00Z",
                        "job-a",
                        "run-b",
                        "reusable_issue",
                        ["x"],
                        logical_occurrence="2026-01-05T00:00:00Z",
                    ),
                ],
                1,
                ["evaluation-run-b", "evaluation-run-a"],
            ),
            (
                "breaks_equal_occurrences_by_run_id",
                [
                    stable_evaluation(
                        1, FIRST_OCCURRENCE, "job-a", "run-b", "reusable_issue", ["x"]
                    ),
                    stable_evaluation(
                        2, FIRST_OCCURRENCE, "job-a", "run-a", "reusable_issue", ["x"]
                    ),
                ],
                1,
                ["evaluation-run-a", "evaluation-run-b"],
            ),
        ]

        for name, events, expected_decisions, expected_evidence in rows:
            with self.subTest(row=name):
                # when
                result = replay(initial=initial, events=events)

                # then
                self.assertEqual(len(result["decisions"]), expected_decisions)
                if expected_evidence is not None:
                    identities = result["decisions"][-1]["artifact_identities"]
                    self.assertEqual(identities["evidence_digests"], expected_evidence)

    def test_effective_outcome_resolves_each_owner_signal_category(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID, controlled_clock=FIRST_CLOCK, jobs=[job("job-a")]
        )
        rows: list[tuple[str, list[ReplayEvent], list[str] | None]] = [
            (
                "result_useful_overrides_a_negative_evaluation",
                [
                    stable_evaluation(
                        1, FIRST_OCCURRENCE, "job-a", "run-1", "reusable_issue", ["x"]
                    ),
                    run_signal(2, FIRST_OCCURRENCE, "job-a", "run-1", "result_useful", revision=1),
                    stable_evaluation(
                        3, SECOND_OCCURRENCE, "job-a", "run-2", "reusable_issue", ["x"]
                    ),
                ],
                None,
            ),
            (
                "evaluation_confirm_preserves_the_evaluator_outcome",
                [
                    stable_evaluation(
                        1, FIRST_OCCURRENCE, "job-a", "run-1", "reusable_issue", ["x"]
                    ),
                    evaluation_signal(
                        2, FIRST_OCCURRENCE, "job-a", "run-1", "evaluation_confirm", revision=1
                    ),
                    stable_evaluation(
                        3, SECOND_OCCURRENCE, "job-a", "run-2", "reusable_issue", ["x"]
                    ),
                ],
                ["x"],
            ),
            (
                "evaluation_dispute_removes_the_evaluation",
                [
                    stable_evaluation(
                        1, FIRST_OCCURRENCE, "job-a", "run-1", "reusable_issue", ["x"]
                    ),
                    evaluation_signal(
                        2, FIRST_OCCURRENCE, "job-a", "run-1", "evaluation_dispute", revision=1
                    ),
                    stable_evaluation(
                        3, SECOND_OCCURRENCE, "job-a", "run-2", "reusable_issue", ["x"]
                    ),
                ],
                None,
            ),
            (
                "result_not_useful_synthesizes_the_owner_code",
                [
                    stable_evaluation(1, FIRST_OCCURRENCE, "job-a", "run-1", "no_issue", []),
                    run_signal(
                        2, FIRST_OCCURRENCE, "job-a", "run-1", "result_not_useful", revision=1
                    ),
                    stable_evaluation(3, SECOND_OCCURRENCE, "job-a", "run-2", "no_issue", []),
                    run_signal(
                        4, SECOND_OCCURRENCE, "job-a", "run-2", "result_not_useful", revision=1
                    ),
                ],
                ["owner_not_useful"],
            ),
            (
                "result_not_useful_keeps_the_exact_evaluator_codes",
                [
                    stable_evaluation(
                        1, FIRST_OCCURRENCE, "job-a", "run-1", "reusable_issue", ["x"]
                    ),
                    run_signal(
                        2, FIRST_OCCURRENCE, "job-a", "run-1", "result_not_useful", revision=1
                    ),
                    stable_evaluation(
                        3, SECOND_OCCURRENCE, "job-a", "run-2", "reusable_issue", ["x"]
                    ),
                ],
                ["x"],
            ),
            (
                "transient_and_uncertain_outcomes_are_neutral",
                [
                    stable_evaluation(
                        1, FIRST_OCCURRENCE, "job-a", "run-1", "transient_issue", ["x"]
                    ),
                    stable_evaluation(2, SECOND_OCCURRENCE, "job-a", "run-2", "uncertain", ["x"]),
                ],
                None,
            ),
        ]

        for name, events, expected_codes in rows:
            with self.subTest(row=name):
                # when
                result = replay(initial=initial, events=events)

                # then
                reflected = [
                    item for item in result["decisions"] if item["decision"] == "reflected"
                ]
                if expected_codes is None:
                    self.assertEqual(reflected, [])
                else:
                    self.assertEqual(len(reflected), 1)
                    self.assertEqual(
                        reflected[0]["artifact_identities"]["issue_codes"], expected_codes
                    )
