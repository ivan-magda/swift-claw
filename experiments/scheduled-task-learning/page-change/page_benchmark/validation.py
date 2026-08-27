"""Contract-specific validators implemented with the Python standard library."""

from __future__ import annotations

from dataclasses import dataclass
from collections import Counter
import json
import re
from typing import Any, Iterable

from .canonical import SHA256_HEX


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
RESPONSES_REQUEST_KEYS = {
    "sequence",
    "requested_model",
    "body_byte_count",
    "body_sha256",
    "normalized_structure_sha256",
    "untrusted_fence_present",
    "untrusted_payload_sha256",
}
SUCCESSFUL_FILE_READ_EVENT = {
    "name": "file_read",
    "path": "input.json",
    "status": "succeeded",
}
FROZEN_PROVIDER_REFERENCE = "openai-chatgpt/gpt-5.6-sol"
FROZEN_WIRE_MODEL = "gpt-5.6-sol"


@dataclass(frozen=True)
class ValidationIssue:
    requirement: str
    message: str


class ContractError(ValueError):
    def __init__(self, issues: Iterable[ValidationIssue]) -> None:
        self.issues = tuple(issues)
        super().__init__("; ".join(issue.message for issue in self.issues))


def _issue(issues: list[ValidationIssue], requirement: str, message: str) -> None:
    item = ValidationIssue(requirement, message)
    if item not in issues:
        issues.append(item)


def _exact_keys(
    value: Any,
    required: set[str],
    allowed: set[str],
    path: str,
    issues: list[ValidationIssue],
) -> bool:
    if not isinstance(value, dict):
        _issue(issues, "schema.single_object", f"{path} must be an object")
        return False
    missing = sorted(required - value.keys())
    unknown = sorted(value.keys() - allowed)
    if missing:
        _issue(issues, "schema.closed_properties", f"{path} missing keys: {missing}")
    if unknown:
        _issue(issues, "schema.closed_properties", f"{path} unknown keys: {unknown}")
    return not missing and not unknown


def _is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _scalar_count(value: str) -> int:
    if any(0xD800 <= ord(character) <= 0xDFFF for character in value):
        return -1
    return len(value)


def _bounded_string(
    value: Any,
    minimum: int,
    maximum: int,
    path: str,
    issues: list[ValidationIssue],
    pattern: re.Pattern[str] | None = None,
) -> bool:
    if not isinstance(value, str):
        _issue(issues, "schema.bounded_values", f"{path} must be a string")
        return False
    size = _scalar_count(value)
    if size < minimum or size > maximum:
        _issue(
            issues,
            "schema.bounded_values",
            f"{path} must contain {minimum}..{maximum} Unicode scalars",
        )
        return False
    if pattern is not None and pattern.fullmatch(value) is None:
        _issue(issues, "schema.bounded_values", f"{path} has invalid format")
        return False
    return True


def _bounded_list(
    value: Any,
    minimum: int,
    maximum: int,
    path: str,
    issues: list[ValidationIssue],
    *,
    unique: bool = False,
) -> bool:
    if not isinstance(value, list):
        _issue(issues, "schema.bounded_values", f"{path} must be an array")
        return False
    if len(value) < minimum or len(value) > maximum:
        _issue(issues, "schema.bounded_values", f"{path} must contain {minimum}..{maximum} items")
    if unique:
        try:
            normalized = [
                json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                for item in value
            ]
        except (TypeError, ValueError):
            _issue(issues, "schema.bounded_values", f"{path} contains a non-JSON value")
            return False
        if len(set(normalized)) != len(normalized):
            _issue(issues, "schema.unique_arrays", f"{path} must contain unique items")
    return minimum <= len(value) <= maximum


def _closed_enum(
    value: Any,
    allowed: Iterable[str],
    path: str,
    issues: list[ValidationIssue],
) -> bool:
    if not isinstance(value, str) or value not in set(allowed):
        _issue(issues, "schema.closed_enums", f"{path} is outside its closed enum")
        return False
    return True


def validate_attempt(
    value: Any,
    *,
    require_request_provenance: bool = False,
) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    required = {"runtime_outcome", "raw_output", "tool_events"}
    allowed = required | {"responses_requests"}
    if require_request_provenance:
        required.add("responses_requests")
    if not _exact_keys(value, required, allowed, "$", issues):
        return issues
    _closed_enum(
        value.get("runtime_outcome"),
        ("completed", "local_output_limit", "tool_budget_stop"),
        "$.runtime_outcome",
        issues,
    )
    raw_output = value.get("raw_output")
    if raw_output is not None and not isinstance(raw_output, str):
        _issue(issues, "schema.bounded_values", "$.raw_output must be text or null")
    tool_events = value.get("tool_events")
    if _bounded_list(tool_events, 0, 4, "$.tool_events", issues):
        for index, event in enumerate(tool_events):
            path = f"$.tool_events[{index}]"
            event_keys = {"name", "path", "status"}
            if not _exact_keys(event, event_keys, event_keys, path, issues):
                continue
            event_path = event.get("path")
            _bounded_string(event.get("name"), 1, 64, f"{path}.name", issues)
            if event_path is not None:
                _bounded_string(event_path, 1, 256, f"{path}.path", issues)
            _closed_enum(event.get("status"), ("proposed", "succeeded", "failed"), f"{path}.status", issues)

    requests = value.get("responses_requests")
    if requests is not None and _bounded_list(
        requests,
        0,
        2,
        "$.responses_requests",
        issues,
    ):
        for index, request in enumerate(requests):
            path = f"$.responses_requests[{index}]"
            if not _exact_keys(
                request,
                RESPONSES_REQUEST_KEYS,
                RESPONSES_REQUEST_KEYS,
                path,
                issues,
            ):
                continue
            sequence = request.get("sequence")
            byte_count = request.get("body_byte_count")
            if not _is_integer(sequence) or sequence not in (1, 2):
                _issue(issues, "schema.bounded_values", f"{path}.sequence must equal 1 or 2")
            if not _is_integer(byte_count) or byte_count < 1:
                _issue(issues, "schema.bounded_values", f"{path}.body_byte_count must be positive")
            requested_model = request.get("requested_model")
            if requested_model is not None:
                _bounded_string(requested_model, 1, 128, f"{path}.requested_model", issues)
            for field in ("body_sha256", "normalized_structure_sha256"):
                _bounded_string(request.get(field), 64, 64, f"{path}.{field}", issues, SHA256_HEX)
            if not isinstance(request.get("untrusted_fence_present"), bool):
                _issue(
                    issues,
                    "schema.bounded_values",
                    f"{path}.untrusted_fence_present must be boolean",
                )
            payload_sha256 = request.get("untrusted_payload_sha256")
            if payload_sha256 is not None:
                _bounded_string(
                    payload_sha256,
                    64,
                    64,
                    f"{path}.untrusted_payload_sha256",
                    issues,
                    SHA256_HEX,
                )
    return issues


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
    if not _bounded_string(task_id, 1, 32, "$.task_id", issues, TASK_ID) or task_id != expected_task_id:
        _issue(issues, "schema.exact_version_identity", "$.task_id does not match the expected task")
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
        isinstance(item, dict) and isinstance(item.get("region_id"), str)
        for item in evidence
    )
    if material_is_string_list and ignored_is_string_list:
        if set(material) & set(ignored):
            _issue(issues, "schema.conditional_consistency", "material and ignored IDs must be disjoint")
        evidence_ids = [item["region_id"] for item in evidence] if evidence_is_valid_list else []
        if evidence_is_valid_list and Counter(evidence_ids) != Counter(material):
            _issue(
                issues,
                "schema.conditional_consistency",
                "evidence must contain exactly one object for every material ID",
            )
        if verdict == "material" and not material:
            _issue(issues, "schema.conditional_consistency", "material verdict requires a material region")
        if verdict == "cosmetic" and (material or not ignored or evidence):
            _issue(issues, "schema.conditional_consistency", "cosmetic verdict requires only ignored changes")
        if verdict == "none" and (material or ignored or evidence):
            _issue(issues, "schema.conditional_consistency", "none verdict requires empty classifications")
    return issues


def validate_source(value: Any) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    keys = {"schema_version", "fixture_id", "task_id", "family_id", "split", "task"}
    if not _exact_keys(value, keys, keys, "$", issues):
        return issues
    if value.get("schema_version") != 1 or not _is_integer(value.get("schema_version")):
        _issue(issues, "schema.exact_version_identity", "source schema_version must equal integer 1")
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
    keys = {"schema_version", "fixture_id", "task_id", "expected_verdict", "atoms", "injection_markers"}
    if not _exact_keys(value, keys, keys, "$", issues):
        return issues
    if value.get("schema_version") != 1 or not _is_integer(value.get("schema_version")):
        _issue(issues, "schema.exact_version_identity", "gold schema_version must equal integer 1")
    _bounded_string(value.get("fixture_id"), 1, 32, "$.fixture_id", issues, FIXTURE_ID)
    _bounded_string(value.get("task_id"), 1, 32, "$.task_id", issues, TASK_ID)
    _closed_enum(value.get("expected_verdict"), ("material", "cosmetic", "none"), "$.expected_verdict", issues)
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
                _closed_enum(atom.get("target_class"), TARGET_CLASSES, f"{path}.target_class", issues)
            elif "target_class" in atom:
                _issue(issues, "schema.conditional_consistency", f"{path} material atom cannot have target_class")
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
            _bounded_list(markers.get(field), 0, 32, f"$.injection_markers.{field}", issues, unique=True)
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
        _issue(issues, "schema.exact_version_identity", "lesson schema_version must equal integer 1")
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


def require_valid(value: Any, validator: Any) -> None:
    issues = validator(value)
    if issues:
        raise ContractError(issues)
