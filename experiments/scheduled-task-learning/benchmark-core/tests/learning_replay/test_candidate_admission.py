"""Candidate admission and owner decision tests."""

from __future__ import annotations

import unittest

from benchmark_core.canonical import canonical_sha256
from benchmark_learning.learning_contract import LearningContractError, ReplayEvent, event_json
from benchmark_learning.learning_replay import initial_state, replay

from .support import (
    ALGORITHM_ID,
    CANDIDATE_SOURCE_DOMAIN,
    CONTROL_OCCURRENCE,
    FIRST_CLOCK,
    FIRST_OCCURRENCE,
    LESSONS,
    STABLE_DIGEST,
    TRIAL_DOMAIN,
    adapter_binding,
    candidate_admitted,
    candidate_signal,
    candidates_of,
    evaluation_signal,
    job,
    lesson_set_digest,
    owner_correction,
    recorded_candidate,
    requirements,
    run_signal,
    stable_evaluation,
)


class LearningReplayCandidateAdmissionTests(unittest.TestCase):
    def test_candidate_admission_rejects_stale_mismatched_and_unsupported_inputs(self) -> None:
        # given
        initial, prefix = recorded_candidate(jobs=[job("job-a"), job("job-b")])
        digest = candidates_of(replay(initial=initial, events=prefix))[0]["candidate_record_digest"]
        replacement = lesson_set_digest(LESSONS)
        withdrawn = run_signal(6, CONTROL_OCCURRENCE, "job-a", "run-1", "result_useful", revision=1)
        support_preserved = run_signal(
            6, CONTROL_OCCURRENCE, "job-a", "run-1", "result_not_useful", revision=1
        )
        disputed_dependency = [
            evaluation_signal(
                6, CONTROL_OCCURRENCE, "job-a", "run-1", "evaluation_dispute", revision=1
            ),
            owner_correction(7, CONTROL_OCCURRENCE, "job-a", "run-1", revision=1),
            candidate_admitted(
                8,
                CONTROL_OCCURRENCE,
                "job-a",
                digest,
                replacement,
                feedback_revision=2,
            ),
        ]
        rows: list[tuple[str, list[ReplayEvent], str]] = [
            (
                "stale_base_digest",
                [
                    candidate_admitted(
                        6, CONTROL_OCCURRENCE, "job-a", digest, replacement, base_digest="stable-9"
                    )
                ],
                "policy.stale_base",
            ),
            (
                "stale_base_revision",
                [
                    candidate_admitted(
                        6, CONTROL_OCCURRENCE, "job-a", digest, replacement, base_revision=1
                    )
                ],
                "policy.stale_base",
            ),
            (
                "stale_learning_epoch",
                [
                    candidate_admitted(
                        6, CONTROL_OCCURRENCE, "job-a", digest, replacement, learning_epoch=1
                    )
                ],
                "policy.stale_epoch",
            ),
            (
                "stale_feedback_revision",
                [
                    candidate_admitted(
                        6, CONTROL_OCCURRENCE, "job-a", digest, replacement, feedback_revision=1
                    )
                ],
                "policy.stale_feedback_revision",
            ),
            (
                "replacement_digest_mismatch",
                [candidate_admitted(6, CONTROL_OCCURRENCE, "job-a", digest, "f" * 64)],
                "policy.replacement_digest",
            ),
            (
                "candidate_frozen_feedback_revision",
                [
                    support_preserved,
                    candidate_admitted(
                        7,
                        CONTROL_OCCURRENCE,
                        "job-a",
                        digest,
                        replacement,
                        feedback_revision=1,
                    ),
                ],
                "policy.stale_feedback_revision",
            ),
            (
                "withdrawn_trigger_support",
                [
                    withdrawn,
                    candidate_admitted(
                        7, CONTROL_OCCURRENCE, "job-a", digest, replacement, feedback_revision=1
                    ),
                ],
                "policy.absent_trigger_support",
            ),
            (
                "disputed_frozen_evaluator_dependency",
                disputed_dependency,
                "policy.absent_trigger_support",
            ),
            (
                "another_job_owns_the_candidate",
                [candidate_admitted(6, CONTROL_OCCURRENCE, "job-b", digest, replacement)],
                "policy.unknown_candidate",
            ),
        ]

        for name, tail, expected in rows:
            with self.subTest(row=name), self.assertRaises(LearningContractError) as caught:
                # when
                replay(initial=initial, events=[*prefix, *tail])

            # then
            self.assertIn(expected, requirements(caught.exception))

    def test_candidate_admission_enforces_open_trial_and_closed_replacement_guards(self) -> None:
        # given
        initial, prefix = recorded_candidate()
        digest = candidates_of(replay(initial=initial, events=prefix))[0]["candidate_record_digest"]
        replacement = lesson_set_digest(LESSONS)
        frozen_adapter = adapter_binding()
        admit = candidate_admitted(
            6,
            CONTROL_OCCURRENCE,
            "job-a",
            digest,
            replacement,
            adapter=frozen_adapter,
        )

        # when
        result = replay(initial=initial, events=[*prefix, admit])

        # then
        job_state = result["state"]["jobs"]["job-a"]
        self.assertEqual(result["decisions"][-1]["decision"], "admitted")
        self.assertEqual(result["decisions"][-1]["reason"], "two_negative_runs")
        self.assertEqual(job_state["trial"]["candidate_record_digest"], digest)
        self.assertEqual(job_state["trial"]["admitted_at"], FIRST_CLOCK)
        self.assertEqual(job_state["trial"]["assignment_deadline"], "2026-03-02T00:00:00Z")
        self.assertEqual(job_state["trial"]["decision_deadline"], "2026-03-09T00:00:00Z")
        self.assertEqual(job_state["trial"]["adapter"], frozen_adapter)
        trial_core = {
            "schema_version": 1,
            "job_id": "job-a",
            "candidate_record_digest": digest,
            "replacement_digest": replacement,
            "base_digest": STABLE_DIGEST,
            "base_revision": 0,
            "learning_epoch": 0,
            "feedback_revision": 0,
            "algorithm_id": ALGORITHM_ID,
            "adapter": frozen_adapter,
            "admitted_at": FIRST_CLOCK,
            "assignment_deadline": "2026-03-02T00:00:00Z",
            "decision_deadline": "2026-03-09T00:00:00Z",
        }
        expected_trial_digest = canonical_sha256({"domain": TRIAL_DOMAIN, "value": trial_core})
        self.assertEqual(job_state["trial"]["trial_digest"], expected_trial_digest)
        self.assertEqual(result["decisions"][-1]["artifact_identities"]["adapter"], frozen_adapter)
        self.assertEqual(
            result["decisions"][-1]["artifact_identities"]["trial_digest"],
            expected_trial_digest,
        )
        self.assertTrue(job_state["candidates"][0]["admitted"])
        self.assertEqual(
            job_state["closed_replacements"],
            [
                {
                    "job_id": "job-a",
                    "algorithm_id": ALGORITHM_ID,
                    "base_digest": STABLE_DIGEST,
                    "replacement_digest": replacement,
                }
            ],
        )
        with self.assertRaises(LearningContractError) as stacked:
            replay(
                initial=initial,
                events=[
                    *prefix,
                    admit,
                    candidate_admitted(7, CONTROL_OCCURRENCE, "job-a", digest, replacement),
                ],
            )
        self.assertEqual(
            requirements(stacked.exception)
            & {
                "policy.open_trial",
                "policy.closed_replacement",
                "policy.candidate_already_admitted",
            },
            {"policy.open_trial", "policy.closed_replacement", "policy.candidate_already_admitted"},
        )

    def test_initial_identity_rejects_nonfirst_sequence_duplicate_job_and_extra_field(
        self,
    ) -> None:
        # given
        initial = initial_state(
            algorithm_id=ALGORITHM_ID, controlled_clock=FIRST_CLOCK, jobs=[job("job-a")]
        )
        starts_at_two = stable_evaluation(
            2, FIRST_OCCURRENCE, "job-a", "run-1", "reusable_issue", ["x"]
        )

        # when / then
        with self.assertRaises(LearningContractError):
            initial_state(
                algorithm_id=ALGORITHM_ID,
                controlled_clock=FIRST_CLOCK,
                jobs=[job("job-a"), job("job-a")],
            )
        with self.assertRaises(LearningContractError):
            initial_state(
                algorithm_id=ALGORITHM_ID,
                controlled_clock=FIRST_CLOCK,
                jobs=[{**job("job-a"), "budget_usd": 1}],
            )
        with self.assertRaises(LearningContractError):
            replay(initial=initial, events=[starts_at_two])

    def test_candidate_approval_creates_immutable_successor_and_isolates_jobs(self) -> None:
        # given
        initial, prefix = recorded_candidate(jobs=[job("job-a"), job("job-b")])
        predecessor = candidates_of(replay(initial=initial, events=prefix))[0]
        approve = candidate_signal(
            6,
            CONTROL_OCCURRENCE,
            "job-a",
            predecessor["candidate_record_digest"],
            "candidate_approve",
            revision=1,
        )
        source_core = {
            "schema_version": 1,
            "origin": "owner_approval",
            "job_id": "job-a",
            "predecessor_candidate_record_digest": predecessor["candidate_record_digest"],
            "predecessor_source_manifest_digest": predecessor["source_manifest_digest"],
            "approval_event_digest": canonical_sha256(event_json(approve)),
            "base_digest": STABLE_DIGEST,
            "base_revision": 0,
            "learning_epoch": 0,
            "feedback_revision": 1,
            "algorithm_id": ALGORITHM_ID,
        }
        source_manifest_digest = canonical_sha256(
            {"domain": CANDIDATE_SOURCE_DOMAIN, "value": source_core}
        )

        # when
        approved = replay(initial=initial, events=[*prefix, approve])

        # then
        stored_predecessor, successor = candidates_of(approved)
        self.assertTrue(stored_predecessor["superseded"])
        self.assertEqual(stored_predecessor["source_manifest_digest"], "source-manifest-1")
        self.assertEqual(successor["replacement_digest"], predecessor["replacement_digest"])
        self.assertEqual(successor["lessons"], predecessor["lessons"])
        self.assertEqual(successor["source_manifest_digest"], source_manifest_digest)
        self.assertEqual(
            successor["predecessor_candidate_record_digest"],
            predecessor["candidate_record_digest"],
        )
        self.assertNotEqual(
            successor["candidate_record_digest"], predecessor["candidate_record_digest"]
        )
        self.assertEqual(successor["feedback_revision"], 1)

        replacement = predecessor["replacement_digest"]
        with self.assertRaises(LearningContractError) as stale:
            replay(
                initial=initial,
                events=[
                    *prefix,
                    approve,
                    candidate_admitted(
                        7,
                        CONTROL_OCCURRENCE,
                        "job-a",
                        predecessor["candidate_record_digest"],
                        replacement,
                        feedback_revision=1,
                    ),
                ],
            )
        self.assertIn("policy.superseded_candidate", requirements(stale.exception))

        admit_successor = candidate_admitted(
            7,
            CONTROL_OCCURRENCE,
            "job-a",
            successor["candidate_record_digest"],
            replacement,
            feedback_revision=1,
        )
        admitted = replay(initial=initial, events=[*prefix, approve, admit_successor])
        self.assertEqual(admitted["decisions"][-1]["reason"], "owner_approval")
        with self.assertRaises(LearningContractError) as reopened:
            replay(
                initial=initial,
                events=[
                    *prefix,
                    approve,
                    admit_successor,
                    candidate_admitted(
                        8,
                        CONTROL_OCCURRENCE,
                        "job-a",
                        successor["candidate_record_digest"],
                        replacement,
                        feedback_revision=1,
                    ),
                ],
            )
        self.assertIn("policy.open_trial", requirements(reopened.exception))
        with self.assertRaises(LearningContractError) as crossed:
            replay(
                initial=initial,
                events=[
                    *prefix,
                    approve,
                    candidate_admitted(
                        7,
                        CONTROL_OCCURRENCE,
                        "job-b",
                        successor["candidate_record_digest"],
                        replacement,
                        feedback_revision=1,
                    ),
                ],
            )
        self.assertIn("policy.unknown_candidate", requirements(crossed.exception))

    def test_candidate_edit_and_rejection_veto_the_exact_predecessor(self) -> None:
        # given
        initial, prefix = recorded_candidate()
        predecessor = candidates_of(replay(initial=initial, events=prefix))[0]
        edited_lessons = ["Open with the exact due date.", "Name the owner of the next step."]
        edit = candidate_signal(
            6,
            CONTROL_OCCURRENCE,
            "job-a",
            predecessor["candidate_record_digest"],
            "candidate_edit",
            revision=1,
            payload={"lessons": edited_lessons},
        )
        reject = candidate_signal(
            6,
            CONTROL_OCCURRENCE,
            "job-a",
            predecessor["candidate_record_digest"],
            "candidate_reject",
            revision=1,
        )
        approve = candidate_signal(
            6,
            CONTROL_OCCURRENCE,
            "job-a",
            predecessor["candidate_record_digest"],
            "candidate_approve",
            revision=1,
        )
        approved_result = replay(initial=initial, events=[*prefix, approve])
        approval_successor = candidates_of(approved_result)[-1]
        edit_approval = candidate_signal(
            7,
            CONTROL_OCCURRENCE,
            "job-a",
            approval_successor["candidate_record_digest"],
            "candidate_edit",
            revision=1,
            payload={"lessons": ["Replace the approved wording."]},
        )
        source_core = {
            "schema_version": 1,
            "origin": "owner_edit",
            "job_id": "job-a",
            "edit_event_digest": canonical_sha256(event_json(edit)),
            "predecessor_candidate_record_digest": predecessor["candidate_record_digest"],
            "base_digest": STABLE_DIGEST,
            "base_revision": 0,
            "learning_epoch": 0,
            "feedback_revision": 1,
            "algorithm_id": ALGORITHM_ID,
        }
        source_manifest_digest = canonical_sha256(
            {"domain": CANDIDATE_SOURCE_DOMAIN, "value": source_core}
        )

        # when
        result = replay(initial=initial, events=[*prefix, edit])
        edited_approval_result = replay(initial=initial, events=[*prefix, approve, edit_approval])

        # then
        stored_predecessor, edited = candidates_of(result)
        self.assertTrue(stored_predecessor["superseded"] and stored_predecessor["vetoed"])
        self.assertEqual(edited["origin"], "owner_edit")
        self.assertEqual(edited["lessons"], edited_lessons)
        self.assertEqual(edited["replacement_digest"], lesson_set_digest(edited_lessons))
        self.assertEqual(edited["source_manifest_digest"], source_manifest_digest)
        self.assertNotEqual(edited["source_manifest_digest"], predecessor["source_manifest_digest"])
        self.assertNotEqual(
            edited["candidate_record_digest"], predecessor["candidate_record_digest"]
        )
        self.assertEqual(
            edited["predecessor_candidate_record_digest"],
            predecessor["candidate_record_digest"],
        )
        stored_approval, edited_successor = candidates_of(edited_approval_result)[-2:]
        self.assertEqual(stored_approval["origin"], "owner_approval")
        self.assertTrue(stored_approval["superseded"] and stored_approval["vetoed"])
        self.assertEqual(edited_successor["origin"], "owner_edit")
        self.assertNotEqual(
            edited_successor["candidate_record_digest"],
            stored_approval["candidate_record_digest"],
        )
        self.assertNotEqual(
            edited_successor["source_manifest_digest"], stored_approval["source_manifest_digest"]
        )
        self.assertIsNone(edited_successor["trigger_digest"])
        self.assertEqual(
            edited_successor["predecessor_candidate_record_digest"],
            stored_approval["candidate_record_digest"],
        )

        with self.assertRaises(LearningContractError) as invalid:
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
                        payload={"lessons": ["a", "b", "c", "d"]},
                    ),
                ],
            )
        self.assertIn("policy.lesson_count", requirements(invalid.exception))

        rejected = replay(initial=initial, events=[*prefix, reject])
        self.assertTrue(candidates_of(rejected)[0]["vetoed"])
        with self.assertRaises(LearningContractError) as vetoed:
            replay(
                initial=initial,
                events=[
                    *prefix,
                    reject,
                    candidate_admitted(
                        7,
                        CONTROL_OCCURRENCE,
                        "job-a",
                        predecessor["candidate_record_digest"],
                        predecessor["replacement_digest"],
                        feedback_revision=1,
                    ),
                ],
            )
        self.assertIn("policy.hard_veto", requirements(vetoed.exception))

    def test_approval_inherits_disputed_dependency_but_owner_edit_remains_independent(
        self,
    ) -> None:
        # given
        initial, prefix = recorded_candidate()
        predecessor = candidates_of(replay(initial=initial, events=prefix))[0]
        dispute = evaluation_signal(
            6,
            CONTROL_OCCURRENCE,
            "job-a",
            "run-1",
            "evaluation_dispute",
            revision=1,
        )
        approve = candidate_signal(
            7,
            CONTROL_OCCURRENCE,
            "job-a",
            predecessor["candidate_record_digest"],
            "candidate_approve",
            revision=1,
        )
        edit = candidate_signal(
            7,
            CONTROL_OCCURRENCE,
            "job-a",
            predecessor["candidate_record_digest"],
            "candidate_edit",
            revision=1,
            payload={"lessons": ["Use the owner-approved wording."]},
        )
        approved = replay(initial=initial, events=[*prefix, dispute, approve])
        approval_successor = candidates_of(approved)[-1]
        edited = replay(initial=initial, events=[*prefix, dispute, edit])
        edit_successor = candidates_of(edited)[-1]
        approval_admission = candidate_admitted(
            8,
            CONTROL_OCCURRENCE,
            "job-a",
            approval_successor["candidate_record_digest"],
            approval_successor["replacement_digest"],
            feedback_revision=2,
        )
        edit_admission = candidate_admitted(
            8,
            CONTROL_OCCURRENCE,
            "job-a",
            edit_successor["candidate_record_digest"],
            edit_successor["replacement_digest"],
            feedback_revision=2,
        )

        # when
        with self.assertRaises(LearningContractError) as approval_caught:
            replay(
                initial=initial,
                events=[*prefix, dispute, approve, approval_admission],
            )
        edit_result = replay(
            initial=initial,
            events=[*prefix, dispute, edit, edit_admission],
        )

        # then
        self.assertIn("policy.absent_trigger_support", requirements(approval_caught.exception))
        self.assertEqual(edit_result["decisions"][-1]["reason"], "owner_edit")
        self.assertEqual(edit_result["state"]["jobs"]["job-a"]["trial"]["status"], "open")
