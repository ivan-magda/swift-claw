"""Shared dependency queue transforms used by scoring and the oracle."""

from __future__ import annotations

from typing import Any


def set_queue_membership(
    queue: list[str],
    finding_id: str,
    member: bool,
) -> list[str]:
    """Return a queue with one canonical finding's membership corrected."""

    if member and finding_id not in queue:
        return [*queue, finding_id]
    if not member:
        return [queued for queued in queue if queued != finding_id]
    return list(queue)


def correct_queue_membership(
    queue: list[str],
    candidate_ids: set[str],
    gold_by_id: dict[str, dict[str, Any]],
    target_class: str,
) -> list[str]:
    """Correct only memberships owned by one target class."""

    corrected = list(queue)
    for finding_id in sorted(candidate_ids):
        label = gold_by_id.get(finding_id)
        if label is None or label["queue"]["target_class"] != target_class:
            continue
        corrected = set_queue_membership(corrected, finding_id, label["queue"]["member"])
    return corrected


def sort_gold_matched_queue(
    queue: list[str],
    grades: dict[str, int],
) -> list[str]:
    """Sort gold-matched entries by grade while preserving every other position."""

    result = list(queue)
    positions = [index for index, finding_id in enumerate(queue) if grades.get(finding_id, 0) > 0]
    matched = [queue[index] for index in positions]
    matched.sort(key=lambda finding_id: -grades[finding_id])
    for index, finding_id in zip(positions, matched, strict=True):
        result[index] = finding_id
    return result
