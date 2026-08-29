from __future__ import annotations

import unittest
from typing import Any

from benchmark_core.canonical import canonical_sha256
from benchmark_learning.learning_contract import (
    LearningContractError,
    ReplayEvent,
    event_json,
    parse_event,
)
from benchmark_learning.learning_replay import initial_state, replay

ALGORITHM_ID = "scheduled-learning/v1"
STABLE_DIGEST = "stable-0"
COMPATIBILITY_DIGEST = "compatibility-0"
CANDIDATE_RECORD_DOMAIN = "scheduled-learning/v1/candidate-record"
CANDIDATE_SOURCE_DOMAIN = "scheduled-learning/v1/candidate-source"
LESSONS = ["Quote the exact deadline in the first sentence."]

FIRST_CLOCK = "2026-01-31T00:00:00Z"
FIRST_OCCURRENCE = "2026-01-01T00:00:00Z"
SECOND_OCCURRENCE = "2026-01-02T00:00:00Z"
REFLECTION_OCCURRENCE = "2026-01-03T00:00:00Z"
CONTROL_OCCURRENCE = "2026-01-04T00:00:00Z"


def job(job_id: str, **overrides: Any) -> dict[str, Any]:
    """Build one closed initial job object."""

    return {
        "job_id": job_id,
        "repeatable": True,
        "cancelled": False,
        "learning_epoch": 0,
        "job_definition_digest": "job-definition-0",
        "stable_digest": STABLE_DIGEST,
        "stable_revision": 0,
        "compatibility_digest": COMPATIBILITY_DIGEST,
        "feedback_revision": 0,
        **overrides,
    }


def adapter_binding() -> dict[str, str]:
    return {
        "adapter_id": "page-change-m3",
        "adapter_version": "v1",
        "dataset_digest": "a" * 64,
        "oracle_digest": "b" * 64,
        "gates_digest": "c" * 64,
        "execution_surface_digest": "d" * 64,
    }


def event(sequence: int, occurred_at: str, kind: str, payload: dict[str, Any]) -> ReplayEvent:
    return parse_event(
        {
            "schema_version": 1,
            "sequence": sequence,
            "occurred_at": occurred_at,
            "kind": kind,
            "payload": payload,
        }
    )


def stable_evaluation(
    sequence: int,
    occurred_at: str,
    job_id: str,
    run_id: str,
    outcome: str,
    issue_codes: list[str],
    **overrides: Any,
) -> ReplayEvent:
    payload = {
        "job_id": job_id,
        "run_id": run_id,
        "operation_id": f"evaluator-{run_id}",
        "evaluation_digest": f"evaluation-{run_id}",
        "logical_occurrence": occurred_at,
        "learning_epoch": 0,
        "compatibility_digest": COMPATIBILITY_DIGEST,
        "stable_digest": STABLE_DIGEST,
        "outcome": outcome,
        "issue_codes": issue_codes,
        **overrides,
    }
    return event(sequence, occurred_at, "stable_evaluation_recorded", payload)


def owner_signal(
    sequence: int,
    occurred_at: str,
    job_id: str,
    signal: str,
    *,
    subject_kind: str,
    subject_digest: str,
    run_id: str | None = None,
    revision: int,
    supersedes_revision: int | None = None,
    payload: dict[str, Any] | None = None,
) -> ReplayEvent:
    return event(
        sequence,
        occurred_at,
        "owner_signal_recorded",
        {
            "job_id": job_id,
            "subject_kind": subject_kind,
            "subject_digest": subject_digest,
            "run_id": run_id,
            "signal": signal,
            "payload": payload,
            "revision": revision,
            "supersedes_revision": supersedes_revision,
        },
    )


def run_signal(
    sequence: int,
    occurred_at: str,
    job_id: str,
    run_id: str,
    signal: str,
    *,
    revision: int,
    payload: dict[str, Any] | None = None,
) -> ReplayEvent:
    return owner_signal(
        sequence,
        occurred_at,
        job_id,
        signal,
        subject_kind="run",
        subject_digest=run_id,
        run_id=run_id,
        revision=revision,
        payload=payload,
    )


def evaluation_signal(
    sequence: int,
    occurred_at: str,
    job_id: str,
    run_id: str,
    signal: str,
    *,
    revision: int,
) -> ReplayEvent:
    return owner_signal(
        sequence,
        occurred_at,
        job_id,
        signal,
        subject_kind="evaluation",
        subject_digest=f"evaluation-{run_id}",
        run_id=run_id,
        revision=revision,
    )


def owner_correction(
    sequence: int,
    occurred_at: str,
    job_id: str,
    run_id: str,
    *,
    revision: int,
) -> ReplayEvent:
    return run_signal(
        sequence,
        occurred_at,
        job_id,
        run_id,
        "result_correction",
        revision=revision,
        payload={"correction_text": "state the deadline in the first sentence"},
    )


def candidate_signal(
    sequence: int,
    occurred_at: str,
    job_id: str,
    candidate_digest: str,
    signal: str,
    *,
    revision: int,
    payload: dict[str, Any] | None = None,
) -> ReplayEvent:
    return owner_signal(
        sequence,
        occurred_at,
        job_id,
        signal,
        subject_kind="candidate",
        subject_digest=candidate_digest,
        revision=revision,
        payload=payload,
    )


def reflector_operation(
    sequence: int,
    occurred_at: str,
    job_id: str,
    trigger_digest: str,
    *,
    operation_id: str = "reflector-1",
    result_digest: str = "reflector-result-1",
    operation_kind: str = "reflector",
    status: str = "succeeded",
) -> list[ReplayEvent]:
    started = event(
        sequence,
        occurred_at,
        "operation_started",
        {
            "job_id": job_id,
            "operation_id": operation_id,
            "operation_kind": operation_kind,
            "attempt_generation": 1,
            "carrier_digest": "carrier-1",
            "route_digest": "route-1",
            "provider_call_id": "provider-call-1",
            "manifest_digest": "manifest-1",
            "freeze_commit": "freeze-commit-1",
            "invocation_core_digest": "invocation-core-1",
            "trigger_digest": trigger_digest if operation_kind == "reflector" else None,
        },
    )
    finished = event(
        sequence + 1,
        occurred_at,
        "operation_finished",
        {
            "job_id": job_id,
            "operation_id": operation_id,
            "operation_kind": operation_kind,
            "attempt_generation": 1,
            "status": status,
            "result_digest": result_digest,
            "usage_digest": None if status == "failed_no_call" else "usage-1",
        },
    )
    return [started, finished]


def lesson_set_digest(lessons: list[str]) -> str:
    return canonical_sha256({"schema_version": 1, "lessons": lessons})


def candidate_artifact(
    sequence: int,
    occurred_at: str,
    job_id: str,
    trigger_digest: str,
    lessons: list[str],
    *,
    normalized: list[str] | None = None,
    **overrides: Any,
) -> ReplayEvent:
    settled = lessons if normalized is None else normalized
    replacement_digest = lesson_set_digest(settled)
    core = {
        "schema_version": 1,
        "job_id": job_id,
        "operation_id": "reflector-1",
        "result_digest": "reflector-result-1",
        "replacement_digest": replacement_digest,
        "lessons": settled,
        "source_manifest_digest": "source-manifest-1",
        "base_digest": STABLE_DIGEST,
        "base_revision": 0,
        "learning_epoch": 0,
        "feedback_revision": 0,
        "algorithm_id": ALGORITHM_ID,
        "trigger_digest": trigger_digest,
    }
    payload = {
        "job_id": job_id,
        "operation_id": "reflector-1",
        "result_digest": "reflector-result-1",
        "candidate_record_digest": canonical_sha256(
            {"domain": CANDIDATE_RECORD_DOMAIN, "value": core}
        ),
        "replacement_digest": replacement_digest,
        "lessons": lessons,
        "source_manifest_digest": "source-manifest-1",
        "base_digest": STABLE_DIGEST,
        "base_revision": 0,
        "learning_epoch": 0,
        "feedback_revision": 0,
        "algorithm_id": ALGORITHM_ID,
        "trigger_digest": trigger_digest,
        **overrides,
    }
    return event(sequence, occurred_at, "candidate_artifact_recorded", payload)


def candidate_admitted(
    sequence: int,
    occurred_at: str,
    job_id: str,
    candidate_record_digest: str,
    replacement_digest: str,
    **overrides: Any,
) -> ReplayEvent:
    payload = {
        "job_id": job_id,
        "candidate_record_digest": candidate_record_digest,
        "replacement_digest": replacement_digest,
        "base_digest": STABLE_DIGEST,
        "base_revision": 0,
        "learning_epoch": 0,
        "feedback_revision": 0,
        "adapter": None,
        **overrides,
    }
    return event(sequence, occurred_at, "candidate_admitted", payload)


def negative_evidence(job_id: str = "job-a") -> list[ReplayEvent]:
    return [
        stable_evaluation(1, FIRST_OCCURRENCE, job_id, "run-1", "reusable_issue", ["x"]),
        stable_evaluation(2, SECOND_OCCURRENCE, job_id, "run-2", "reusable_issue", ["x"]),
    ]


def frozen_trigger_digest(initial: dict[str, Any], events: list[ReplayEvent]) -> str:
    identities = replay(initial=initial, events=events)["decisions"][-1]["artifact_identities"]
    digest: str = identities["trigger_digest"]
    return digest


def recorded_candidate(
    *,
    jobs: list[dict[str, Any]] | None = None,
    lessons: list[str] | None = None,
    job_id: str = "job-a",
) -> tuple[dict[str, Any], list[ReplayEvent]]:
    """Replay-ready prefix that ends with one valid unadmitted reflector candidate."""

    initial = initial_state(
        algorithm_id=ALGORITHM_ID,
        controlled_clock=FIRST_CLOCK,
        jobs=jobs if jobs is not None else [job(job_id)],
    )
    evidence = negative_evidence(job_id)
    trigger_digest = frozen_trigger_digest(initial, evidence)
    events = [
        *evidence,
        *reflector_operation(3, REFLECTION_OCCURRENCE, job_id, trigger_digest),
        candidate_artifact(
            5,
            REFLECTION_OCCURRENCE,
            job_id,
            trigger_digest,
            LESSONS if lessons is None else lessons,
        ),
    ]
    return initial, events


def candidates_of(result: dict[str, Any], job_id: str = "job-a") -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = result["state"]["jobs"][job_id]["candidates"]
    return records


def requirements(error: LearningContractError) -> set[str]:
    return {item.requirement for item in error.issues}


class LearningReplayTests(unittest.TestCase):
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
            owner_correction(3, REFLECTION_OCCURRENCE, "job-a", "run-1", revision=1),
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
        self.assertEqual(result["decisions"][-1]["artifact_identities"]["adapter"], frozen_adapter)
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


if __name__ == "__main__":
    unittest.main()
