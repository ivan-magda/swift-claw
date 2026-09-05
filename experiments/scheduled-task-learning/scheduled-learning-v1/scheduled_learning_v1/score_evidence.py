"""Closed active and restart score-evidence binding."""

from __future__ import annotations

from pathlib import Path
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256
from page_benchmark.scorer import score
from page_change_m3.oracle import sealed_score

from scheduled_learning_v1.evidence_contract import canonical_object

SCORE_EVIDENCE_KEYS = {
    "schema_version",
    "operation_id",
    "task_id",
    "task_result_digest",
    "fixture_id",
    "condition",
    "scoring_condition",
    "source_sha256",
    "gold_sha256",
    "attempt_sha256",
    "scorer_sha256",
    "oracle_digest",
    "score",
    "critical_codes",
    "score_receipt_digest",
    "promoted_digest",
}
_RESTART_ORDER_INDEX = 9
_SHA256_LENGTH = 64


def score_evidence_projection(
    root: Path,
    manifest: dict[str, Any],
    value: dict[str, Any],
    threshold: object,
    order_index: int,
    promoted_digest: str | None,
    *,
    expected_result_digest: str | None = None,
) -> dict[str, object] | None:
    """Return the report projection only for exact task-bound score evidence."""

    if set(value) != SCORE_EVIDENCE_KEYS or value.get("schema_version") != 1:
        return None
    rows = manifest.get("run_order")
    identities = manifest.get("identities")
    if (
        not isinstance(rows, list)
        or order_index >= len(rows)
        or not isinstance(rows[order_index], dict)
        or not isinstance(identities, dict)
        or promoted_digest is None
    ):
        return None
    row = cast(dict[str, Any], rows[order_index])
    operation_id = f"task-{order_index}"
    task_result_path = root / "results" / "task-attempts" / operation_id / "result.json"
    split = "sealed" if row.get("stage") in {"active", "restart"} else row.get("stage")
    fixture_id = row.get("fixture_id")
    if not isinstance(split, str) or not isinstance(fixture_id, str):
        return None
    try:
        task_result = canonical_object(task_result_path, "score task result")
        source = canonical_object(
            root / "corpus" / split / f"{fixture_id}.source.json",
            "score source",
        )
        gold = canonical_object(
            root / "gold" / split / f"{fixture_id}.gold.json",
            "score gold",
        )
        raw_output = task_result.get("raw_output")
        if not isinstance(raw_output, str):
            raw_output = ""
        http = task_result.get("http")
        tools = task_result.get("tools")
        if (
            not isinstance(http, dict)
            or not isinstance(tools, list)
            or any(not isinstance(tool, dict) for tool in tools)
        ):
            return None
        tool_events = [
            {key: tool[key] for key in ("name", "path", "status")}
            for tool in cast(list[dict[str, object]], tools)
        ]
        attempt = {
            "runtime_outcome": task_result.get("outcome"),
            "raw_output": raw_output,
            "tool_events": tool_events,
            "responses_requests": http.get("responsesSends"),
        }
    except (KeyError, OSError, RecursionError, UnicodeError, ValueError):
        return None
    task_result_digest = canonical_sha256(task_result)
    scorer_sha256 = canonical_sha256(Path(score.__code__.co_filename).read_text(encoding="utf-8"))
    numeric_score = value.get("score")
    critical_codes = value.get("critical_codes")
    expected_scoring_condition = "restart" if order_index == _RESTART_ORDER_INDEX else "active"
    expected_score = sealed_score(
        {"source": source, "gold": gold, "attempt": attempt},
        expected_scoring_condition,
    )
    if (
        value.get("operation_id") != operation_id
        or value.get("task_id") != source.get("task_id")
        or value.get("task_result_digest") != task_result_digest
        or expected_result_digest not in {None, task_result_digest}
        or value.get("fixture_id") != fixture_id
        or value.get("condition") != row.get("condition")
        or value.get("scoring_condition") != expected_scoring_condition
        or value.get("source_sha256") != canonical_sha256(source)
        or value.get("gold_sha256") != canonical_sha256(gold)
        or value.get("attempt_sha256") != canonical_sha256(attempt)
        or value.get("scorer_sha256") != scorer_sha256
        or value.get("oracle_digest") != identities.get("oracle_digest")
        or value.get("promoted_digest") != promoted_digest
        or value.get("score") != expected_score.get("score")
        or value.get("critical_codes") != expected_score.get("critical_codes")
        or value.get("score_receipt_digest") != expected_score.get("score_receipt_digest")
        or value.get("scorer_sha256") != expected_score.get("scorer_sha256")
        or not _number(numeric_score)
        or not _number(threshold)
        or not isinstance(critical_codes, list)
        or any(not isinstance(item, str) for item in critical_codes)
        or not _sha256(value.get("score_receipt_digest"))
    ):
        return None
    score_value = cast(int | float, numeric_score)
    threshold_value = cast(int | float, threshold)
    projection: dict[str, object] = {
        "score": score_value,
        "threshold": threshold_value,
        "passed": score_value >= threshold_value,
    }
    if order_index == _RESTART_ORDER_INDEX:
        projection["promoted_digest_matched"] = True
    return projection


def _number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _sha256(value: object) -> bool:
    return bool(
        isinstance(value, str)
        and len(value) == _SHA256_LENGTH
        and all(character in "0123456789abcdef" for character in value)
    )
