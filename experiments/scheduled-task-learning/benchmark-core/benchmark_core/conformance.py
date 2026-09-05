"""Deterministic scorer-conformance corpus mechanics."""

from __future__ import annotations

import hashlib
from collections import Counter
from collections.abc import Callable
from typing import Any

from .canonical import canonical_sha256, dumps

ScoreCase = Callable[[dict[str, Any]], dict[str, Any]]


def run_conformance(
    corpus: dict[str, Any],
    coverage_contract: dict[str, Any],
    score_case: ScoreCase,
    *,
    domain: bytes,
    expected_count: int = 24,
) -> dict[str, Any]:
    cases = corpus.get("cases", [])
    if corpus.get("schema_version") != 1 or len(cases) != expected_count:
        raise ValueError(
            f"the frozen conformance corpus must contain exactly {expected_count} cases"
        )
    results: list[dict[str, Any]] = []
    coverage: Counter[str] = Counter()
    case_ids: set[str] = set()
    attempt_digests: set[str] = set()
    for case in cases:
        case_id = case.get("case_id") if isinstance(case, dict) else None
        if not isinstance(case_id, str) or not case_id or case_id in case_ids:
            raise ValueError("conformance case IDs must be non-empty and unique")
        case_ids.add(case_id)
        attempt_digest = canonical_sha256(case.get("attempt"))
        if attempt_digest in attempt_digests:
            raise ValueError("conformance attempts must be byte-distinct")
        attempt_digests.add(attempt_digest)
        result = score_case(case)
        if result != case["expected"]:
            raise ValueError(f"conformance oracle mismatch: {case_id}")
        if not set(case["covers"]).issubset(result["requirement_hits"]):
            raise ValueError(f"conformance coverage declaration mismatch: {case_id}")
        coverage.update(case["covers"])
        results.append(
            {
                "case_id": case_id,
                "attempt_sha256": attempt_digest,
                "result": result,
            }
        )

    required = set(coverage_contract["requirements"])
    minimum = coverage_contract["minimum_cases_per_requirement"]
    if set(coverage) != required or any(
        coverage[requirement] < minimum for requirement in required
    ):
        raise ValueError("conformance coverage contract is not satisfied")
    bindings = {
        "schema_version": 1,
        "corpus_sha256": canonical_sha256(corpus),
        "passed": expected_count,
        "total": expected_count,
        "coverage": dict(sorted(coverage.items())),
        "results": results,
    }
    conformance_sha256 = hashlib.sha256(domain + dumps(bindings).encode("utf-8")).hexdigest()
    return {
        **bindings,
        "conformance_id": f"conformance-{conformance_sha256[:12]}",
    }
