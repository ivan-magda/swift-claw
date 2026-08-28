"""Shared task-attempt carrier validation."""

from __future__ import annotations

from typing import Any

from .canonical import SHA256_HEX
from .contract_validation import (
    ValidationIssue,
    bounded_list,
    bounded_string,
    closed_enum,
    exact_keys,
    is_integer,
    issue,
)

RESPONSES_REQUEST_KEYS = {
    "sequence",
    "requested_model",
    "body_byte_count",
    "body_sha256",
    "normalized_structure_sha256",
    "untrusted_fence_present",
    "untrusted_payload_sha256",
}
SUCCESSFUL_FILE_READ_EVENT = {
    "name": "file_read",
    "path": "input.json",
    "status": "succeeded",
}


def validate_attempt(
    value: Any,
    *,
    require_request_provenance: bool = False,
) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    required = {"runtime_outcome", "raw_output", "tool_events"}
    allowed = required | {"responses_requests"}
    if require_request_provenance:
        required.add("responses_requests")
    if not exact_keys(value, required, allowed, "$", issues):
        return issues
    closed_enum(
        value.get("runtime_outcome"),
        ("completed", "local_output_limit", "tool_budget_stop"),
        "$.runtime_outcome",
        issues,
    )
    raw_output = value.get("raw_output")
    if raw_output is not None and not isinstance(raw_output, str):
        issue(issues, "schema.bounded_values", "$.raw_output must be text or null")
    tool_events = value.get("tool_events")
    if bounded_list(tool_events, 0, 4, "$.tool_events", issues):
        for index, event in enumerate(tool_events):
            path = f"$.tool_events[{index}]"
            event_keys = {"name", "path", "status"}
            if not exact_keys(event, event_keys, event_keys, path, issues):
                continue
            event_path = event.get("path")
            bounded_string(event.get("name"), 1, 64, f"{path}.name", issues)
            if event_path is not None:
                bounded_string(event_path, 1, 256, f"{path}.path", issues)
            closed_enum(
                event.get("status"),
                ("proposed", "succeeded", "failed"),
                f"{path}.status",
                issues,
            )

    requests = value.get("responses_requests")
    if requests is not None and bounded_list(
        requests,
        0,
        2,
        "$.responses_requests",
        issues,
    ):
        for index, request in enumerate(requests):
            path = f"$.responses_requests[{index}]"
            if not exact_keys(
                request,
                RESPONSES_REQUEST_KEYS,
                RESPONSES_REQUEST_KEYS,
                path,
                issues,
            ):
                continue
            sequence = request.get("sequence")
            byte_count = request.get("body_byte_count")
            if not is_integer(sequence) or sequence not in (1, 2):
                issue(issues, "schema.bounded_values", f"{path}.sequence must equal 1 or 2")
            if not is_integer(byte_count) or byte_count < 1:
                issue(issues, "schema.bounded_values", f"{path}.body_byte_count must be positive")
            requested_model = request.get("requested_model")
            if requested_model is not None:
                bounded_string(requested_model, 1, 128, f"{path}.requested_model", issues)
            for field in ("body_sha256", "normalized_structure_sha256"):
                bounded_string(request.get(field), 64, 64, f"{path}.{field}", issues, SHA256_HEX)
            if not isinstance(request.get("untrusted_fence_present"), bool):
                issue(
                    issues,
                    "schema.bounded_values",
                    f"{path}.untrusted_fence_present must be boolean",
                )
            payload_sha256 = request.get("untrusted_payload_sha256")
            if payload_sha256 is not None:
                bounded_string(
                    payload_sha256,
                    64,
                    64,
                    f"{path}.untrusted_payload_sha256",
                    issues,
                    SHA256_HEX,
                )
    return issues
