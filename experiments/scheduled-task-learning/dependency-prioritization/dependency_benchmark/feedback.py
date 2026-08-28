"""Dependency taxonomy validation and normalized frozen feedback."""

from __future__ import annotations

from typing import Any

from benchmark_core.feedback import normalize_feedback


def validate_contracts(
    target_contract: dict[str, Any],
    error_contract: dict[str, Any],
    templates_contract: dict[str, Any],
) -> None:
    if set(target_contract) != {"schema_version", "target_class_order", "definitions"}:
        raise ValueError("target-class contract is malformed")
    target_order = target_contract["target_class_order"]
    definitions = target_contract["definitions"]
    if (
        target_contract["schema_version"] != 1
        or not isinstance(target_order, list)
        or len(target_order) != len(set(target_order))
        or not isinstance(definitions, dict)
        or set(target_order) != set(definitions)
    ):
        raise ValueError("target-class order and definitions differ")
    if set(error_contract) != {"schema_version", "critical_order", "codes"}:
        raise ValueError("error-code contract is malformed")
    codes = error_contract["codes"]
    critical_order = error_contract["critical_order"]
    if (
        error_contract["schema_version"] != 1
        or not isinstance(codes, dict)
        or not isinstance(critical_order, list)
        or len(critical_order) != len(set(critical_order))
        or not set(critical_order).issubset(codes)
    ):
        raise ValueError("error-code order is malformed")
    for code, definition in codes.items():
        if (
            not isinstance(code, str)
            or not isinstance(definition, dict)
            or set(definition) != {"addressable", "critical"}
            or type(definition["addressable"]) is not bool
            or type(definition["critical"]) is not bool
            or (definition["addressable"] and definition["critical"])
        ):
            raise ValueError(f"error-code definition is malformed: {code}")
    addressable = {code for code, definition in codes.items() if definition["addressable"]}
    critical = {code for code, definition in codes.items() if definition["critical"]}
    if addressable != set(target_order) or critical != set(critical_order):
        raise ValueError("target and critical code sets differ from their frozen order")
    if set(templates_contract) != {"schema_version", "templates"}:
        raise ValueError("feedback-template contract is malformed")
    templates = templates_contract["templates"]
    if templates_contract["schema_version"] != 1 or not isinstance(templates, dict):
        raise ValueError("feedback-template identity is malformed")
    if set(templates) != set(codes):
        raise ValueError("every error code must have exactly one frozen feedback template")
    for code, template in templates.items():
        if (
            not isinstance(template, dict)
            or set(template) != {"summary", "guidance"}
            or not isinstance(template["summary"], str)
            or not template["summary"]
            or not isinstance(template["guidance"], str)
            or not template["guidance"]
        ):
            raise ValueError(f"feedback template is malformed: {code}")


def build_feedback(
    runs: list[dict[str, Any]],
    target_contract: dict[str, Any],
    error_contract: dict[str, Any],
    templates_contract: dict[str, Any],
) -> list[dict[str, Any]]:
    validate_contracts(target_contract, error_contract, templates_contract)
    return normalize_feedback(runs, templates_contract)
