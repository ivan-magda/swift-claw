"""Shared worker send and usage accounting verification."""

from __future__ import annotations

from typing import cast


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
    try:
        sends = _integer(usage, "responses_sends")
        not_started = _integer(usage, "proven_not_started_responses_sends")
    except ValueError as error:
        raise ValueError("invalid worker usage") from error
    if not (0 <= sends <= retry_budget and 0 <= not_started <= sends):
        raise ValueError("worker send counts exceed frozen retry budget")
    if sends == 0:
        if allow_no_usage and not_started == 0:
            return 0
        raise ValueError("handed-off worker result has zero sends")
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
