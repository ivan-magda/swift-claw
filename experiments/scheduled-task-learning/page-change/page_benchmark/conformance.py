"""Run the frozen 24-case scorer conformance corpus."""

from __future__ import annotations

import argparse
import hashlib
from collections import Counter
from pathlib import Path
from typing import Any

from .canonical import canonical_sha256, dumps, load_object
from .scorer import score

_CONFORMANCE_DOMAIN = b"swift-claw/scheduled-task-learning/page-change/conformance/v1\x00"
_FROZEN_CASE_COUNT = 24


def run(root: str | Path) -> dict[str, Any]:
    root = Path(root)
    corpus = load_object(root / "conformance/cases.json")
    if corpus.get("schema_version") != 1 or len(corpus.get("cases", [])) != _FROZEN_CASE_COUNT:
        raise ValueError("the frozen conformance corpus must contain exactly 24 cases")
    split_contract = load_object(root / "contracts/splits.json")
    lookup = {
        entry["fixture_id"]: entry
        for entries in split_contract["splits"].values()
        for entry in entries
    }
    results: list[dict[str, Any]] = []
    coverage: Counter[str] = Counter()
    case_ids: set[str] = set()
    attempt_digests: set[str] = set()
    for case in corpus["cases"]:
        case_id = case.get("case_id") if isinstance(case, dict) else None
        if not isinstance(case_id, str) or not case_id or case_id in case_ids:
            raise ValueError("conformance case IDs must be non-empty and unique")
        case_ids.add(case_id)
        attempt_digest = canonical_sha256(case.get("attempt"))
        if attempt_digest in attempt_digests:
            raise ValueError("conformance attempts must be byte-distinct")
        attempt_digests.add(attempt_digest)
        fixture = lookup[case["fixture_id"]]
        result = score(
            load_object(root / fixture["source"]),
            load_object(root / fixture["gold"]),
            case["attempt"],
        )
        expected = case["expected"]
        if result != expected:
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

    coverage_contract = load_object(root / "contracts/conformance-coverage.json")
    required = set(coverage_contract["requirements"])
    minimum = coverage_contract["minimum_cases_per_requirement"]
    if set(coverage) != required or any(
        coverage[requirement] < minimum for requirement in required
    ):
        raise ValueError("conformance coverage contract is not satisfied")
    bindings = {
        "schema_version": 1,
        "corpus_sha256": canonical_sha256(corpus),
        "passed": 24,
        "total": 24,
        "coverage": dict(sorted(coverage.items())),
        "results": results,
    }
    conformance_sha256 = hashlib.sha256(
        _CONFORMANCE_DOMAIN + dumps(bindings).encode("utf-8")
    ).hexdigest()
    return {
        **bindings,
        "conformance_id": f"conformance-{conformance_sha256[:12]}",
    }


def verify_receipt(root: str | Path, receipt: dict[str, Any]) -> str:
    """Require a receipt to equal a fresh run of the frozen corpus."""

    if receipt != run(root):
        raise ValueError("conformance receipt is absent, stale, or not 24/24")
    return canonical_sha256(receipt)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    arguments = parser.parse_args()
    print(dumps(run(arguments.root)), end="")


if __name__ == "__main__":
    main()
