"""Closed Swift worker inputs and their frozen artifact projections."""

from __future__ import annotations

import hashlib
import json
import re
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, cast

from benchmark_core.canonical import canonical_sha256, dumps, loads_object

_LEARNING_CORE_KEYS = {
    "schema_version",
    "execution_profile",
    "job_id",
    "operation_id",
    "attempt_generation",
    "provider_call_id",
    "kind",
    "state_root",
    "prompt",
    "carrier",
    "result_path",
    "manifest",
}
_TASK_CORE_KEYS = {
    "schema_version",
    "execution_profile",
    "job_id",
    "operation_id",
    "attempt_generation",
    "provider_call_id",
    "configuration_path",
    "configuration_sha256",
    "manifest",
    "budget",
}
_MANIFEST_KEYS = {
    "repository_root",
    "evaluation_root",
    "manifest_path",
    "manifest_sha256",
    "owner_approval",
}
_BUDGET_KEYS = {
    "task_attempts",
    "evaluator_calls",
    "reflector_calls",
    "responses_sends",
    "accounted_tokens",
}
_ROUTE_KEYS = {
    "provider_reference",
    "wire_model",
    "retry_budget",
    "max_output_tokens",
    "max_output_utf8_bytes",
    "max_output_graphemes",
}
_EXECUTION_KEYS = {
    "evaluator_route",
    "executable_sha256",
    "missing_usage_token_proxy",
    "reflector_route",
    "task_route",
}
_APPROVAL_KEYS = {
    "schema_version",
    "manifest_sha256",
    "expected_freeze_commit",
    "budgets",
    "owner_identity",
    "approved_at",
}
_TASK_BUDGET_KEYS = {
    "stage_accounted_tokens",
    "global_accounted_tokens",
    "stage_responses_sends",
    "global_responses_sends",
    "stage_accounted_token_threshold",
    "global_accounted_token_threshold",
    "stage_responses_send_cap",
    "global_responses_send_cap",
}
_CONFIGURATION_KEYS = {
    "execution_profile",
    "carrier_path",
    "carrier_sha256",
    "schema_version",
    "attempt_id",
    "fixture_id",
    "task_id",
    "split",
    "stage",
    "frozen_order_index",
    "frozen_order_key",
    "replicate",
    "condition",
    "evaluation_root",
    "source_artifact_path",
    "source_sha256",
    "input_sha256",
    "lesson_source",
    "lesson_artifact_path",
    "promotion_receipt_path",
    "promotion_receipt_sha256",
    "publish_lesson_as_active",
    "task_prompt_path",
    "task_prompt_sha256",
    "result_path",
    "fixed_timestamp",
    "protocol_sha256",
    "lesson_set_digest",
    "expected_policy_version",
    "provider_reference",
    "wire_model",
    "transport_mode",
    "fallback_reference",
    "approval",
    "provenance",
    "replacement_of_attempt_id",
    "replacement_ordinal",
}
_OPTIONAL_CONFIGURATION_KEYS = {
    "lesson_artifact_path",
    "promotion_receipt_path",
    "promotion_receipt_sha256",
    "fallback_reference",
    "replacement_of_attempt_id",
}
_PROVENANCE_KEYS = {
    "freeze_commit",
    "executable_sha256",
    "runtime_sources_sha256",
    "harness_sources_sha256",
    "dependencies_sha256",
    "configuration_sha256",
    "model_sha256",
    "retry_sha256",
    "output_sha256",
    "prompts_sha256",
    "schemas_sha256",
    "scorer_sha256",
    "splits_sha256",
    "run_order_sha256",
    "system_prompt_sha256",
    "proactive_system_prompt_sha256",
}
_TASK_APPROVAL_KEYS = {
    "comment_id",
    "comment_node_id",
    "author_login",
    "author_id",
    "author_node_id",
    "created_at",
    "updated_at",
    "manifest_sha256",
    "approved_manifest_sha256",
    "approval_comment_url",
    "approval_body_sha256",
}
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_COMMIT = re.compile(r"^[0-9a-f]{40}$")
_GLOBAL_ACCOUNTED_TOKEN_THRESHOLD = 4_350_000
_GLOBAL_RESPONSES_SEND_CAP = 454
_TASK_MISSING_USAGE_TOKEN_PROXY = 132_768
_TASK_ROUTE = {
    "provider_reference": "openai-chatgpt/gpt-5.6-sol",
    "wire_model": "gpt-5.6-sol",
    "retry_budget": 1,
    "max_output_tokens": 4096,
    "max_output_utf8_bytes": 32_768,
    "max_output_graphemes": 16_384,
}
_LEARNING_RETRY_BUDGET = 3


@dataclass(frozen=True)
class TaskAttemptCall:
    invocation_core: dict[str, object]
    invocation_path: Path
    result_path: Path


@dataclass(frozen=True)
class LearningCall:
    kind: Literal["evaluator", "reflector"]
    request_core: dict[str, object]
    request_path: Path
    result_path: Path


def core_digest(core: dict[str, object]) -> str:
    return canonical_sha256(core)


def bind_authorization(
    core: dict[str, object], event_path: Path, event_sha256: str
) -> dict[str, object]:
    if not event_path.is_absolute() or not _SHA256.fullmatch(event_sha256):
        raise ValueError("committed authorization is not canonical")
    return {**core, "authorization": {"event_path": str(event_path), "event_sha256": event_sha256}}


def write_closed_input(path: Path, value: dict[str, object]) -> None:
    if not path.is_absolute():
        raise ValueError("worker input path must be absolute")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(dumps(value), encoding="utf-8")


def final_request_digest(call: LearningCall) -> str:
    """Bind result provenance to the exact final authorized request bytes."""

    request = _canonical_object(call.request_path)
    if set(request) != _LEARNING_CORE_KEYS | {"authorization"}:
        raise ValueError("learning request has non-canonical fields")
    authorization = _required_object(request, "authorization")
    _require_exact(authorization, {"event_path", "event_sha256"}, "authorization")
    if {key: request[key] for key in _LEARNING_CORE_KEYS} != call.request_core:
        raise ValueError("final request does not retain the exact request core")
    _absolute(authorization.get("event_path"))
    _require_sha(authorization.get("event_sha256"), "authorization event")
    return _sha256(call.request_path.read_bytes())


def bound_contract(core: dict[str, object], kind: str) -> dict[str, object]:
    """Read the immutable artifacts Swift admission itself uses for this launch."""

    _validate_core(core, kind)
    manifest = _required_object(core, "manifest")
    manifest_data = _absolute(manifest.get("manifest_path")).read_bytes()
    if _sha256(manifest_data) != manifest.get("manifest_sha256"):
        raise ValueError("manifest digest does not bind to core")
    manifest_document = _canonical_bytes_object(manifest_data)
    budgets = _required_object(manifest_document, "budgets")
    _require_exact(budgets, _BUDGET_KEYS, "manifest budgets")
    if any(_positive_integer(budgets, key) <= 0 for key in _BUDGET_KEYS):
        raise ValueError("manifest budgets must be positive")
    execution = _required_object(manifest_document, "swift_execution")
    _require_exact(execution, _EXECUTION_KEYS, "manifest swift_execution")
    routes: dict[str, dict[str, object]] = {}
    for route_kind in ("task", "evaluator", "reflector"):
        route = _required_object(execution, f"{route_kind}_route")
        _require_exact(route, _ROUTE_KEYS, f"manifest {route_kind} route")
        _validate_route(route)
        routes[route_kind] = route
    _require_sha(execution.get("executable_sha256"), "manifest executable")
    proxy = _positive_integer(execution, "missing_usage_token_proxy")
    if kind == "task" and (
        routes["task"] != _TASK_ROUTE or proxy != _TASK_MISSING_USAGE_TOKEN_PROXY
    ):
        raise ValueError("task route or usage proxy does not match the Swift runtime contract")
    if kind in {"evaluator", "reflector"} and (
        routes[kind].get("retry_budget") != _LEARNING_RETRY_BUDGET
    ):
        raise ValueError("learning route retry budget does not match the Swift call contract")

    approval_binding = _required_object(manifest, "owner_approval")
    approval_data = _absolute(approval_binding.get("path")).read_bytes()
    if _sha256(approval_data) != approval_binding.get("sha256"):
        raise ValueError("owner approval digest does not bind to core")
    approval = _canonical_bytes_object(approval_data)
    _require_exact(approval, _APPROVAL_KEYS, "owner approval")
    approval_budgets = _required_object(approval, "budgets")
    _require_exact(approval_budgets, _BUDGET_KEYS, "owner approval budgets")
    if (
        approval.get("schema_version") != 1
        or approval.get("manifest_sha256") != manifest.get("manifest_sha256")
        or approval_budgets != budgets
        or not isinstance(approval.get("owner_identity"), str)
        or not approval.get("owner_identity")
        or not _COMMIT.fullmatch(str(approval.get("expected_freeze_commit")))
    ):
        raise ValueError("owner approval does not bind to manifest")

    projection: dict[str, object] = {
        "route": routes[kind],
        "freeze_commit": approval["expected_freeze_commit"],
        "executable_sha256": execution["executable_sha256"],
        "missing_usage_token_proxy": proxy,
        "approval": approval,
    }
    if kind == "task":
        configuration_data = _absolute(core.get("configuration_path")).read_bytes()
        if _sha256(configuration_data) != core.get("configuration_sha256"):
            raise ValueError("configuration digest does not bind to invocation")
        configuration = _canonical_bytes_object(configuration_data)
        _validate_configuration(configuration, projection, manifest)
        projection["configuration"] = configuration
    return projection


def _validate_core(core: dict[str, object], kind: str) -> None:
    expected = _TASK_CORE_KEYS if kind == "task" else _LEARNING_CORE_KEYS
    _require_exact(core, expected, f"{kind} core")
    if (
        core.get("schema_version") != 1
        or core.get("execution_profile") != "scheduled-learning-v1"
        or not isinstance(core.get("job_id"), str)
        or not core.get("job_id")
        or not isinstance(core.get("operation_id"), str)
        or not core.get("operation_id")
        or not _is_positive_integer(core.get("attempt_generation"))
        or not _canonical_uuid(core.get("provider_call_id"))
    ):
        raise ValueError("worker core has invalid identity")
    if kind == "reflector" and not _SHA256.fullmatch(str(core["operation_id"])):
        raise ValueError("reflector operation ID must be its frozen trigger digest")
    manifest = _required_object(core, "manifest")
    _require_exact(manifest, _MANIFEST_KEYS, "manifest binding")
    for key in ("repository_root", "evaluation_root", "manifest_path"):
        _absolute(manifest.get(key))
    _require_sha(manifest.get("manifest_sha256"), "manifest")
    approval = _required_object(manifest, "owner_approval")
    _require_exact(approval, {"path", "sha256"}, "owner approval binding")
    _absolute(approval.get("path"))
    _require_sha(approval.get("sha256"), "owner approval")
    if kind == "task":
        _absolute(core.get("configuration_path"))
        _require_sha(core.get("configuration_sha256"), "configuration")
        budget = _required_object(core, "budget")
        _require_exact(budget, _TASK_BUDGET_KEYS, "task budget")
        if any(not _is_integer(budget.get(key)) for key in _TASK_BUDGET_KEYS):
            raise ValueError("task budget fields must be integers")
        if (
            any(
                cast(int, budget[key]) < 0
                for key in (
                    "stage_accounted_tokens",
                    "global_accounted_tokens",
                    "stage_responses_sends",
                    "global_responses_sends",
                )
            )
            or cast(int, budget["stage_accounted_token_threshold"]) <= 0
            or budget["global_accounted_token_threshold"] != _GLOBAL_ACCOUNTED_TOKEN_THRESHOLD
            or cast(int, budget["stage_responses_send_cap"]) <= 0
            or budget["global_responses_send_cap"] != _GLOBAL_RESPONSES_SEND_CAP
        ):
            raise ValueError("task budget does not match the Swift admission contract")
        return
    if core.get("kind") != kind:
        raise ValueError("learning core kind does not match call")
    for key in ("state_root", "result_path"):
        _absolute(core.get(key))
    for key in ("prompt", "carrier"):
        binding = _required_object(core, key)
        _require_exact(binding, {"path", "sha256"}, f"{key} binding")
        _absolute(binding.get("path"))
        _require_sha(binding.get("sha256"), key)


def _validate_configuration(
    configuration: dict[str, object],
    projection: dict[str, object],
    manifest: dict[str, object],
) -> None:
    if not (
        _CONFIGURATION_KEYS - _OPTIONAL_CONFIGURATION_KEYS
        <= set(configuration)
        <= _CONFIGURATION_KEYS
    ):
        raise ValueError("task configuration has non-canonical fields")
    provenance = _required_object(configuration, "provenance")
    _require_exact(provenance, _PROVENANCE_KEYS, "task configuration provenance")
    approval = _required_object(configuration, "approval")
    _require_exact(approval, _TASK_APPROVAL_KEYS, "task configuration approval")
    route = _required_object(projection, "route")
    if (
        configuration.get("schema_version") != 1
        or configuration.get("execution_profile") != "scheduled-learning-v1"
        or configuration.get("carrier_sha256") != configuration.get("input_sha256")
        or configuration.get("provider_reference") != route.get("provider_reference")
        or configuration.get("wire_model") != route.get("wire_model")
        or configuration.get("transport_mode") != "streaming_sse"
        or approval.get("manifest_sha256") != manifest.get("manifest_sha256")
        or approval.get("approved_manifest_sha256") != manifest.get("manifest_sha256")
        or provenance.get("freeze_commit") != projection.get("freeze_commit")
        or provenance.get("executable_sha256") != projection.get("executable_sha256")
    ):
        raise ValueError("task configuration changed frozen admission bindings")
    _require_sha(approval.get("approval_body_sha256"), "task approval body")
    for key in _PROVENANCE_KEYS - {"freeze_commit"}:
        _require_sha(provenance.get(key), f"task provenance {key}")
    if not _COMMIT.fullmatch(str(provenance.get("freeze_commit"))):
        raise ValueError("task provenance freeze commit is not canonical")
    for key in ("carrier_sha256", "input_sha256", "lesson_set_digest"):
        _require_sha(configuration.get(key), f"configuration {key}")
    _absolute(configuration.get("carrier_path"))


def _validate_route(route: dict[str, object]) -> None:
    if (
        not isinstance(route.get("provider_reference"), str)
        or not route.get("provider_reference")
        or not isinstance(route.get("wire_model"), str)
        or not route.get("wire_model")
    ):
        raise ValueError("manifest route identity is invalid")
    for key in (
        "retry_budget",
        "max_output_tokens",
        "max_output_utf8_bytes",
        "max_output_graphemes",
    ):
        _positive_integer(route, key)


def _canonical_object(path: Path) -> dict[str, object]:
    return _canonical_bytes_object(path.read_bytes())


def _canonical_bytes_object(data: bytes) -> dict[str, object]:
    try:
        text = data.decode("utf-8")
        value = loads_object(text)
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError("bound artifact must be canonical JSON") from error
    if dumps(value).encode() != data:
        raise ValueError("bound artifact must be canonical JSON")
    return cast(dict[str, object], value)


def _absolute(value: object) -> Path:
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise ValueError("bound artifact path must be absolute")
    return Path(value)


def _required_object(value: dict[str, object], key: str) -> dict[str, object]:
    candidate = value.get(key)
    if not isinstance(candidate, dict):
        raise ValueError(f"{key} must be an object")
    return cast(dict[str, object], candidate)


def _require_exact(value: dict[str, object], keys: set[str], name: str) -> None:
    if set(value) != keys:
        raise ValueError(f"{name} has non-canonical fields")


def _require_sha(value: object, name: str) -> None:
    if not isinstance(value, str) or not _SHA256.fullmatch(value):
        raise ValueError(f"{name} digest is not canonical")


def _positive_integer(value: dict[str, object], key: str) -> int:
    candidate = value.get(key)
    if not _is_positive_integer(candidate):
        raise ValueError(f"{key} must be a positive integer")
    return cast(int, candidate)


def _is_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_positive_integer(value: object) -> bool:
    return _is_integer(value) and cast(int, value) > 0


def _canonical_uuid(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
