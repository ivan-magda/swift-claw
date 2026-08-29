"""Validation of canonical evaluator and reflector result records."""

from __future__ import annotations

import hashlib
import unicodedata
from typing import cast

from .accounting import validate_usage
from .requests import LearningCall, bound_contract, final_request_digest

_RESULT_KEYS = {
    "schema_version",
    "job_id",
    "operation_id",
    "attempt_generation",
    "provider_call_id",
    "kind",
    "outcome",
    "failure_code",
    "output",
    "output_sha256",
    "finish_reason",
    "provider_reference",
    "wire_model",
    "reported_model",
    "retry_budget",
    "max_output_tokens",
    "max_output_utf8_bytes",
    "max_output_graphemes",
    "usage",
    "provenance",
}
_PROVENANCE_KEYS = {
    "request_sha256",
    "manifest_sha256",
    "freeze_commit",
    "executable_sha256",
    "prompt_sha256",
    "carrier_sha256",
}
_FAILURE_CODES = {
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
_REGIONAL_INDICATORS = range(0x1F1E6, 0x1F200)
_VARIATION_SELECTORS = range(0xFE00, 0xFE10)
_SUPPLEMENTARY_VARIATION_SELECTORS = range(0xE0100, 0xE01F0)
_EMOJI_MODIFIERS = range(0x1F3FB, 0x1F400)
_MAX_BOUND_TEXT_BYTES = 256
_FIRST_CONTROL_SCALAR = 0x20
_DELETE_SCALAR = 0x7F


def validate_learning_result(call: LearningCall, result: dict[str, object]) -> dict[str, object]:
    """Fail closed unless this exact authorized learning call produced the result."""

    core = call.request_core
    contract = bound_contract(core, call.kind)
    if set(result) != _RESULT_KEYS or result.get("schema_version") != 1:
        raise ValueError("learning result has non-canonical fields")
    _require_result_identity(result, core, call.kind)
    provenance = _object(result, "provenance")
    if set(provenance) != _PROVENANCE_KEYS:
        raise ValueError("learning result provenance has non-canonical fields")
    manifest = _object(core, "manifest")
    prompt = _object(core, "prompt")
    carrier = _object(core, "carrier")
    if (
        provenance.get("request_sha256") != final_request_digest(call)
        or provenance.get("manifest_sha256") != manifest.get("manifest_sha256")
        or provenance.get("freeze_commit") != contract.get("freeze_commit")
        or provenance.get("executable_sha256") != contract.get("executable_sha256")
        or provenance.get("prompt_sha256") != prompt.get("sha256")
        or provenance.get("carrier_sha256") != carrier.get("sha256")
    ):
        raise ValueError("learning result provenance does not bind to final authorized request")
    route = _object(contract, "route")
    for key in (
        "provider_reference",
        "wire_model",
        "retry_budget",
        "max_output_tokens",
        "max_output_utf8_bytes",
        "max_output_graphemes",
    ):
        if result.get(key) != route.get(key):
            raise ValueError("learning result changed frozen route")
    retry_budget = _integer(route, "retry_budget")
    maximum = 512 if call.kind == "evaluator" else 768
    if _integer(route, "max_output_tokens") != maximum:
        raise ValueError("learning result changed frozen completion cap")
    _require_optional_bounded_text(result.get("finish_reason"), "finish_reason")
    _require_optional_bounded_text(result.get("reported_model"), "reported_model")
    _require_output(result, route)
    return _classify_outcome(result, core, contract, retry_budget, maximum)


def _classify_outcome(
    result: dict[str, object],
    core: dict[str, object],
    contract: dict[str, object],
    retry_budget: int,
    maximum: int,
) -> dict[str, object]:
    outcome = result.get("outcome")
    usage = _optional_object(result, "usage")
    if outcome == "failed_no_call":
        if (
            result.get("failure_code") not in _FAILURE_CODES
            or usage is not None
            or result.get("output") is not None
            or result.get("output_sha256") is not None
            or result.get("finish_reason") is not None
            or result.get("reported_model") is not None
        ):
            raise ValueError("failed_no_call result has an invalid terminal shape")
        return {**result, "status": "failed_no_call", "accounted_tokens": 0}
    if outcome == "response":
        if (
            result.get("failure_code") is not None
            or not isinstance(result.get("output"), str)
            or usage is None
            or not _positive_integer(usage.get("responses_sends"))
        ):
            raise ValueError("response result has an invalid terminal shape")
    elif outcome == "failed":
        if (
            result.get("failure_code") not in _FAILURE_CODES
            or result.get("output") is not None
            or result.get("output_sha256") is not None
            or result.get("finish_reason") is not None
            or result.get("reported_model") is not None
        ):
            raise ValueError("failed result has an invalid terminal shape")
    else:
        raise ValueError("learning result has an unknown outcome")
    accounted = validate_usage(
        usage,
        str(core["provider_call_id"]),
        retry_budget,
        _integer(contract, "missing_usage_token_proxy"),
        maximum,
    )
    return {**result, "status": str(outcome), "accounted_tokens": accounted}


def _require_output(result: dict[str, object], route: dict[str, object]) -> None:
    output = result.get("output")
    output_sha256 = result.get("output_sha256")
    if output is None:
        if output_sha256 is not None:
            raise ValueError("nil learning output must have a nil digest")
        return
    if not isinstance(output, str):
        raise ValueError("learning output must be text or null")
    if (
        len(output.encode()) > _integer(route, "max_output_utf8_bytes")
        or _grapheme_count(output) > _integer(route, "max_output_graphemes")
        or output_sha256 != hashlib.sha256(output.encode()).hexdigest()
    ):
        raise ValueError("learning output violates frozen hash or local limits")


def _grapheme_count(value: str) -> int:
    """Count the extended clusters used by Swift for the bounded worker outputs."""

    count = 0
    regional_run = 0
    previous_joiner = False
    for index, character in enumerate(value):
        codepoint = ord(character)
        regional = codepoint in _REGIONAL_INDICATORS
        extends = (
            unicodedata.combining(character) != 0
            or unicodedata.category(character) in {"Mc", "Me"}
            or codepoint in _VARIATION_SELECTORS
            or codepoint in _SUPPLEMENTARY_VARIATION_SELECTORS
            or codepoint in _EMOJI_MODIFIERS
            or previous_joiner
            or character == "\u200d"
            or (character == "\n" and index > 0 and value[index - 1] == "\r")
        )
        if regional:
            if regional_run % 2 == 0:
                count += 1
            regional_run += 1
        else:
            regional_run = 0
            if not extends or count == 0:
                count += 1
        previous_joiner = character == "\u200d"
    return count


def _require_optional_bounded_text(value: object, name: str) -> None:
    if value is None:
        return
    if (
        not isinstance(value, str)
        or not value
        or len(value.encode()) > _MAX_BOUND_TEXT_BYTES
        or any(
            ord(character) < _FIRST_CONTROL_SCALAR or ord(character) == _DELETE_SCALAR
            for character in value
        )
    ):
        raise ValueError(f"learning result {name} is not bounded text")


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


def _positive_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0
