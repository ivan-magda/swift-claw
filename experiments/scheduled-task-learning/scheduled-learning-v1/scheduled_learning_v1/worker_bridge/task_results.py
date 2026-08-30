"""Validation of the canonical scheduled-learning task-worker result."""

from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import cast

from benchmark_core.canonical import canonical_sha256, dumps, loads_object

from ..frozen_contract import GATES
from .accounting import validate_task_usage
from .requests import TaskAttemptCall, bound_contract

_RESULT_KEYS = {
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
    "process_uuid",
    "process_id",
    "lock_acquisition_id",
    "run_id",
    "session_id",
    "conversation_id",
    "started_at",
    "finished_at",
    "duration_milliseconds",
    "protocol_sha256",
    "manifest_sha256",
    "approval",
    "provenance",
    "input_sha256",
    "task_prompt_sha256",
    "lesson_set_digest",
    "lesson_set_id",
    "lesson_ids",
    "carrier_receipt",
    "carrier_receipt_sha256",
    "policy_version",
    "provider_reference",
    "wire_model",
    "transport_mode",
    "fallback_reference",
    "outcome",
    "critical_code",
    "raw_output",
    "model_observations",
    "http",
    "output_counts",
    "tools",
    "audit",
    "usage",
    "accounted_tokens",
    "replacement_disposition",
    "replacement_reason",
    "replacement_of_attempt_id",
    "replacement_ordinal",
    "workspace",
    "learning_carrier_sha256",
    "learning_lesson_set_sha256",
    "learning_initial_tainted",
    "learning_carrier_verified",
}
_OPTIONAL_RESULT_KEYS = {
    "lock_acquisition_id",
    "fallback_reference",
    "critical_code",
    "raw_output",
    "output_counts",
    "replacement_of_attempt_id",
}
_HTTP_KEYS = {
    "responsesSends",
    "provenNotStartedResponsesSends",
    "credentialHTTPCalls",
    "integrityFailures",
}
_SEND_KEYS = {
    "sequence",
    "requested_model",
    "body_byte_count",
    "body_sha256",
    "normalized_structure_sha256",
    "untrusted_fence_present",
    "untrusted_payload_sha256",
}
_USAGE_KEYS = {
    "provider_call_id",
    "run_id",
    "session_id",
    "model",
    "prompt_tokens",
    "completion_tokens",
    "total_tokens",
    "is_estimated",
    "cost_usd",
    "cost_source",
    "timestamp",
}
_RECEIPT_KEYS = {
    "source_sha256",
    "task_id",
    "lesson_source",
    "lesson_set_sha256",
    "lesson_set_id",
    "lesson_ids",
    "input_sha256",
    "promotion_receipt_sha256",
}
_WORKSPACE_KEYS = {
    "workspace_was_empty_at_start",
    "input_was_regenerated",
    "input_path",
    "input_sha256",
    "input_byte_count",
    "source_artifact_path",
    "source_sha256",
    "task_id",
    "lesson_source",
    "lesson_set_path",
    "lesson_set_digest",
    "lesson_set_id",
    "lesson_ids",
    "carrier_receipt",
    "carrier_receipt_sha256",
}
_CARRIER_KEYS = {"active_lessons", "schema_version", "task", "task_id"}
_OUTPUT_COUNT_KEYS = {"utf8Bytes", "graphemes", "limitExceeded"}
_FAILURE_OUTCOMES = {
    "provider_failure",
    "authentication_required",
    "access_denied",
    "quota_limited",
    "invalid_provider_state",
    "local_output_limit",
    "model_identity_mismatch",
    "budget_stopped",
    "tool_contract_failure",
    "policy_mismatch",
    "harness_failure",
}
_ELIGIBLE_REPLACEMENT_REASONS = {
    "transport_failure",
    "credential_refresh_exhausted",
    "deadline",
    "process_interruption",
    "partial_stream_without_completed_terminal",
}
_CONTROLLER_ADMISSION_CAPS = {
    "evaluation-stage-accounted-token-threshold",
    "evaluation-global-accounted-token-threshold",
    "evaluation-stage-responses-send-cap",
    "evaluation-global-responses-send-cap",
}
_TOOL_VIOLATION_CODES = {
    "expected_one_file_read",
    "unexpected_tool",
    "unexpected_file_read_path",
    "file_read_failed",
    "unexpected_suspension",
}
_MAX_ACTIVE_LESSONS = 3
_MAX_LESSON_UTF8_BYTES = 512


def validate_task_result(call: TaskAttemptCall, result: dict[str, object]) -> dict[str, object]:
    """Fail closed unless the exact Swift task result binds its carrier and frozen call."""

    contract = bound_contract(call.invocation_core, "task")
    configuration = _object(contract, "configuration")
    route = _object(contract, "route")
    _require_result_schema(result)
    _require_configuration_identity(call, result, configuration)
    carrier, carrier_bytes = _load_carrier(configuration)
    _require_carrier_bindings(result, configuration, carrier, carrier_bytes)
    _require_process_identity(result, configuration)
    _require_route_and_output(result, route)
    accounted = _require_accounting(call, result, route, contract)
    if result.get("accounted_tokens") != accounted:
        raise ValueError("task result accounted-token total does not match shared formula")
    outcome = result.get("outcome")
    if outcome == "completed":
        if (
            result.get("critical_code") is not None
            or not isinstance(result.get("raw_output"), str)
            or result.get("replacement_disposition") != "ineligible"
            or result.get("replacement_reason") != "scorable_output_exists"
        ):
            raise ValueError("completed task result has an invalid terminal shape")
        status = "completed"
    elif outcome in _FAILURE_OUTCOMES:
        _require_failure_shape(result, cast(str, outcome))
        status = "failed"
    else:
        raise ValueError("task result has an unknown outcome")
    return {**result, "status": status}


def _require_result_schema(result: dict[str, object]) -> None:
    if not (_RESULT_KEYS - _OPTIONAL_RESULT_KEYS <= set(result) <= _RESULT_KEYS):
        raise ValueError("task result has non-canonical fields")
    if result.get("schema_version") != 1:
        raise ValueError("task result has an unknown schema")
    for key in ("model_observations", "tools", "audit", "usage", "lesson_ids"):
        if not isinstance(result.get(key), list):
            raise ValueError(f"task result {key} must be an array")
    _require_exact_object(result, "carrier_receipt", _RECEIPT_KEYS)
    workspace = _object(result, "workspace")
    if not (_WORKSPACE_KEYS - {"lesson_set_path"} <= set(workspace) <= _WORKSPACE_KEYS):
        raise ValueError("task result workspace has non-canonical fields")
    _require_exact_object(workspace, "carrier_receipt", _RECEIPT_KEYS)
    output_counts = result.get("output_counts")
    if output_counts is not None and (
        not isinstance(output_counts, dict) or set(output_counts) != _OUTPUT_COUNT_KEYS
    ):
        raise ValueError("scheduled task result output counts have non-canonical fields")
    http = _require_exact_object(result, "http", _HTTP_KEYS)
    sends = http.get("responsesSends")
    if not isinstance(sends, list):
        raise ValueError("task result responses sends must be an array")
    for send in sends:
        if not isinstance(send, dict):
            raise ValueError("task response send must be an object")
        keys = set(cast(dict[str, object], send))
        if not (_SEND_KEYS - {"requested_model", "untrusted_payload_sha256"} <= keys <= _SEND_KEYS):
            raise ValueError("task response send has non-canonical fields")
    for row in cast(list[object], result["usage"]):
        if not isinstance(row, dict) or set(row) != _USAGE_KEYS:
            raise ValueError("task usage row has non-canonical fields")


def _require_configuration_identity(
    call: TaskAttemptCall,
    result: dict[str, object],
    configuration: dict[str, object],
) -> None:
    if call.result_path != Path(str(configuration.get("result_path"))):
        raise ValueError("task call result path does not bind to configuration")
    for result_key, configuration_key in (
        ("attempt_id", "attempt_id"),
        ("fixture_id", "fixture_id"),
        ("task_id", "task_id"),
        ("split", "split"),
        ("stage", "stage"),
        ("frozen_order_index", "frozen_order_index"),
        ("frozen_order_key", "frozen_order_key"),
        ("replicate", "replicate"),
        ("condition", "condition"),
        ("protocol_sha256", "protocol_sha256"),
        ("input_sha256", "input_sha256"),
        ("task_prompt_sha256", "task_prompt_sha256"),
        ("lesson_set_digest", "lesson_set_digest"),
        ("policy_version", "expected_policy_version"),
        ("provider_reference", "provider_reference"),
        ("wire_model", "wire_model"),
        ("transport_mode", "transport_mode"),
        ("fallback_reference", "fallback_reference"),
        ("replacement_of_attempt_id", "replacement_of_attempt_id"),
        ("replacement_ordinal", "replacement_ordinal"),
    ):
        if result.get(result_key) != configuration.get(configuration_key):
            raise ValueError(f"task result {result_key} does not bind to configuration")
    if result.get("approval") != configuration.get("approval") or result.get(
        "provenance"
    ) != configuration.get("provenance"):
        raise ValueError("task result approval/provenance changed configuration")
    manifest = _object(call.invocation_core, "manifest")
    if result.get("manifest_sha256") != manifest.get("manifest_sha256"):
        raise ValueError("task result manifest does not bind to invocation")


def _load_carrier(
    configuration: dict[str, object],
) -> tuple[dict[str, object], bytes]:
    path = Path(str(configuration.get("carrier_path")))
    data = path.read_bytes()
    try:
        carrier = loads_object(data.decode())
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError("task carrier is not canonical JSON") from error
    if dumps(carrier).encode() != data or set(carrier) != _CARRIER_KEYS:
        raise ValueError("task carrier is not canonical JSON")
    active = _require_exact_object(carrier, "active_lessons", {"schema_version", "lessons"})
    task = _require_exact_object(carrier, "task", {"before_html", "after_html", "region_ids"})
    lessons = active.get("lessons")
    region_ids = task.get("region_ids")
    if (
        carrier.get("schema_version") != 1
        or not isinstance(carrier.get("task_id"), str)
        or not carrier.get("task_id")
        or active.get("schema_version") != 1
        or not isinstance(lessons, list)
        or any(not isinstance(lesson, str) for lesson in lessons)
        or len(lessons) > _MAX_ACTIVE_LESSONS
        or len(set(cast(list[str], lessons))) != len(lessons)
        or any(not lesson or len(lesson.encode()) > _MAX_LESSON_UTF8_BYTES for lesson in lessons)
        or not isinstance(task.get("before_html"), str)
        or not isinstance(task.get("after_html"), str)
        or not isinstance(region_ids, list)
        or any(not isinstance(region_id, str) for region_id in region_ids)
    ):
        raise ValueError("task carrier has invalid canonical values")
    return cast(dict[str, object], carrier), data


def _require_carrier_bindings(
    result: dict[str, object],
    configuration: dict[str, object],
    carrier: dict[str, object],
    carrier_bytes: bytes,
) -> None:
    carrier_sha256 = canonical_sha256(carrier)
    active = _object(carrier, "active_lessons")
    lesson_digest = canonical_sha256(active)
    lessons = cast(list[object], active["lessons"])
    if (
        carrier_sha256 != configuration.get("carrier_sha256")
        or carrier_sha256 != configuration.get("input_sha256")
        or lesson_digest != configuration.get("lesson_set_digest")
        or carrier.get("task_id") != configuration.get("task_id")
        or result.get("learning_carrier_sha256") != carrier_sha256
        or result.get("learning_lesson_set_sha256") != lesson_digest
        or result.get("learning_initial_tainted") is not bool(lessons)
        or result.get("learning_carrier_verified") is not True
    ):
        raise ValueError("task result does not bind the scheduled-learning carrier")
    receipt = _object(result, "carrier_receipt")
    workspace = _object(result, "workspace")
    if (
        workspace.get("carrier_receipt") != receipt
        or canonical_sha256(receipt) != result.get("carrier_receipt_sha256")
        or workspace.get("carrier_receipt_sha256") != result.get("carrier_receipt_sha256")
        or workspace.get("input_sha256") != carrier_sha256
        or workspace.get("input_byte_count") != len(carrier_bytes)
        or workspace.get("source_artifact_path") != configuration.get("source_artifact_path")
        or workspace.get("source_sha256") != configuration.get("source_sha256")
        or workspace.get("task_id") != configuration.get("task_id")
        or workspace.get("lesson_source") != configuration.get("lesson_source")
        or workspace.get("lesson_set_path") != configuration.get("lesson_artifact_path")
        or workspace.get("lesson_set_digest") != lesson_digest
        or result.get("lesson_set_id") != ""
        or result.get("lesson_ids") != []
        or workspace.get("lesson_set_id") != ""
        or workspace.get("lesson_ids") != []
        or receipt.get("lesson_set_id") != ""
        or receipt.get("lesson_ids") != []
        or result.get("lesson_set_id") != workspace.get("lesson_set_id")
        or result.get("lesson_ids") != workspace.get("lesson_ids")
        or result.get("lesson_set_id") != receipt.get("lesson_set_id")
        or result.get("lesson_ids") != receipt.get("lesson_ids")
    ):
        raise ValueError("task workspace does not bind carrier materialization")
    for key in ("source_sha256", "task_id", "lesson_source"):
        if receipt.get(key) != configuration.get(key):
            raise ValueError("task carrier receipt changed configuration")
    if (
        receipt.get("lesson_set_sha256") != lesson_digest
        or receipt.get("input_sha256") != carrier_sha256
        or receipt.get("promotion_receipt_sha256") != configuration.get("promotion_receipt_sha256")
    ):
        raise ValueError("task carrier receipt changed frozen digests")


def _require_process_identity(result: dict[str, object], configuration: dict[str, object]) -> None:
    process_uuid = result.get("process_uuid")
    lock_acquisition_id = result.get("lock_acquisition_id")
    try:
        canonical_uuid = str(uuid.UUID(str(process_uuid)))
        canonical_lock = str(uuid.UUID(str(lock_acquisition_id)))
    except ValueError as error:
        raise ValueError("task result process or lock UUID is invalid") from error
    process_id = result.get("process_id")
    if (
        canonical_uuid != str(process_uuid).lower()
        or canonical_lock != str(lock_acquisition_id).lower()
        or not _positive_integer(process_id)
        or result.get("conversation_id") != f"{canonical_uuid}:{configuration['attempt_id']}"
        or not _positive_integer(result.get("run_id"))
        or not _positive_integer(result.get("session_id"))
    ):
        raise ValueError("task result process identity is invalid")


def _require_route_and_output(result: dict[str, object], route: dict[str, object]) -> None:
    if result.get("provider_reference") != route.get("provider_reference") or result.get(
        "wire_model"
    ) != route.get("wire_model"):
        raise ValueError("task result changed manifest route")
    raw_output = result.get("raw_output")
    if raw_output is not None and not isinstance(raw_output, str):
        raise ValueError("task output must be text or absent")
    maximum_bytes = _integer(route, "max_output_utf8_bytes")
    maximum_graphemes = _integer(route, "max_output_graphemes")
    output_counts_value = result.get("output_counts")
    if output_counts_value is None:
        if result.get("outcome") == "completed":
            raise ValueError("completed task result requires output counts")
        return
    output_counts = cast(dict[str, object], output_counts_value)
    counted_bytes = _integer(output_counts, "utf8Bytes")
    counted_graphemes = _integer(output_counts, "graphemes")
    limit_exceeded = output_counts.get("limitExceeded")
    if (
        counted_bytes < 0
        or counted_graphemes < 0
        or not isinstance(limit_exceeded, bool)
        or (
            limit_exceeded is False
            and (counted_bytes > maximum_bytes or counted_graphemes > maximum_graphemes)
        )
        or (
            isinstance(raw_output, str)
            and (
                len(raw_output.encode()) > maximum_bytes
                or len(raw_output) > maximum_graphemes
                or len(raw_output.encode()) > counted_bytes
            )
        )
        or (result.get("outcome") == "completed" and limit_exceeded)
    ):
        raise ValueError("task output exceeds frozen local limits")


def _require_accounting(
    call: TaskAttemptCall,
    result: dict[str, object],
    route: dict[str, object],
    contract: dict[str, object],
) -> int:
    http = _object(result, "http")
    sends = cast(list[dict[str, object]], http["responsesSends"])
    proven_not_started = _integer(http, "provenNotStartedResponsesSends")
    sends_by_operation = _object(GATES, "responses_sends_per_operation")
    maximum_sends = _integer(sends_by_operation, "task")
    if not 1 <= len(sends) <= maximum_sends or not 0 <= proven_not_started <= len(sends):
        raise ValueError("task Responses sends exceed frozen operation limit")
    for index, send in enumerate(sends, start=1):
        if send.get("sequence") != index or send.get("requested_model") != route.get("wire_model"):
            raise ValueError("task response send does not bind frozen route")
    usage = cast(list[dict[str, object]], result["usage"])
    if usage and usage[0].get("provider_call_id") != call.invocation_core.get("provider_call_id"):
        raise ValueError("task first usage row does not bind pre-minted provider call")
    for row in usage:
        if (
            row.get("run_id") != result.get("run_id")
            or row.get("session_id") != result.get("session_id")
            or row.get("model") != route.get("wire_model")
        ):
            raise ValueError("task usage row does not bind result and frozen route identity")
    return validate_task_usage(
        len(sends),
        proven_not_started,
        usage,
        _integer(contract, "missing_usage_token_proxy"),
        _integer(route, "max_output_tokens"),
    )


def _require_failure_shape(result: dict[str, object], outcome: str) -> None:
    critical_code = result.get("critical_code")
    raw_output = result.get("raw_output")
    disposition = result.get("replacement_disposition")
    reason = result.get("replacement_reason")
    if (
        not isinstance(disposition, str)
        or disposition not in {"eligible", "ineligible"}
        or not isinstance(reason, str)
        or not reason
    ):
        raise ValueError("failed task result has an invalid replacement shape")
    if raw_output is not None and outcome != "tool_contract_failure":
        raise ValueError("failed task result has an invalid raw output")
    if disposition == "eligible":
        if (
            outcome != "provider_failure"
            or critical_code is not None
            or reason not in _ELIGIBLE_REPLACEMENT_REASONS
        ):
            raise ValueError("failed task result has an invalid replacement eligibility")
    elif not _valid_ineligible_failure(outcome, critical_code, reason):
        raise ValueError("failed task result has an invalid outcome-specific shape")


def _valid_ineligible_failure(outcome: str, critical_code: object, reason: str) -> bool:
    if outcome == "provider_failure":
        ordinary_reasons = {
            "provider_terminal",
            "credential_refresh_completed",
            "credential_state_unavailable",
        }
        return (critical_code is None and reason in ordinary_reasons) or (
            critical_code == "vision_unsupported" and reason == "vision_unsupported"
        )
    if outcome == "authentication_required":
        return critical_code is None and reason == "authentication"
    if outcome == "access_denied":
        return critical_code is None and reason == "access"
    if outcome == "quota_limited":
        return critical_code is None and reason == "quota"
    if outcome == "invalid_provider_state":
        return critical_code == "invalid_provider_state" and reason == "invalid_provider_state"
    if outcome == "local_output_limit":
        return critical_code == "local_output_limit" and reason == "local_output_limit"
    if outcome == "model_identity_mismatch":
        valid_code = isinstance(critical_code, str) and critical_code in {
            "model_identity_mismatch",
            "wire_model_mismatch",
        }
        return valid_code and reason == "model_identity_mismatch"
    if outcome == "budget_stopped":
        return (critical_code == "tool_budget_stop" and reason == "budget_or_tool_deviation") or (
            critical_code is None and reason in _CONTROLLER_ADMISSION_CAPS
        )
    if outcome == "tool_contract_failure":
        valid_code = isinstance(critical_code, str) and critical_code in _TOOL_VIOLATION_CODES
        return valid_code and reason == "task_contract_failure"
    if outcome == "policy_mismatch":
        return False
    if outcome == "harness_failure":
        has_critical_code = isinstance(critical_code, str) and bool(critical_code)
        allowed_reasons = {"harness_integrity_failure", "preflight_budget_exhausted"}
        return has_critical_code and reason in allowed_reasons
    return False


def _require_exact_object(value: dict[str, object], key: str, keys: set[str]) -> dict[str, object]:
    candidate = _object(value, key)
    if set(candidate) != keys:
        raise ValueError(f"task result {key} has non-canonical fields")
    return candidate


def _object(value: dict[str, object], key: str) -> dict[str, object]:
    candidate = value.get(key)
    if not isinstance(candidate, dict):
        raise ValueError(f"{key} must be an object")
    return cast(dict[str, object], candidate)


def _integer(value: dict[str, object], key: str) -> int:
    candidate = value.get(key)
    if isinstance(candidate, bool) or not isinstance(candidate, int):
        raise ValueError(f"{key} must be an integer")
    return candidate


def _positive_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0
