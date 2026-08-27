"""Build the one-file untrusted carrier without leaking source metadata."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from .canonical import dumps, load_object, write
from .validation import (
    ContractError,
    TOKEN,
    TARGET_CLASSES,
    ValidationIssue,
    require_valid,
    validate_source,
)


def _validate_active_lessons(value: Any) -> None:
    issues: list[ValidationIssue] = []
    if not isinstance(value, dict):
        issues.append(ValidationIssue("schema.single_object", "active lesson set must be an object"))
    else:
        expected = {"schema_version", "lesson_set_id", "lessons"}
        if set(value) != expected:
            issues.append(ValidationIssue("schema.closed_properties", "active lesson set has wrong keys"))
        if value.get("schema_version") != 1 or isinstance(value.get("schema_version"), bool):
            issues.append(ValidationIssue("schema.exact_version_identity", "active lesson schema_version must be 1"))
        lesson_set_id = value.get("lesson_set_id")
        if (
            not isinstance(lesson_set_id, str)
            or not (1 <= len(lesson_set_id) <= 64)
            or TOKEN.fullmatch(lesson_set_id) is None
        ):
            issues.append(ValidationIssue("schema.bounded_values", "lesson_set_id must contain 1..64 scalars"))
        lessons = value.get("lessons")
        if not isinstance(lessons, list) or len(lessons) > 3:
            issues.append(ValidationIssue("schema.bounded_values", "lessons must contain at most three items"))
        else:
            seen_ids: set[str] = set()
            seen_classes: set[str] = set()
            for index, lesson in enumerate(lessons):
                if not isinstance(lesson, dict) or set(lesson) != {"lesson_id", "target_class", "text"}:
                    issues.append(ValidationIssue("schema.closed_properties", f"lesson {index} has wrong keys"))
                    continue
                lesson_id = lesson["lesson_id"]
                target_class = lesson["target_class"]
                text = lesson["text"]
                if (
                    not isinstance(lesson_id, str)
                    or not (1 <= len(lesson_id) <= 64)
                    or TOKEN.fullmatch(lesson_id) is None
                ):
                    issues.append(ValidationIssue("schema.bounded_values", f"lesson {index} has invalid ID"))
                if isinstance(lesson_id, str):
                    if lesson_id in seen_ids:
                        issues.append(ValidationIssue("schema.unique_arrays", "lesson IDs must be unique"))
                    seen_ids.add(lesson_id)
                if not isinstance(target_class, str) or target_class not in TARGET_CLASSES:
                    issues.append(ValidationIssue("schema.closed_enums", f"lesson {index} has invalid target class"))
                else:
                    if target_class in seen_classes:
                        issues.append(ValidationIssue("schema.unique_arrays", "lesson target classes must be unique"))
                    seen_classes.add(target_class)
                if (
                    not isinstance(text, str)
                    or not (1 <= len(text) <= 400)
                    or any(0xD800 <= ord(character) <= 0xDFFF for character in text)
                ):
                    issues.append(ValidationIssue("schema.bounded_values", f"lesson {index} text is out of bounds"))
            if sum(len(lesson.get("text", "")) for lesson in lessons if isinstance(lesson, dict)) > 1000:
                issues.append(ValidationIssue("schema.bounded_values", "lesson set exceeds 1,000 Unicode scalars"))
    if issues:
        raise ContractError(issues)


def materialize(source: dict[str, Any], active_lessons: dict[str, Any]) -> dict[str, Any]:
    require_valid(source, validate_source)
    _validate_active_lessons(active_lessons)
    carrier = {
        "schema_version": 1,
        "task_id": source["task_id"],
        "task": source["task"],
        "active_lessons": active_lessons,
    }
    if len(dumps(carrier)) >= 60_000:
        raise ContractError((ValidationIssue("schema.bounded_values", "input.json reaches the 60,000-scalar cap"),))
    return carrier


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--lessons", required=True)
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()
    write(
        Path(arguments.output),
        materialize(load_object(arguments.source), load_object(arguments.lessons)),
    )


if __name__ == "__main__":
    main()
