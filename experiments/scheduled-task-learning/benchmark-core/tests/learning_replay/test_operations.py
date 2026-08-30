"""Controller and operation lifecycle tests."""

from __future__ import annotations

import unittest

from benchmark_learning.learning_contract import LearningContractError
from benchmark_learning.learning_replay import initial_state, replay

from .support import (
    ALGORITHM_ID,
    CONTROL_OCCURRENCE,
    FIRST_CLOCK,
    REFLECTION_OCCURRENCE,
    admitted_trial,
    controller_started,
    frozen_trigger_digest,
    job,
    negative_evidence,
    operation_finished,
    operation_started,
    requirements,
    trial_of,
    trial_run_created,
)


class LearningReplayOperationTests(unittest.TestCase):
    def test_controller_started_marks_prior_started_operation_interrupted_unknown(self) -> None:
        # given
        simple_initial = initial_state(
            algorithm_id=ALGORITHM_ID,
            controlled_clock="2026-01-01T00:00:00Z",
            jobs=[job("job-a")],
        )
        reflector_initial = initial_state(
            algorithm_id=ALGORITHM_ID,
            controlled_clock=FIRST_CLOCK,
            jobs=[job("job-a")],
        )
        evidence = negative_evidence()
        trigger_digest = frozen_trigger_digest(reflector_initial, evidence)
        rows = [
            (
                "task",
                simple_initial,
                [
                    operation_started(
                        1,
                        "2026-01-01T00:00:00Z",
                        kind="task",
                        generation=1,
                        operation_id="task-1",
                    ),
                    controller_started(2, "2026-01-01T00:00:01Z", generation=2),
                ],
                "task-1",
            ),
            (
                "evaluator",
                simple_initial,
                [
                    operation_started(
                        1,
                        "2026-01-01T00:00:00Z",
                        kind="evaluator",
                        generation=1,
                        operation_id="eval-1",
                    ),
                    controller_started(2, "2026-01-01T00:00:01Z", generation=2),
                ],
                "eval-1",
            ),
            (
                "reflector",
                reflector_initial,
                [
                    *evidence,
                    operation_started(
                        3,
                        REFLECTION_OCCURRENCE,
                        kind="reflector",
                        generation=1,
                        operation_id=trigger_digest,
                    ),
                    controller_started(4, "2026-01-03T00:00:01Z", generation=2),
                ],
                trigger_digest,
            ),
        ]

        # when
        results = [
            (kind, operation_id, replay(initial=initial, events=events))
            for kind, initial, events, operation_id in rows
        ]

        # then
        for kind, operation_id, result in results:
            with self.subTest(operation_kind=kind):
                operation = result["state"]["jobs"]["job-a"]["operations"][operation_id]
                self.assertEqual(operation["status"], "interrupted_unknown")
                self.assertEqual(result["state"]["controller_generation"], 2)

    def test_controller_restart_covers_all_operation_kinds_and_exact_next_generation(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID,
            controlled_clock="2026-01-01T00:00:00Z",
            jobs=[job("job-a")],
        )
        events = [
            operation_started(
                1,
                "2026-01-01T00:00:00Z",
                kind="evaluator",
                generation=1,
                operation_id="eval-1",
            ),
            controller_started(2, "2026-01-01T00:00:01Z", generation=3),
        ]

        # when
        with self.assertRaises(LearningContractError) as caught:
            replay(initial=initial, events=events)

        # then
        self.assertIn("policy.controller_generation", requirements(caught.exception))

    def test_end_of_log_does_not_synthesize_interruption_or_clock_advance(self) -> None:
        # given
        simple_initial = initial_state(
            algorithm_id=ALGORITHM_ID,
            controlled_clock="2026-01-01T00:00:00Z",
            jobs=[job("job-a")],
        )
        reflector_initial = initial_state(
            algorithm_id=ALGORITHM_ID,
            controlled_clock=FIRST_CLOCK,
            jobs=[job("job-a")],
        )
        evidence = negative_evidence()
        trigger_digest = frozen_trigger_digest(reflector_initial, evidence)
        operation_rows = [
            (
                "task",
                simple_initial,
                [
                    operation_started(
                        1,
                        "2026-01-01T00:00:00Z",
                        kind="task",
                        generation=1,
                        operation_id="task-1",
                    )
                ],
                "task-1",
            ),
            (
                "evaluator",
                simple_initial,
                [
                    operation_started(
                        1,
                        "2026-01-01T00:00:00Z",
                        kind="evaluator",
                        generation=1,
                        operation_id="eval-1",
                    )
                ],
                "eval-1",
            ),
            (
                "reflector",
                reflector_initial,
                [
                    *evidence,
                    operation_started(
                        3,
                        REFLECTION_OCCURRENCE,
                        kind="reflector",
                        generation=1,
                        operation_id=trigger_digest,
                    ),
                ],
                trigger_digest,
            ),
        ]
        trial_initial, admitted = admitted_trial("2026-01-01T00:00:00Z")
        trial = trial_of(trial_initial, admitted)
        created = trial_run_created(
            7,
            CONTROL_OCCURRENCE,
            trial["candidate_record_digest"],
            "trial-run-1",
        )

        # when
        operation_results = [
            (kind, operation_id, replay(initial=initial, events=events))
            for kind, initial, events, operation_id in operation_rows
        ]
        trial_result = replay(initial=trial_initial, events=[*admitted, created])

        # then
        for kind, operation_id, result in operation_results:
            with self.subTest(operation_kind=kind):
                operation = result["state"]["jobs"]["job-a"]["operations"][operation_id]
                self.assertEqual(operation["status"], "started")
        trial_state = trial_result["state"]["jobs"]["job-a"]["trial"]
        self.assertEqual(trial_result["state"]["controlled_clock"], "2026-01-01T00:00:00Z")
        self.assertIsNone(trial_state["assignment_closed_at"])
        self.assertEqual(trial_state["status"], "open")
        self.assertFalse(
            any(item["decision"] in {"promoted", "fallback"} for item in trial_result["decisions"])
        )

    def test_operation_events_reject_unknown_nonterminal_or_mismatched_identity(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID,
            controlled_clock="2026-01-01T00:00:00Z",
            jobs=[job("job-a")],
        )
        started = operation_started(
            1,
            "2026-01-01T00:00:00Z",
            kind="evaluator",
            generation=1,
            operation_id="eval-1",
        )
        finished = operation_finished(
            2,
            "2026-01-01T00:00:01Z",
            kind="evaluator",
            generation=1,
            operation_id="eval-1",
        )

        # when
        with self.assertRaises(LearningContractError) as unknown_kind:
            operation_started(
                1,
                "2026-01-01T00:00:00Z",
                kind="planner",
                generation=1,
                operation_id="planner-1",
            )
        with self.assertRaises(LearningContractError) as nonterminal_status:
            operation_finished(
                2,
                "2026-01-01T00:00:01Z",
                kind="evaluator",
                generation=1,
                operation_id="eval-1",
                status="started",
            )
        with self.assertRaises(LearningContractError) as unknown_operation:
            replay(
                initial=initial,
                events=[
                    started,
                    operation_finished(
                        2,
                        "2026-01-01T00:00:01Z",
                        kind="evaluator",
                        generation=1,
                        operation_id="eval-other",
                    ),
                ],
            )
        with self.assertRaises(LearningContractError) as wrong_generation:
            replay(
                initial=initial,
                events=[
                    started,
                    operation_finished(
                        2,
                        "2026-01-01T00:00:01Z",
                        kind="evaluator",
                        generation=2,
                        operation_id="eval-1",
                    ),
                ],
            )
        with self.assertRaises(LearningContractError) as wrong_kind:
            replay(
                initial=initial,
                events=[
                    started,
                    operation_finished(
                        2,
                        "2026-01-01T00:00:01Z",
                        kind="task",
                        generation=1,
                        operation_id="eval-1",
                    ),
                ],
            )
        with self.assertRaises(LearningContractError) as rebound_result:
            replay(
                initial=initial,
                events=[
                    started,
                    finished,
                    operation_finished(
                        3,
                        "2026-01-01T00:00:02Z",
                        kind="evaluator",
                        generation=1,
                        operation_id="eval-1",
                        result_digest="result-2",
                        usage_digest="usage-2",
                    ),
                ],
            )

        # then
        self.assertIn("schema.closed_enums", requirements(unknown_kind.exception))
        self.assertIn("schema.closed_enums", requirements(nonterminal_status.exception))
        self.assertIn("policy.unknown_operation", requirements(unknown_operation.exception))
        self.assertIn("policy.operation_identity", requirements(wrong_generation.exception))
        self.assertIn("policy.operation_identity", requirements(wrong_kind.exception))
        self.assertIn("policy.operation_identity", requirements(rebound_result.exception))
