"""Frozen npm and PyPI version semantics for dependency source derivation."""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from functools import cmp_to_key
from itertools import pairwise
from typing import Literal

import nodesemver
from packaging.specifiers import InvalidSpecifier, SpecifierSet
from packaging.utils import InvalidName, canonicalize_name
from packaging.version import InvalidVersion, Version

Ecosystem = Literal["npm", "pypi"]

_NUMERIC_IDENTIFIER = r"(?:0|[1-9][0-9]*)"
_PRERELEASE_IDENTIFIER = rf"(?:{_NUMERIC_IDENTIFIER}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
_BUILD_IDENTIFIER = r"[0-9A-Za-z-]+"
_NPM_VERSION_TEXT = (
    rf"{_NUMERIC_IDENTIFIER}\.{_NUMERIC_IDENTIFIER}\.{_NUMERIC_IDENTIFIER}"
    rf"(?:-{_PRERELEASE_IDENTIFIER}(?:\.{_PRERELEASE_IDENTIFIER})*)?"
    rf"(?:\+{_BUILD_IDENTIFIER}(?:\.{_BUILD_IDENTIFIER})*)?"
)
_NPM_VERSION = re.compile(rf"^{_NPM_VERSION_TEXT}$")
_NPM_COMPARATOR = rf"(?:<=|>=|<|>|=)?{_NPM_VERSION_TEXT}"
_NPM_REQUIREMENT = re.compile(
    rf"^(?:\*|(?:\^|~){_NPM_VERSION_TEXT}|{_NPM_COMPARATOR}(?: +{_NPM_COMPARATOR})*)$"
)
_NPM_PACKAGE = re.compile(r"^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$")


class VersioningError(ValueError):
    """Raised when frozen ecosystem version facts are invalid or unsupported."""


@dataclass(frozen=True, slots=True)
class AffectedInterval:
    """One half-open affected interval; ``None`` denotes an unbounded endpoint."""

    introduced: str | None
    fixed: str | None


def normalize_ecosystem(value: str) -> Ecosystem:
    if value == "npm":
        return "npm"
    if value in {"PyPI", "pypi"}:
        return "pypi"
    raise VersioningError(f"unsupported package ecosystem: {value}")


def canonical_package_name(ecosystem: Ecosystem, value: str) -> str:
    if not value or value != value.strip():
        raise VersioningError("package name must be non-empty and have no surrounding whitespace")
    if ecosystem == "npm":
        if _NPM_PACKAGE.fullmatch(value) is None:
            raise VersioningError(f"invalid canonical npm package name: {value}")
        return value
    try:
        return canonicalize_name(value, validate=True)
    except InvalidName as error:
        raise VersioningError(f"invalid PyPI package name: {value}") from error


def canonical_version(ecosystem: Ecosystem, value: str) -> str:
    if not value or value != value.strip():
        raise VersioningError("version must be non-empty and have no surrounding whitespace")
    if ecosystem == "npm":
        if _NPM_VERSION.fullmatch(value) is None:
            raise VersioningError(f"version is outside the frozen npm grammar: {value}")
        try:
            parsed = nodesemver.SemVer(value, loose=False, include_prerelease=False)
        except (TypeError, ValueError) as error:
            raise VersioningError(f"invalid npm version: {value}") from error
        if parsed.raw != value:
            raise VersioningError(f"invalid npm version: {value}")
        return value
    try:
        return str(Version(value))
    except InvalidVersion as error:
        raise VersioningError(f"invalid PyPI version: {value}") from error


def compare_versions(ecosystem: Ecosystem, left: str, right: str) -> int:
    canonical_left = canonical_version(ecosystem, left)
    canonical_right = canonical_version(ecosystem, right)
    if ecosystem == "npm":
        result = nodesemver.compare(canonical_left, canonical_right, False)
        if not isinstance(result, int) or result not in {-1, 0, 1}:
            raise VersioningError("npm comparator returned an unsupported result")
        return result
    left_version = Version(canonical_left)
    right_version = Version(canonical_right)
    return (left_version > right_version) - (left_version < right_version)


def sort_versions(ecosystem: Ecosystem, values: Iterable[str]) -> tuple[str, ...]:
    canonical = {canonical_version(ecosystem, value) for value in values}

    def compare(left: str, right: str) -> int:
        precedence = compare_versions(ecosystem, left, right)
        if precedence != 0:
            return precedence
        return (left > right) - (left < right)

    return tuple(sorted(canonical, key=cmp_to_key(compare)))


def canonical_requirement(ecosystem: Ecosystem, value: str) -> str:
    if not value or value != value.strip():
        raise VersioningError("requirement must be non-empty and have no surrounding whitespace")
    if ecosystem == "npm":
        if _NPM_REQUIREMENT.fullmatch(value) is None:
            raise VersioningError(f"requirement is outside the frozen npm grammar: {value}")
        try:
            parsed = nodesemver.Range(value, False)
        except (TypeError, ValueError) as error:
            raise VersioningError(f"invalid npm requirement: {value}") from error
        return parsed.range or "*"
    if "===" in value:
        raise VersioningError("arbitrary PEP 440 equality is outside the frozen grammar")
    try:
        return str(SpecifierSet(value))
    except InvalidSpecifier as error:
        raise VersioningError(f"invalid PyPI requirement: {value}") from error


def satisfies_requirement(ecosystem: Ecosystem, version: str, requirement: str) -> bool:
    candidate = canonical_version(ecosystem, version)
    normalized_requirement = canonical_requirement(ecosystem, requirement)
    if ecosystem == "npm":
        return bool(
            nodesemver.satisfies(
                candidate,
                normalized_requirement,
                loose=False,
                include_prerelease=False,
            )
        )
    candidate_version = Version(candidate)
    specifiers = SpecifierSet(normalized_requirement)
    if candidate_version.is_prerelease and specifiers.prereleases is not True:
        return False
    return specifiers.contains(candidate_version, prereleases=True)


def parse_osv_intervals(
    ecosystem: Ecosystem,
    events: Iterable[Mapping[str, str]],
) -> tuple[AffectedInterval, ...]:
    boundaries: list[tuple[str, str | None]] = []
    for event in events:
        if len(event) != 1:
            raise VersioningError("each OSV event must contain exactly one boundary")
        kind, raw_version = next(iter(event.items()))
        if kind not in {"introduced", "fixed"}:
            raise VersioningError(f"unsupported OSV event type: {kind}")
        if not isinstance(raw_version, str):
            raise VersioningError("OSV event versions must be strings")
        if kind == "introduced" and raw_version == "0":
            boundaries.append((kind, None))
        else:
            boundaries.append((kind, canonical_version(ecosystem, raw_version)))
    if not boundaries:
        raise VersioningError("OSV event list must not be empty")

    intervals: list[AffectedInterval] = []
    index = 0
    while index < len(boundaries):
        kind, introduced = boundaries[index]
        if kind != "introduced":
            raise VersioningError("each OSV interval must begin with an introduced event")
        index += 1
        if index >= len(boundaries):
            raise VersioningError("open OSV intervals are outside the frozen source grammar")
        next_kind, fixed = boundaries[index]
        if next_kind != "fixed":
            raise VersioningError("each OSV introduction must be followed by a fix")
        index += 1
        if (
            introduced is not None
            and fixed is not None
            and compare_versions(ecosystem, introduced, fixed) >= 0
        ):
            raise VersioningError("OSV fixed boundary must follow its introduction")
        intervals.append(AffectedInterval(introduced=introduced, fixed=fixed))

    def compare_intervals(left: AffectedInterval, right: AffectedInterval) -> int:
        if left.introduced is None:
            return 0 if right.introduced is None else -1
        if right.introduced is None:
            return 1
        return compare_versions(ecosystem, left.introduced, right.introduced)

    ordered = sorted(set(intervals), key=cmp_to_key(compare_intervals))
    for previous, current in pairwise(ordered):
        if previous.fixed is None:
            raise VersioningError("an open OSV interval overlaps a later interval")
        if (
            current.introduced is None
            or compare_versions(
                ecosystem,
                current.introduced,
                previous.fixed,
            )
            < 0
        ):
            raise VersioningError("OSV affected intervals must not overlap")
    return tuple(ordered)


def is_version_affected(
    ecosystem: Ecosystem,
    version: str,
    intervals: Iterable[AffectedInterval],
    explicit_versions: Iterable[str] = (),
) -> bool:
    candidate = canonical_version(ecosystem, version)
    if any(compare_versions(ecosystem, candidate, explicit) == 0 for explicit in explicit_versions):
        return True
    for interval in intervals:
        at_or_after_introduction = (
            interval.introduced is None
            or compare_versions(
                ecosystem,
                candidate,
                interval.introduced,
            )
            >= 0
        )
        before_fix = (
            interval.fixed is None
            or compare_versions(
                ecosystem,
                candidate,
                interval.fixed,
            )
            < 0
        )
        if at_or_after_introduction and before_fix:
            return True
    return False
