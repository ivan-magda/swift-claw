from __future__ import annotations

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
        operation_id=trigger_digest,
    )
    finished = operation_finished(
        sequence + 1,
        occurred_at,
        job_id=job_id,
        kind=operation_kind,
        generation=1,
        operation_id=trigger_digest,
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
    frozen_operation_id: str | None = None,
    frozen_result_digest: str = "reflector-result-1",
    frozen_source_manifest_digest: str = "source-manifest-1",
    **overrides: Any,
) -> ReplayEvent:
    settled = lessons if normalized is None else normalized
    operation_id = trigger_digest if frozen_operation_id is None else frozen_operation_id
    replacement_digest = lesson_set_digest(settled)
    core = {
        "schema_version": 1,
        "job_id": job_id,
        "operation_id": operation_id,
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
        "operation_id": operation_id,
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
            logical_occurrence=FIRST_OCCURRENCE,
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
    operation_id = trigger["trigger_digest"]
    result_digest = "reflector-result-later"
    operation = reflector_operation(
        next_sequence + 2,
        CONTROL_OCCURRENCE,
        "job-a",
        trigger["trigger_digest"],
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
