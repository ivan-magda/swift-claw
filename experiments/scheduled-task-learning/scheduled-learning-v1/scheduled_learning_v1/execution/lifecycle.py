"""One directed, non-resumable M3 scored lifecycle over the generic reducer."""

from __future__ import annotations

import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256, load_object, write
from page_change_m3.materialize import normalize_lesson_text

from scheduled_learning_v1 import ALGORITHM_ID
from scheduled_learning_v1.preflight import verify_pre_run
from scheduled_learning_v1.replay_bootstrap import (
    EMPTY_LESSON_SET,
    JOB_ID,
    compatibility_digest,
    initial_replay_state,
)
from scheduled_learning_v1.replay_controller import EventJournal, ReplayController
from scheduled_learning_v1.reporting import build_final_report

from .budgets import AggregateBudget
from .operations import Operations
from .replay import (
    promoted_digest,
    promoted_lessons,
    refresh_replay,
    replay_and_publish,
    replay_job,
    require_no_interrupted,
)

_RUN_ORDER_COUNT = 10
_MIN_TRIGGER_RUNS = 2
_SHA256_LENGTH = 64


def run_scored(root: Path, credential_state_root: Path) -> dict[str, object]:
    """Execute the owner-authorized ten-row scored lifecycle exactly once."""

    root = Path(root).resolve(strict=True)
    try:
        manifest, approval = _frozen_inputs(root)
        verify_pre_run(root, approval)
        results = root / "results"
        if results.exists() and any(results.iterdir()):
            raise ValueError("a scored result tree already exists; incomplete runs never resume")
        journal = EventJournal(results / "events")
        controller = ReplayController(journal, initial=initial_replay_state(manifest, approval))
        budget = AggregateBudget()
        operations = _make_operations(
            root, manifest, approval, journal, budget, credential_state_root
        )
        _start_process(root, journal, controller, 2)
        _run_parent(root, manifest, controller, journal, operations, credential_state_root)
    except Exception as error:
        refresh_replay(root)
        _write_failure(root, error)
    return build_final_report(root)


def run_active(root: Path, generation: int, credential_state_root: Path) -> dict[str, object]:
    """Replay a promoted tree and execute only the post-restart active row."""

    root = Path(root).resolve(strict=True)
    try:
        if (root / "results" / "failure.json").is_file():
            raise ValueError("failure-marked result trees never resume")
        manifest, approval = _frozen_inputs(root)
        verify_pre_run(root, approval)
        if (root / "results" / "restart-evidence.json").exists():
            raise ValueError("post-restart evidence already exists; restart never resumes")
        journal = EventJournal(root / "results" / "events")
        controller = ReplayController(journal, initial=initial_replay_state(manifest, approval))
        replayed = replay_and_publish(root, controller)
        require_no_interrupted(replayed)
        job = replay_job(replayed)
        selected_digest = promoted_digest(job)
        lessons = promoted_lessons(job)
        if generation != int(replayed["state"]["controller_generation"]) + 1:
            raise ValueError("restart generation must be the next replay generation")
        budget = _budget_from_results(root)
        operations = _make_operations(
            root, manifest, approval, journal, budget, credential_state_root
        )
        _start_process(root, journal, controller, generation)
        row = _run_order(manifest)[9]
        attempt = operations.run_task(
            row,
            lessons,
            root / "results" / "promotion-receipt.json",
        )
        _require_task(attempt)
        score = operations.score_active(attempt, restart=True)
        write(
            root / "results" / "restart-evidence.json",
            {
                "schema_version": 1,
                **score,
                "promoted_digest": selected_digest,
            },
        )
        replay_and_publish(root, controller)
    except Exception as error:
        refresh_replay(root)
        _write_failure(root, error)
    return build_final_report(root)


def replayed_promoted_digest(root: Path) -> str:
    """Independently reconstruct the exact promoted lesson-set digest for child admission."""

    root = Path(root).resolve(strict=True)
    manifest, approval = _frozen_inputs(root)
    journal = EventJournal(root / "results" / "events")
    controller = ReplayController(journal, initial=initial_replay_state(manifest, approval))
    result = replay_and_publish(root, controller)
    return promoted_digest(replay_job(result))


def _run_parent(
    root: Path,
    manifest: dict[str, object],
    controller: ReplayController,
    journal: EventJournal,
    operations: Operations,
    credential_state_root: Path,
) -> None:
    evaluations: list[dict[str, object]] = []
    run_order = _run_order(manifest)
    for row in run_order[:2]:
        task = operations.run_task(row, [])
        _require_task(task)
        evaluated = operations.run_evaluator(task)
        evaluation = _evaluation(evaluated, task)
        evaluations.append(evaluation)
        journal.append(
            "stable_evaluation_recorded",
            _utc_now(),
            _evaluation_payload(task, evaluated, evaluation, compatibility_digest(manifest)),
        )
        replayed = replay_and_publish(root, controller)
    job = replay_job(replayed)
    trigger_digest = _open_trigger_digest(job)
    reflector = operations.run_reflector(
        trigger_digest,
        evaluations,
        _qualifying_issue_codes(evaluations),
    )
    if reflector.get("status") != "response":
        raise ValueError("reflector did not return a valid response")
    lessons = _lessons(reflector)
    result_digest = _required_digest(reflector.get("result_digest"), "reflector result")
    if not lessons:
        journal.append(
            "no_candidate_recorded",
            _utc_now(),
            {
                "job_id": JOB_ID,
                "operation_id": trigger_digest,
                "result_digest": result_digest,
                "trigger_digest": trigger_digest,
            },
        )
        replay_and_publish(root, controller)
        return
    candidate = _candidate_payload(job, trigger_digest, result_digest, lessons, manifest)
    lessons = _lessons(candidate)
    journal.append("candidate_artifact_recorded", _utc_now(), candidate)
    replayed = replay_and_publish(root, controller)
    adapter_binding = _adapter_binding(manifest)
    journal.append(
        "candidate_admitted",
        _utc_now(),
        {
            "job_id": JOB_ID,
            "candidate_record_digest": candidate["candidate_record_digest"],
            "replacement_digest": candidate["replacement_digest"],
            "base_digest": candidate["base_digest"],
            "base_revision": candidate["base_revision"],
            "learning_epoch": candidate["learning_epoch"],
            "feedback_revision": candidate["feedback_revision"],
            "adapter": adapter_binding,
        },
    )
    replayed = replay_and_publish(root, controller)
    job = replay_job(replayed)
    trial = _object(job.get("trial"), "open trial")
    pairs: list[dict[str, object]] = []
    settlements: list[tuple[str, str]] = []
    for clean_row, candidate_row in zip(run_order[2:8:2], run_order[3:8:2], strict=True):
        clean = operations.run_task(clean_row, [])
        _require_task(clean)
        run_id = f"task-{candidate_row['order_index']}"
        journal.append(
            "trial_run_created",
            _utc_now(),
            {
                "job_id": JOB_ID,
                "candidate_record_digest": candidate["candidate_record_digest"],
                "run_id": run_id,
            },
        )
        replay_and_publish(root, controller)
        candidate_attempt = operations.run_task(candidate_row, lessons)
        _require_task(candidate_attempt)
        evaluated = operations.run_evaluator(candidate_attempt)
        evaluation = _evaluation(evaluated, candidate_attempt)
        settlements.append((run_id, _trial_outcome(evaluation)))
        pairs.append(operations.score_pair(clean, candidate_attempt))
    receipt, envelope = operations.build_adapter(lessons, pairs)
    write(root / "results" / "page-adapter-receipt.json", receipt)
    journal.append(
        "adapter_receipt_recorded",
        _utc_now(),
        {
            "job_id": JOB_ID,
            "subject_kind": "trial",
            "subject_digest": trial["trial_digest"],
            "envelope": envelope,
        },
    )
    replayed = replay_and_publish(root, controller)
    current_trial = _object(replay_job(replayed).get("trial"), "trial after adapter receipt")
    if current_trial.get("status") != "open":
        return
    for run_id, outcome in settlements:
        journal.append(
            "trial_run_settled",
            _utc_now(),
            {"job_id": JOB_ID, "run_id": run_id, "outcome": outcome},
        )
        replayed = replay_and_publish(root, controller)
        trial_after_settlement = _object(replay_job(replayed).get("trial"), "settled trial")
        if trial_after_settlement.get("status") != "open" and run_id != settlements[-1][0]:
            return
    job = replay_job(replayed)
    if _promotion_status(job) != "active":
        return
    selected_digest = promoted_digest(job)
    write(
        root / "results" / "candidate.json",
        {
            "schema_version": 1,
            "base_digest": candidate["base_digest"],
            "candidate_record_digest": candidate["candidate_record_digest"],
            "replacement_digest": candidate["replacement_digest"],
            "lessons": lessons,
        },
    )
    write(
        root / "results" / "promotion-receipt.json", _promotion_receipt(replayed, selected_digest)
    )
    active = operations.run_task(run_order[8], lessons, root / "results" / "promotion-receipt.json")
    _require_task(active)
    active_score = operations.score_active(active, restart=False)
    write(
        root / "results" / "active-evidence.json",
        {"schema_version": 1, **active_score, "promoted_digest": selected_digest},
    )
    replayed = replay_and_publish(root, controller)
    threshold = _active_threshold(manifest, restart=False)
    if _score(active_score) < threshold:
        return
    generation = int(replayed["state"]["controller_generation"]) + 1
    _launch_restart(root, generation, selected_digest, credential_state_root)


def _start_process(
    root: Path, journal: EventJournal, controller: ReplayController, generation: int
) -> dict[str, object]:
    timestamp = _utc_now()
    journal.append("controller_started", timestamp, {"controller_generation": generation})
    journal.append("clock_advanced", timestamp, {})
    return replay_and_publish(root, controller)


def _make_operations(
    root: Path,
    manifest: dict[str, object],
    approval: dict[str, object],
    journal: EventJournal,
    budget: AggregateBudget,
    credential_state_root: Path,
) -> Operations:
    return Operations(
        root,
        manifest,
        approval,
        budget,
        journal=journal,
        credential_state_root=credential_state_root,
    )


def _launch_restart(
    root: Path, generation: int, promoted_digest: str, credential_state_root: Path
) -> None:
    completed = subprocess.run(  # noqa: S603 -- fixed interpreter/module and frozen arguments
        [
            sys.executable,
            "-B",
            "-m",
            "scheduled_learning_v1.run",
            "active",
            "--root",
            str(root),
            "--generation",
            str(generation),
            "--promoted-digest",
            promoted_digest,
            "--credential-state-root",
            str(credential_state_root),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        diagnostic = (completed.stdout + completed.stderr)[:1024]
        raise RuntimeError(f"fresh active process failed: {diagnostic}")


def _candidate_payload(
    job: dict[str, Any],
    trigger_digest: str,
    result_digest: str,
    lessons: list[str],
    manifest: dict[str, object],
) -> dict[str, object]:
    normalized = [normalize_lesson_text(lesson) for lesson in lessons]
    replacement_digest = canonical_sha256({"schema_version": 1, "lessons": normalized})
    payload: dict[str, object] = {
        "job_id": JOB_ID,
        "operation_id": trigger_digest,
        "result_digest": result_digest,
        "replacement_digest": replacement_digest,
        "lessons": normalized,
        "source_manifest_digest": canonical_sha256(
            {
                "manifest_sha256": canonical_sha256(manifest),
                "trigger_digest": trigger_digest,
                "result_digest": result_digest,
            }
        ),
        "base_digest": job["stable_digest"],
        "base_revision": job["stable_revision"],
        "learning_epoch": job["learning_epoch"],
        "feedback_revision": job["feedback_revision"],
        "algorithm_id": ALGORITHM_ID,
        "trigger_digest": trigger_digest,
    }
    core: dict[str, object] = {"schema_version": 1, **payload}
    return {
        **payload,
        "candidate_record_digest": canonical_sha256(
            {"domain": "scheduled-learning/v1/candidate-record", "value": core}
        ),
    }


def _evaluation_payload(
    task: dict[str, object],
    evaluated: dict[str, object],
    evaluation: dict[str, object],
    compatibility_digest: str,
) -> dict[str, object]:
    return {
        "job_id": JOB_ID,
        "run_id": task["run_id"],
        "operation_id": evaluated["operation_id"],
        "evaluation_digest": canonical_sha256(evaluation),
        "logical_occurrence": _utc_now(),
        "learning_epoch": 0,
        "compatibility_digest": compatibility_digest,
        "stable_digest": canonical_sha256(EMPTY_LESSON_SET),
        "outcome": evaluation["outcome"],
        "issue_codes": evaluation["issue_codes"],
    }


def _frozen_inputs(root: Path) -> tuple[dict[str, object], dict[str, object]]:
    manifest = load_object(root / "freeze" / "manifest.json")
    approval = load_object(root / "freeze" / "owner-budget-approval.json")
    return cast(dict[str, object], manifest), cast(dict[str, object], approval)


def _run_order(manifest: dict[str, object]) -> list[dict[str, object]]:
    value = manifest.get("run_order")
    if not isinstance(value, list) or len(value) != _RUN_ORDER_COUNT:
        raise ValueError("frozen run order must contain exactly ten rows")
    return [cast(dict[str, object], row) for row in value if isinstance(row, dict)]


def _open_trigger_digest(job: dict[str, Any]) -> str:
    triggers = job.get("triggers")
    if not isinstance(triggers, list):
        raise ValueError("stable evaluations did not produce a trigger")
    for trigger in reversed(triggers):
        if isinstance(trigger, dict) and trigger.get("closed") is False:
            return _required_digest(trigger.get("trigger_digest"), "reflector trigger")
    raise ValueError("stable evaluations did not produce an open trigger")


def _promotion_status(job: dict[str, Any]) -> str | None:
    value = job.get("promotion")
    return value.get("status") if isinstance(value, dict) else None


def _promotion_receipt(result: dict[str, Any], replacement_digest: str) -> dict[str, Any]:
    decisions = result.get("decisions")
    if isinstance(decisions, list):
        for receipt in reversed(decisions):
            if not isinstance(receipt, dict) or receipt.get("decision") != "promoted":
                continue
            identities = receipt.get("artifact_identities")
            if (
                isinstance(identities, dict)
                and identities.get("replacement_digest") == replacement_digest
            ):
                return cast(dict[str, Any], receipt)
    raise ValueError("exact promotion decision receipt is unavailable")


def _evaluation(evaluated: dict[str, object], task: dict[str, object]) -> dict[str, object]:
    value = evaluated.get("evaluation")
    if not isinstance(value, dict):
        return {
            "schema_version": 1,
            "task_id": task["task_id"],
            "outcome": "uncertain",
            "issue_codes": [],
        }
    return cast(dict[str, object], value)


def _qualifying_issue_codes(evaluations: list[dict[str, object]]) -> list[str]:
    counts: dict[str, int] = {}
    for evaluation in evaluations:
        codes = evaluation.get("issue_codes")
        if evaluation.get("outcome") == "reusable_issue" and isinstance(codes, list):
            for code in codes:
                if isinstance(code, str):
                    counts[code] = counts.get(code, 0) + 1
    return sorted(code for code, count in counts.items() if count >= _MIN_TRIGGER_RUNS)


def _adapter_binding(manifest: dict[str, object]) -> dict[str, object]:
    identities = _object(manifest.get("identities"), "page identities")
    return {
        key: identities[key]
        for key in (
            "adapter_id",
            "adapter_version",
            "dataset_digest",
            "oracle_digest",
            "gates_digest",
            "execution_surface_digest",
        )
    }


def _trial_outcome(evaluation: dict[str, object]) -> str:
    outcome = evaluation.get("outcome")
    if outcome == "no_issue":
        return "positive"
    if outcome == "reusable_issue":
        return "negative"
    return "neutral"


def _require_task(task: dict[str, object]) -> None:
    if task.get("status") != "completed":
        raise ValueError("task attempt did not complete")


def _lessons(value: dict[str, object]) -> list[str]:
    lessons = value.get("lessons")
    if not isinstance(lessons, list) or any(not isinstance(item, str) for item in lessons):
        raise ValueError("reflector lesson output is invalid")
    return cast(list[str], lessons)


def _object(value: object, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return cast(dict[str, Any], value)


def _required_digest(value: object, name: str) -> str:
    if not isinstance(value, str) or len(value) != _SHA256_LENGTH:
        raise ValueError(f"{name} digest is invalid")
    return value


def _score(value: dict[str, object]) -> float:
    score = value.get("score")
    if not isinstance(score, (int, float)) or isinstance(score, bool):
        raise ValueError("score evidence is invalid")
    return float(score)


def _active_threshold(manifest: dict[str, object], *, restart: bool) -> float:
    gates = _object(manifest.get("gates"), "gates")
    active = _object(gates.get("active_and_restart_gates"), "active gates")
    key = "minimum_restart_active_score" if restart else "minimum_active_score"
    value = active.get(key)
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError("active threshold is invalid")
    return float(value)


def _budget_from_results(root: Path) -> AggregateBudget:
    value = (
        load_object(root / "results" / "aggregate-budget.json")
        if (root / "results" / "aggregate-budget.json").is_file()
        else {}
    )
    return AggregateBudget(
        task_attempts=int(value.get("task_attempts", 9)),
        evaluator_calls=int(value.get("evaluator_calls", 5)),
        reflector_calls=int(value.get("reflector_calls", 1)),
        responses_sends=int(value.get("responses_sends", 0)),
        accounted_tokens=int(value.get("accounted_tokens", 0)),
    )


def _write_failure(root: Path, error: Exception) -> None:
    results = root / "results"
    results.mkdir(parents=True, exist_ok=True)
    write(
        results / "failure.json",
        {"schema_version": 1, "status": "incomplete_failed", "error": str(error)[:1024]},
    )


def _utc_now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
