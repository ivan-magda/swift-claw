"""Offline closure of operation artifacts, budgets, and replay projection ownership."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256

from scheduled_learning_v1.evidence_contract import canonical_object, operation_usage
from scheduled_learning_v1.score_evidence import score_evidence_projection

_LEGACY_MANIFEST_SHA256 = "d16ae90f1e54e866a75af773ae304884906fa943ad937a2e74c00a4638842c07"
_LEGACY_TERMINAL_SHA256 = "f6aac70171a8f99901acdff398d5f6d3f688a0738cd3e91d1b3a1308e6674576"
_LEGACY_USAGE_SHA256 = "531aba7952b1e0ea8add007f421a0f497d9c8f13ab9a6da9a382579acb88f787"
_ROOT_FILES = {
    "active-evidence.json",
    "aggregate-budget.json",
    "candidate.json",
    "decision-receipts.json",
    "failure.json",
    "final-report.json",
    "page-adapter-receipt.json",
    "promotion-receipt.json",
    "replay-receipt.json",
    "restart-evidence.json",
    "state.json",
}
_ROOT_DIRECTORIES = {"events", "learning-calls", "task-attempts"}
_AUXILIARY = ("state.json", "decision-receipts.json", "replay-receipt.json")
_EVENT_NAME = re.compile(r"^\d{6}-[0-9a-f]{64}\.json$")
_BUDGET_FIELDS = {
    "task_attempts",
    "evaluator_calls",
    "reflector_calls",
    "responses_sends",
    "accounted_tokens",
}


def verify_artifact_closure(
    root: Path,
    manifest: dict[str, object],
    event_values: list[dict[str, object]],
) -> dict[str, object]:
    """Verify every non-replay artifact owned by the scored result tree."""

    results = root / "results"
    _verify_root_inventory(results)
    _verify_auxiliary_projections(results)
    starts, finishes = _paired_operations(event_values)
    expected_directories = {
        "task": {operation_id for operation_id, value in starts.items() if _kind(value) == "task"},
        "learning": {
            operation_id for operation_id, value in starts.items() if _kind(value) != "task"
        },
    }
    _verify_directory_names(results / "task-attempts", expected_directories["task"])
    _verify_directory_names(results / "learning-calls", expected_directories["learning"])
    totals = {
        "schema_version": 1,
        "task_attempts": 0,
        "evaluator_calls": 0,
        "reflector_calls": 0,
        "responses_sends": 0,
        "accounted_tokens": 0,
    }
    legacy_digests: list[str] = []
    manifest_digest = canonical_sha256(manifest)
    for operation_id, start in starts.items():
        finish = finishes[operation_id]
        kind = _kind(start)
        counter = "task_attempts" if kind == "task" else f"{kind}_calls"
        totals[counter] += 1
        if kind == "task":
            sends, tokens, legacy = _verify_task(
                root,
                manifest,
                manifest_digest,
                operation_id,
                start,
                finish,
            )
        else:
            sends, tokens, legacy = _verify_learning(
                root,
                manifest,
                manifest_digest,
                operation_id,
                start,
                finish,
            )
        totals["responses_sends"] += sends
        totals["accounted_tokens"] += tokens
        if legacy is not None:
            if not _known_legacy_terminal(
                manifest_digest,
                operation_id,
                kind,
                finish,
                legacy,
            ):
                raise ValueError("finished operation has no result or terminal carrier")
            legacy_digests.append(legacy)
    budget = canonical_object(results / "aggregate-budget.json", "aggregate budget")
    if budget != totals:
        raise ValueError("aggregate budget differs from committed operation evidence")
    _verify_authorized_budget(root, manifest, totals)
    _verify_score_evidence(root, manifest, finishes)
    return {
        "self_verifying": not legacy_digests,
        "unreconstructable_terminal_digests": len(legacy_digests),
    }


def _known_legacy_terminal(
    manifest_digest: str,
    operation_id: str,
    kind: str,
    finish: dict[str, object],
    result_digest: str,
) -> bool:
    return (
        manifest_digest == _LEGACY_MANIFEST_SHA256
        and operation_id == "task-0"
        and kind == "task"
        and finish.get("status") == "failed"
        and result_digest == _LEGACY_TERMINAL_SHA256
        and finish.get("usage_digest") == _LEGACY_USAGE_SHA256
    )


def _verify_task(
    root: Path,
    manifest: dict[str, object],
    manifest_digest: str,
    operation_id: str,
    start: dict[str, object],
    finish: dict[str, object],
) -> tuple[int, int, str | None]:
    directory = root / "results" / "task-attempts" / operation_id
    allowed = {
        "carrier.json",
        "configuration.json",
        "invocation.json",
        "lessons.json",
        "result.json",
        "terminal.json",
        "evaluation",
    }
    _verify_children(directory, allowed, "task operation")
    for name in ("carrier.json", "configuration.json", "invocation.json"):
        if not (directory / name).is_file():
            raise ValueError(f"task operation is missing {name}")
    carrier = canonical_object(directory / "carrier.json", "task carrier")
    configuration = canonical_object(directory / "configuration.json", "task configuration")
    invocation = canonical_object(directory / "invocation.json", "task invocation")
    core = _authorized_core(invocation, start, root, operation_id, "invocation.json")
    if canonical_sha256(core) != start.get("invocation_core_digest"):
        raise ValueError("task invocation core digest differs from its start event")
    if core.get("configuration_sha256") != canonical_sha256(configuration):
        raise ValueError("task configuration digest differs from invocation")
    _require_path_suffix(
        core.get("configuration_path"), ("task-attempts", operation_id, "configuration.json")
    )
    if configuration.get("carrier_sha256") != canonical_sha256(carrier):
        raise ValueError("task carrier digest differs from configuration")
    if start.get("carrier_digest") != canonical_sha256(carrier):
        raise ValueError("task carrier digest differs from start event")
    _require_path_suffix(
        configuration.get("carrier_path"), ("task-attempts", operation_id, "carrier.json")
    )
    _verify_common_core(core, manifest, manifest_digest, start, operation_id)
    _verify_route(manifest, "task", start)
    return _verify_closure(directory, configuration.get("result_path"), finish, "task")


def _verify_learning(
    root: Path,
    manifest: dict[str, object],
    manifest_digest: str,
    operation_id: str,
    start: dict[str, object],
    finish: dict[str, object],
) -> tuple[int, int, str | None]:
    directory = root / "results" / "learning-calls" / operation_id
    allowed = {"carrier.json", "request.json", "result.json", "terminal.json"}
    _verify_children(directory, allowed, "learning operation")
    for name in ("carrier.json", "request.json"):
        if not (directory / name).is_file():
            raise ValueError(f"learning operation is missing {name}")
    carrier = canonical_object(directory / "carrier.json", "learning carrier")
    request = canonical_object(directory / "request.json", "learning request")
    core = _authorized_core(request, start, root, operation_id, "request.json")
    if canonical_sha256(core) != start.get("invocation_core_digest"):
        raise ValueError("learning request core digest differs from its start event")
    binding = _object(core.get("carrier"), "learning carrier binding")
    if binding.get("sha256") != canonical_sha256(carrier):
        raise ValueError("learning carrier digest differs from request")
    if start.get("carrier_digest") != canonical_sha256(carrier):
        raise ValueError("learning carrier digest differs from start event")
    _require_path_suffix(binding.get("path"), ("learning-calls", operation_id, "carrier.json"))
    _require_path_suffix(core.get("state_root"), (".private-learning-state", operation_id))
    _require_path_suffix(
        core.get("result_path"),
        (".private-learning-state", operation_id, "result.json"),
    )
    _verify_common_core(core, manifest, manifest_digest, start, operation_id)
    _verify_route(manifest, _kind(start), start)
    sends, tokens, legacy = _verify_closure(
        directory,
        str(directory / "result.json"),
        finish,
        "learning",
    )
    result_path = directory / "result.json"
    if result_path.is_file():
        result = canonical_object(result_path, "learning result")
        provenance = result.get("provenance")
        if isinstance(provenance, dict):
            if provenance.get("request_sha256") != _sha256(directory / "request.json"):
                raise ValueError("learning result request digest differs from authorized request")
            prompt = _object(core.get("prompt"), "learning prompt binding")
            if provenance.get("carrier_sha256") != binding.get("sha256"):
                raise ValueError("learning result carrier provenance differs from request")
            if provenance.get("prompt_sha256") != prompt.get("sha256"):
                raise ValueError("learning result prompt provenance differs from request")
    return sends, tokens, legacy


def _verify_closure(
    directory: Path,
    declared_result_path: object,
    finish: dict[str, object],
    name: str,
) -> tuple[int, int, str | None]:
    _require_path_suffix(
        declared_result_path, (directory.parent.name, directory.name, "result.json")
    )
    result_path = directory / "result.json"
    terminal_path = directory / "terminal.json"
    if result_path.is_file() and terminal_path.is_file():
        raise ValueError(f"{name} operation has both result and terminal carriers")
    if result_path.is_file():
        value = canonical_object(result_path, f"{name} result")
    elif terminal_path.is_file():
        value = canonical_object(terminal_path, f"{name} terminal")
    else:
        digest = finish.get("result_digest")
        if not isinstance(digest, str):
            raise ValueError(f"{name} finish result digest is invalid")
        return 0, 0, digest
    if canonical_sha256(value) != finish.get("result_digest"):
        raise ValueError(f"{name} result digest differs from finish event")
    sends, tokens, usage = operation_usage(value)
    if usage is not None:
        expected_usage: object | None = canonical_sha256(usage)
    else:
        status = value.get("status") or value.get("outcome") or finish.get("status")
        expected_usage = (
            None if status == "failed_no_call" else canonical_sha256({"status": status})
        )
    if finish.get("usage_digest") != expected_usage:
        raise ValueError(f"{name} usage digest differs from finish event")
    return sends, tokens, None


def _authorized_core(
    value: dict[str, object],
    start: dict[str, object],
    root: Path,
    operation_id: str,
    input_name: str,
) -> dict[str, object]:
    authorization = _object(value.get("authorization"), "operation authorization")
    event_sha = authorization.get("event_sha256")
    if not isinstance(event_sha, str) or event_sha != start.get("_event_sha256"):
        raise ValueError("operation authorization digest differs from start event")
    _require_path_suffix(authorization.get("event_path"), ("events", str(start["_event_name"])))
    expected_input = (
        root
        / "results"
        / ("task-attempts" if _kind(start) == "task" else "learning-calls")
        / operation_id
        / input_name
    )
    if not expected_input.is_file():
        raise ValueError("authorized operation input is missing")
    return {key: item for key, item in value.items() if key != "authorization"}


def _verify_common_core(
    core: dict[str, object],
    manifest: dict[str, object],
    manifest_digest: str,
    start: dict[str, object],
    operation_id: str,
) -> None:
    for key in ("job_id", "attempt_generation", "provider_call_id"):
        if core.get(key) != start.get(key):
            raise ValueError(f"operation {key} differs from start event")
    if core.get("operation_id") != operation_id:
        raise ValueError("operation ID differs from its artifact directory")
    binding = _object(core.get("manifest"), "operation manifest binding")
    if binding.get("manifest_sha256") != manifest_digest:
        raise ValueError("operation manifest digest differs from frozen manifest")
    if start.get("manifest_digest") != manifest_digest:
        raise ValueError("start event manifest digest differs from frozen manifest")
    freeze = binding.get("freeze_commit")
    if freeze is not None and freeze != start.get("freeze_commit"):
        raise ValueError("operation freeze commit differs from start event")


def _verify_route(manifest: dict[str, object], kind: str, start: dict[str, object]) -> None:
    execution = _object(manifest.get("swift_execution"), "manifest swift execution")
    route = _object(execution.get(f"{kind}_route"), f"manifest {kind} route")
    if canonical_sha256(route) != start.get("route_digest"):
        raise ValueError("operation route digest differs from frozen route")


def _paired_operations(
    events: list[dict[str, object]],
) -> tuple[dict[str, dict[str, object]], dict[str, dict[str, object]]]:
    starts: dict[str, dict[str, object]] = {}
    finishes: dict[str, dict[str, object]] = {}
    for value in events:
        kind = value.get("kind")
        if kind not in {"operation_started", "operation_finished"}:
            continue
        payload = dict(_object(value.get("payload"), "operation event payload"))
        operation_id = payload.get("operation_id")
        if not isinstance(operation_id, str) or not operation_id:
            raise ValueError("operation event has no canonical operation ID")
        target = starts if kind == "operation_started" else finishes
        if operation_id in target:
            raise ValueError("operation event identity is duplicated")
        if kind == "operation_started":
            payload["_event_sha256"] = value["_event_sha256"]
            payload["_event_name"] = value["_event_name"]
        target[operation_id] = payload
    if set(starts) != set(finishes):
        raise ValueError("operation start/finish inventory differs")
    for operation_id, start in starts.items():
        for key in ("job_id", "operation_kind", "attempt_generation"):
            if start.get(key) != finishes[operation_id].get(key):
                raise ValueError("operation finish identity differs from start")
    return starts, finishes


def _verify_auxiliary_projections(results: Path) -> None:
    events = results / "events"
    unknown = {
        path.name
        for path in events.iterdir()
        if path.name not in _AUXILIARY and _EVENT_NAME.fullmatch(path.name) is None
    }
    if unknown:
        raise ValueError(f"unowned event artifact: {sorted(unknown)[0]}")
    for name in _AUXILIARY:
        root_path = results / name
        auxiliary = events / name
        if not auxiliary.is_file() or auxiliary.read_bytes() != root_path.read_bytes():
            label = name.removesuffix(".json").replace("-", " ")
            raise ValueError(f"auxiliary {label} differs from root projection")


def _verify_root_inventory(results: Path) -> None:
    required = {
        "aggregate-budget.json",
        "decision-receipts.json",
        "final-report.json",
        "replay-receipt.json",
        "state.json",
    }
    names = {path.name for path in results.iterdir()}
    unknown = names - _ROOT_FILES - _ROOT_DIRECTORIES
    if unknown:
        raise ValueError(f"unowned result artifact: {sorted(unknown)[0]}")
    missing = required - names
    if missing:
        raise ValueError(f"required result artifact is missing: {sorted(missing)[0]}")


def _verify_authorized_budget(
    root: Path,
    manifest: dict[str, object],
    totals: dict[str, int],
) -> None:
    manifest_budget = _object(manifest.get("budgets"), "manifest budgets")
    approval = canonical_object(
        root / "freeze" / "owner-budget-approval.json",
        "owner approval",
    )
    approval_budget = _object(approval.get("budgets"), "owner approval budgets")
    if set(manifest_budget) != _BUDGET_FIELDS or set(approval_budget) != _BUDGET_FIELDS:
        raise ValueError("authorized budget inventory is not closed")
    for field in _BUDGET_FIELDS:
        manifest_limit = _nonnegative_integer(manifest_budget.get(field), field)
        approval_limit = _nonnegative_integer(approval_budget.get(field), field)
        if totals[field] > manifest_limit:
            raise ValueError(f"reconstructed total exceeds manifest authorized {field}")
        if totals[field] > approval_limit:
            raise ValueError(f"reconstructed total exceeds owner authorized {field}")
        if manifest_limit != approval_limit:
            raise ValueError(f"manifest and owner authorized {field} differ")


def _verify_score_evidence(
    root: Path,
    manifest: dict[str, object],
    finishes: dict[str, dict[str, object]],
) -> None:
    evidence_paths = [
        root / "results" / "active-evidence.json",
        root / "results" / "restart-evidence.json",
    ]
    if not any(path.is_file() for path in evidence_paths):
        return
    gates = _object(manifest.get("gates"), "manifest gates")
    thresholds = _object(
        gates.get("active_and_restart_gates"),
        "active and restart gates",
    )
    promotion = canonical_object(root / "results" / "promotion-receipt.json", "promotion")
    identities = _object(promotion.get("artifact_identities"), "promotion identities")
    promoted_digest = identities.get("replacement_digest")
    if not isinstance(promoted_digest, str):
        raise ValueError("promotion has no replacement digest")
    for name, order_index, threshold_name in (
        ("active", 8, "minimum_active_score"),
        ("restart", 9, "minimum_restart_active_score"),
    ):
        path = root / "results" / f"{name}-evidence.json"
        if not path.is_file():
            continue
        evidence = canonical_object(path, f"{name} evidence")
        operation_id = f"task-{order_index}"
        finish = finishes.get(operation_id)
        expected_result_digest = finish.get("result_digest") if finish is not None else None
        projection = score_evidence_projection(
            root,
            cast(dict[str, Any], manifest),
            cast(dict[str, Any], evidence),
            thresholds.get(threshold_name),
            order_index,
            promoted_digest,
            expected_result_digest=(
                str(expected_result_digest) if expected_result_digest is not None else ""
            ),
        )
        if projection is None:
            raise ValueError(f"{name} evidence is not bound to its frozen task result")


def _verify_directory_names(root: Path, expected: set[str]) -> None:
    observed = {path.name for path in root.iterdir()} if root.is_dir() else set()
    if observed != expected:
        raise ValueError("operation directory inventory differs from event log")
    if root.is_dir() and any(not path.is_dir() for path in root.iterdir()):
        raise ValueError("operation directory inventory contains a non-directory")


def _verify_children(root: Path, allowed: set[str], name: str) -> None:
    unknown = {path.name for path in root.iterdir()} - allowed
    if unknown:
        raise ValueError(f"{name} has an unowned artifact: {sorted(unknown)[0]}")
    evaluation = root / "evaluation"
    if evaluation.is_dir():
        allowed_relative = {
            "state",
            "state/clawd.lock",
            "workspace",
            "workspace/input.json",
        }
        observed = {str(path.relative_to(evaluation)) for path in evaluation.rglob("*")}
        if observed - allowed_relative:
            raise ValueError(f"{name} evaluation directory has an unowned artifact")


def _require_path_suffix(value: object, suffix: tuple[str, ...]) -> None:
    if not isinstance(value, str) or tuple(Path(value).parts[-len(suffix) :]) != suffix:
        raise ValueError("bound artifact path differs from its result-tree location")


def _kind(value: dict[str, object]) -> str:
    kind = value.get("operation_kind")
    if kind not in {"task", "evaluator", "reflector"}:
        raise ValueError("operation kind is outside the closed contract")
    return cast(str, kind)


def _object(value: object, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return cast(dict[str, Any], value)


def _nonnegative_integer(value: object, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError(f"authorized {name} must be a nonnegative integer")
    return value


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()
