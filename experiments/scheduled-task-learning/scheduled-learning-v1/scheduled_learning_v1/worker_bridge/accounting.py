"""Shared worker send and usage accounting verification."""

from __future__ import annotations

from typing import cast

_LEARNING_USAGE_KEYS = {
    "provider_call_id",
    "responses_sends",
    "proven_not_started_responses_sends",
    "prompt_tokens",
    "completion_tokens",
    "reported_total_tokens",
    "accounted_tokens",
    "is_estimated",
}
_TASK_USAGE_KEYS = {
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


def validate_usage(
    usage: dict[str, object] | None,
    provider_call_id: str,
    retry_budget: int,
    missing_usage_token_proxy: int,
    completion_cap: int,
    *,
    allow_no_usage: bool = False,
) -> int:
    """Verify the Swift terminal-usage formula and return accounted tokens.

    The terminal usage row remains in the sum.  Only genuinely missing usage rows
    receive the frozen proxy; Python deliberately performs no second subtraction.
    """

    if usage is None:
        if allow_no_usage:
            return 0
        raise ValueError("handed-off worker result requires usage")
    if set(usage) != _LEARNING_USAGE_KEYS and not (
        allow_no_usage and set(usage) == {"responses_sends", "proven_not_started_responses_sends"}
    ):
        raise ValueError("learning usage has non-canonical fields")
    try:
        sends = _integer(usage, "responses_sends")
        not_started = _integer(usage, "proven_not_started_responses_sends")
    except ValueError as error:
        raise ValueError("invalid worker usage") from error
    if not (0 <= sends <= retry_budget and 0 <= not_started <= sends):
        raise ValueError("worker send counts exceed frozen retry budget")
    if (
        sends == 0
        and allow_no_usage
        and set(usage)
        == {
            "responses_sends",
            "proven_not_started_responses_sends",
        }
    ):
        return 0
    if usage.get("provider_call_id") != provider_call_id:
        raise ValueError("usage provider-call ID does not bind to request")
    reported = _reported_total(usage, completion_cap)
    accounted = _integer(usage, "accounted_tokens")
    reported_rows = 1 if reported is not None else 0
    expected = (reported or 0) + (sends - not_started - reported_rows) * missing_usage_token_proxy
    if expected < 0 or accounted != expected:
        raise ValueError("worker accounted-token total does not match frozen proxy formula")
    if usage.get("is_estimated") is not (sends - not_started > reported_rows):
        raise ValueError("worker usage estimation flag does not match send accounting")
    return accounted


def validate_task_usage(
    responses_sends: int,
    proven_not_started_responses_sends: int,
    usage: list[dict[str, object]],
    missing_usage_token_proxy: int,
    completion_cap: int,
) -> int:
    """Recompute the task worker's shared send/usage accounting formula."""

    if (
        responses_sends < 0
        or proven_not_started_responses_sends < 0
        or proven_not_started_responses_sends > responses_sends
        or missing_usage_token_proxy <= 0
        or completion_cap <= 0
    ):
        raise ValueError("invalid task accounting bounds")
    accountable_sends = responses_sends - proven_not_started_responses_sends
    if len(usage) > accountable_sends:
        raise ValueError("task usage has more rows than accountable sends")
    accounted = 0
    for row in usage:
        if set(row) not in (
            _TASK_USAGE_KEYS,
            {"prompt_tokens", "completion_tokens", "total_tokens", "is_estimated"},
        ):
            raise ValueError("task usage row has non-canonical fields")
        prompt = _integer(row, "prompt_tokens")
        completion = _integer(row, "completion_tokens")
        total = _integer(row, "total_tokens")
        estimated = row.get("is_estimated")
        if estimated is not True and estimated is not False:
            raise ValueError("task usage estimation flag must be boolean")
        if completion > completion_cap or total != max(0, prompt) + max(0, completion):
            raise ValueError("task usage row violates frozen bounds")
        accounted += missing_usage_token_proxy if estimated else total
    accounted += (accountable_sends - len(usage)) * missing_usage_token_proxy
    return accounted


def _reported_total(usage: dict[str, object], completion_cap: int) -> int | None:
    values = [
        usage.get(name) for name in ("prompt_tokens", "completion_tokens", "reported_total_tokens")
    ]
    if all(value is None for value in values):
        return None
    if any(
        value is None or isinstance(value, bool) or not isinstance(value, int) for value in values
    ):
        raise ValueError("terminal usage fields must be all present or all absent")
    prompt, completion, total = cast(tuple[int, int, int], tuple(values))
    if prompt < 0 or completion < 0 or total != prompt + completion or completion > completion_cap:
        raise ValueError("terminal usage violates frozen bounds")
    return total


def _integer(value: dict[str, object], key: str) -> int:
    candidate = value.get(key)
    if isinstance(candidate, bool) or not isinstance(candidate, int):
        raise ValueError(f"{key} must be an integer")
    return candidate
