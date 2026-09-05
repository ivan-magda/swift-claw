"""Run the frozen 24-case scorer conformance corpus."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from benchmark_core.conformance import run_conformance

from .canonical import canonical_sha256, dumps, load_object
from .scorer import score

_CONFORMANCE_DOMAIN = b"swift-claw/scheduled-task-learning/page-change/conformance/v1\x00"


def run(root: str | Path) -> dict[str, Any]:
    root = Path(root)
    corpus = load_object(root / "conformance/cases.json")
    split_contract = load_object(root / "contracts/splits.json")
    lookup = {
        entry["fixture_id"]: entry
        for entries in split_contract["splits"].values()
        for entry in entries
    }

    def score_case(case: dict[str, Any]) -> dict[str, Any]:
        fixture = lookup[case["fixture_id"]]
        return score(
            load_object(root / fixture["source"]),
            load_object(root / fixture["gold"]),
            case["attempt"],
        )

    return run_conformance(
        corpus,
        load_object(root / "contracts/conformance-coverage.json"),
        score_case,
        domain=_CONFORMANCE_DOMAIN,
    )


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
