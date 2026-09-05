"""Run the frozen dependency scorer conformance corpus."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from benchmark_core.canonical import canonical_sha256, dumps, load_object
from benchmark_core.conformance import run_conformance

from .scorer import score

_CONFORMANCE_DOMAIN = (
    b"swift-claw/scheduled-task-learning/dependency-prioritization/conformance/v1\x00"
)


def run(root: str | Path) -> dict[str, Any]:
    root = Path(root)
    corpus = load_object(root / "conformance/cases.json")
    fixtures = corpus.get("fixtures")
    if not isinstance(fixtures, list):
        raise ValueError("conformance fixtures must be an array")
    by_id = {
        fixture["fixture_id"]: fixture
        for fixture in fixtures
        if isinstance(fixture, dict) and isinstance(fixture.get("fixture_id"), str)
    }
    if len(by_id) != len(fixtures):
        raise ValueError("conformance fixture IDs must be non-empty and unique")
    ranking_policy = load_object(root / "contracts/ranking-policy.json")
    target_contract = load_object(root / "contracts/target-classes.json")
    error_contract = load_object(root / "contracts/error-codes.json")

    def score_case(case: dict[str, Any]) -> dict[str, Any]:
        fixture = by_id[case["fixture_id"]]
        return score(
            fixture["source"],
            fixture["gold"],
            case["attempt"],
            ranking_policy,
            target_contract,
            error_contract,
        )

    return run_conformance(
        corpus,
        load_object(root / "contracts/conformance-coverage.json"),
        score_case,
        domain=_CONFORMANCE_DOMAIN,
    )


def verify_receipt(root: str | Path, receipt: dict[str, Any]) -> str:
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
