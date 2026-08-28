"""Derive normalized dependency facts from frozen projects and advisories."""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from functools import cmp_to_key
from pathlib import Path
from typing import Any

from benchmark_core.canonical import canonical_sha256

from .advisory_records import (
    AdvisoryComponent,
    AdvisoryRecord,
    alias_components,
    fixed_versions,
    fixture_record_ids,
    load_frozen_advisories,
    record_affects,
)
from .fixture_policy import (
    FixtureFamilyFingerprint,
    RemediationCandidate,
    graph_template_digest,
    manifest_structure_digest,
)
from .normalization import materialize_task
from .policy import is_safe_remediation_option
from .project_snapshot import (
    FindingFact,
    PackageNode,
    ProjectSnapshot,
    ReleaseInventory,
    dependency_paths,
    incoming_requirements,
)
from .validation import (
    MAX_EVIDENCE_PER_FINDING,
    MAX_FINDINGS,
    MAX_OPTIONS_PER_FINDING,
)
from .versioning import compare_versions, satisfies_requirement

_RELEASE_INVENTORY_ORIGIN = "release-inventory"


class DependencyDerivationError(ValueError):
    """Raised when frozen source facts cannot produce one unambiguous task."""


@dataclass(frozen=True, slots=True)
class DerivedSource:
    source: dict[str, Any]
    family_fingerprint: FixtureFamilyFingerprint
    snapshot_sha256: str
    selected_record_ids: tuple[str, ...]
    remediation_candidates_by_finding: Mapping[
        str,
        tuple[RemediationCandidate, ...],
    ]


def derive_normalized_source(
    snapshot: ProjectSnapshot,
    source_root: Path,
) -> DerivedSource:
    """Join one project snapshot with its authenticated frozen advisory allocation."""

    return _derive_normalized_source(
        snapshot,
        load_frozen_advisories(source_root),
        fixture_record_ids(source_root, snapshot.fixture_id, snapshot.split),
    )


def _derive_normalized_source(
    snapshot: ProjectSnapshot,
    records: Iterable[AdvisoryRecord],
    selected_record_ids: Iterable[str],
) -> DerivedSource:

    ordered_records = tuple(sorted(records, key=lambda record: record.record_id))
    record_by_id = {record.record_id: record for record in ordered_records}
    if len(record_by_id) != len(ordered_records):
        raise DependencyDerivationError("advisory record ids must be unique")
    selected_ids = tuple(sorted(selected_record_ids))
    if not selected_ids or len(selected_ids) != len(set(selected_ids)):
        raise DependencyDerivationError("selected advisory record ids must be non-empty and unique")
    if not set(selected_ids).issubset(record_by_id):
        raise DependencyDerivationError("selected advisory record is unavailable")

    selected_components = _selected_components(ordered_records, selected_ids)
    if any(component.ecosystem != snapshot.ecosystem for component in selected_components):
        raise DependencyDerivationError("selected advisory ecosystem differs from the project")
    selected_packages = {component.package_name for component in selected_components}
    if snapshot.root.package_name in selected_packages:
        raise DependencyDerivationError("the project root cannot be a benchmark finding")

    facts = {fact.node_key: fact for fact in snapshot.finding_facts}
    target_nodes = tuple(
        node for node in snapshot.dependencies if node.package_name in selected_packages
    )
    if {node.package_name for node in target_nodes} != selected_packages:
        raise DependencyDerivationError(
            "selected-advisory packages must all exist in the project dependency graph"
        )
    if set(facts) != {node.node_key for node in target_nodes}:
        raise DependencyDerivationError(
            "finding facts must exactly match selected-advisory dependency nodes"
        )
    inventories = {inventory.package_name: inventory for inventory in snapshot.release_inventories}
    if set(inventories) != selected_packages:
        raise DependencyDerivationError(
            "release inventories must exactly match selected advisory packages"
        )

    paths_by_node = dependency_paths(snapshot)
    findings: list[dict[str, Any]] = []
    candidates_by_finding: dict[str, tuple[RemediationCandidate, ...]] = {}
    for component in selected_components:
        component_records = tuple(record_by_id[record_id] for record_id in component.record_ids)
        for node in target_nodes:
            if node.package_name == component.package_name:
                finding, candidates = _derive_finding(
                    snapshot,
                    node,
                    facts[node.node_key],
                    inventories[node.package_name],
                    component,
                    component_records,
                    paths_by_node[node.node_key],
                )
                findings.append(finding)
                candidates_by_finding[finding["source_key"]] = candidates
    if len(findings) > MAX_FINDINGS:
        raise DependencyDerivationError("derived source exceeds the canonical finding limit")

    task_id = _task_id(snapshot, (record_by_id[record_id] for record_id in selected_ids))
    source = {
        "schema_version": 1,
        "fixture_id": snapshot.fixture_id,
        "task_id": task_id,
        "family_id": snapshot.family_id,
        "split": snapshot.split,
        "normalized_findings": sorted(findings, key=lambda item: item["source_key"]),
    }
    task = materialize_task(source)
    return DerivedSource(
        source=source,
        family_fingerprint=_family_fingerprint(
            snapshot,
            selected_components,
            task,
        ),
        snapshot_sha256=snapshot.semantic_sha256,
        selected_record_ids=selected_ids,
        remediation_candidates_by_finding=dict(sorted(candidates_by_finding.items())),
    )


def _selected_components(
    records: tuple[AdvisoryRecord, ...],
    selected_ids: tuple[str, ...],
) -> tuple[AdvisoryComponent, ...]:
    selected = set(selected_ids)
    result: list[AdvisoryComponent] = []
    covered: set[str] = set()
    for component in alias_components(records):
        component_ids = set(component.record_ids)
        if component_ids.isdisjoint(selected):
            continue
        if not component_ids.issubset(selected):
            raise DependencyDerivationError("advisory selection splits an alias component")
        covered.update(component_ids)
        result.append(component)
    if covered != selected:
        raise DependencyDerivationError("advisory selection does not resolve to alias components")
    return tuple(result)


def _derive_finding(
    snapshot: ProjectSnapshot,
    node: PackageNode,
    fact: FindingFact,
    inventory: ReleaseInventory,
    component: AdvisoryComponent,
    records: tuple[AdvisoryRecord, ...],
    paths: tuple[Any, ...],
) -> tuple[dict[str, Any], tuple[RemediationCandidate, ...]]:
    finding_key = _source_key(
        "finding-source",
        {
            "component_record_ids": list(component.record_ids),
            "package": node.package_name,
            "installed_version": node.installed_version,
        },
    )
    affected = any(record_affects(record, node.installed_version) for record in records)
    derived_paths = [
        {
            "source_key": _source_key(
                "path-source",
                {
                    "finding_source_key": finding_key,
                    "package_chain": list(path.package_chain),
                    "relationship": path.relationship,
                    "runtime_scope": path.runtime_scope,
                },
            ),
            "package_chain": list(path.package_chain),
            "relationship": path.relationship,
            "runtime_scope": path.runtime_scope,
        }
        for path in paths
    ]
    options, candidates = _remediation_options(
        snapshot,
        node,
        finding_key,
        inventory,
        records,
    )
    evidence = _evidence_references(finding_key, fact, records)
    return (
        {
            "source_key": finding_key,
            "ecosystem": snapshot.ecosystem,
            "package_name": node.package_name,
            "installed_version": node.installed_version,
            "affected_status": "affected" if affected else "unaffected",
            "advisories": [
                {"advisory_id": record.record_id, "severity": record.severity} for record in records
            ],
            "reachability": fact.reachability,
            "dependency_paths": sorted(derived_paths, key=lambda item: item["source_key"]),
            "remediation_options": options,
            "evidence_references": evidence,
        },
        candidates,
    )


def _remediation_options(
    snapshot: ProjectSnapshot,
    node: PackageNode,
    finding_key: str,
    inventory: ReleaseInventory,
    records: tuple[AdvisoryRecord, ...],
) -> tuple[list[dict[str, str]], tuple[RemediationCandidate, ...]]:
    requirements = incoming_requirements(snapshot, node.node_key)
    candidates: list[RemediationCandidate] = []
    for record in records:
        for version in fixed_versions(record):
            candidates.append(
                _candidate(
                    snapshot,
                    finding_key,
                    version,
                    record.record_id,
                    "available",
                    records,
                    requirements,
                )
            )
    for release in inventory.releases:
        candidates.append(
            _candidate(
                snapshot,
                finding_key,
                release.version,
                _RELEASE_INVENTORY_ORIGIN,
                release.availability,
                records,
                requirements,
            )
        )

    def compare(left: RemediationCandidate, right: RemediationCandidate) -> int:
        version_order = compare_versions(
            snapshot.ecosystem,
            left["target_version"],
            right["target_version"],
        )
        if version_order != 0:
            return version_order
        left_tie = (left["origin_id"], left["source_key"])
        right_tie = (right["origin_id"], right["source_key"])
        return (left_tie > right_tie) - (left_tie < right_tie)

    ordered = sorted(candidates, key=cmp_to_key(compare))
    equivalent_groups: list[list[RemediationCandidate]] = []
    for candidate in ordered:
        if equivalent_groups and (
            compare_versions(
                snapshot.ecosystem,
                equivalent_groups[-1][-1]["target_version"],
                candidate["target_version"],
            )
            == 0
        ):
            equivalent_groups[-1].append(candidate)
        else:
            equivalent_groups.append([candidate])
    resolved = [
        next(
            (
                candidate
                for candidate in group
                if is_safe_remediation_option(candidate)
                and compare_versions(
                    snapshot.ecosystem,
                    candidate["target_version"],
                    node.installed_version,
                )
                > 0
            ),
            group[0],
        )
        for group in equivalent_groups
    ]
    if len(resolved) > MAX_OPTIONS_PER_FINDING:
        raise DependencyDerivationError("derived source exceeds the remediation-option limit")
    return (
        [
            {
                "source_key": candidate["source_key"],
                "target_version": candidate["target_version"],
                "availability": candidate["availability"],
                "affected_status": candidate["affected_status"],
                "compatibility": candidate["compatibility"],
            }
            for candidate in resolved
        ],
        tuple(ordered),
    )


def _candidate(
    snapshot: ProjectSnapshot,
    finding_key: str,
    version: str,
    origin_id: str,
    availability: str,
    records: tuple[AdvisoryRecord, ...],
    requirements: tuple[str, ...],
) -> RemediationCandidate:
    source_key = _source_key(
        "option-source",
        {
            "finding_source_key": finding_key,
            "origin_id": origin_id,
            "target_version": version,
        },
    )
    return {
        "target_version": version,
        "origin_id": origin_id,
        "source_key": source_key,
        "availability": availability,
        "affected_status": (
            "affected"
            if any(record_affects(record, version) for record in records)
            else "unaffected"
        ),
        "compatibility": (
            "compatible"
            if all(
                satisfies_requirement(snapshot.ecosystem, version, requirement)
                for requirement in requirements
            )
            else "incompatible"
        ),
    }


def _evidence_references(
    finding_key: str,
    fact: FindingFact,
    records: tuple[AdvisoryRecord, ...],
) -> list[dict[str, str]]:
    candidates = [
        (record.record_id, (record.summary or record.details)[:600]) for record in records
    ]
    candidates.extend(
        (f"manifest-{index:02d}", snippet)
        for index, snippet in enumerate(fact.manifest_evidence, start=1)
    )
    unique_snippets: dict[str, str] = {}
    for origin_id, snippet in candidates:
        unique_snippets.setdefault(snippet, origin_id)
    references = [
        {
            "source_key": _source_key(
                "evidence-source",
                {
                    "finding_source_key": finding_key,
                    "origin_id": origin_id,
                    "snippet": snippet,
                },
            ),
            "subject_type": "finding",
            "subject_key": finding_key,
            "snippet": snippet,
        }
        for snippet, origin_id in sorted(unique_snippets.items(), key=lambda item: item[1])
    ]
    if len(references) > MAX_EVIDENCE_PER_FINDING:
        raise DependencyDerivationError("derived source exceeds the evidence-reference limit")
    return sorted(references, key=lambda item: item["source_key"])


def _task_id(snapshot: ProjectSnapshot, records: Iterable[AdvisoryRecord]) -> str:
    payload = {
        "project_snapshot_sha256": snapshot.semantic_sha256,
        "advisory_sources": [
            {"record_id": record.record_id, "source_sha256": record.source_sha256}
            for record in sorted(records, key=lambda item: item.record_id)
        ],
    }
    return f"dependency-{canonical_sha256(payload)[:12]}"


def _family_fingerprint(
    snapshot: ProjectSnapshot,
    components: tuple[AdvisoryComponent, ...],
    task: dict[str, Any],
) -> FixtureFamilyFingerprint:
    return FixtureFamilyFingerprint(
        split=snapshot.split,
        project_packages=frozenset(
            f"{snapshot.ecosystem}:{node.package_name}"
            for node in (snapshot.root, *snapshot.dependencies)
        ),
        record_alias_components=frozenset(
            _source_key("alias-component", {"identities": list(component.identities)})
            for component in components
        ),
        graph_template_ids=frozenset({snapshot.graph_template_id}),
        graph_template_digests=frozenset({graph_template_digest(task)}),
        generator_seeds=frozenset({snapshot.generator_seed}),
        manifest_digests=frozenset({manifest_structure_digest(task)}),
    )


def _source_key(prefix: str, value: Any) -> str:
    return f"{prefix}-{canonical_sha256({'domain': prefix, 'value': value})[:12]}"
