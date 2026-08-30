"""Trusted post-freeze calls into the reused page scorer and receipt sealer."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from benchmark_core.canonical import canonical_sha256
from page_benchmark.records import seal_score_receipts
from page_benchmark.scorer import score


def sealed_score(attempt: dict[str, object], condition: str) -> dict[str, object]:
    """Score one raw attempt and return only its trusted sealed score evidence."""

    source = attempt["source"]
    gold = attempt["gold"]
    raw_attempt = attempt["attempt"]
    if (
        not isinstance(source, dict)
        or not isinstance(gold, dict)
        or not isinstance(raw_attempt, dict)
    ):
        raise ValueError("page attempts must carry source, gold, and raw attempt objects")

    scorer_digest = canonical_sha256(Path(score.__code__.co_filename).read_text(encoding="utf-8"))
    scorer_result = score(source, gold, raw_attempt)
    record: dict[str, Any] = {
        "attempt_id": canonical_sha256({"condition": condition, "attempt": raw_attempt}),
        "attempt_digest": "",
        "condition": condition,
        "fixture_id": source["fixture_id"],
        "original_attempt_evidence_sha256": None,
        "parsed_output": None,
        "replicate": 1,
        "replacement_of_attempt_id": None,
        "replacement_ordinal": 0,
        "result_or_envelope_sha256": canonical_sha256(raw_attempt),
        "score_result": scorer_result,
        "scorer_digest": scorer_digest,
        "carrier_receipt": {},
        "carrier_receipt_sha256": "",
        "score_receipt_digest": "",
        "attempt": raw_attempt,
    }
    fixtures = {source["fixture_id"]: {"source": source, "gold": gold}}
    seal_score_receipts([record], fixtures, scorer_digest)
    return {
        "score": record["score_result"]["score"],
        "critical_codes": record["score_result"]["critical_codes"],
        "score_receipt_digest": record["score_receipt_digest"],
        "scorer_sha256": scorer_digest,
    }
