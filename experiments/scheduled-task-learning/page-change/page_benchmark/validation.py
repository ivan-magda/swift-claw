"""Contract-specific validators implemented with the Python standard library."""

from __future__ import annotations

import re
from collections import Counter
from typing import Any

from benchmark_core.attempt import SUCCESSFUL_FILE_READ_EVENT, validate_attempt
from benchmark_core.contract_validation import ContractError, ValidationIssue, require_valid
from benchmark_core.contract_validation import (
    bounded_list as _bounded_list,
)
from benchmark_core.contract_validation import (
    bounded_string as _bounded_string,
)
from benchmark_core.contract_validation import (
    closed_enum as _closed_enum,
)
from benchmark_core.contract_validation import (
    exact_keys as _exact_keys,
)
from benchmark_core.contract_validation import (
    is_integer as _is_integer,
)
from benchmark_core.contract_validation import (
    issue as _issue,
)

__all__ = [
    "SUCCESSFUL_FILE_READ_EVENT",
    "ContractError",
    "ValidationIssue",
    "require_valid",
    "validate_attempt",
]

FIXTURE_ID = re.compile(r"^pc-(development|regression|sealed)-[0-9]{2}$")
TASK_ID = re.compile(r"^page-[0-9a-f]{12}$")
TOKEN = re.compile(r"^[a-z0-9-]{1,64}$")
REGION_ID = re.compile(r"^region-[0-9a-f]{10}$")
MODEL_SPLIT_MARKER = re.compile(
    r"(?i)\b(?:development|regression|sealed)\b|(?<![a-z0-9])(?:dv|rg|sl)[0-9]+(?:-[a-z0-9-]+)?(?![a-z0-9])"
)
TARGET_CLASSES = (
    "noise.volatile_value",
    "noise.time_or_build_metadata",
    "noise.structure_or_order",
)
FROZEN_PROVIDER_REFERENCE = "openai-chatgpt/gpt-5.6-sol"
FROZEN_WIRE_MODEL = "gpt-5.6-sol"


def validate_output(value: Any, expected_task_id: str) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    keys = {
        "schema_version",
        "task_id",
        "verdict",
        "material_region_ids",
        "ignored_region_ids",
        "evidence",
    }
    if not _exact_keys(value, keys, keys, "$", issues):
        return issues
    if not _is_integer(value.get("schema_version")) or value.get("schema_version") != 1:
        _issue(issues, "schema.exact_version_identity", "$.schema_version must equal integer 1")
    task_id = value.get("task_id")
    if (
        not _bounded_string(task_id, 1, 32, "$.task_id", issues, TASK_ID)
        or task_id != expected_task_id
    ):
        _issue(
            issues, "schema.exact_version_identity", "$.task_id does not match the expected task"
        )
    _closed_enum(value.get("verdict"), ("material", "cosmetic", "none"), "$.verdict", issues)

    for field in ("material_region_ids", "ignored_region_ids"):
        entries = value.get(field)
        if _bounded_list(entries, 0, 32, f"$.{field}", issues, unique=True):
            for index, entry in enumerate(entries):
                _bounded_string(entry, 1, 32, f"$.{field}[{index}]", issues, REGION_ID)

    evidence = value.get("evidence")
    if _bounded_list(evidence, 0, 32, "$.evidence", issues, unique=True):
        for index, item in enumerate(evidence):
            path = f"$.evidence[{index}]"
            item_keys = {"region_id", "before", "after"}
            if not _exact_keys(item, item_keys, item_keys, path, issues):
                continue
            _bounded_string(item.get("region_id"), 1, 32, f"{path}.region_id", issues, REGION_ID)
            _bounded_string(item.get("before"), 1, 200, f"{path}.before", issues)
            _bounded_string(item.get("after"), 1, 200, f"{path}.after", issues)

    material = value.get("material_region_ids")
    ignored = value.get("ignored_region_ids")
    verdict = value.get("verdict")
    material_is_string_list = isinstance(material, list) and all(
        isinstance(item, str) for item in material
    )
    ignored_is_string_list = isinstance(ignored, list) and all(
        isinstance(item, str) for item in ignored
    )
    evidence_is_valid_list = isinstance(evidence, list) and all(
        isinstance(item, dict) and isinstance(item.get("region_id"), str) for item in evidence
    )
    if material_is_string_list and ignored_is_string_list:
        if set(material) & set(ignored):
            _issue(
                issues,
                "schema.conditional_consistency",
                "material and ignored IDs must be disjoint",
            )
        evidence_ids = [item["region_id"] for item in evidence] if evidence_is_valid_list else []
        if evidence_is_valid_list and Counter(evidence_ids) != Counter(material):
            _issue(
                issues,
                "schema.conditional_consistency",
                "evidence must contain exactly one object for every material ID",
            )
        if verdict == "material" and not material:
            _issue(
                issues,
                "schema.conditional_consistency",
                "material verdict requires a material region",
            )
        if verdict == "cosmetic" and (material or not ignored or evidence):
            _issue(
                issues,
                "schema.conditional_consistency",
                "cosmetic verdict requires only ignored changes",
            )
        if verdict == "none" and (material or ignored or evidence):
            _issue(
                issues,
                "schema.conditional_consistency",
                "none verdict requires empty classifications",
            )
    return issues


def validate_source(value: Any) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    keys = {"schema_version", "fixture_id", "task_id", "family_id", "split", "task"}
    if not _exact_keys(value, keys, keys, "$", issues):
        return issues
    if value.get("schema_version") != 1 or not _is_integer(value.get("schema_version")):
        _issue(
            issues, "schema.exact_version_identity", "source schema_version must equal integer 1"
        )
    _bounded_string(value.get("fixture_id"), 1, 32, "$.fixture_id", issues, FIXTURE_ID)
    _bounded_string(value.get("task_id"), 1, 32, "$.task_id", issues, TASK_ID)
    _bounded_string(value.get("family_id"), 3, 64, "$.family_id", issues, TOKEN)
    _closed_enum(value.get("split"), ("development", "regression", "sealed"), "$.split", issues)
    task = value.get("task")
    task_keys = {"before_html", "after_html", "region_ids"}
    if _exact_keys(task, task_keys, task_keys, "$.task", issues):
        _bounded_string(task.get("before_html"), 1, 30000, "$.task.before_html", issues)
        _bounded_string(task.get("after_html"), 1, 30000, "$.task.after_html", issues)
        region_ids = task.get("region_ids")
        if _bounded_list(region_ids, 1, 32, "$.task.region_ids", issues, unique=True):
            for index, region_id in enumerate(region_ids):
                _bounded_string(region_id, 1, 32, f"$.task.region_ids[{index}]", issues, REGION_ID)
    return issues


def validate_gold(value: Any) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    keys = {
        "schema_version",
        "fixture_id",
        "task_id",
        "expected_verdict",
        "atoms",
        "injection_markers",
    }
    if not _exact_keys(value, keys, keys, "$", issues):
        return issues
    if value.get("schema_version") != 1 or not _is_integer(value.get("schema_version")):
        _issue(issues, "schema.exact_version_identity", "gold schema_version must equal integer 1")
    _bounded_string(value.get("fixture_id"), 1, 32, "$.fixture_id", issues, FIXTURE_ID)
    _bounded_string(value.get("task_id"), 1, 32, "$.task_id", issues, TASK_ID)
    _closed_enum(
        value.get("expected_verdict"),
        ("material", "cosmetic", "none"),
        "$.expected_verdict",
        issues,
    )
    atoms = value.get("atoms")
    if _bounded_list(atoms, 0, 32, "$.atoms", issues):
        atom_ids: list[str] = []
        region_ids: list[str] = []
        for index, atom in enumerate(atoms):
            path = f"$.atoms[{index}]"
            required = {"atom_id", "region_id", "kind", "mechanism_id", "before", "after"}
            allowed = required | {"target_class"}
            if not _exact_keys(atom, required, allowed, path, issues):
                continue
            atom_id = atom.get("atom_id")
            region_id = atom.get("region_id")
            atom_id_is_valid = _bounded_string(
                atom_id,
                1,
                48,
                f"{path}.atom_id",
                issues,
                TOKEN,
            )
            region_id_is_valid = _bounded_string(
                region_id,
                1,
                32,
                f"{path}.region_id",
                issues,
                REGION_ID,
            )
            _bounded_string(atom.get("mechanism_id"), 3, 64, f"{path}.mechanism_id", issues, TOKEN)
            _bounded_string(atom.get("before"), 1, 200, f"{path}.before", issues)
            _bounded_string(atom.get("after"), 1, 200, f"{path}.after", issues)
            kind = atom.get("kind")
            _closed_enum(kind, ("material", "noise"), f"{path}.kind", issues)
            if kind == "noise":
                _closed_enum(
                    atom.get("target_class"), TARGET_CLASSES, f"{path}.target_class", issues
                )
            elif "target_class" in atom:
                _issue(
                    issues,
                    "schema.conditional_consistency",
                    f"{path} material atom cannot have target_class",
                )
            if atom_id_is_valid:
                atom_ids.append(atom_id)
            if region_id_is_valid:
                region_ids.append(region_id)
        if len(set(atom_ids)) != len(atom_ids) or len(set(region_ids)) != len(region_ids):
            _issue(issues, "schema.unique_arrays", "gold atom and region IDs must be unique")
    markers = value.get("injection_markers")
    marker_keys = {"task_ids", "region_ids", "phrases"}
    if _exact_keys(markers, marker_keys, marker_keys, "$.injection_markers", issues):
        for field in marker_keys:
            _bounded_list(
                markers.get(field), 0, 32, f"$.injection_markers.{field}", issues, unique=True
            )
            if isinstance(markers.get(field), list):
                for index, item in enumerate(markers[field]):
                    _bounded_string(item, 1, 200, f"$.injection_markers.{field}[{index}]", issues)
    return issues


def validate_lesson_candidate(value: Any) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    keys = {"schema_version", "lessons"}
    if not _exact_keys(value, keys, keys, "$", issues):
        return issues
    if value.get("schema_version") != 1 or not _is_integer(value.get("schema_version")):
        _issue(
            issues, "schema.exact_version_identity", "lesson schema_version must equal integer 1"
        )
    lessons = value.get("lessons")
    if _bounded_list(lessons, 1, 3, "$.lessons", issues):
        classes: list[str] = []
        for index, lesson in enumerate(lessons):
            path = f"$.lessons[{index}]"
            lesson_keys = {"target_class", "text"}
            if not _exact_keys(lesson, lesson_keys, lesson_keys, path, issues):
                continue
            target_class = lesson.get("target_class")
            target_class_is_valid = _closed_enum(
                target_class,
                TARGET_CLASSES,
                f"{path}.target_class",
                issues,
            )
            _bounded_string(lesson.get("text"), 1, 400, f"{path}.text", issues)
            if target_class_is_valid:
                classes.append(target_class)
        if len(set(classes)) != len(classes):
            _issue(issues, "schema.unique_arrays", "lesson target classes must be unique")
    return issues
