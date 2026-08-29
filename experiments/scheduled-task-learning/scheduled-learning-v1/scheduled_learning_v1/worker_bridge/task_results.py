"""Validation of the canonical scheduled-learning task-worker result."""

from __future__ import annotations

from typing import cast

from .requests import TaskAttemptCall, bound_contract

_MAX_RESPONSES_SENDS = 3


def validate_task_result(call: TaskAttemptCall, result: dict[str, object]) -> dict[str, object]:
    """Fail closed unless the task carrier and actual worker records bind."""

    contract = bound_contract(call.invocation_core, "task")
    configuration = _object(contract.get("configuration"))
    if (
        result.get("learning_carrier_sha256") != configuration.get("carrier_sha256")
        or result.get("learning_lesson_set_sha256") != configuration.get("lesson_set_digest")
        or result.get("learning_initial_tainted") is not configuration.get("initial_tainted")
        or result.get("learning_carrier_verified") is not True
        or not isinstance(result.get("carrier_receipt_sha256"), str)
    ):
        raise ValueError("task result does not bind the scheduled-learning carrier")
    route = _object(contract.get("route"))
    if result.get("provider_reference") != route.get("provider_reference") or result.get(
        "wire_model"
    ) != route.get("wire_model"):
        raise ValueError("task result changed manifest route")
    http = _object(result.get("http"))
    sends = http.get("responses_sends")
    if not isinstance(sends, list) or not 1 <= len(sends) <= _MAX_RESPONSES_SENDS:
        raise ValueError("task result has invalid Responses send count")
    if not isinstance(result.get("raw_output"), str) or not isinstance(result.get("usage"), list):
        raise ValueError("task result lacks output or usage")
    return {**result, "status": "completed"}


def _object(value: object) -> dict[str, object]:
    return cast(dict[str, object], value) if isinstance(value, dict) else {}
