"""Fresh M3 fixture discovery and independence from Protocol 0.6/M0.

Owns the frozen 2/3/2 fresh fixture identity and the boundary check that
rejects any exact path or digest overlap with Protocol 0.6's existing
page-change corpus. M0 (the milestone that produced the initial single
lesson) reused that same corpus rather than owning a separate fixture tree,
so checking against Protocol 0.6's corpus covers both.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from benchmark_core.canonical import canonical_sha256, load_object
from benchmark_core.contract_validation import ContractError, ValidationIssue, issue

FRESH_SPLIT_FIXTURE_IDS: dict[str, tuple[str, ...]] = {
    "development": ("pc-development-07", "pc-development-08"),
    "regression": ("pc-regression-04", "pc-regression-05", "pc-regression-06"),
    "sealed": ("pc-sealed-05", "pc-sealed-06"),
}
ALL_FRESH_FIXTURE_IDS = frozenset(
    fixture_id for fixture_ids in FRESH_SPLIT_FIXTURE_IDS.values() for fixture_id in fixture_ids
)
_EXPECTED_FRESH_FIXTURE_COUNT = 7

# Protocol 0.6's frozen corpus lives in the sibling `page-change` project.
_PROTOCOL_06_ROOT = Path(__file__).resolve().parents[2] / "page-change"


def fresh_source_path(root: Path | str, split: str, fixture_id: str) -> Path:
    return Path(root) / "corpus" / split / f"{fixture_id}.source.json"


def fresh_gold_path(root: Path | str, split: str, fixture_id: str) -> Path:
    return Path(root) / "gold" / split / f"{fixture_id}.gold.json"


def load_fresh_sources(root: Path | str) -> list[dict[str, Any]]:
    """Load all seven frozen fresh sources, in frozen split/fixture order."""

    return [
        load_object(fresh_source_path(root, split, fixture_id))
        for split, fixture_ids in FRESH_SPLIT_FIXTURE_IDS.items()
        for fixture_id in fixture_ids
    ]


def load_fresh_golds(root: Path | str) -> list[dict[str, Any]]:
    """Load all seven frozen fresh gold records, in frozen split/fixture order."""

    return [
        load_object(fresh_gold_path(root, split, fixture_id))
        for split, fixture_ids in FRESH_SPLIT_FIXTURE_IDS.items()
        for fixture_id in fixture_ids
    ]


def _protocol_06_source_index() -> tuple[set[Path], set[str], set[str]]:
    paths = sorted(_PROTOCOL_06_ROOT.glob("sources/*/*.source.json"))
    source_digests: set[str] = set()
    task_digests: set[str] = set()
    for path in paths:
        source = load_object(path)
        source_digests.add(canonical_sha256(source))
        task_digests.add(canonical_sha256(source["task"]))
    return {path.resolve() for path in paths}, source_digests, task_digests


def _protocol_06_gold_index() -> tuple[set[Path], set[str]]:
    paths = sorted(_PROTOCOL_06_ROOT.glob("gold/*/*.gold.json"))
    gold_digests = {canonical_sha256(load_object(path)) for path in paths}
    return {path.resolve() for path in paths}, gold_digests


def verify_fixture_independence(root: Path | str) -> None:
    """Reject a fresh corpus that is incomplete or reuses a Protocol 0.6/M0 fixture.

    Compares exact declared paths and canonical digests only; it never applies a
    lexical filter for hypothetical text similarity, per the frozen protocol.
    """

    root = Path(root)
    issues: list[ValidationIssue] = []

    fresh_sources: list[tuple[Path, dict[str, Any]]] = []
    fresh_golds: list[tuple[Path, dict[str, Any]]] = []
    for split, fixture_ids in FRESH_SPLIT_FIXTURE_IDS.items():
        for fixture_id in fixture_ids:
            source_path = fresh_source_path(root, split, fixture_id)
            if source_path.is_file():
                fresh_sources.append((source_path, load_object(source_path)))
            else:
                issue(issues, "fixtures.missing_source", f"missing fresh source {source_path}")
            gold_path = fresh_gold_path(root, split, fixture_id)
            if gold_path.is_file():
                fresh_golds.append((gold_path, load_object(gold_path)))
            else:
                issue(issues, "fixtures.missing_gold", f"missing fresh gold {gold_path}")

    if len(fresh_sources) != _EXPECTED_FRESH_FIXTURE_COUNT:
        issue(
            issues,
            "fixtures.exact_split_counts",
            "the frozen M3 proposal is exactly 2 development, 3 regression, 2 sealed sources",
        )
    if len(fresh_golds) != _EXPECTED_FRESH_FIXTURE_COUNT:
        issue(
            issues,
            "fixtures.exact_split_counts",
            "the frozen M3 proposal is exactly 2 development, 3 regression, 2 sealed gold records",
        )

    protocol_source_paths, protocol_source_digests, protocol_task_digests = (
        _protocol_06_source_index()
    )
    protocol_gold_paths, protocol_gold_digests = _protocol_06_gold_index()

    for path, source in fresh_sources:
        if path.resolve() in protocol_source_paths:
            issue(issues, "fixtures.path_overlap", f"{path} reuses a Protocol 0.6/M0 source path")
        if canonical_sha256(source) in protocol_source_digests:
            issue(
                issues, "fixtures.digest_overlap", f"{path} reuses a Protocol 0.6/M0 source digest"
            )
        if canonical_sha256(source["task"]) in protocol_task_digests:
            issue(issues, "fixtures.digest_overlap", f"{path} reuses Protocol 0.6/M0 task content")

    for path, gold in fresh_golds:
        if path.resolve() in protocol_gold_paths:
            issue(issues, "fixtures.path_overlap", f"{path} reuses a Protocol 0.6/M0 gold path")
        if canonical_sha256(gold) in protocol_gold_digests:
            issue(issues, "fixtures.digest_overlap", f"{path} reuses a Protocol 0.6/M0 gold digest")

    if issues:
        raise ContractError(issues)
