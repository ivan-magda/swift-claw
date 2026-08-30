"""Page-pair aggregation and the frozen M3 adapter gate."""

from __future__ import annotations

from typing import Any

from .oracle import sealed_score

_MINIMUM_PAIR_COUNT = 2
_MAXIMUM_PAIR_COUNT = 3
_MINIMUM_CANDIDATE_SCORE = 90
_MINIMUM_MEAN_DELTA = 10


def score_pair(
    clean_attempt: dict[str, object], candidate_attempt: dict[str, object]
) -> dict[str, object]:
    """Score one clean/candidate raw-attempt pair through the trusted oracle."""

    clean = sealed_score(clean_attempt, "clean")
    candidate = sealed_score(candidate_attempt, "candidate")
    return {
        "clean": clean,
        "candidate": candidate,
        "delta": _score_value(candidate["score"]) - _score_value(clean["score"]),
    }


def outcome_for_pairs(pairs: list[dict[str, object]]) -> str:
    """Apply only the frozen paired comparison rules to sealed score pairs."""

    if any(not _is_complete_pair(pair) for pair in pairs):
        return "inconclusive"
    if any(_has_critical_result(pair) for pair in pairs):
        return "critical"
    if not _MINIMUM_PAIR_COUNT <= len(pairs) <= _MAXIMUM_PAIR_COUNT:
        return "regression"
    if any(_candidate_score(pair) < _MINIMUM_CANDIDATE_SCORE for pair in pairs):
        return "regression"
    if any(_delta(pair) < 0 for pair in pairs):
        return "regression"
    mean_delta = sum(_delta(pair) for pair in pairs) / len(pairs)
    if mean_delta < _MINIMUM_MEAN_DELTA:
        return "regression"
    return "pass"


def receipt_metrics(pairs: list[dict[str, object]]) -> dict[str, object]:
    """Return the full-receipt metrics without exposing them to the generic reducer."""

    complete_pairs = [pair for pair in pairs if _is_complete_pair(pair)]
    return {
        "pair_count": len(pairs),
        "valid_pair_count": len(complete_pairs),
        "mean_delta": (
            sum(_delta(pair) for pair in complete_pairs) / len(complete_pairs)
            if complete_pairs
            else None
        ),
    }


def _is_complete_pair(pair: dict[str, object]) -> bool:
    clean = pair.get("clean")
    candidate = pair.get("candidate")
    return (
        isinstance(clean, dict)
        and isinstance(candidate, dict)
        and _is_score(clean.get("score"))
        and _is_score(candidate.get("score"))
        and isinstance(clean.get("critical_codes"), list)
        and isinstance(candidate.get("critical_codes"), list)
    )


def _has_critical_result(pair: dict[str, object]) -> bool:
    clean = _score_result(pair, "clean")
    candidate = _score_result(pair, "candidate")
    return bool(clean["critical_codes"] or candidate["critical_codes"])


def _candidate_score(pair: dict[str, object]) -> float:
    return _score_value(_score_result(pair, "candidate")["score"])


def _delta(pair: dict[str, object]) -> float:
    return _candidate_score(pair) - _score_value(_score_result(pair, "clean")["score"])


def _is_score(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _score_result(pair: dict[str, object], condition: str) -> dict[str, object]:
    result = pair[condition]
    if not isinstance(result, dict):
        raise ValueError("adapter pair is missing a score result")
    return result


def _score_value(value: object) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError("adapter pair score must be numeric")
    return float(value)
