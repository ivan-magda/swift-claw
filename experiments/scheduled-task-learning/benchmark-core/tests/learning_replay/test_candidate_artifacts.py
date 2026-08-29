"""Candidate artifact and reflector control tests."""

from __future__ import annotations

import unittest
from typing import Any

from benchmark_core.canonical import canonical_sha256
from benchmark_learning.learning_contract import LearningContractError, ReplayEvent
from benchmark_learning.learning_replay import initial_state, replay

from .support import (
    ALGORITHM_ID,
    CANDIDATE_RECORD_DOMAIN,
    CONTROL_OCCURRENCE,
    FIRST_CLOCK,
    FIRST_OCCURRENCE,
    LESSONS,
    REFLECTION_OCCURRENCE,
    SECOND_OCCURRENCE,
    STABLE_DIGEST,
    candidate_admitted,
    candidate_artifact,
    candidate_signal,
    candidates_of,
    evaluation_signal,
    event,
    frozen_trigger_digest,
    job,
    lesson_set_digest,
    negative_evidence,
    operation_finished,
    recorded_candidate,
    reflector_operation,
    requirements,
    stable_evaluation,
    trial_of,
    trial_run_created,
    trial_run_settled,
)


class LearningReplayCandidateArtifactTests(unittest.TestCase):
    def test_candidate_artifact_normalizes_and_rejects_invalid_or_noop_lessons(self) -> None:
        # given
        raw = ["  Café\r\n rules  "]
        normalized = ["Café\n rules"]
        initial, prefix = recorded_candidate()
        trigger_digest = prefix[-1].payload["trigger_digest"]
        noop_jobs = [job("job-a", stable_digest=lesson_set_digest(LESSONS))]
        noop_evidence = [
            stable_evaluation(
                1,
                FIRST_OCCURRENCE,
                "job-a",
                "run-1",
                "reusable_issue",
                ["x"],
                stable_digest=lesson_set_digest(LESSONS),
            ),
            stable_evaluation(
                2,
                SECOND_OCCURRENCE,
                "job-a",
                "run-2",
                "reusable_issue",
                ["x"],
                stable_digest=lesson_set_digest(LESSONS),
            ),
        ]
        noop_initial = initial_state(
            algorithm_id=ALGORITHM_ID, controlled_clock=FIRST_CLOCK, jobs=noop_jobs
        )
        noop_trigger = frozen_trigger_digest(noop_initial, noop_evidence)
        empty_initial, empty_events = recorded_candidate(lessons=[])
        ordered_lessons = ["Zulu remains first.", "Alpha remains second."]
        ordered_initial, ordered_events = recorded_candidate(lessons=ordered_lessons)
        rejections: list[tuple[str, list[str], set[str]]] = [
            ("more_than_three_lessons", ["a", "b", "c", "d"], {"policy.lesson_count"}),
            ("blank_after_normalization", ["   \r\n  "], {"policy.empty_lesson"}),
            ("duplicate_after_normalization", ["rule", " rule "], {"policy.duplicate_lesson"}),
            ("over_512_utf8_bytes", ["é" * 257], {"policy.lesson_bytes"}),
            (
                "over_1536_total_utf8_bytes",
                ["a" * 512, "b" * 512, "c" * 512, "d" * 512],
                {"policy.lesson_count", "policy.lesson_set_bytes"},
            ),
        ]

        # when
        normalizing = replay(
            initial=initial,
            events=[
                *prefix[:-1],
                candidate_artifact(
                    5, REFLECTION_OCCURRENCE, "job-a", trigger_digest, raw, normalized=normalized
                ),
            ],
        )
        empty_result = replay(initial=empty_initial, events=empty_events)
        ordered_result = replay(initial=ordered_initial, events=ordered_events)

        # then
        self.assertEqual(candidates_of(normalizing)[0]["lessons"], normalized)
        self.assertEqual(
            candidates_of(normalizing)[0]["replacement_digest"], lesson_set_digest(normalized)
        )
        self.assertEqual(candidates_of(empty_result)[0]["lessons"], [])
        self.assertEqual(
            candidates_of(empty_result)[0]["replacement_digest"], lesson_set_digest([])
        )
        self.assertEqual(candidates_of(ordered_result)[0]["lessons"], ordered_lessons)
        for name, lessons, expected in rejections:
            with self.subTest(row=name), self.assertRaises(LearningContractError) as caught:
                replay(
                    initial=initial,
                    events=[
                        *prefix[:-1],
                        candidate_artifact(
                            5, REFLECTION_OCCURRENCE, "job-a", trigger_digest, lessons
                        ),
                    ],
                )
            self.assertEqual(requirements(caught.exception) & expected, expected)

        with self.assertRaises(LearningContractError) as noop:
            replay(
                initial=noop_initial,
                events=[
                    *noop_evidence,
                    *reflector_operation(3, REFLECTION_OCCURRENCE, "job-a", noop_trigger),
                    candidate_artifact(
                        5,
                        REFLECTION_OCCURRENCE,
                        "job-a",
                        noop_trigger,
                        LESSONS,
                        base_digest=lesson_set_digest(LESSONS),
                    ),
                ],
            )
        self.assertIn("policy.noop_replacement", requirements(noop.exception))

    def test_candidate_digest_projections_exclude_claimed_digests(self) -> None:
        # given
        initial, events = recorded_candidate()
        artifact = events[-1].payload
        core = {
            "schema_version": 1,
            "job_id": "job-a",
            "operation_id": artifact["operation_id"],
            "result_digest": artifact["result_digest"],
            "replacement_digest": lesson_set_digest(LESSONS),
            "lessons": LESSONS,
            "source_manifest_digest": artifact["source_manifest_digest"],
            "base_digest": STABLE_DIGEST,
            "base_revision": 0,
            "learning_epoch": 0,
            "feedback_revision": 0,
            "algorithm_id": ALGORITHM_ID,
            "trigger_digest": artifact["trigger_digest"],
        }
        record_digest = canonical_sha256({"domain": CANDIDATE_RECORD_DOMAIN, "value": core})
        self_inclusive = canonical_sha256(
            {
                "domain": CANDIDATE_RECORD_DOMAIN,
                "value": {**core, "candidate_record_digest": record_digest},
            }
        )

        # when
        result = replay(initial=initial, events=events)

        # then
        stored = candidates_of(result)[0]
        self.assertEqual(stored["replacement_digest"], lesson_set_digest(LESSONS))
        self.assertEqual(stored["candidate_record_digest"], record_digest)
        self.assertNotEqual(stored["candidate_record_digest"], stored["replacement_digest"])
        with self.assertRaises(LearningContractError) as claimed:
            replay(
                initial=initial,
                events=[
                    *events[:-1],
                    candidate_artifact(
                        5,
                        REFLECTION_OCCURRENCE,
                        "job-a",
                        artifact["trigger_digest"],
                        LESSONS,
                        candidate_record_digest=self_inclusive,
                    ),
                ],
            )
        self.assertIn("policy.candidate_record_digest", requirements(claimed.exception))
        with self.assertRaises(LearningContractError) as swapped:
            replay(
                initial=initial,
                events=[
                    *events[:-1],
                    candidate_artifact(
                        5,
                        REFLECTION_OCCURRENCE,
                        "job-a",
                        artifact["trigger_digest"],
                        LESSONS,
                        replacement_digest=record_digest,
                    ),
                ],
            )
        self.assertIn("policy.replacement_digest", requirements(swapped.exception))

    def test_reflector_start_binds_and_consumes_one_trigger(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID, controlled_clock=FIRST_CLOCK, jobs=[job("job-a")]
        )
        evidence = negative_evidence()
        trigger_digest = frozen_trigger_digest(initial, evidence)
        failed_attempt = reflector_operation(
            3,
            REFLECTION_OCCURRENCE,
            "job-a",
            trigger_digest,
            operation_id="reflector-failed",
            status="failed",
        )
        retry = reflector_operation(
            5,
            REFLECTION_OCCURRENCE,
            "job-a",
            trigger_digest,
            operation_id="reflector-retry",
        )[0]
        unknown_start = reflector_operation(
            3,
            REFLECTION_OCCURRENCE,
            "job-a",
            "unknown-trigger",
            operation_id="reflector-unknown",
        )[0]
        successful_attempt = reflector_operation(
            3,
            REFLECTION_OCCURRENCE,
            "job-a",
            trigger_digest,
            operation_id="reflector-closed",
        )
        close_trigger = event(
            5,
            REFLECTION_OCCURRENCE,
            "no_candidate_recorded",
            {
                "job_id": "job-a",
                "operation_id": "reflector-closed",
                "result_digest": "reflector-result-1",
                "trigger_digest": trigger_digest,
            },
        )
        closed_retry = reflector_operation(
            6,
            REFLECTION_OCCURRENCE,
            "job-a",
            trigger_digest,
            operation_id="reflector-after-close",
        )[0]

        # when
        attempted = replay(initial=initial, events=[*evidence, *failed_attempt])
        with self.assertRaises(LearningContractError) as attempted_caught:
            replay(initial=initial, events=[*evidence, *failed_attempt, retry])
        with self.assertRaises(LearningContractError) as unknown_caught:
            replay(initial=initial, events=[*evidence, unknown_start])
        with self.assertRaises(LearningContractError) as closed_caught:
            replay(
                initial=initial,
                events=[*evidence, *successful_attempt, close_trigger, closed_retry],
            )

        # then
        trigger = attempted["state"]["jobs"]["job-a"]["triggers"][0]
        self.assertTrue(trigger["attempted"])
        self.assertEqual(trigger["operation_id"], "reflector-failed")
        self.assertIn("policy.attempted_trigger", requirements(attempted_caught.exception))
        self.assertIn("policy.unknown_trigger", requirements(unknown_caught.exception))
        self.assertIn("policy.closed_trigger", requirements(closed_caught.exception))

    def test_no_candidate_closes_trigger_and_artifact_alone_opens_no_trial(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID, controlled_clock=FIRST_CLOCK, jobs=[job("job-a")]
        )
        evidence = negative_evidence()
        trigger_digest = frozen_trigger_digest(initial, evidence)
        no_candidate = event(
            5,
            REFLECTION_OCCURRENCE,
            "no_candidate_recorded",
            {
                "job_id": "job-a",
                "operation_id": "reflector-1",
                "result_digest": "reflector-result-1",
                "trigger_digest": trigger_digest,
            },
        )
        closing = [
            *evidence,
            *reflector_operation(3, REFLECTION_OCCURRENCE, "job-a", trigger_digest),
            no_candidate,
        ]
        artifact_initial, artifact_events = recorded_candidate()
        invalid_rows: list[tuple[str, dict[str, Any], list[ReplayEvent], str]] = [
            (
                "operation_kind",
                initial,
                [
                    *evidence,
                    *reflector_operation(
                        3,
                        REFLECTION_OCCURRENCE,
                        "job-a",
                        trigger_digest,
                        operation_kind="task",
                    ),
                    no_candidate,
                ],
                "policy.operation_identity",
            ),
            (
                "terminal_status",
                initial,
                [
                    *evidence,
                    *reflector_operation(
                        3,
                        REFLECTION_OCCURRENCE,
                        "job-a",
                        trigger_digest,
                        status="failed",
                    ),
                    no_candidate,
                ],
                "policy.operation_identity",
            ),
            (
                "operation_id",
                initial,
                [
                    *evidence,
                    *reflector_operation(3, REFLECTION_OCCURRENCE, "job-a", trigger_digest),
                    event(
                        5,
                        REFLECTION_OCCURRENCE,
                        "no_candidate_recorded",
                        {**no_candidate.payload, "operation_id": "reflector-other"},
                    ),
                ],
                "policy.unknown_operation",
            ),
            (
                "result_digest",
                initial,
                [
                    *evidence,
                    *reflector_operation(3, REFLECTION_OCCURRENCE, "job-a", trigger_digest),
                    event(
                        5,
                        REFLECTION_OCCURRENCE,
                        "no_candidate_recorded",
                        {**no_candidate.payload, "result_digest": "another-result"},
                    ),
                ],
                "policy.result_binding",
            ),
        ]
        second_trigger_events = [
            *evidence,
            stable_evaluation(
                3,
                REFLECTION_OCCURRENCE,
                "job-a",
                "run-3",
                "reusable_issue",
                ["x"],
            ),
        ]
        second_trigger_result = replay(initial=initial, events=second_trigger_events)
        first_trigger = second_trigger_result["decisions"][0]["artifact_identities"][
            "trigger_digest"
        ]
        second_trigger = second_trigger_result["decisions"][1]["artifact_identities"][
            "trigger_digest"
        ]
        invalid_rows.append(
            (
                "trigger_digest",
                initial,
                [
                    *second_trigger_events,
                    *reflector_operation(4, REFLECTION_OCCURRENCE, "job-a", first_trigger),
                    event(
                        6,
                        REFLECTION_OCCURRENCE,
                        "no_candidate_recorded",
                        {**no_candidate.payload, "trigger_digest": second_trigger},
                    ),
                ],
                "policy.trigger_binding",
            )
        )

        # when
        closed = replay(initial=initial, events=closing)
        recorded = replay(initial=artifact_initial, events=artifact_events)

        # then
        self.assertEqual(
            [item["decision"] for item in closed["decisions"]], ["reflected", "no_candidate"]
        )
        trigger = closed["state"]["jobs"]["job-a"]["triggers"][0]
        self.assertEqual((trigger["closed"], trigger["closure"]), (True, "no_candidate"))
        self.assertEqual(closed["state"]["jobs"]["job-a"]["candidates"], [])
        self.assertIsNone(closed["state"]["jobs"]["job-a"]["trial"])
        with self.assertRaises(LearningContractError) as retried:
            replay(
                initial=initial,
                events=[
                    *closing,
                    event(6, REFLECTION_OCCURRENCE, "no_candidate_recorded", no_candidate.payload),
                ],
            )
        self.assertIn("policy.closed_trigger", requirements(retried.exception))
        self.assertEqual([item["decision"] for item in recorded["decisions"]], ["reflected"])
        self.assertIsNone(recorded["state"]["jobs"]["job-a"]["trial"])
        self.assertFalse(candidates_of(recorded)[0]["admitted"])
        for name, row_initial, row_events, expected in invalid_rows:
            with self.subTest(row=name), self.assertRaises(LearningContractError) as caught:
                replay(initial=row_initial, events=row_events)
            self.assertIn(expected, requirements(caught.exception))

    def test_stale_reflector_snapshot_cannot_rebind_to_current_state(self) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID, controlled_clock=FIRST_CLOCK, jobs=[job("job-a")]
        )
        evidence = negative_evidence()
        trigger_digest = frozen_trigger_digest(initial, evidence)
        start = reflector_operation(
            3,
            REFLECTION_OCCURRENCE,
            "job-a",
            trigger_digest,
        )[0]
        confirm = evaluation_signal(
            4,
            CONTROL_OCCURRENCE,
            "job-a",
            "run-1",
            "evaluation_confirm",
            revision=1,
        )
        finish = operation_finished(
            5,
            CONTROL_OCCURRENCE,
            kind="reflector",
            generation=1,
            operation_id="reflector-1",
            result_digest="reflector-result-1",
        )
        stale_artifact = candidate_artifact(
            6,
            CONTROL_OCCURRENCE,
            "job-a",
            trigger_digest,
            LESSONS,
            frozen_feedback_revision=1,
        )
        stale_start = reflector_operation(
            4,
            CONTROL_OCCURRENCE,
            "job-a",
            trigger_digest,
            operation_id="reflector-after-feedback",
        )[0]
        confirm_before_start = evaluation_signal(
            3,
            CONTROL_OCCURRENCE,
            "job-a",
            "run-1",
            "evaluation_confirm",
            revision=1,
        )
        base_initial = initial_state(
            algorithm_id=ALGORITHM_ID, controlled_clock=FIRST_CLOCK, jobs=[job("job-a")]
        )
        base_evidence = negative_evidence()
        third_evaluation = stable_evaluation(
            3,
            REFLECTION_OCCURRENCE,
            "job-a",
            "run-3",
            "reusable_issue",
            ["x"],
        )
        base_prefix = [*base_evidence, third_evaluation]
        trigger_decisions = replay(initial=base_initial, events=base_prefix)["decisions"]
        old_base_trigger = trigger_decisions[0]["artifact_identities"]["trigger_digest"]
        current_trigger = trigger_decisions[1]["artifact_identities"]["trigger_digest"]
        current_operation = reflector_operation(
            4,
            REFLECTION_OCCURRENCE,
            "job-a",
            current_trigger,
        )
        current_artifact = candidate_artifact(
            6,
            REFLECTION_OCCURRENCE,
            "job-a",
            current_trigger,
            LESSONS,
        )
        candidate_prefix = [*base_prefix, *current_operation, current_artifact]
        candidate = candidates_of(replay(initial=base_initial, events=candidate_prefix))[0]
        admission = candidate_admitted(
            7,
            CONTROL_OCCURRENCE,
            "job-a",
            candidate["candidate_record_digest"],
            candidate["replacement_digest"],
        )
        admitted = [*candidate_prefix, admission]
        trial = trial_of(base_initial, admitted)
        promoted_events = [
            *admitted,
            trial_run_created(
                8,
                CONTROL_OCCURRENCE,
                trial["candidate_record_digest"],
                "base-trial-run-1",
            ),
            trial_run_created(
                9,
                CONTROL_OCCURRENCE,
                trial["candidate_record_digest"],
                "base-trial-run-2",
            ),
            trial_run_settled(10, CONTROL_OCCURRENCE, "base-trial-run-1", "positive"),
            trial_run_settled(11, CONTROL_OCCURRENCE, "base-trial-run-2", "positive"),
        ]
        stale_base_start = reflector_operation(
            12,
            CONTROL_OCCURRENCE,
            "job-a",
            old_base_trigger,
            operation_id="reflector-after-promotion",
        )[0]

        # when
        attempted = replay(initial=initial, events=[*evidence, start, confirm, finish])
        with self.assertRaises(LearningContractError) as artifact_caught:
            replay(
                initial=initial,
                events=[*evidence, start, confirm, finish, stale_artifact],
            )
        with self.assertRaises(LearningContractError) as start_caught:
            replay(initial=initial, events=[*evidence, confirm_before_start, stale_start])
        promoted = replay(initial=base_initial, events=promoted_events)
        with self.assertRaises(LearningContractError) as base_caught:
            replay(
                initial=base_initial,
                events=[*promoted_events, stale_base_start],
            )

        # then
        trigger = attempted["state"]["jobs"]["job-a"]["triggers"][0]
        self.assertTrue(trigger["attempted"])
        self.assertEqual(trigger["operation_id"], "reflector-1")
        self.assertEqual(candidates_of(attempted), [])
        self.assertIn("policy.stale_trigger", requirements(artifact_caught.exception))
        self.assertIn("policy.stale_trigger", requirements(start_caught.exception))
        promoted_job = promoted["state"]["jobs"]["job-a"]
        self.assertEqual(promoted_job["stable_digest"], lesson_set_digest(LESSONS))
        self.assertFalse(promoted_job["triggers"][0]["closed"])
        self.assertIn("policy.stale_trigger", requirements(base_caught.exception))

    def test_lesson_validation_rejects_control_and_format_characters_for_artifact_and_edit(
        self,
    ) -> None:
        # given
        initial, prefix = recorded_candidate()
        predecessor = candidates_of(replay(initial=initial, events=prefix))[0]
        rows = [
            ("artifact_control", "artifact", "Visible\u0007control"),
            ("edit_bidi", "edit", "Bidi\u202eoverride"),
        ]

        # when / then
        for name, source, lesson in rows:
            with self.subTest(row=name):
                with self.assertRaises(LearningContractError) as caught:
                    if source == "artifact":
                        artifact_initial, artifact_events = recorded_candidate(lessons=[lesson])
                        replay(initial=artifact_initial, events=artifact_events)
                    else:
                        replay(
                            initial=initial,
                            events=[
                                *prefix,
                                candidate_signal(
                                    6,
                                    CONTROL_OCCURRENCE,
                                    "job-a",
                                    predecessor["candidate_record_digest"],
                                    "candidate_edit",
                                    revision=1,
                                    payload={"lessons": [lesson]},
                                ),
                            ],
                        )
                self.assertIn("policy.lesson_characters", requirements(caught.exception))
