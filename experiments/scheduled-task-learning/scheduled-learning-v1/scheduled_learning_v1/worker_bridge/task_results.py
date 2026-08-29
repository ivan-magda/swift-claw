"""Validation of task-worker result records."""

from __future__ import annotations

from .requests import TaskAttemptCall


def validate_task_result(call: TaskAttemptCall, result: dict[str, object]) -> dict[str, object]:
    """Fail closed unless a task result carries every materialized task binding."""

    core = call.invocation_core
    required = {
        "job_id": "job_id",
        "operation_id": "operation_id",
        "attempt_generation": "attempt_generation",
        "provider_call_id": "provider_call_id",
        "learning_carrier_sha256": "carrier_digest",
        "learning_lesson_set_sha256": "lesson_set_digest",
        "initial_taint_receipt": "initial_taint_receipt",
    }
    for result_key, core_key in required.items():
        if result.get(result_key) != core.get(core_key):
            raise ValueError(f"task result {result_key} does not bind to invocation")
    route = core.get("route")
    if not isinstance(route, dict):
        raise ValueError("task invocation lacks frozen route")
    if result.get("provider_reference") != route.get("provider_reference") or result.get(
        "wire_model"
    ) != route.get("wire_model"):
        raise ValueError("task result route does not bind to invocation")
    if not isinstance(result.get("process_uuid"), str) or not isinstance(
        result.get("process_id"), int
    ):
        raise ValueError("task result lacks process identity")
    if not isinstance(result.get("raw_output"), str) or not isinstance(result.get("usage"), list):
        raise ValueError("task result lacks durable output or usage")
    return {**result, "status": "completed"}
