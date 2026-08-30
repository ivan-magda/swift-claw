"""Thin command-line adapter for live execution, restart, and offline verification."""

from __future__ import annotations

import argparse
from collections.abc import Sequence
from pathlib import Path
from typing import cast

from benchmark_core.canonical import load_object

from scheduled_learning_v1.execution import run_active, run_scored
from scheduled_learning_v1.execution.lifecycle import replayed_promoted_digest
from scheduled_learning_v1.reporting import verify_results


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Run or verify the scheduled-learning M3 harness.")
    commands = parser.add_subparsers(dest="command", required=True)
    scored = commands.add_parser("scored", help="run the owner-authorized live lifecycle")
    scored.add_argument("--root", required=True)
    scored.add_argument("--manifest", required=True)
    scored.add_argument("--approval", required=True)
    active = commands.add_parser("active", help=argparse.SUPPRESS)
    active.add_argument("--root", required=True)
    active.add_argument("--generation", required=True, type=int)
    active.add_argument("--promoted-digest", required=True)
    verify = commands.add_parser("verify-results", help="verify a committed result tree offline")
    verify.add_argument("--root", required=True)
    arguments = parser.parse_args(argv)
    root = Path(cast(str, arguments.root)).resolve(strict=True)
    if arguments.command == "scored":
        _require_canonical_argument(
            root, Path(cast(str, arguments.manifest)), "freeze/manifest.json"
        )
        _require_canonical_argument(
            root,
            Path(cast(str, arguments.approval)),
            "freeze/owner-budget-approval.json",
        )
        report = run_scored(root)
        print(f"status={report['status']}")
        return
    if arguments.command == "active":
        expected = cast(str, arguments.promoted_digest)
        observed = _replayed_promoted_digest(root)
        if observed != expected:
            raise ValueError("fresh process promoted digest differs from the exact parent handoff")
        report = run_active(root, cast(int, arguments.generation))
        print(f"status={report['status']}")
        return
    manifest = load_object(root / "freeze" / "manifest.json")
    receipt = verify_results(root, manifest)
    print(f"status={receipt['status']}")


def _replayed_promoted_digest(root: Path) -> str:
    return replayed_promoted_digest(root)


def _require_canonical_argument(root: Path, supplied: Path, relative: str) -> None:
    expected = (root / relative).resolve(strict=True)
    observed = supplied if supplied.is_absolute() else (Path.cwd() / supplied)
    if observed.resolve(strict=True) != expected:
        raise ValueError(f"{relative} must be the exact canonical scored artifact")


if __name__ == "__main__":
    main()
