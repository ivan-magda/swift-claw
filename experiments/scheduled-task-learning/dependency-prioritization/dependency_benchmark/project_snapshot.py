"""Closed project snapshots and deterministic dependency-graph facts."""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass, replace
from functools import cmp_to_key
from pathlib import Path
from typing import Any, Literal

from benchmark_core.canonical import canonical_sha256, load_object
from benchmark_core.contract_validation import scalar_count

from .versioning import (
    Ecosystem,
    VersioningError,
    canonical_package_name,
    canonical_requirement,
    canonical_version,
    compare_versions,
    satisfies_requirement,
)

Split = Literal["development", "regression", "sealed"]
RuntimeScope = Literal["development_only", "production"]
Reachability = Literal["unreachable", "unknown", "reachable"]
Availability = Literal["available", "unavailable"]

_SOURCE_KEY = re.compile(r"^[a-z0-9-]{1,64}$")
_FAMILY_ID = re.compile(r"^[a-z0-9-]{3,64}$")
_FIXTURE_ID = re.compile(r"^dp-(development|regression|sealed)-[0-9]{2}$")
_DIRECT_PATH_NODE_COUNT = 2
_MAX_PACKAGE_CHAIN_ITEM_SCALARS = 128
_MAX_PATH_NODES = 12
_MAX_PATHS_PER_FINDING = 8


class ProjectSnapshotError(ValueError):
    """Raised when a frozen project snapshot is ambiguous or unsupported."""


@dataclass(frozen=True, slots=True)
class PackageNode:
    node_key: str
    package_name: str
    installed_version: str


@dataclass(frozen=True, slots=True)
class RootDependency:
    child_node_key: str
    requirement: str
    runtime_scope: RuntimeScope


@dataclass(frozen=True, slots=True)
class DependencyEdge:
    parent_node_key: str
    child_node_key: str
    requirement: str


@dataclass(frozen=True, slots=True)
class FindingFact:
    node_key: str
    reachability: Reachability
    manifest_evidence: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Release:
    version: str
    availability: Availability


@dataclass(frozen=True, slots=True)
class ReleaseInventory:
    package_name: str
    releases: tuple[Release, ...]


@dataclass(frozen=True, slots=True)
class ProjectSnapshot:
    fixture_id: str
    split: Split
    family_id: str
    ecosystem: Ecosystem
    graph_template_id: str
    generator_seed: str
    root: PackageNode
    dependencies: tuple[PackageNode, ...]
    root_dependencies: tuple[RootDependency, ...]
    dependency_edges: tuple[DependencyEdge, ...]
    finding_facts: tuple[FindingFact, ...]
    release_inventories: tuple[ReleaseInventory, ...]
    semantic_sha256: str


@dataclass(frozen=True, slots=True)
class DependencyPath:
    node_keys: tuple[str, ...]
    package_chain: tuple[str, ...]
    relationship: Literal["direct", "transitive"]
    runtime_scope: RuntimeScope


def load_project_snapshot(
    path: Path,
    snapshot_root: Path | None = None,
) -> ProjectSnapshot:
    """Load one strict JSON project snapshot."""

    declared_root = snapshot_root or path.parent
    if ".." in path.parts or ".." in declared_root.parts:
        raise ProjectSnapshotError("project snapshot escapes its declared root")
    target = path.absolute()
    root = declared_root.absolute()
    try:
        target.relative_to(root)
    except ValueError as error:
        raise ProjectSnapshotError("project snapshot escapes its declared root") from error
    candidate = target
    while True:
        if candidate.is_symlink():
            raise ProjectSnapshotError("project snapshot path must not contain symlinks")
        if candidate == root:
            break
        parent = candidate.parent
        if parent == candidate:
            raise ProjectSnapshotError("project snapshot escapes its declared root")
        candidate = parent
    try:
        resolved_root = root.resolve(strict=True)
        resolved_target = target.resolve(strict=True)
    except OSError as error:
        raise ProjectSnapshotError("project snapshot must be a regular file") from error
    if not resolved_target.is_relative_to(resolved_root):
        raise ProjectSnapshotError("project snapshot escapes its declared root")
    if not resolved_target.is_file():
        raise ProjectSnapshotError("project snapshot must be a regular file")
    try:
        value = load_object(resolved_target)
    except (OSError, ValueError) as error:
        raise ProjectSnapshotError("project snapshot could not be decoded strictly") from error
    return parse_project_snapshot(value)


def parse_project_snapshot(value: Mapping[str, Any]) -> ProjectSnapshot:
    """Parse, canonicalize, and validate one closed project snapshot."""

    root = _closed(
        value,
        {
            "schema_version",
            "fixture_id",
            "split",
            "family_id",
            "ecosystem",
            "graph_template_id",
            "generator_seed",
            "root",
            "dependencies",
            "root_dependencies",
            "dependency_edges",
            "finding_facts",
            "release_inventories",
        },
        "project snapshot",
    )
    if type(root["schema_version"]) is not int or root["schema_version"] != 1:
        raise ProjectSnapshotError("project snapshot schema version is unsupported")
    fixture_id = _bounded_text(root["fixture_id"], 1, 32, "fixture id", _FIXTURE_ID)
    split = _choice(root["split"], ("development", "regression", "sealed"), "split")
    if not fixture_id.startswith(f"dp-{split}-"):
        raise ProjectSnapshotError("fixture id does not encode its split")
    family_id = _bounded_text(root["family_id"], 3, 64, "family id", _FAMILY_ID)
    ecosystem = _choice(root["ecosystem"], ("npm", "pypi"), "ecosystem")
    graph_template_id = _bounded_text(
        root["graph_template_id"], 1, 64, "graph template id", _SOURCE_KEY
    )
    generator_seed = _bounded_text(root["generator_seed"], 1, 64, "generator seed", _SOURCE_KEY)
    try:
        root_node = _package_node(root["root"], ecosystem, "root")
        dependencies = tuple(
            sorted(
                (
                    _package_node(item, ecosystem, "dependency")
                    for item in _bounded_array(root["dependencies"], 1, 24, "dependencies")
                ),
                key=lambda item: item.node_key,
            )
        )
        root_dependencies = tuple(
            sorted(
                (
                    _root_dependency(item, ecosystem)
                    for item in _bounded_array(
                        root["root_dependencies"], 1, 12, "root dependencies"
                    )
                ),
                key=lambda item: (item.child_node_key, item.runtime_scope, item.requirement),
            )
        )
        dependency_edges = tuple(
            sorted(
                (
                    _dependency_edge(item, ecosystem)
                    for item in _bounded_array(root["dependency_edges"], 0, 48, "dependency edges")
                ),
                key=lambda item: (
                    item.parent_node_key,
                    item.child_node_key,
                    item.requirement,
                ),
            )
        )
        finding_facts = tuple(
            sorted(
                (
                    _finding_fact(item)
                    for item in _bounded_array(root["finding_facts"], 1, 12, "finding facts")
                ),
                key=lambda item: item.node_key,
            )
        )
        release_inventories = tuple(
            sorted(
                (
                    _release_inventory(item, ecosystem)
                    for item in _bounded_array(
                        root["release_inventories"], 1, 12, "release inventories"
                    )
                ),
                key=lambda item: item.package_name,
            )
        )
    except VersioningError as error:
        raise ProjectSnapshotError("project snapshot contains invalid version facts") from error

    snapshot = ProjectSnapshot(
        fixture_id=fixture_id,
        split=split,
        family_id=family_id,
        ecosystem=ecosystem,
        graph_template_id=graph_template_id,
        generator_seed=generator_seed,
        root=root_node,
        dependencies=dependencies,
        root_dependencies=root_dependencies,
        dependency_edges=dependency_edges,
        finding_facts=finding_facts,
        release_inventories=release_inventories,
        semantic_sha256="",
    )
    _validate_snapshot(snapshot)
    snapshot = replace(snapshot, semantic_sha256=canonical_sha256(_semantic_value(snapshot)))
    dependency_paths(snapshot)
    return snapshot


def dependency_paths(snapshot: ProjectSnapshot) -> Mapping[str, tuple[DependencyPath, ...]]:
    """Return every bounded simple root-to-dependency path."""

    nodes = {node.node_key: node for node in (snapshot.root, *snapshot.dependencies)}
    outgoing: dict[str, list[tuple[str, RuntimeScope | None]]] = {key: [] for key in nodes}
    for dependency in snapshot.root_dependencies:
        outgoing[snapshot.root.node_key].append(
            (dependency.child_node_key, dependency.runtime_scope)
        )
    for edge in snapshot.dependency_edges:
        outgoing[edge.parent_node_key].append((edge.child_node_key, None))
    for edges in outgoing.values():
        edges.sort()

    result: dict[str, list[DependencyPath]] = {node.node_key: [] for node in snapshot.dependencies}
    finding_node_keys = {fact.node_key for fact in snapshot.finding_facts}

    def walk(current: str, path: tuple[str, ...], scope: RuntimeScope | None) -> None:
        for child, root_scope in outgoing[current]:
            if child in path:
                raise ProjectSnapshotError("dependency graph contains a cycle")
            child_scope = root_scope if scope is None else scope
            if child_scope is None:
                raise ProjectSnapshotError("dependency path has no root runtime scope")
            child_path = (*path, child)
            if len(child_path) > _MAX_PATH_NODES:
                raise ProjectSnapshotError("dependency path exceeds the canonical chain limit")
            package_chain = tuple(
                _package_coordinate(snapshot.ecosystem, nodes[key]) for key in child_path
            )
            if any(scalar_count(item) > _MAX_PACKAGE_CHAIN_ITEM_SCALARS for item in package_chain):
                raise ProjectSnapshotError("dependency package coordinate exceeds the chain limit")
            paths = result[child]
            paths.append(
                DependencyPath(
                    node_keys=child_path,
                    package_chain=package_chain,
                    relationship=(
                        "direct" if len(child_path) == _DIRECT_PATH_NODE_COUNT else "transitive"
                    ),
                    runtime_scope=child_scope,
                )
            )
            if child in finding_node_keys and len(paths) > _MAX_PATHS_PER_FINDING:
                raise ProjectSnapshotError("dependency has more than eight root paths")
            walk(child, child_path, child_scope)

    walk(snapshot.root.node_key, (snapshot.root.node_key,), None)
    if any(not paths for paths in result.values()):
        raise ProjectSnapshotError("every dependency node must be reachable from the root")
    return {
        node_key: tuple(sorted(paths, key=lambda item: (item.node_keys, item.runtime_scope)))
        for node_key, paths in sorted(result.items())
    }


def incoming_requirements(snapshot: ProjectSnapshot, node_key: str) -> tuple[str, ...]:
    """Return every canonical constraint whose edge targets one dependency node."""

    dependency_keys = {node.node_key for node in snapshot.dependencies}
    if node_key not in dependency_keys:
        raise ProjectSnapshotError("incoming requirements need a dependency node key")
    requirements = [
        edge.requirement for edge in snapshot.root_dependencies if edge.child_node_key == node_key
    ]
    requirements.extend(
        edge.requirement for edge in snapshot.dependency_edges if edge.child_node_key == node_key
    )
    if not requirements:
        raise ProjectSnapshotError("dependency node has no incoming requirement")
    return tuple(sorted(requirements))


def _package_node(value: Any, ecosystem: Ecosystem, label: str) -> PackageNode:
    item = _closed(value, {"node_key", "package_name", "installed_version"}, label)
    return PackageNode(
        node_key=_bounded_text(item["node_key"], 1, 64, f"{label} node key", _SOURCE_KEY),
        package_name=canonical_package_name(
            ecosystem,
            _bounded_text(item["package_name"], 1, 128, f"{label} package name"),
        ),
        installed_version=canonical_version(
            ecosystem,
            _bounded_text(item["installed_version"], 1, 64, f"{label} installed version"),
        ),
    )


def _root_dependency(value: Any, ecosystem: Ecosystem) -> RootDependency:
    item = _closed(
        value,
        {"child_node_key", "requirement", "runtime_scope"},
        "root dependency",
    )
    return RootDependency(
        child_node_key=_bounded_text(
            item["child_node_key"], 1, 64, "root dependency child", _SOURCE_KEY
        ),
        requirement=canonical_requirement(
            ecosystem,
            _bounded_text(item["requirement"], 1, 128, "root dependency requirement"),
        ),
        runtime_scope=_choice(
            item["runtime_scope"],
            ("development_only", "production"),
            "root dependency runtime scope",
        ),
    )


def _dependency_edge(value: Any, ecosystem: Ecosystem) -> DependencyEdge:
    item = _closed(
        value,
        {"parent_node_key", "child_node_key", "requirement"},
        "dependency edge",
    )
    return DependencyEdge(
        parent_node_key=_bounded_text(item["parent_node_key"], 1, 64, "edge parent", _SOURCE_KEY),
        child_node_key=_bounded_text(item["child_node_key"], 1, 64, "edge child", _SOURCE_KEY),
        requirement=canonical_requirement(
            ecosystem,
            _bounded_text(item["requirement"], 1, 128, "edge requirement"),
        ),
    )


def _finding_fact(value: Any) -> FindingFact:
    item = _closed(
        value,
        {"node_key", "reachability", "manifest_evidence"},
        "finding fact",
    )
    evidence = tuple(
        sorted(
            _bounded_text(snippet, 1, 600, "manifest evidence")
            for snippet in _bounded_array(item["manifest_evidence"], 0, 4, "manifest evidence")
        )
    )
    if len(evidence) != len(set(evidence)):
        raise ProjectSnapshotError("manifest evidence must not contain duplicates")
    return FindingFact(
        node_key=_bounded_text(item["node_key"], 1, 64, "finding node key", _SOURCE_KEY),
        reachability=_choice(
            item["reachability"],
            ("unreachable", "unknown", "reachable"),
            "finding reachability",
        ),
        manifest_evidence=evidence,
    )


def _release_inventory(value: Any, ecosystem: Ecosystem) -> ReleaseInventory:
    item = _closed(value, {"package_name", "releases"}, "release inventory")
    package_name = canonical_package_name(
        ecosystem,
        _bounded_text(item["package_name"], 1, 128, "inventory package name"),
    )
    releases = [
        _release(entry, ecosystem)
        for entry in _bounded_array(item["releases"], 0, 8, "inventory releases")
    ]

    def compare(left: Release, right: Release) -> int:
        version_order = compare_versions(ecosystem, left.version, right.version)
        if version_order != 0:
            return version_order
        if left.version != right.version:
            return (left.version > right.version) - (left.version < right.version)
        return (left.availability > right.availability) - (left.availability < right.availability)

    ordered = tuple(sorted(releases, key=cmp_to_key(compare)))
    versions = [release.version for release in ordered]
    if len(versions) != len(set(versions)):
        raise ProjectSnapshotError("release inventory contains duplicate canonical versions")
    return ReleaseInventory(package_name=package_name, releases=ordered)


def _release(value: Any, ecosystem: Ecosystem) -> Release:
    item = _closed(value, {"version", "availability"}, "release")
    return Release(
        version=canonical_version(
            ecosystem,
            _bounded_text(item["version"], 1, 64, "release version"),
        ),
        availability=_choice(
            item["availability"],
            ("available", "unavailable"),
            "release availability",
        ),
    )


def _validate_snapshot(snapshot: ProjectSnapshot) -> None:
    nodes = (snapshot.root, *snapshot.dependencies)
    node_keys = [node.node_key for node in nodes]
    if len(node_keys) != len(set(node_keys)):
        raise ProjectSnapshotError("package node keys must be unique")
    coordinates = [_package_coordinate(snapshot.ecosystem, node) for node in nodes]
    if len(coordinates) != len(set(coordinates)):
        raise ProjectSnapshotError("package node coordinates must be unique")
    dependency_keys = {node.node_key for node in snapshot.dependencies}
    root_pairs = [edge.child_node_key for edge in snapshot.root_dependencies]
    if len(root_pairs) != len(set(root_pairs)) or not set(root_pairs).issubset(dependency_keys):
        raise ProjectSnapshotError("root dependencies must target unique dependency nodes")
    edge_pairs = [(edge.parent_node_key, edge.child_node_key) for edge in snapshot.dependency_edges]
    if len(edge_pairs) != len(set(edge_pairs)):
        raise ProjectSnapshotError("dependency graph edges must be unique")
    for parent, child in edge_pairs:
        if parent == child or parent not in dependency_keys or child not in dependency_keys:
            raise ProjectSnapshotError("dependency edge has an invalid endpoint")
    fact_keys = [fact.node_key for fact in snapshot.finding_facts]
    if len(fact_keys) != len(set(fact_keys)) or not set(fact_keys).issubset(dependency_keys):
        raise ProjectSnapshotError("finding facts must target unique dependency nodes")
    inventory_packages = [item.package_name for item in snapshot.release_inventories]
    if len(inventory_packages) != len(set(inventory_packages)):
        raise ProjectSnapshotError("release inventory package names must be unique")

    by_key = {node.node_key: node for node in snapshot.dependencies}
    for node_key, node in by_key.items():
        requirements = incoming_requirements(snapshot, node_key)
        if not all(
            satisfies_requirement(snapshot.ecosystem, node.installed_version, requirement)
            for requirement in requirements
        ):
            raise ProjectSnapshotError("installed version violates an incoming requirement")


def _semantic_value(snapshot: ProjectSnapshot) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "fixture_id": snapshot.fixture_id,
        "split": snapshot.split,
        "family_id": snapshot.family_id,
        "ecosystem": snapshot.ecosystem,
        "graph_template_id": snapshot.graph_template_id,
        "generator_seed": snapshot.generator_seed,
        "root": _node_value(snapshot.root),
        "dependencies": [_node_value(node) for node in snapshot.dependencies],
        "root_dependencies": [
            {
                "child_node_key": edge.child_node_key,
                "requirement": edge.requirement,
                "runtime_scope": edge.runtime_scope,
            }
            for edge in snapshot.root_dependencies
        ],
        "dependency_edges": [
            {
                "parent_node_key": edge.parent_node_key,
                "child_node_key": edge.child_node_key,
                "requirement": edge.requirement,
            }
            for edge in snapshot.dependency_edges
        ],
        "finding_facts": [
            {
                "node_key": fact.node_key,
                "reachability": fact.reachability,
                "manifest_evidence": list(fact.manifest_evidence),
            }
            for fact in snapshot.finding_facts
        ],
        "release_inventories": [
            {
                "package_name": inventory.package_name,
                "releases": [
                    {"version": release.version, "availability": release.availability}
                    for release in inventory.releases
                ],
            }
            for inventory in snapshot.release_inventories
        ],
    }


def _node_value(node: PackageNode) -> dict[str, str]:
    return {
        "node_key": node.node_key,
        "package_name": node.package_name,
        "installed_version": node.installed_version,
    }


def _package_coordinate(ecosystem: Ecosystem, node: PackageNode) -> str:
    return f"{ecosystem}:{node.package_name}@{node.installed_version}"


def _closed(value: Any, keys: set[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping) or set(value) != keys:
        raise ProjectSnapshotError(f"{label} has the wrong shape")
    return value


def _bounded_array(value: Any, minimum: int, maximum: int, label: str) -> list[Any]:
    if not isinstance(value, list) or not minimum <= len(value) <= maximum:
        raise ProjectSnapshotError(f"{label} must contain {minimum}..{maximum} items")
    return value


def _bounded_text(
    value: Any,
    minimum: int,
    maximum: int,
    label: str,
    pattern: re.Pattern[str] | None = None,
) -> str:
    if not isinstance(value, str) or not minimum <= scalar_count(value) <= maximum:
        raise ProjectSnapshotError(f"{label} must contain {minimum}..{maximum} Unicode scalars")
    if pattern is not None and pattern.fullmatch(value) is None:
        raise ProjectSnapshotError(f"{label} has an invalid format")
    return value


def _choice(value: Any, choices: tuple[str, ...], label: str) -> Any:
    if not isinstance(value, str) or value not in choices:
        raise ProjectSnapshotError(f"{label} is outside its closed enum")
    return value
