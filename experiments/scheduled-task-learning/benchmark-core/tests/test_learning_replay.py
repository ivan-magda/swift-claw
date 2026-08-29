from __future__ import annotations

import unittest
from typing import Any

from benchmark_core.canonical import canonical_sha256, dumps
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
TRIAL_DOMAIN = "scheduled-learning/v1/trial"
TRIAL_EVALUATION_DOMAIN = "scheduled-learning/v1/trial-evaluation"
PROMOTION_DOMAIN = "scheduled-learning/v1/promotion"
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


def promotion_signal(
    sequence: int,
    occurred_at: str,
    job_id: str,
    promotion_digest: str,
    *,
    revision: int,
    supersedes_revision: int | None = None,
) -> ReplayEvent:
    return owner_signal(
        sequence,
        occurred_at,
        job_id,
        "promotion_rollback",
        subject_kind="promotion",
        subject_digest=promotion_digest,
        revision=revision,
        supersedes_revision=supersedes_revision,
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
    started = operation_started(
        sequence,
        occurred_at,
        job_id=job_id,
        kind=operation_kind,
        generation=1,
        operation_id=operation_id,
        trigger_digest=trigger_digest if operation_kind == "reflector" else None,
    )
    finished = operation_finished(
        sequence + 1,
        occurred_at,
        job_id=job_id,
        kind=operation_kind,
        generation=1,
        operation_id=operation_id,
        status=status,
        result_digest=result_digest,
        usage_digest=None if status == "failed_no_call" else "usage-1",
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
    frozen_base_digest: str = STABLE_DIGEST,
    frozen_base_revision: int = 0,
    frozen_learning_epoch: int = 0,
    frozen_feedback_revision: int = 0,
    frozen_operation_id: str = "reflector-1",
    frozen_result_digest: str = "reflector-result-1",
    frozen_source_manifest_digest: str = "source-manifest-1",
    **overrides: Any,
) -> ReplayEvent:
    settled = lessons if normalized is None else normalized
    replacement_digest = lesson_set_digest(settled)
    core = {
        "schema_version": 1,
        "job_id": job_id,
        "operation_id": frozen_operation_id,
        "result_digest": frozen_result_digest,
        "replacement_digest": replacement_digest,
        "lessons": settled,
        "source_manifest_digest": frozen_source_manifest_digest,
        "base_digest": frozen_base_digest,
        "base_revision": frozen_base_revision,
        "learning_epoch": frozen_learning_epoch,
        "feedback_revision": frozen_feedback_revision,
        "algorithm_id": ALGORITHM_ID,
        "trigger_digest": trigger_digest,
    }
    payload = {
        "job_id": job_id,
        "operation_id": frozen_operation_id,
        "result_digest": frozen_result_digest,
        "candidate_record_digest": canonical_sha256(
            {"domain": CANDIDATE_RECORD_DOMAIN, "value": core}
        ),
        "replacement_digest": replacement_digest,
        "lessons": lessons,
        "source_manifest_digest": frozen_source_manifest_digest,
        "base_digest": frozen_base_digest,
        "base_revision": frozen_base_revision,
        "learning_epoch": frozen_learning_epoch,
        "feedback_revision": frozen_feedback_revision,
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


def negative_evidence(
    job_id: str = "job-a",
    *,
    stable_digest: str = STABLE_DIGEST,
    learning_epoch: int = 0,
    compatibility_digest: str = COMPATIBILITY_DIGEST,
) -> list[ReplayEvent]:
    return [
        stable_evaluation(
            1,
            FIRST_OCCURRENCE,
            job_id,
            "run-1",
            "reusable_issue",
            ["x"],
            stable_digest=stable_digest,
            learning_epoch=learning_epoch,
            compatibility_digest=compatibility_digest,
        ),
        stable_evaluation(
            2,
            SECOND_OCCURRENCE,
            job_id,
            "run-2",
            "reusable_issue",
            ["x"],
            stable_digest=stable_digest,
            learning_epoch=learning_epoch,
            compatibility_digest=compatibility_digest,
        ),
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
    controlled_clock: str = FIRST_CLOCK,
) -> tuple[dict[str, Any], list[ReplayEvent]]:
    """Replay-ready prefix that ends with one valid unadmitted reflector candidate."""

    initial = initial_state(
        algorithm_id=ALGORITHM_ID,
        controlled_clock=controlled_clock,
        jobs=jobs if jobs is not None else [job(job_id)],
    )
    job_state = initial["jobs"][job_id]
    evidence = negative_evidence(
        job_id,
        stable_digest=job_state["stable_digest"],
        learning_epoch=job_state["learning_epoch"],
        compatibility_digest=job_state["compatibility_digest"],
    )
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
            frozen_base_digest=job_state["stable_digest"],
            frozen_base_revision=job_state["stable_revision"],
            frozen_learning_epoch=job_state["learning_epoch"],
            frozen_feedback_revision=job_state["feedback_revision"],
        ),
    ]
    return initial, events


def admitted_trial(
    controlled_clock: str,
    *,
    adapter: dict[str, str] | None = None,
    jobs: list[dict[str, Any]] | None = None,
    lessons: list[str] | None = None,
) -> tuple[dict[str, Any], list[ReplayEvent]]:
    """Replay-ready history that ends with one admitted trial."""

    initial, prefix = recorded_candidate(
        controlled_clock=controlled_clock,
        jobs=jobs,
        lessons=lessons,
    )
    candidate = candidates_of(replay(initial=initial, events=prefix))[0]
    admit = candidate_admitted(
        6,
        CONTROL_OCCURRENCE,
        "job-a",
        candidate["candidate_record_digest"],
        candidate["replacement_digest"],
        base_digest=candidate["base_digest"],
        base_revision=candidate["base_revision"],
        learning_epoch=candidate["learning_epoch"],
        feedback_revision=candidate["feedback_revision"],
        adapter=adapter,
    )
    return initial, [*prefix, admit]


def operation_started(
    sequence: int,
    occurred_at: str,
    *,
    job_id: str = "job-a",
    kind: str,
    generation: int,
    operation_id: str,
    trigger_digest: str | None = None,
) -> ReplayEvent:
    return event(
        sequence,
        occurred_at,
        "operation_started",
        {
            "job_id": job_id,
            "operation_id": operation_id,
            "operation_kind": kind,
            "attempt_generation": generation,
            "carrier_digest": f"carrier-{operation_id}",
            "route_digest": "route-1",
            "provider_call_id": f"provider-{operation_id}",
            "manifest_digest": "manifest-1",
            "freeze_commit": "freeze-commit-1",
            "invocation_core_digest": f"invocation-{operation_id}",
            "trigger_digest": trigger_digest,
        },
    )


def operation_finished(
    sequence: int,
    occurred_at: str,
    *,
    job_id: str = "job-a",
    kind: str,
    generation: int,
    operation_id: str,
    status: str = "succeeded",
    result_digest: str = "result-1",
    usage_digest: str | None = "usage-1",
) -> ReplayEvent:
    return event(
        sequence,
        occurred_at,
        "operation_finished",
        {
            "job_id": job_id,
            "operation_id": operation_id,
            "operation_kind": kind,
            "attempt_generation": generation,
            "status": status,
            "result_digest": result_digest,
            "usage_digest": usage_digest,
        },
    )


def controller_started(sequence: int, occurred_at: str, *, generation: int) -> ReplayEvent:
    return event(
        sequence,
        occurred_at,
        "controller_started",
        {"controller_generation": generation},
    )


def clock_advanced(sequence: int, occurred_at: str) -> ReplayEvent:
    return event(sequence, occurred_at, "clock_advanced", {})


def trial_run_created(
    sequence: int,
    occurred_at: str,
    candidate_record_digest: str,
    run_id: str,
) -> ReplayEvent:
    return event(
        sequence,
        occurred_at,
        "trial_run_created",
        {
            "job_id": "job-a",
            "candidate_record_digest": candidate_record_digest,
            "run_id": run_id,
        },
    )


def trial_run_settled(
    sequence: int,
    occurred_at: str,
    run_id: str,
    outcome: str,
) -> ReplayEvent:
    return event(
        sequence,
        occurred_at,
        "trial_run_settled",
        {"job_id": "job-a", "run_id": run_id, "outcome": outcome},
    )


def adapter_receipt(
    sequence: int,
    occurred_at: str,
    *,
    trial_digest: str,
    candidate_digest: str,
    outcome: str,
    binding: dict[str, str] | None = None,
    subject_kind: str = "trial",
    subject_digest: str | None = None,
    envelope_overrides: dict[str, str] | None = None,
) -> ReplayEvent:
    envelope = {
        **(adapter_binding() if binding is None else binding),
        "candidate_digest": candidate_digest,
        "outcome": outcome,
        "receipt_digest": "e" * 64,
        **({} if envelope_overrides is None else envelope_overrides),
    }
    return event(
        sequence,
        occurred_at,
        "adapter_receipt_recorded",
        {
            "job_id": "job-a",
            "subject_kind": subject_kind,
            "subject_digest": trial_digest if subject_digest is None else subject_digest,
            "envelope": envelope,
        },
    )


def hard_veto_receipt(
    sequence: int,
    occurred_at: str,
    *,
    promotion_digest: str,
    candidate_record_digest: str,
    replacement_digest: str,
    trigger_kind: str = "security",
    receipt_digest: str = "f" * 64,
    receipt_version: str = "hard-veto/v1",
) -> ReplayEvent:
    return event(
        sequence,
        occurred_at,
        "hard_veto_receipt_recorded",
        {
            "job_id": "job-a",
            "promotion_digest": promotion_digest,
            "candidate_record_digest": candidate_record_digest,
            "replacement_digest": replacement_digest,
            "trigger_kind": trigger_kind,
            "receipt_digest": receipt_digest,
            "receipt_version": receipt_version,
        },
    )


def trial_of(initial: dict[str, Any], events: list[ReplayEvent]) -> dict[str, Any]:
    trial: dict[str, Any] = replay(initial=initial, events=events)["state"]["jobs"]["job-a"][
        "trial"
    ]
    return trial


def trial_subject_digest(trial: dict[str, Any]) -> str:
    core = {
        "schema_version": 1,
        "job_id": "job-a",
        "candidate_record_digest": trial["candidate_record_digest"],
        "replacement_digest": trial["replacement_digest"],
        "base_digest": trial["base_digest"],
        "base_revision": trial["base_revision"],
        "learning_epoch": trial["learning_epoch"],
        "feedback_revision": trial["feedback_revision"],
        "algorithm_id": trial["algorithm_id"],
        "adapter": trial["adapter"],
        "admitted_at": trial["admitted_at"],
        "assignment_deadline": trial["assignment_deadline"],
        "decision_deadline": trial["decision_deadline"],
    }
    return canonical_sha256({"domain": TRIAL_DOMAIN, "value": core})


def trial_evaluation_digest(settled: ReplayEvent) -> str:
    return canonical_sha256({"domain": TRIAL_EVALUATION_DOMAIN, "value": event_json(settled)})


def promotable_trial(
    *,
    adapter: dict[str, str] | None = None,
    positive_run_count: int = 2,
    stable_digest: str = STABLE_DIGEST,
    lessons: list[str] | None = None,
) -> tuple[dict[str, Any], list[ReplayEvent]]:
    initial, admitted = admitted_trial(
        FIRST_CLOCK,
        adapter=adapter,
        jobs=[job("job-a", stable_digest=stable_digest)],
        lessons=lessons,
    )
    trial = trial_of(initial, admitted)
    next_sequence = 7
    tail: list[ReplayEvent] = []
    if adapter is not None:
        tail.append(
            adapter_receipt(
                next_sequence,
                CONTROL_OCCURRENCE,
                trial_digest=trial_subject_digest(trial),
                candidate_digest=trial["replacement_digest"],
                outcome="pass",
                binding=adapter,
            )
        )
        next_sequence += 1
    for run_number in range(1, positive_run_count + 1):
        tail.append(
            trial_run_created(
                next_sequence,
                CONTROL_OCCURRENCE,
                trial["candidate_record_digest"],
                f"trial-run-{run_number}",
            )
        )
        next_sequence += 1
    for run_number in range(1, positive_run_count + 1):
        tail.append(
            trial_run_settled(
                next_sequence,
                CONTROL_OCCURRENCE,
                f"trial-run-{run_number}",
                "positive",
            )
        )
        next_sequence += 1
    return initial, [*admitted, *tail]


def append_admitted_trial(
    initial: dict[str, Any],
    prefix: list[ReplayEvent],
    *,
    lessons: list[str],
) -> list[ReplayEvent]:
    current = replay(initial=initial, events=prefix)["state"]["jobs"]["job-a"]
    next_sequence = len(prefix) + 1
    evidence = [
        stable_evaluation(
            next_sequence + offset,
            CONTROL_OCCURRENCE,
            "job-a",
            f"later-stable-run-{offset + 1}",
            "reusable_issue",
            ["x"],
            stable_digest=current["stable_digest"],
            learning_epoch=current["learning_epoch"],
            compatibility_digest=current["compatibility_digest"],
        )
        for offset in range(2)
    ]
    with_evidence = [*prefix, *evidence]
    evidence_state = replay(initial=initial, events=with_evidence)["state"]["jobs"]["job-a"]
    trigger = next(
        record for record in reversed(evidence_state["triggers"]) if not record["closed"]
    )
    operation_id = "reflector-later"
    result_digest = "reflector-result-later"
    operation = reflector_operation(
        next_sequence + 2,
        CONTROL_OCCURRENCE,
        "job-a",
        trigger["trigger_digest"],
        operation_id=operation_id,
        result_digest=result_digest,
    )
    artifact = candidate_artifact(
        next_sequence + 4,
        CONTROL_OCCURRENCE,
        "job-a",
        trigger["trigger_digest"],
        lessons,
        frozen_base_digest=current["stable_digest"],
        frozen_base_revision=current["stable_revision"],
        frozen_learning_epoch=current["learning_epoch"],
        frozen_feedback_revision=current["feedback_revision"],
        frozen_operation_id=operation_id,
        frozen_result_digest=result_digest,
        frozen_source_manifest_digest="source-manifest-later",
    )
    candidate_prefix = [*with_evidence, *operation, artifact]
    candidate = candidates_of(replay(initial=initial, events=candidate_prefix))[-1]
    admission = candidate_admitted(
        next_sequence + 5,
        CONTROL_OCCURRENCE,
        "job-a",
        candidate["candidate_record_digest"],
        candidate["replacement_digest"],
        base_digest=current["stable_digest"],
        base_revision=current["stable_revision"],
        learning_epoch=current["learning_epoch"],
        feedback_revision=current["feedback_revision"],
    )
    return [*candidate_prefix, admission]


def append_promotable_trial(
    initial: dict[str, Any],
    prefix: list[ReplayEvent],
    *,
    lessons: list[str],
) -> list[ReplayEvent]:
    trial_prefix = append_admitted_trial(initial, prefix, lessons=lessons)
    trial = trial_of(initial, trial_prefix)
    next_sequence = len(trial_prefix) + 1
    tail = [
        trial_run_created(
            next_sequence,
            CONTROL_OCCURRENCE,
            trial["candidate_record_digest"],
            "later-trial-run-1",
        ),
        trial_run_created(
            next_sequence + 1,
            CONTROL_OCCURRENCE,
            trial["candidate_record_digest"],
            "later-trial-run-2",
        ),
        trial_run_settled(
            next_sequence + 2,
            CONTROL_OCCURRENCE,
            "later-trial-run-1",
            "positive",
        ),
        trial_run_settled(
            next_sequence + 3,
            CONTROL_OCCURRENCE,
            "later-trial-run-2",
            "positive",
        ),
    ]
    return [*trial_prefix, *tail]


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
                        operation_id="reflector-1",
                        trigger_digest=trigger_digest,
                    ),
                    controller_started(4, "2026-01-03T00:00:01Z", generation=2),
                ],
                "reflector-1",
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
                        operation_id="reflector-1",
                        trigger_digest=trigger_digest,
                    ),
                ],
                "reflector-1",
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
