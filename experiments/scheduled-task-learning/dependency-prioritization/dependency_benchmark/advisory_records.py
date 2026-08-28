"""Verified, deterministic decoding of the frozen OSV advisory snapshots."""

from __future__ import annotations

import hashlib
from collections import Counter
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from functools import cmp_to_key
from pathlib import Path
from typing import Any, Literal

from benchmark_core.canonical import SHA256_HEX, canonical_sha256, load_object, loads_object
from cvss.cvss3 import CVSS3
from cvss.cvss4 import CVSS4
from cvss.exceptions import CVSS3Error, CVSS4Error
from ruamel.yaml import YAML
from ruamel.yaml.error import YAMLError

from dependency_benchmark.versioning import (
    AffectedInterval,
    Ecosystem,
    VersioningError,
    canonical_package_name,
    canonical_version,
    compare_versions,
    is_version_affected,
    normalize_ecosystem,
    parse_osv_intervals,
    sort_versions,
)

SeverityBand = Literal["low", "moderate", "high", "critical"]

_LOW_MAX = 3.9
_MODERATE_MAX = 6.9
_HIGH_MAX = 8.9
_CRITICAL_MAX = 10.0


class AdvisorySourceError(ValueError):
    """Raised when a frozen source cannot produce unambiguous advisory facts."""


@dataclass(frozen=True, slots=True)
class CVSSVector:
    kind: Literal["CVSS_V3", "CVSS_V4"]
    vector: str
    base_score: float
    band: SeverityBand


@dataclass(frozen=True, slots=True)
class AdvisoryRecord:
    repository_id: str
    source_sha256: str
    source_bytes: int
    record_id: str
    aliases: tuple[str, ...]
    summary: str | None
    details: str
    ecosystem: Ecosystem
    package_name: str
    affected_entry_count: int
    intervals: tuple[AffectedInterval, ...]
    explicit_versions: tuple[str, ...]
    explicit_version_raw_count: int
    ignored_git_range_count: int
    cvss_vectors: tuple[CVSSVector, ...]
    severity: SeverityBand | None


@dataclass(frozen=True, slots=True)
class AdvisoryComponent:
    record_ids: tuple[str, ...]
    identities: tuple[str, ...]
    ecosystem: Ecosystem
    package_name: str
    severity: SeverityBand


@dataclass(frozen=True, slots=True)
class _VerifiedRecord:
    metadata: Mapping[str, Any]
    raw_text: str


_CatalogEntry = tuple[str, Mapping[str, Any], bool]


def _object(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AdvisorySourceError(f"{context} must be an object")
    return value


def _array(value: Any, context: str) -> list[Any]:
    if not isinstance(value, list):
        raise AdvisorySourceError(f"{context} must be an array")
    return value


def _text(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise AdvisorySourceError(f"{context} must be a non-empty string")
    return value


def _texts(value: Any, context: str) -> tuple[str, ...]:
    result = tuple(_text(item, f"{context} item") for item in _array(value, context))
    if len(result) != len(set(result)):
        raise AdvisorySourceError(f"{context} must not contain duplicates")
    return result


def _catalog_entries(
    root: Path,
) -> tuple[Mapping[str, Any], Path, frozenset[str], tuple[_CatalogEntry, ...]]:
    index_path = root / "index.json"
    if index_path.is_symlink():
        raise AdvisorySourceError("source catalogs must not be symlinks")
    index = load_object(index_path)
    if set(index) != {"schema_version", "fixtures", "provenance_path"}:
        raise AdvisorySourceError("source index has the wrong shape")
    if type(index["schema_version"]) is not int or index["schema_version"] != 1:
        raise AdvisorySourceError("source index schema version is unsupported")
    fixtures = _array(index["fixtures"], "source fixtures")
    fixture_ids: list[str] = []
    for raw_fixture in fixtures:
        fixture = _object(raw_fixture, "source fixture")
        if set(fixture) != {"fixture_id", "record_ids", "split"}:
            raise AdvisorySourceError("source fixture has the wrong shape")
        fixture_id = _text(fixture["fixture_id"], "fixture id")
        split = _text(fixture["split"], "fixture split")
        if split not in {"development", "regression", "sealed"}:
            raise AdvisorySourceError("source fixture split is unsupported")
        if not fixture_id.startswith(f"dp-{split}-"):
            raise AdvisorySourceError("source fixture id does not encode its split")
        _texts(fixture["record_ids"], "fixture record ids")
        fixture_ids.append(fixture_id)
    if len(fixture_ids) != len(set(fixture_ids)):
        raise AdvisorySourceError("source fixture ids must be unique")
    provenance_declaration = Path(_text(index.get("provenance_path"), "provenance path"))
    if provenance_declaration.name != "provenance.json":
        raise AdvisorySourceError("source index must declare provenance.json")
    snapshot_prefix = provenance_declaration.parent / "snapshots"
    provenance_path = root / provenance_declaration.name
    if provenance_path.is_symlink():
        raise AdvisorySourceError("source catalogs must not be symlinks")
    provenance = load_object(provenance_path)
    repositories = {
        _text(repository.get("repository_id"), "repository id"): repository
        for repository in _array(provenance.get("repositories"), "repositories")
        if isinstance(repository, dict)
    }
    if len(repositories) != len(_array(provenance.get("repositories"), "repositories")):
        raise AdvisorySourceError("repository catalog contains an invalid or duplicate entry")
    records = _array(provenance.get("records"), "records")
    record_ids = [
        _text(_object(record, "record").get("record_id"), "record id") for record in records
    ]
    if len(record_ids) != len(set(record_ids)):
        raise AdvisorySourceError("record catalog contains duplicate record ids")

    entries: list[_CatalogEntry] = [
        (
            _text(_object(record, "record").get("repository_id"), "record repository id"),
            _object(record, "record"),
            True,
        )
        for record in records
    ]
    entries.extend(
        (
            repository_id,
            _object(repository.get("license"), "repository license"),
            False,
        )
        for repository_id, repository in repositories.items()
    )
    return index, snapshot_prefix, frozenset(repositories), tuple(entries)


def _verified_entry(
    root: Path,
    snapshot_prefix: Path,
    repositories: frozenset[str],
    repository_id: str,
    entry: Mapping[str, Any],
) -> tuple[Path, bytes]:
    if repository_id not in repositories:
        raise AdvisorySourceError(f"unknown source repository: {repository_id}")
    snapshot_path = Path(_text(entry.get("snapshot_path"), "snapshot path"))
    repository_path = Path(_text(entry.get("repository_path"), "repository path"))
    try:
        relative_path = snapshot_path.relative_to(snapshot_prefix)
    except ValueError as error:
        raise AdvisorySourceError("snapshot path escapes the declared source prefix") from error
    expected_path = Path(repository_id) / repository_path
    if relative_path != expected_path or ".." in relative_path.parts:
        raise AdvisorySourceError("snapshot path does not match repository provenance")
    local_path = root / "snapshots" / relative_path
    for candidate in (local_path, *local_path.parents):
        if candidate == root:
            break
        if candidate.is_symlink():
            raise AdvisorySourceError("source snapshot paths must not contain symlinks")
    try:
        resolved_path = local_path.resolve(strict=True)
    except OSError as error:
        raise AdvisorySourceError(f"source snapshot is unavailable: {snapshot_path}") from error
    if not resolved_path.is_relative_to(root / "snapshots"):
        raise AdvisorySourceError("source snapshot resolves outside the source root")
    raw = resolved_path.read_bytes()
    declared_bytes = entry.get("bytes")
    declared_sha256 = entry.get("sha256")
    if type(declared_bytes) is not int or declared_bytes < 0:
        raise AdvisorySourceError("source byte count must be a non-negative integer")
    if not isinstance(declared_sha256, str) or SHA256_HEX.fullmatch(declared_sha256) is None:
        raise AdvisorySourceError("source SHA-256 must be canonical lowercase hex")
    if len(raw) != declared_bytes or hashlib.sha256(raw).hexdigest() != declared_sha256:
        raise AdvisorySourceError(f"source snapshot does not match provenance: {snapshot_path}")
    return local_path, raw


def _verified_sources(source_root: Path) -> tuple[_VerifiedRecord, ...]:
    if source_root.is_symlink():
        raise AdvisorySourceError("source root must not be a symlink")
    root = source_root.resolve()
    _, snapshot_prefix, repositories, entries = _catalog_entries(root)

    declared_paths: set[Path] = set()
    verified_records: list[_VerifiedRecord] = []
    for repository_id, entry, is_record in entries:
        resolved_path, raw = _verified_entry(
            root,
            snapshot_prefix,
            repositories,
            repository_id,
            entry,
        )
        declared_paths.add(resolved_path)
        if is_record:
            try:
                raw_text = raw.decode("utf-8")
            except UnicodeDecodeError as error:
                raise AdvisorySourceError("advisory snapshots must be UTF-8") from error
            verified_records.append(_VerifiedRecord(metadata=entry, raw_text=raw_text))

    actual_paths: set[Path] = set()
    for path in (root / "snapshots").rglob("*"):
        if path.is_symlink():
            raise AdvisorySourceError("source snapshot tree must not contain symlinks")
        if path.is_file():
            actual_paths.add(path)
    if actual_paths != declared_paths:
        raise AdvisorySourceError("source snapshot tree does not match the provenance catalog")
    return tuple(verified_records)


def verify_frozen_source_catalog(source_root: Path) -> None:
    """Verify path closure, byte counts, and hashes for every frozen source entry."""

    _verified_sources(source_root)


def fixture_record_ids(source_root: Path, fixture_id: str, split: str) -> tuple[str, ...]:
    """Return the sole frozen advisory selection for one fixture."""

    if source_root.is_symlink():
        raise AdvisorySourceError("source root must not be a symlink")
    root = source_root.resolve()
    index, _, _, entries = _catalog_entries(root)
    known_record_ids = {
        _text(entry.get("record_id"), "catalog record id")
        for _, entry, is_record in entries
        if is_record
    }
    matches = [
        fixture
        for raw_fixture in _array(index["fixtures"], "source fixtures")
        if (fixture := _object(raw_fixture, "source fixture"))["fixture_id"] == fixture_id
    ]
    if len(matches) != 1 or matches[0]["split"] != split:
        raise AdvisorySourceError("fixture advisory selection is missing or mismatched")
    record_ids = _texts(matches[0]["record_ids"], "fixture record ids")
    if not record_ids or not set(record_ids).issubset(known_record_ids):
        raise AdvisorySourceError("fixture advisory selection contains unknown records")
    return record_ids


def _decode_record(source: _VerifiedRecord) -> dict[str, Any]:
    repository_id = _text(source.metadata.get("repository_id"), "record repository id")
    try:
        if repository_id == "github-advisory-database":
            return loads_object(source.raw_text)
        if repository_id == "pypa-advisory-database":
            yaml = YAML(typ="base", pure=True)
            yaml.version = (1, 2)
            yaml.allow_duplicate_keys = False
            yaml.max_depth = 64
            return _object(yaml.load(source.raw_text), "YAML advisory")
    except (ValueError, YAMLError) as error:
        raise AdvisorySourceError("advisory snapshot could not be decoded strictly") from error
    raise AdvisorySourceError(f"unsupported advisory repository: {repository_id}")


def _severity_vectors(value: Any) -> tuple[CVSSVector, ...]:
    items = [] if value is None else _array(value, "severity")
    vectors: list[CVSSVector] = []
    for raw_item in items:
        item = _object(raw_item, "severity item")
        raw_kind = _text(item.get("type"), "severity type")
        vector = _text(item.get("score"), "severity vector")
        try:
            if raw_kind == "CVSS_V3" and vector.startswith(("CVSS:3.0/", "CVSS:3.1/")):
                kind: Literal["CVSS_V3", "CVSS_V4"] = "CVSS_V3"
                parsed_v3 = CVSS3(vector)
                clean_vector = parsed_v3.clean_vector()
                score = float(parsed_v3.scores()[0])
            elif raw_kind == "CVSS_V4" and vector.startswith("CVSS:4.0/"):
                kind = "CVSS_V4"
                parsed_v4 = CVSS4(vector)
                clean_vector = parsed_v4.clean_vector()
                score = float(parsed_v4.scores()[0])
            else:
                raise AdvisorySourceError("severity type and vector version do not match")
            if clean_vector != vector:
                raise AdvisorySourceError("CVSS vector is not in canonical form")
        except (CVSS3Error, CVSS4Error) as error:
            raise AdvisorySourceError("invalid CVSS vector") from error
        if score <= 0:
            raise AdvisorySourceError("CVSS base score has no benchmark severity band")
        if score <= _LOW_MAX:
            band: SeverityBand = "low"
        elif score <= _MODERATE_MAX:
            band = "moderate"
        elif score <= _HIGH_MAX:
            band = "high"
        elif score <= _CRITICAL_MAX:
            band = "critical"
        else:
            raise AdvisorySourceError("CVSS base score has no benchmark severity band")
        vectors.append(CVSSVector(kind=kind, vector=vector, base_score=score, band=band))
    return tuple(sorted(vectors, key=lambda item: (item.kind, item.vector)))


def _compare_intervals(
    ecosystem: Ecosystem, left: AffectedInterval, right: AffectedInterval
) -> int:
    if left.introduced is None:
        return 0 if right.introduced is None else -1
    if right.introduced is None:
        return 1
    result = compare_versions(ecosystem, left.introduced, right.introduced)
    if result != 0:
        return result
    if left.fixed is None:
        return 0 if right.fixed is None else 1
    if right.fixed is None:
        return -1
    return compare_versions(ecosystem, left.fixed, right.fixed)


def _record_from_source(source: _VerifiedRecord) -> AdvisoryRecord:
    raw = _decode_record(source)
    metadata = source.metadata
    record_id = _text(raw.get("id"), "advisory id")
    if record_id != _text(metadata.get("record_id"), "catalog record id"):
        raise AdvisorySourceError("raw advisory id does not match provenance")
    aliases = tuple(sorted(_texts(raw.get("aliases"), "advisory aliases")))
    if aliases != tuple(sorted(_texts(metadata.get("aliases"), "catalog aliases"))):
        raise AdvisorySourceError("raw advisory aliases do not match provenance")
    raw_summary = raw.get("summary")
    summary = None if raw_summary is None else _text(raw_summary, "advisory summary")
    details = _text(raw.get("details"), "advisory details")

    catalog_package = _object(metadata.get("package"), "catalog package")
    ecosystem = normalize_ecosystem(_text(catalog_package.get("ecosystem"), "ecosystem"))
    package_name = canonical_package_name(
        ecosystem,
        _text(catalog_package.get("name"), "package name"),
    )
    affected_entries = _array(raw.get("affected"), "affected")
    if not affected_entries:
        raise AdvisorySourceError("advisory must contain an affected package")
    intervals: list[AffectedInterval] = []
    explicit_versions: list[str] = []
    ignored_git_ranges = 0
    raw_version_count = 0
    for raw_affected in affected_entries:
        affected = _object(raw_affected, "affected item")
        raw_package = _object(affected.get("package"), "affected package")
        raw_ecosystem = normalize_ecosystem(_text(raw_package.get("ecosystem"), "ecosystem"))
        raw_package_name = canonical_package_name(
            raw_ecosystem,
            _text(raw_package.get("name"), "package name"),
        )
        if (raw_ecosystem, raw_package_name) != (ecosystem, package_name):
            raise AdvisorySourceError("raw affected package does not match provenance")

        raw_versions = _array(affected.get("versions", []), "affected versions")
        raw_version_count += len(raw_versions)
        explicit_versions.extend(
            canonical_version(ecosystem, _text(version, "affected version"))
            for version in raw_versions
        )
        for raw_range in _array(affected.get("ranges", []), "affected ranges"):
            affected_range = _object(raw_range, "affected range")
            range_type = _text(affected_range.get("type"), "affected range type")
            if range_type == "GIT":
                ignored_git_ranges += 1
                continue
            if range_type != "ECOSYSTEM":
                raise AdvisorySourceError(f"unsupported affected range type: {range_type}")
            raw_events = _array(affected_range.get("events"), "affected range events")
            events = [_object(event, "affected range event") for event in raw_events]
            intervals.extend(parse_osv_intervals(ecosystem, events))
    if not intervals and not explicit_versions:
        raise AdvisorySourceError("advisory has no supported affected-version facts")

    def compare_intervals(left: AffectedInterval, right: AffectedInterval) -> int:
        return _compare_intervals(ecosystem, left, right)

    ordered_intervals = tuple(sorted(set(intervals), key=cmp_to_key(compare_intervals)))
    vectors = _severity_vectors(raw.get("severity"))
    severity = max((vector.band for vector in vectors), key=_severity_rank, default=None)
    return AdvisoryRecord(
        repository_id=_text(metadata.get("repository_id"), "repository id"),
        source_sha256=_text(metadata.get("sha256"), "source SHA-256"),
        source_bytes=int(metadata["bytes"]),
        record_id=record_id,
        aliases=aliases,
        summary=summary,
        details=details,
        ecosystem=ecosystem,
        package_name=package_name,
        affected_entry_count=len(affected_entries),
        intervals=ordered_intervals,
        explicit_versions=sort_versions(ecosystem, explicit_versions),
        explicit_version_raw_count=raw_version_count,
        ignored_git_range_count=ignored_git_ranges,
        cvss_vectors=vectors,
        severity=severity,
    )


def _severity_rank(value: SeverityBand) -> int:
    return {"low": 0, "moderate": 1, "high": 2, "critical": 3}[value]


def load_frozen_advisories(source_root: Path) -> tuple[AdvisoryRecord, ...]:
    """Decode all verified frozen advisory records into canonical source facts."""

    try:
        return tuple(
            sorted(
                map(_record_from_source, _verified_sources(source_root)),
                key=lambda record: record.record_id,
            )
        )
    except VersioningError as error:
        raise AdvisorySourceError("advisory contains invalid package version facts") from error


def alias_components(records: Iterable[AdvisoryRecord]) -> tuple[AdvisoryComponent, ...]:
    """Compute transitive OSV alias closure and aggregate component severity."""

    ordered = tuple(sorted(records, key=lambda record: record.record_id))
    if len({record.record_id for record in ordered}) != len(ordered):
        raise AdvisorySourceError("advisory record ids must be unique")
    parent = list(range(len(ordered)))

    def find(index: int) -> int:
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def union(left: int, right: int) -> None:
        left_root = find(left)
        right_root = find(right)
        if left_root != right_root:
            parent[right_root] = left_root

    owner: dict[str, int] = {}
    for index, record in enumerate(ordered):
        for identity in (record.record_id, *record.aliases):
            previous = owner.setdefault(identity, index)
            union(index, previous)

    grouped: dict[int, list[AdvisoryRecord]] = {}
    for index, record in enumerate(ordered):
        grouped.setdefault(find(index), []).append(record)
    components: list[AdvisoryComponent] = []
    for grouped_records in grouped.values():
        packages = {(record.ecosystem, record.package_name) for record in grouped_records}
        if len(packages) != 1:
            raise AdvisorySourceError("one alias component spans different packages")
        severities = [record.severity for record in grouped_records if record.severity is not None]
        if not severities:
            raise AdvisorySourceError("alias component has no supported CVSS severity")
        ecosystem, package_name = next(iter(packages))
        components.append(
            AdvisoryComponent(
                record_ids=tuple(sorted(record.record_id for record in grouped_records)),
                identities=tuple(
                    sorted(
                        {
                            identity
                            for record in grouped_records
                            for identity in (record.record_id, *record.aliases)
                        }
                    )
                ),
                ecosystem=ecosystem,
                package_name=package_name,
                severity=max(severities, key=_severity_rank),
            )
        )
    return tuple(sorted(components, key=lambda component: component.record_ids))


def record_affects(record: AdvisoryRecord, version: str) -> bool:
    return is_version_affected(
        record.ecosystem,
        version,
        record.intervals,
        record.explicit_versions,
    )


def fixed_versions(record: AdvisoryRecord) -> tuple[str, ...]:
    return sort_versions(
        record.ecosystem,
        (interval.fixed for interval in record.intervals if interval.fixed is not None),
    )


def semantic_receipt(records: Iterable[AdvisoryRecord]) -> dict[str, Any]:
    """Return a compact receipt for normalized parser semantics, distinct from byte provenance."""

    ordered = tuple(sorted(records, key=lambda record: record.record_id))
    components = alias_components(ordered)
    record_payload = [
        {
            "repository_id": record.repository_id,
            "source_sha256": record.source_sha256,
            "record_id": record.record_id,
            "aliases": list(record.aliases),
            "summary_present": record.summary is not None,
            "details_sha256": hashlib.sha256(record.details.encode("utf-8")).hexdigest(),
            "package": {"ecosystem": record.ecosystem, "name": record.package_name},
            "affected_entry_count": record.affected_entry_count,
            "intervals": [
                {"introduced": interval.introduced, "fixed": interval.fixed}
                for interval in record.intervals
            ],
            "fixed_versions": list(fixed_versions(record)),
            "explicit_version_raw_count": record.explicit_version_raw_count,
            "explicit_versions_sha256": canonical_sha256(list(record.explicit_versions)),
            "ignored_git_range_count": record.ignored_git_range_count,
            "cvss": [
                {
                    "type": vector.kind,
                    "vector": vector.vector,
                    "base_score": vector.base_score,
                    "band": vector.band,
                }
                for vector in record.cvss_vectors
            ],
            "severity": record.severity,
        }
        for record in ordered
    ]
    component_payload = [
        {
            "record_ids": list(component.record_ids),
            "identities": list(component.identities),
            "package": {"ecosystem": component.ecosystem, "name": component.package_name},
            "severity": component.severity,
        }
        for component in components
    ]
    return {
        "schema_version": 1,
        "record_count": len(ordered),
        "repository_counts": dict(
            sorted(Counter(record.repository_id for record in ordered).items())
        ),
        "total_bytes": sum(record.source_bytes for record in ordered),
        "normalized_package_count": len(
            {(record.ecosystem, record.package_name) for record in ordered}
        ),
        "alias_component_count": len(components),
        "affected_entry_count": sum(record.affected_entry_count for record in ordered),
        "ecosystem_interval_count": sum(len(record.intervals) for record in ordered),
        "git_range_count": sum(record.ignored_git_range_count for record in ordered),
        "fixed_version_count": sum(len(fixed_versions(record)) for record in ordered),
        "explicit_version_raw_count": sum(record.explicit_version_raw_count for record in ordered),
        "explicit_version_canonical_count": sum(
            len(record.explicit_versions) for record in ordered
        ),
        "cvss_type_counts": dict(
            sorted(
                Counter(vector.kind for record in ordered for vector in record.cvss_vectors).items()
            )
        ),
        "record_band_counts": dict(
            sorted(Counter(record.severity or "missing" for record in ordered).items())
        ),
        "component_band_counts": dict(
            sorted(Counter(component.severity for component in components).items())
        ),
        "records_semantic_sha256": canonical_sha256(record_payload),
        "alias_components_sha256": canonical_sha256(component_payload),
    }
