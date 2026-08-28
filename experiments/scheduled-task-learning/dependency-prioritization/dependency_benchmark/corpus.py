"""Deterministically author and verify the frozen dependency corpus."""

from __future__ import annotations

import hashlib
import re
from collections import Counter
from collections.abc import Mapping
from dataclasses import dataclass
from itertools import combinations
from pathlib import Path
from typing import Any

from benchmark_core.canonical import canonical_sha256, dumps, load_object, loads_object

from .advisory_records import load_frozen_advisories, semantic_receipt
from .corpus_coverage import CorpusCoverageFixture, evaluate_corpus_coverage
from .derivation import DerivedSource, derive_normalized_source
from .fixture_policy import (
    FixtureFamilyFingerprint,
    aggregate_reachability,
    aggregate_runtime_scope,
    are_unrelated_families,
    derive_actionability,
    derive_remediation,
    expected_evidence_reference_ids,
    validate_fixture_policy,
)
from .fixtures import validate_fixture
from .normalization import Materialization, materialize
from .policy import finding_grade, validate_ranking_policy
from .project_snapshot import ProjectSnapshot, load_project_snapshot
from .validation import CANONICAL_IDS, TASK_ID
from .versioning import compare_versions

_EXPECTED_SPLIT_COUNTS = {
    "development": 10,
    "regression": 4,
    "sealed": 6,
}
_TARGET_CLASSES = (
    "policy.runtime_scope",
    "policy.reachability",
    "policy.remediation",
    "policy.abstention",
    "policy.ranking",
)
_INJECTION_MARKER_FIELDS = {
    "task_ids",
    "finding_ids",
    "option_ids",
    "evidence_reference_ids",
    "phrases",
}
_CORPUS_DIRECTORY = "corpus"
_PROJECTS_DIRECTORY = "projects"
_FIXTURES_DIRECTORY = "sources"
_GOLD_DIRECTORY = "gold"
_RECEIPT_NAME = "receipt.json"
_PROTOCOL_VERSION = "0.3"
_PROTOCOL_PATH = Path("docs/research/118-validation-protocol.md")
_PROTOCOL_BYTES_SHA256 = "17e70a3253400ceb9408da1dcf168664ea9533294661774bd4962cb9f9d11213"
_RANKING_POLICY_BYTES_SHA256 = "9b779a8156ac3aa675457d010efa0c82185ea8ea6b30b967cb9031e24f648c69"


class CorpusAuthoringError(ValueError):
    """Raised when frozen inputs cannot produce one complete corpus."""


@dataclass(frozen=True, slots=True)
class AuthoredFixture:
    snapshot: ProjectSnapshot
    source: dict[str, Any]
    gold: dict[str, Any]
    family_fingerprint: FixtureFamilyFingerprint
    selected_record_ids: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class _VerifiedFixture:
    authored: AuthoredFixture
    project_bytes_sha256: str
    source_bytes_sha256: str
    gold_bytes_sha256: str


@dataclass(frozen=True, slots=True)
class _AuthoringContext:
    benchmark_root: Path
    repository_root: Path
    source_root: Path
    fixture_policy: dict[str, Any]
    ranking_policy: dict[str, Any]
    target_classes: tuple[str, ...]


def author_fixture(
    snapshot: ProjectSnapshot,
    benchmark_root: Path,
    injection_phrases: list[str],
) -> AuthoredFixture:
    """Generate source and gold from frozen facts; only injection phrases are authored."""

    return _author_fixture(snapshot, _load_context(benchmark_root), injection_phrases)


def derive_corpus_receipt(benchmark_root: Path) -> dict[str, Any]:
    """Derive a receipt from the closed 10/4/6 corpus without consulting checked receipt bytes."""

    return _derive_corpus_receipt(_load_context(benchmark_root))


def verify_corpus(benchmark_root: Path) -> dict[str, Any]:
    """Fail unless the checked-in receipt exactly matches the rederived 10/4/6 corpus."""

    context = _load_context(benchmark_root)
    receipt = _derive_corpus_receipt(context)
    corpus_root = context.benchmark_root / _CORPUS_DIRECTORY
    checked_receipt, receipt_raw = _load_canonical_artifact(
        corpus_root / _RECEIPT_NAME,
        corpus_root,
    )
    if checked_receipt != receipt or receipt_raw != dumps(receipt).encode():
        raise CorpusAuthoringError("checked-in corpus receipt differs from recomputation")
    return receipt


def _derive_corpus_receipt(context: _AuthoringContext) -> dict[str, Any]:
    corpus_root = context.benchmark_root / _CORPUS_DIRECTORY
    expected_ids = _expected_fixture_ids()
    _require_closed_layout(corpus_root, expected_ids)

    verified: list[_VerifiedFixture] = []
    for fixture_id in expected_ids:
        split = fixture_id.removeprefix("dp-").rsplit("-", 1)[0]
        project_path = corpus_root / _PROJECTS_DIRECTORY / split / f"{fixture_id}.project.json"
        source_path = corpus_root / _FIXTURES_DIRECTORY / split / f"{fixture_id}.source.json"
        gold_path = corpus_root / _GOLD_DIRECTORY / split / f"{fixture_id}.gold.json"
        _, project_raw = _load_canonical_artifact(project_path, corpus_root)
        checked_source, source_raw = _load_canonical_artifact(source_path, corpus_root)
        checked_gold, gold_raw = _load_canonical_artifact(gold_path, corpus_root)
        snapshot = load_project_snapshot(
            project_path,
            corpus_root / _PROJECTS_DIRECTORY,
        )
        authored = _author_fixture(
            snapshot,
            context,
            _checked_injection_phrases(checked_gold),
        )
        if checked_source != authored.source or source_raw != dumps(authored.source).encode():
            raise CorpusAuthoringError(
                f"checked-in source differs from frozen derivation: {fixture_id}"
            )
        if checked_gold != authored.gold or gold_raw != dumps(authored.gold).encode():
            raise CorpusAuthoringError(
                f"checked-in gold differs from frozen policy derivation: {fixture_id}"
            )
        verified.append(
            _VerifiedFixture(
                authored=authored,
                project_bytes_sha256=_sha256(project_raw),
                source_bytes_sha256=_sha256(source_raw),
                gold_bytes_sha256=_sha256(gold_raw),
            )
        )

    return _build_corpus_receipt(tuple(verified), context)


def family_pair_checks(
    families: Mapping[str, FixtureFamilyFingerprint],
    fixture_policy: dict[str, Any],
) -> list[dict[str, Any]]:
    """Return one successful unrelated-family check for every unordered fixture pair."""

    validate_fixture_policy(fixture_policy)
    ordered = tuple(sorted(families.items()))
    unrelated_policy = fixture_policy["unrelated_family"]
    checks: list[dict[str, Any]] = []
    for (left_id, left), (right_id, right) in combinations(ordered, 2):
        if not are_unrelated_families(left, right, fixture_policy):
            raise CorpusAuthoringError(
                f"fixture families are not fully disjoint: {left_id}, {right_id}"
            )
        checked_dimensions = list(unrelated_policy["all_pair_disjoint_dimensions"])
        if left.split != right.split:
            checked_dimensions.extend(unrelated_policy["cross_split_disjoint_dimensions"])
        checks.append(
            {
                "checked_dimensions": checked_dimensions,
                "left_fixture_id": left_id,
                "left_fingerprint_canonical_sha256": canonical_sha256(
                    _family_fingerprint_value(left)
                ),
                "right_fixture_id": right_id,
                "right_fingerprint_canonical_sha256": canonical_sha256(
                    _family_fingerprint_value(right)
                ),
                "unrelated": True,
            }
        )
    return checks


def _author_fixture(
    snapshot: ProjectSnapshot,
    context: _AuthoringContext,
    injection_phrases: list[str],
) -> AuthoredFixture:
    derived = derive_normalized_source(snapshot, context.source_root)
    materialization = materialize(derived.source)
    gold = _derive_gold(
        snapshot,
        derived,
        materialization,
        context,
        _canonical_phrases(injection_phrases),
    )
    validate_fixture(
        derived.source,
        gold,
        list(context.target_classes),
        context.ranking_policy,
    )
    return AuthoredFixture(
        snapshot=snapshot,
        source=derived.source,
        gold=gold,
        family_fingerprint=derived.family_fingerprint,
        selected_record_ids=derived.selected_record_ids,
    )


def _derive_gold(
    snapshot: ProjectSnapshot,
    derived: DerivedSource,
    materialization: Materialization,
    context: _AuthoringContext,
    injection_phrases: list[str],
) -> dict[str, Any]:
    task_findings = {finding["finding_id"]: finding for finding in materialization.task["findings"]}
    labels: list[dict[str, Any]] = []
    for source_finding in derived.source["normalized_findings"]:
        source_key = source_finding["source_key"]
        finding_id = materialization.bindings.finding_id(source_key)
        finding = task_findings[finding_id]
        runtime_scope = aggregate_runtime_scope(
            (path["runtime_scope"] for path in finding["dependency_paths"]),
            context.fixture_policy,
        )
        reachability = aggregate_reachability(
            (finding["reachability"],),
            context.fixture_policy,
        )
        actionability = derive_actionability(
            finding["affected_status"],
            runtime_scope,
            reachability,
            context.fixture_policy,
        )
        remediation = derive_remediation(
            actionability["value"],
            finding["installed_version"],
            list(derived.remediation_candidates_by_finding[source_key]),
            lambda left, right: compare_versions(snapshot.ecosystem, left, right),
            context.fixture_policy,
        )
        selected_source_key = remediation["selected_source_key"]
        selected_option_id = (
            None
            if selected_source_key is None
            else materialization.bindings.option_id(source_key, selected_source_key)
        )
        queue_member = actionability["value"] == "actionable"
        labels.append(
            {
                "finding_id": finding_id,
                "actionability": actionability,
                "remediation": {
                    "disposition": remediation["disposition"],
                    "selected_option_id": selected_option_id,
                    "target_class": remediation["target_class"],
                },
                "queue": {
                    "member": queue_member,
                    "target_class": actionability["target_class"],
                    "grade": finding_grade(
                        finding,
                        queue_member,
                        context.ranking_policy,
                    ),
                },
                "evidence_reference_ids": expected_evidence_reference_ids(
                    finding_id,
                    materialization.task["evidence_references"],
                    context.fixture_policy,
                ),
            }
        )
    return {
        "schema_version": 1,
        "fixture_id": snapshot.fixture_id,
        "task_id": derived.source["task_id"],
        "expected_verdict": (
            "action_required" if any(label["queue"]["member"] for label in labels) else "no_action"
        ),
        "findings": sorted(labels, key=lambda item: item["finding_id"]),
        "injection_markers": _derive_injection_markers(
            materialization.task,
            injection_phrases,
        ),
    }


def _build_corpus_receipt(
    fixtures: tuple[_VerifiedFixture, ...],
    context: _AuthoringContext,
) -> dict[str, Any]:
    authored = tuple(item.authored for item in fixtures)
    _require_exact_fixture_set(authored)
    families = {fixture.snapshot.fixture_id: fixture.family_fingerprint for fixture in authored}
    pair_checks = family_pair_checks(families, context.fixture_policy)
    expected_pair_count = len(authored) * (len(authored) - 1) // 2
    if len(pair_checks) != expected_pair_count:
        raise CorpusAuthoringError("family isolation did not check every fixture pair")
    cross_split_checks = [
        check
        for check in pair_checks
        if families[check["left_fixture_id"]].split != families[check["right_fixture_id"]].split
    ]
    expected_cross_split_count = sum(
        left_count * right_count
        for left_count, right_count in combinations(_EXPECTED_SPLIT_COUNTS.values(), 2)
    )
    if len(cross_split_checks) != expected_cross_split_count:
        raise CorpusAuthoringError("cross-split isolation did not check every split pair")
    coverage, violations = evaluate_corpus_coverage(
        tuple(
            CorpusCoverageFixture(source=item.authored.source, gold=item.authored.gold)
            for item in fixtures
        ),
        context.fixture_policy,
        context.target_classes,
        _EXPECTED_SPLIT_COUNTS,
    )
    if violations:
        raise CorpusAuthoringError("; ".join(violations))

    advisory_receipt = semantic_receipt(load_frozen_advisories(context.source_root))
    return {
        "schema_version": 1,
        "protocol": {
            "version": _PROTOCOL_VERSION,
            "bytes_sha256": _file_sha256(context.repository_root / _PROTOCOL_PATH),
        },
        "contract_digests": {
            "fixture_policy_bytes_sha256": _file_sha256(
                context.benchmark_root / "contracts/fixture-policy.json"
            ),
            "ranking_policy_bytes_sha256": _file_sha256(
                context.benchmark_root / "contracts/ranking-policy.json"
            ),
            "target_classes_bytes_sha256": _file_sha256(
                context.benchmark_root / "contracts/target-classes.json"
            ),
        },
        "source_catalog_digests": {
            "source_index_bytes_sha256": _file_sha256(context.source_root / "index.json"),
            "provenance_bytes_sha256": _file_sha256(context.source_root / "provenance.json"),
            "advisory_semantic_receipt_canonical_sha256": canonical_sha256(advisory_receipt),
        },
        "split_quotas": dict(_EXPECTED_SPLIT_COUNTS),
        "coverage": coverage,
        "fixtures": [_fixture_receipt(fixture) for fixture in fixtures],
        "family_separation": {
            "pair_count": expected_pair_count,
            "pair_set_canonical_sha256": canonical_sha256(pair_checks),
            "cross_split_pair_count": expected_cross_split_count,
            "cross_split_pair_set_canonical_sha256": canonical_sha256(cross_split_checks),
            "violations": [],
        },
    }


def _load_context(benchmark_root: Path) -> _AuthoringContext:
    root = benchmark_root.resolve()
    repository_root = next(
        (parent for parent in root.parents if (parent / "Package.swift").is_file()),
        None,
    )
    if repository_root is None:
        raise CorpusAuthoringError("benchmark root is not inside the repository layout")
    protocol_path = repository_root / _PROTOCOL_PATH
    _require_approved_bytes(
        protocol_path,
        _PROTOCOL_BYTES_SHA256,
        "protocol",
    )
    ranking_policy_path = root / "contracts/ranking-policy.json"
    _require_approved_bytes(
        ranking_policy_path,
        _RANKING_POLICY_BYTES_SHA256,
        "D5 ranking policy",
    )
    fixture_policy = load_object(root / "contracts/fixture-policy.json")
    ranking_policy = load_object(ranking_policy_path)
    target_contract = load_object(root / "contracts/target-classes.json")
    validate_fixture_policy(fixture_policy)
    validate_ranking_policy(ranking_policy)
    target_classes = target_contract.get("target_class_order")
    if target_classes != list(_TARGET_CLASSES):
        raise CorpusAuthoringError("target-class order differs from the frozen contract")
    return _AuthoringContext(
        benchmark_root=root,
        repository_root=repository_root,
        source_root=root / "sources",
        fixture_policy=fixture_policy,
        ranking_policy=ranking_policy,
        target_classes=tuple(target_classes),
    )


def _require_approved_bytes(path: Path, expected_sha256: str, artifact: str) -> None:
    if not path.is_file() or _file_sha256(path) != expected_sha256:
        raise CorpusAuthoringError(f"{artifact} bytes differ from the owner-approved contract")


def _canonical_phrases(value: list[str]) -> list[str]:
    if (
        not isinstance(value, list)
        or any(not isinstance(phrase, str) or not phrase for phrase in value)
        or len(value) != len(set(value))
    ):
        raise CorpusAuthoringError("injection phrases are malformed")
    return sorted(value)


def _derive_injection_markers(
    task: dict[str, Any],
    phrases: list[str],
) -> dict[str, list[str]]:
    tokens = {
        token
        for reference in task["evidence_references"]
        for token in re.findall(r"[A-Za-z0-9-]+", reference["snippet"])
    }
    markers = {
        "task_ids": sorted(token for token in tokens if TASK_ID.fullmatch(token)),
        "finding_ids": sorted(
            token for token in tokens if CANONICAL_IDS["finding"].fullmatch(token)
        ),
        "option_ids": sorted(token for token in tokens if CANONICAL_IDS["option"].fullmatch(token)),
        "evidence_reference_ids": sorted(
            token for token in tokens if CANONICAL_IDS["evidence"].fullmatch(token)
        ),
        "phrases": phrases,
    }
    if set(markers) != _INJECTION_MARKER_FIELDS:
        raise CorpusAuthoringError("derived injection markers have the wrong shape")
    return markers


def _checked_injection_phrases(gold: dict[str, Any]) -> list[str]:
    markers = gold.get("injection_markers")
    if not isinstance(markers, dict):
        raise CorpusAuthoringError("checked-in gold has no injection-marker mapping")
    phrases = markers.get("phrases")
    if not isinstance(phrases, list):
        raise CorpusAuthoringError("checked-in gold has malformed injection phrases")
    return _canonical_phrases(phrases)


def _expected_fixture_ids() -> tuple[str, ...]:
    return tuple(
        f"dp-{split}-{index:02d}"
        for split, count in _EXPECTED_SPLIT_COUNTS.items()
        for index in range(1, count + 1)
    )


def _require_exact_fixture_set(fixtures: tuple[AuthoredFixture, ...]) -> None:
    fixture_ids = [fixture.snapshot.fixture_id for fixture in fixtures]
    if len(fixture_ids) != len(set(fixture_ids)):
        raise CorpusAuthoringError("corpus fixture ids must be unique")
    if set(fixture_ids) != set(_expected_fixture_ids()):
        raise CorpusAuthoringError("corpus must contain the exact frozen 10/4/6 fixture set")
    observed = Counter(fixture.snapshot.split for fixture in fixtures)
    if dict(observed) != _EXPECTED_SPLIT_COUNTS:
        raise CorpusAuthoringError("corpus split labels differ from the frozen 10/4/6 quota")


def _require_closed_layout(corpus_root: Path, fixture_ids: tuple[str, ...]) -> None:
    expected: set[Path] = set()
    for fixture_id in fixture_ids:
        split = fixture_id.removeprefix("dp-").rsplit("-", 1)[0]
        expected.update(
            {
                Path(_PROJECTS_DIRECTORY) / split / f"{fixture_id}.project.json",
                Path(_FIXTURES_DIRECTORY) / split / f"{fixture_id}.source.json",
                Path(_GOLD_DIRECTORY) / split / f"{fixture_id}.gold.json",
            }
        )
    actual: set[Path] = set()
    if corpus_root.is_symlink():
        raise CorpusAuthoringError("corpus root must not be a symlink")
    for path in corpus_root.rglob("*"):
        if path.is_symlink():
            raise CorpusAuthoringError("corpus paths must not contain symlinks")
        if path.is_file():
            actual.add(path.relative_to(corpus_root))
    allowed = expected | {Path(_RECEIPT_NAME)}
    if not expected.issubset(actual) or not actual.issubset(allowed):
        raise CorpusAuthoringError("corpus layout differs from the frozen artifact set")


def _load_canonical_artifact(path: Path, corpus_root: Path) -> tuple[dict[str, Any], bytes]:
    if not path.is_relative_to(corpus_root) or path.is_symlink() or not path.is_file():
        raise CorpusAuthoringError("corpus artifact path is unavailable or outside its root")
    raw = path.read_bytes()
    try:
        value = loads_object(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise CorpusAuthoringError(f"corpus artifact is not strict JSON: {path.name}") from error
    if raw != dumps(value).encode("utf-8"):
        raise CorpusAuthoringError(f"corpus artifact is not canonical JSON: {path.name}")
    return value, raw


def _fixture_receipt(fixture: _VerifiedFixture) -> dict[str, Any]:
    authored = fixture.authored
    return {
        "fixture_id": authored.snapshot.fixture_id,
        "split": authored.snapshot.split,
        "family_id": authored.snapshot.family_id,
        "task_id": authored.source["task_id"],
        "selected_record_ids": list(authored.selected_record_ids),
        "project_snapshot_bytes_sha256": fixture.project_bytes_sha256,
        "project_snapshot_semantic_sha256": authored.snapshot.semantic_sha256,
        "normalized_source_bytes_sha256": fixture.source_bytes_sha256,
        "gold_bytes_sha256": fixture.gold_bytes_sha256,
        "materialized_task_canonical_sha256": canonical_sha256(materialize(authored.source).task),
        "family_fingerprint_canonical_sha256": canonical_sha256(
            _family_fingerprint_value(authored.family_fingerprint)
        ),
    }


def _family_fingerprint_value(value: FixtureFamilyFingerprint) -> dict[str, Any]:
    return {
        "split": value.split,
        "project_packages": sorted(value.project_packages),
        "record_alias_components": sorted(value.record_alias_components),
        "graph_template_ids": sorted(value.graph_template_ids),
        "graph_template_digests": sorted(value.graph_template_digests),
        "generator_seeds": sorted(value.generator_seeds),
        "manifest_digests": sorted(value.manifest_digests),
    }


def _file_sha256(path: Path) -> str:
    return _sha256(path.read_bytes())


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()
