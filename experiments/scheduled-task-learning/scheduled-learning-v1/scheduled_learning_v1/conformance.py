"""Run the frozen 24-case scheduled-learning replay conformance corpus."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from benchmark_core.canonical import dumps, load_object
from benchmark_core.conformance import run_conformance
from benchmark_learning.learning_contract import LearningContractError, parse_event
from benchmark_learning.learning_replay import replay

_CONFORMANCE_DOMAIN = b"swift-claw/scheduled-task-learning/scheduled-learning-v1/conformance/v1\x00"


def _accepted_hits(decisions: list[dict[str, Any]]) -> list[str]:
    if not decisions:
        return ["decision.none"]
    return sorted({f"decision.{item['decision']}.{item['reason']}" for item in decisions})


def _rejected_hits(error: LearningContractError) -> list[str]:
    return sorted({f"error.{item.requirement}" for item in error.issues})


def score_case(case: dict[str, Any]) -> dict[str, Any]:
    """Replay one frozen attempt, closing rejection into the stable contract-error code."""

    attempt = case["attempt"]
    events = [parse_event(value) for value in attempt["events"]]
    try:
        result = replay(initial=attempt["initial"], events=events)
    except LearningContractError as error:
        return {
            "outcome": "rejected",
            "error_code": error.issues[0].requirement,
            "requirement_hits": _rejected_hits(error),
        }
    return {
        "outcome": "accepted",
        "state": result["state"],
        "decisions": result["decisions"],
        "receipt": result["receipt"],
        "requirement_hits": _accepted_hits(result["decisions"]),
    }


def run(root: str | Path) -> dict[str, Any]:
    root = Path(root)
    corpus = load_object(root / "conformance/replay-cases.json")
    coverage_contract = load_object(root / "conformance/coverage.json")
    return run_conformance(corpus, coverage_contract, score_case, domain=_CONFORMANCE_DOMAIN)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    arguments = parser.parse_args()
    print(dumps(run(arguments.root)), end="")


if __name__ == "__main__":
    main()
