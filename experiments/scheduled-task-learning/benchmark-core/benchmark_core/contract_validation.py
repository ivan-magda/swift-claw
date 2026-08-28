"""Small validation primitives shared by deterministic benchmark contracts."""

from __future__ import annotations

import json
import re
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from typing import Any

_UTF16_SURROGATE_LOW = 0xD800
_UTF16_SURROGATE_HIGH = 0xDFFF


@dataclass(frozen=True)
class ValidationIssue:
    requirement: str
    message: str


class ContractError(ValueError):
    def __init__(self, issues: Iterable[ValidationIssue]) -> None:
        self.issues = tuple(issues)
        super().__init__("; ".join(issue.message for issue in self.issues))


def issue(issues: list[ValidationIssue], requirement: str, message: str) -> None:
    item = ValidationIssue(requirement, message)
    if item not in issues:
        issues.append(item)


def exact_keys(
    value: Any,
    required: set[str],
    allowed: set[str],
    path: str,
    issues: list[ValidationIssue],
) -> bool:
    if not isinstance(value, dict):
        issue(issues, "schema.single_object", f"{path} must be an object")
        return False
    missing = sorted(required - value.keys())
    unknown = sorted(value.keys() - allowed)
    if missing:
        issue(issues, "schema.closed_properties", f"{path} missing keys: {missing}")
    if unknown:
        issue(issues, "schema.closed_properties", f"{path} unknown keys: {unknown}")
    return not missing and not unknown


def is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def scalar_count(value: str) -> int:
    if any(_UTF16_SURROGATE_LOW <= ord(character) <= _UTF16_SURROGATE_HIGH for character in value):
        return -1
    return len(value)


def bounded_string(
    value: Any,
    minimum: int,
    maximum: int,
    path: str,
    issues: list[ValidationIssue],
    pattern: re.Pattern[str] | None = None,
) -> bool:
    if not isinstance(value, str):
        issue(issues, "schema.bounded_values", f"{path} must be a string")
        return False
    size = scalar_count(value)
    if size < minimum or size > maximum:
        issue(
            issues,
            "schema.bounded_values",
            f"{path} must contain {minimum}..{maximum} Unicode scalars",
        )
        return False
    if pattern is not None and pattern.fullmatch(value) is None:
        issue(issues, "schema.bounded_values", f"{path} has invalid format")
        return False
    return True


def bounded_list(
    value: Any,
    minimum: int,
    maximum: int,
    path: str,
    issues: list[ValidationIssue],
    *,
    unique: bool = False,
) -> bool:
    if not isinstance(value, list):
        issue(issues, "schema.bounded_values", f"{path} must be an array")
        return False
    if len(value) < minimum or len(value) > maximum:
        issue(issues, "schema.bounded_values", f"{path} must contain {minimum}..{maximum} items")
    if unique:
        try:
            normalized = [
                json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                for item in value
            ]
        except (TypeError, ValueError):
            issue(issues, "schema.bounded_values", f"{path} contains a non-JSON value")
            return False
        if len(set(normalized)) != len(normalized):
            issue(issues, "schema.unique_arrays", f"{path} must contain unique items")
    return minimum <= len(value) <= maximum


def closed_enum(
    value: Any,
    allowed: Iterable[str],
    path: str,
    issues: list[ValidationIssue],
) -> bool:
    if not isinstance(value, str) or value not in set(allowed):
        issue(issues, "schema.closed_enums", f"{path} is outside its closed enum")
        return False
    return True


def require_valid(value: Any, validator: Callable[[Any], list[ValidationIssue]]) -> None:
    issues = validator(value)
    if issues:
        raise ContractError(issues)
