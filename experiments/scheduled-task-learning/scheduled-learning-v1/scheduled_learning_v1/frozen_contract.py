"""Shared immutable values for the scheduled-learning v1 frozen runtime contract."""

from __future__ import annotations

from benchmark_core.canonical import dumps

SCHEMA_VERSION = 1
APPROVAL_KEYS = frozenset(
    {
        "schema_version",
        "manifest_sha256",
        "expected_freeze_commit",
        "budgets",
        "owner_identity",
        "approved_at",
    }
)
AGGREGATE_BUDGETS: dict[str, int] = {
    "task_attempts": 10,
    "evaluator_calls": 5,
    "reflector_calls": 1,
    "responses_sends": 38,
    "accounted_tokens": 5_045_184,
}
TASK_ROUTE: dict[str, object] = {
    "provider_reference": "openai-chatgpt/gpt-5.6-sol",
    "wire_model": "gpt-5.6-sol",
    "retry_budget": 1,
    "max_output_tokens": 4_096,
    "max_output_utf8_bytes": 32_768,
    "max_output_graphemes": 16_384,
}
LEARNING_RETRY_BUDGET = 3
EVALUATOR_ROUTE: dict[str, object] = {
    "provider_reference": "openai-chatgpt/gpt-5.6-sol",
    "wire_model": "gpt-5.6-sol",
    "retry_budget": LEARNING_RETRY_BUDGET,
    "max_output_tokens": 512,
    "max_output_utf8_bytes": 4_096,
    "max_output_graphemes": 4_096,
}
REFLECTOR_ROUTE: dict[str, object] = {**EVALUATOR_ROUTE, "max_output_tokens": 768}
MISSING_USAGE_TOKEN_PROXY = 132_768
GATES: dict[str, object] = {
    "schema_version": SCHEMA_VERSION,
    "adapter_pass_rule": {
        "minimum_valid_pairs": 2,
        "maximum_valid_pairs": 3,
        "minimum_candidate_score": 90,
        "minimum_mean_delta": 10,
        "allow_critical_result": False,
        "allow_negative_delta": False,
    },
    "active_and_restart_gates": {
        "minimum_active_score": 90,
        "minimum_restart_active_score": 90,
    },
    "aggregate_budgets": dict(AGGREGATE_BUDGETS),
    "responses_sends_per_operation": {
        "task": 2,
        "evaluator": LEARNING_RETRY_BUDGET,
        "reflector": LEARNING_RETRY_BUDGET,
    },
}


def json_exactly_matches(observed: object, expected: object) -> bool:
    """Compare JSON values without Python's boolean/numeric coercions."""

    try:
        return dumps(observed) == dumps(expected)
    except (TypeError, ValueError):
        return False
