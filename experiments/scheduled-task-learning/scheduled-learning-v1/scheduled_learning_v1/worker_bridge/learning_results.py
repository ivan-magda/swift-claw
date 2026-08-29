"""Validation of evaluator and reflector result records."""

from __future__ import annotations

from typing import cast

from .accounting import validate_usage
from .requests import LearningCall, bound_contract, core_digest


def validate_learning_result(call: LearningCall, result: dict[str, object]) -> dict[str, object]:
    """Fail closed unless this exact learning operation produced a bounded result."""

    core = call.request_core
    contract = bound_contract(core, call.kind)
    _require_result_identity(result, core, call.kind)
    provenance = _object(result, "provenance")
    manifest = _object(core, "manifest")
    prompt = _object(core, "prompt")
    carrier = _object(core, "carrier")
    if (
        provenance.get("request_sha256") != core_digest(core)
        or provenance.get("manifest_sha256") != manifest.get("manifest_sha256")
        or provenance.get("prompt_sha256") != prompt.get("sha256")
        or provenance.get("carrier_sha256") != carrier.get("sha256")
    ):
        raise ValueError("learning result provenance does not bind to closed request")
    route = _object(contract, "route")
    for result_key, route_key in (
        ("provider_reference", "provider_reference"),
        ("wire_model", "wire_model"),
        ("retry_budget", "retry_budget"),
        ("max_output_tokens", "max_output_tokens"),
        ("max_output_utf8_bytes", "max_output_utf8_bytes"),
        ("max_output_graphemes", "max_output_graphemes"),
    ):
        if result.get(result_key) != route.get(route_key):
            raise ValueError("learning result changed frozen route")
    retry_budget = _integer(route, "retry_budget")
    maximum = 512 if call.kind == "evaluator" else 768
    if _integer(route, "max_output_tokens") != maximum:
        raise ValueError("learning result changed frozen completion cap")
    if (
        _integer(route, "max_output_utf8_bytes") <= 0
        or _integer(route, "max_output_graphemes") <= 0
    ):
        raise ValueError("learning result changed local output limits")
    outcome = result.get("outcome")
    usage = _optional_object(result, "usage")
    if outcome == "failed_no_call":
        if usage is not None or result.get("output") is not None:
            raise ValueError("failed_no_call must have no usage or output")
        return {**result, "status": "failed_no_call", "accounted_tokens": 0}
    if outcome not in {"response", "failed"}:
        return {"status": "schema_invalid", "kind": call.kind, "operation_id": core["operation_id"]}
    if outcome == "response" and not isinstance(result.get("output"), str):
        return {"status": "schema_invalid", "kind": call.kind, "operation_id": core["operation_id"]}
    accounted = validate_usage(
        usage,
        str(core["provider_call_id"]),
        retry_budget,
        _integer(contract, "missing_usage_token_proxy"),
        maximum,
    )
    return {**result, "status": str(outcome), "accounted_tokens": accounted}


def _require_result_identity(result: dict[str, object], core: dict[str, object], kind: str) -> None:
    for key in ("job_id", "operation_id", "attempt_generation", "provider_call_id"):
        if result.get(key) != core.get(key):
            raise ValueError(f"learning result {key} does not bind to request")
    if result.get("kind") != kind:
        raise ValueError("learning result kind does not bind to request")


def _object(value: dict[str, object], key: str) -> dict[str, object]:
    candidate = value.get(key)
    if not isinstance(candidate, dict):
        raise ValueError(f"{key} must be an object")
    return cast(dict[str, object], candidate)


def _optional_object(value: dict[str, object], key: str) -> dict[str, object] | None:
    candidate = value.get(key)
    if candidate is None:
        return None
    if not isinstance(candidate, dict):
        raise ValueError(f"{key} must be an object or null")
    return cast(dict[str, object], candidate)


def _integer(value: dict[str, object], key: str) -> int:
    candidate = value.get(key)
    if isinstance(candidate, bool) or not isinstance(candidate, int):
        raise ValueError(f"{key} must be an integer")
    return candidate
