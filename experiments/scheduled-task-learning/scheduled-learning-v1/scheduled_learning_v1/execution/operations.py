"""Materialization and freshly verified bridge/scorer boundaries."""

from __future__ import annotations

import hashlib
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256, load_object, loads_object, write
from page_change_m3.fixtures import fresh_gold_path, fresh_source_path
from page_change_m3.oracle import sealed_score

from page_change_m3 import (
    build_adapter_receipt,
    build_evaluator_carrier,
    build_reflector_carrier,
    materialize_task,
    score_pair,
)
from scheduled_learning_v1.freeze_inputs import load_canonical_object
from scheduled_learning_v1.frozen_contract import json_exactly_matches
from scheduled_learning_v1.preflight import verify_pre_run
from scheduled_learning_v1.replay_bootstrap import JOB_ID
from scheduled_learning_v1.replay_controller import EventJournal
from scheduled_learning_v1.worker_bridge import (
    LearningCall,
    TaskAttemptCall,
    WorkerBridge,
)

from .budgets import AggregateBudget
from .task_configuration import build_task_configuration, executable_path, manifest_binding

_MAX_REFLECTOR_LESSONS = 3
_MAX_REFLECTOR_LESSON_LENGTH = 4000
_MAX_ISSUE_CODES = 32
_MAX_ISSUE_CODE_LENGTH = 128


class Operations:
    """One cohesive materializer around all real external/trusted boundaries."""

    def __init__(
        self,
        root: Path,
        manifest: dict[str, object],
        approval: dict[str, object],
        budget: AggregateBudget,
        *,
        journal: EventJournal | None = None,
        bridge: object | None = None,
        credential_state_root: Path | None = None,
        verify: Callable[[Path, dict[str, object]], dict[str, object]] = verify_pre_run,
        pair_scorer: Callable[
            [dict[str, object], dict[str, object]], dict[str, object]
        ] = score_pair,
        active_scorer: Callable[[dict[str, object], str], dict[str, object]] = sealed_score,
        dispatch_bounds: Callable[[str], tuple[int, int]] | None = None,
    ) -> None:
        self.root = Path(root).absolute()
        self.manifest = manifest
        self.approval = approval
        self.budget = budget
        self.verify = verify
        self.pair_scorer = pair_scorer
        self.active_scorer = active_scorer
        self.dispatch_bounds = dispatch_bounds
        self.journal = journal
        if bridge is not None:
            self.bridge = bridge
        else:
            if journal is None:
                raise ValueError("a journal is required when constructing the real bridge")
            if credential_state_root is None:
                raise ValueError("a credential state root is required for the real bridge")
            self.bridge = WorkerBridge(self._executable(), journal, credential_state_root)

    def dispatch_task(self, call: object) -> dict[str, object]:
        """Reserve, freshly verify, and enter the Swift task bridge without intervening I/O."""

        return self._dispatch_task(call)

    def _dispatch_task(
        self,
        call: object,
        prepared_approval: dict[str, object] | None = None,
    ) -> dict[str, object]:
        maximum_sends, maximum_tokens = self._dispatch_bounds("task")
        self.budget.reserve(
            "task",
            maximum_responses_sends=maximum_sends,
            maximum_accounted_tokens=maximum_tokens,
        )
        self._verify_boundary(prepared_approval)
        terminal = cast(Any, self.bridge).run_task(call)
        self.budget.record(terminal)
        self._publish_budget()
        return cast(dict[str, object], terminal)

    def dispatch_learning(self, call: LearningCall) -> dict[str, object]:
        """Reserve, freshly verify, and enter one Swift learning bridge."""

        return self._dispatch_learning(call)

    def _dispatch_learning(
        self,
        call: LearningCall,
        prepared_approval: dict[str, object] | None = None,
    ) -> dict[str, object]:
        maximum_sends, maximum_tokens = self._dispatch_bounds(call.kind)
        self.budget.reserve(
            call.kind,
            maximum_responses_sends=maximum_sends,
            maximum_accounted_tokens=maximum_tokens,
        )
        self._verify_boundary(prepared_approval)
        terminal = cast(Any, self.bridge).run_learning(call)
        self.budget.record(terminal)
        self._publish_budget()
        return cast(dict[str, object], terminal)

    def run_task(
        self,
        row: dict[str, object],
        lessons: list[str],
        promotion_receipt: Path | None = None,
    ) -> dict[str, object]:
        """Materialize one frozen schedule row and validate its task terminal projection."""

        operation_approval = self._current_approval()
        split = _split(row)
        fixture_id = str(row["fixture_id"])
        source = load_object(fresh_source_path(self.root, split, fixture_id))
        gold = load_object(fresh_gold_path(self.root, split, fixture_id))
        carrier = materialize_task(source, lessons)
        operation_id = f"task-{row['order_index']}"
        directory = self.root / "results" / "task-attempts" / operation_id
        directory.mkdir(parents=True, exist_ok=True)
        carrier_path = directory / "carrier.json"
        configuration_path = directory / "configuration.json"
        invocation_path = directory / "invocation.json"
        result_path = directory / "result.json"
        write(carrier_path, carrier)
        lesson_path = self._lesson_artifact(directory, lessons, row)
        configuration = build_task_configuration(
            self.root,
            self.manifest,
            operation_approval,
            row,
            source,
            carrier_path,
            lesson_path,
            promotion_receipt,
            result_path,
        )
        write(configuration_path, configuration)
        core: dict[str, object] = {
            "schema_version": 1,
            "execution_profile": "scheduled-learning-v1",
            "job_id": JOB_ID,
            "operation_id": operation_id,
            "attempt_generation": self._attempt_generation(),
            "provider_call_id": _uuid(operation_id),
            "configuration_path": str(configuration_path),
            "configuration_sha256": _sha256(configuration_path),
            "manifest": self._manifest_binding(operation_approval),
            "budget": self.budget.task_snapshot(),
        }
        terminal = self._dispatch_task(
            TaskAttemptCall(
                invocation_core=core,
                invocation_path=invocation_path,
                result_path=result_path,
            ),
            operation_approval,
        )
        raw_output = terminal.get("raw_output")
        if not isinstance(raw_output, str):
            raw_output = ""
        raw_attempt: dict[str, object]
        try:
            raw_attempt = cast(dict[str, object], loads_object(raw_output))
        except ValueError:
            raw_attempt = {}
        return {
            **terminal,
            "operation_id": operation_id,
            "run_id": operation_id,
            "task_id": source["task_id"],
            "fixture_id": fixture_id,
            "condition": row["condition"],
            "task_result_digest": self._operation_result_digest(operation_id, terminal),
            "raw_output": raw_output,
            "attempt": {"source": source, "gold": gold, "attempt": raw_attempt},
        }

    def run_evaluator(self, task: dict[str, object]) -> dict[str, object]:
        """Run one closed evaluator carrier and classify schema-invalid output as uncertain."""

        carrier = build_evaluator_carrier(
            self._task_carrier(task["operation_id"]), str(task["raw_output"])
        )
        operation_id = f"evaluator-{task['run_id']}"
        terminal = self._run_learning(operation_id, "evaluator", carrier)
        evaluation = _evaluator_output(terminal.get("output"), str(task["task_id"]))
        return {**terminal, "operation_id": operation_id, "evaluation": evaluation}

    def run_reflector(
        self,
        trigger_digest: str,
        evaluations: list[dict[str, object]],
        issue_codes: list[str],
    ) -> dict[str, object]:
        """Run the one reflector using its immutable trigger digest as operation ID."""

        carrier = build_reflector_carrier([], evaluations, issue_codes, [])
        terminal = self._run_learning(trigger_digest, "reflector", carrier)
        result_digest = self._operation_result_digest(trigger_digest)
        lessons = _reflector_output(terminal.get("output"))
        if lessons is None:
            return {**terminal, "status": "schema_invalid", "result_digest": result_digest}
        return {**terminal, "result_digest": result_digest, "lessons": lessons}

    def score_pair(
        self, clean: dict[str, object], candidate: dict[str, object]
    ) -> dict[str, object]:
        """Freshly verify immediately before the trusted paired scorer."""

        self._verify_boundary()
        return self.pair_scorer(_attempt(clean), _attempt(candidate))

    def build_adapter(
        self, lessons: list[str], pairs: list[dict[str, object]]
    ) -> tuple[dict[str, object], dict[str, object]]:
        """Seal the post-freeze page receipt under the exact manifest identities."""

        identities = _object(self.manifest.get("identities"), "page identities")
        frozen = {
            key: str(identities[key])
            for key in (
                "adapter_id",
                "adapter_version",
                "dataset_digest",
                "oracle_digest",
                "gates_digest",
                "execution_surface_digest",
            )
        }
        self._verify_boundary()
        return build_adapter_receipt(lessons, pairs, frozen)

    def score_active(self, attempt: dict[str, object], *, restart: bool) -> dict[str, object]:
        """Freshly verify immediately before the trusted active/restart score."""

        self._verify_boundary()
        trusted_attempt = _attempt(attempt)
        score_evidence = self.active_scorer(
            trusted_attempt,
            "restart" if restart else "active",
        )
        identities = _object(self.manifest.get("identities"), "page identities")
        source = _object(trusted_attempt.get("source"), "active source")
        gold = _object(trusted_attempt.get("gold"), "active gold")
        raw_attempt = _object(trusted_attempt.get("attempt"), "active attempt")
        return {
            **score_evidence,
            "operation_id": attempt["operation_id"],
            "task_id": attempt["task_id"],
            "task_result_digest": attempt["task_result_digest"],
            "fixture_id": attempt["fixture_id"],
            "condition": attempt["condition"],
            "scoring_condition": "restart" if restart else "active",
            "source_sha256": canonical_sha256(source),
            "gold_sha256": canonical_sha256(gold),
            "attempt_sha256": canonical_sha256(raw_attempt),
            "oracle_digest": identities["oracle_digest"],
        }

    def _run_learning(
        self, operation_id: str, kind: str, carrier: dict[str, object]
    ) -> dict[str, object]:
        operation_approval = self._current_approval()
        directory = self.root / "results" / "learning-calls" / operation_id
        directory.mkdir(parents=True, exist_ok=True)
        carrier_path = directory / "carrier.json"
        request_path = directory / "request.json"
        result_path = directory / "result.json"
        private_state = self.root / "results" / ".private-learning-state" / operation_id
        published_result_path = private_state / "result.json"
        write(carrier_path, carrier)
        prompt_path = self.root / "prompts" / f"{kind}.md"
        core: dict[str, object] = {
            "schema_version": 1,
            "execution_profile": "scheduled-learning-v1",
            "job_id": JOB_ID,
            "operation_id": operation_id,
            "attempt_generation": self._attempt_generation(),
            "provider_call_id": _uuid(operation_id),
            "kind": kind,
            "state_root": str(private_state),
            "prompt": {"path": str(prompt_path), "sha256": _sha256(prompt_path)},
            "carrier": {"path": str(carrier_path), "sha256": _sha256(carrier_path)},
            "result_path": str(published_result_path),
            "manifest": self._manifest_binding(operation_approval),
        }
        call = LearningCall(
            kind=cast(Any, kind),
            request_core=core,
            request_path=request_path,
            result_path=result_path,
        )
        return self._dispatch_learning(call, operation_approval)

    def _lesson_artifact(
        self, directory: Path, lessons: list[str], row: dict[str, object]
    ) -> Path | None:
        if not lessons or row["condition"] == "post_restart_active":
            return None
        path = directory / "lessons.json"
        write(path, {"schema_version": 1, "lessons": lessons})
        return path

    def _task_carrier(self, operation_id: object) -> dict[str, Any]:
        return load_object(
            self.root / "results" / "task-attempts" / str(operation_id) / "carrier.json"
        )

    def _operation_result_digest(
        self,
        operation_id: str,
        terminal: dict[str, object] | None = None,
    ) -> str:
        journal = getattr(self.bridge, "journal", None)
        if not isinstance(journal, EventJournal):
            if terminal is not None:
                return canonical_sha256(terminal)
            raise ValueError("real learning bridge did not expose its committed journal")
        for event in reversed(journal.load()):
            if (
                event.kind.value == "operation_finished"
                and event.payload.get("operation_id") == operation_id
            ):
                return str(event.payload["result_digest"])
        raise ValueError("learning operation has no committed terminal result")

    def _attempt_generation(self) -> int:
        journal = self.journal
        if journal is None:
            candidate = getattr(self.bridge, "journal", None)
            journal = candidate if isinstance(candidate, EventJournal) else None
        if journal is None:
            return 1
        for event in reversed(journal.load()):
            if event.kind.value == "controller_started":
                generation = event.payload.get("controller_generation")
                if isinstance(generation, int) and not isinstance(generation, bool):
                    return generation
        raise ValueError("task or learning call has no committed controller generation")

    def _manifest_binding(self, approval: dict[str, object]) -> dict[str, object]:
        approval_path = self.root / "freeze" / "owner-budget-approval.json"
        binding = manifest_binding(self.root, self.manifest, approval_path)
        owner_approval = _object(binding.get("owner_approval"), "owner approval binding")
        if owner_approval.get("sha256") != canonical_sha256(approval):
            raise ValueError("operation approval binding differs from the approved object")
        return binding

    def _current_approval(self) -> dict[str, object]:
        current = load_canonical_object(self.root / "freeze" / "owner-budget-approval.json")
        if not json_exactly_matches(current, self.approval):
            raise ValueError("owner approval changed after initial verification")
        return current

    def _verify_boundary(
        self, prepared_approval: dict[str, object] | None = None
    ) -> dict[str, object]:
        current = self._current_approval()
        if prepared_approval is not None and not json_exactly_matches(current, prepared_approval):
            raise ValueError("operation approval changed during materialization")
        self.verify(self.root, current)
        return current

    def _dispatch_bounds(self, kind: str) -> tuple[int, int]:
        if self.dispatch_bounds is not None:
            return self.dispatch_bounds(kind)
        execution = _object(self.manifest.get("swift_execution"), "swift execution")
        missing_usage = execution.get("missing_usage_token_proxy")
        gates = _object(self.manifest.get("gates"), "manifest gates")
        sends_by_kind = _object(
            gates.get("responses_sends_per_operation"),
            "responses sends per operation",
        )
        maximum_sends = sends_by_kind.get(kind)
        if (
            not isinstance(missing_usage, int)
            or isinstance(missing_usage, bool)
            or missing_usage <= 0
            or not isinstance(maximum_sends, int)
            or isinstance(maximum_sends, bool)
            or maximum_sends <= 0
        ):
            raise ValueError("manifest has no positive dispatch accounting bound")
        return maximum_sends, maximum_sends * missing_usage

    def _executable(self) -> Path:
        return executable_path(self.root, self.manifest)

    def _publish_budget(self) -> None:
        (self.root / "results").mkdir(parents=True, exist_ok=True)
        write(
            self.root / "results" / "aggregate-budget.json",
            {
                "schema_version": 1,
                "task_attempts": self.budget.task_attempts,
                "evaluator_calls": self.budget.evaluator_calls,
                "reflector_calls": self.budget.reflector_calls,
                "responses_sends": self.budget.responses_sends,
                "accounted_tokens": self.budget.accounted_tokens,
            },
        )


def _evaluator_output(value: object, task_id: str) -> dict[str, object] | None:
    try:
        output = loads_object(value) if isinstance(value, str) else {}
    except ValueError:
        return None
    if (
        set(output) != {"schema_version", "task_id", "outcome", "issue_codes"}
        or output.get("schema_version") != 1
        or output.get("task_id") != task_id
        or output.get("outcome")
        not in {"no_issue", "reusable_issue", "transient_issue", "uncertain"}
        or not _issue_codes(output.get("issue_codes"))
    ):
        return None
    return cast(dict[str, object], output)


def _reflector_output(value: object) -> list[str] | None:
    try:
        output = loads_object(value) if isinstance(value, str) else {}
    except ValueError:
        return None
    lessons = output.get("lessons")
    if (
        set(output) != {"schema_version", "lessons"}
        or output.get("schema_version") != 1
        or not isinstance(lessons, list)
        or len(lessons) > _MAX_REFLECTOR_LESSONS
        or any(
            not isinstance(item, str) or not item or len(item) > _MAX_REFLECTOR_LESSON_LENGTH
            for item in lessons
        )
    ):
        return None
    return cast(list[str], lessons)


def _issue_codes(value: object) -> bool:
    return bool(
        isinstance(value, list)
        and len(value) <= _MAX_ISSUE_CODES
        and len(set(cast(list[object], value))) == len(value)
        and all(
            isinstance(item, str) and 1 <= len(item) <= _MAX_ISSUE_CODE_LENGTH for item in value
        )
    )


def _attempt(value: dict[str, object]) -> dict[str, object]:
    attempt = value.get("attempt")
    if not isinstance(attempt, dict):
        raise ValueError("task execution has no trusted score input")
    return cast(dict[str, object], attempt)


def _split(row: dict[str, object]) -> str:
    stage = row.get("stage")
    if stage in {"active", "restart"}:
        return "sealed"
    if stage not in {"development", "regression"}:
        raise ValueError("run-order stage is invalid")
    return str(stage)


def _object(value: object, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return cast(dict[str, Any], value)


def _sha256(path: Path | None) -> str:
    if path is None:
        raise ValueError("cannot hash an absent artifact")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _uuid(value: str) -> str:
    return str(uuid.UUID(hex=canonical_sha256({"operation_id": value})[:32]))
