"""Closed dependency benchmark contract validation."""

from __future__ import annotations

import re
from typing import Any

from benchmark_core.contract_validation import (
    ValidationIssue,
    bounded_list,
    bounded_string,
    closed_enum,
    exact_keys,
    is_integer,
    issue,
)

FIXTURE_ID = re.compile(r"^dp-(development|regression|sealed)-[0-9]{2}$")
TASK_ID = re.compile(r"^dependency-[0-9a-f]{12}$")
SOURCE_KEY = re.compile(r"^[a-z0-9-]{1,64}$")
CANONICAL_IDS = {
    "finding": re.compile(r"^finding-[0-9a-f]{10}$"),
    "option": re.compile(r"^option-[0-9a-f]{10}$"),
    "evidence": re.compile(r"^evidence-[0-9a-f]{10}$"),
}
_MAX_QUEUE_GRADE = 48
_MAX_TASK_EVIDENCE_REFERENCES = 48
MAX_FINDINGS = 12
MAX_PATHS_PER_FINDING = 8
MAX_PATH_NODES = 12
MAX_OPTIONS_PER_FINDING = 8
MAX_EVIDENCE_PER_FINDING = 16
MAX_PACKAGE_CHAIN_ITEM_SCALARS = 128


def _source_key(value: Any, path: str, issues: list[ValidationIssue]) -> bool:
    return bool(bounded_string(value, 1, 64, path, issues, SOURCE_KEY))


def validate_source(value: Any) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    keys = {
        "schema_version",
        "fixture_id",
        "task_id",
        "family_id",
        "split",
        "normalized_findings",
    }
    if not exact_keys(value, keys, keys, "$", issues):
        return issues
    if not is_integer(value.get("schema_version")) or value.get("schema_version") != 1:
        issue(issues, "schema.exact_version_identity", "source schema_version must equal integer 1")
    bounded_string(value.get("fixture_id"), 1, 32, "$.fixture_id", issues, FIXTURE_ID)
    bounded_string(value.get("task_id"), 1, 32, "$.task_id", issues, TASK_ID)
    bounded_string(
        value.get("family_id"),
        3,
        64,
        "$.family_id",
        issues,
        re.compile(r"^[a-z0-9-]{3,64}$"),
    )
    split = value.get("split")
    closed_enum(split, ("development", "regression", "sealed"), "$.split", issues)
    fixture_id = value.get("fixture_id")
    if (
        isinstance(fixture_id, str)
        and isinstance(split, str)
        and not fixture_id.startswith(f"dp-{split}-")
    ):
        issue(issues, "schema.exact_version_identity", "fixture_id does not encode split")
    findings = value.get("normalized_findings")
    finding_keys: list[str] = []
    if bounded_list(findings, 0, MAX_FINDINGS, "$.normalized_findings", issues):
        for index, finding in enumerate(findings):
            path = f"$.normalized_findings[{index}]"
            finding_keys.extend(_validate_source_finding(finding, path, issues))
        evidence_total = sum(
            len(finding.get("evidence_references", ()))
            for finding in findings
            if isinstance(finding, dict) and isinstance(finding.get("evidence_references"), list)
        )
        if evidence_total > _MAX_TASK_EVIDENCE_REFERENCES:
            issue(
                issues,
                "schema.bounded_values",
                "$.normalized_findings contain more than 48 evidence references",
            )
    if len(finding_keys) != len(set(finding_keys)):
        issue(issues, "schema.unique_arrays", "normalized finding source keys must be unique")
    return issues


def _validate_source_finding(
    value: Any,
    path: str,
    issues: list[ValidationIssue],
) -> list[str]:
    keys = {
        "source_key",
        "ecosystem",
        "package_name",
        "installed_version",
        "affected_status",
        "advisories",
        "reachability",
        "dependency_paths",
        "remediation_options",
        "evidence_references",
    }
    if not exact_keys(value, keys, keys, path, issues):
        return []
    finding_key = value.get("source_key")
    found = [finding_key] if _source_key(finding_key, f"{path}.source_key", issues) else []
    closed_enum(value.get("ecosystem"), ("npm", "pypi"), f"{path}.ecosystem", issues)
    bounded_string(value.get("package_name"), 1, 128, f"{path}.package_name", issues)
    bounded_string(value.get("installed_version"), 1, 64, f"{path}.installed_version", issues)
    closed_enum(
        value.get("affected_status"),
        ("affected", "unaffected"),
        f"{path}.affected_status",
        issues,
    )
    closed_enum(
        value.get("reachability"),
        ("unreachable", "unknown", "reachable"),
        f"{path}.reachability",
        issues,
    )
    _validate_advisories(value.get("advisories"), f"{path}.advisories", issues)
    path_keys = _validate_source_paths(
        value.get("dependency_paths"), f"{path}.dependency_paths", issues
    )
    option_keys = _validate_source_options(
        value.get("remediation_options"), f"{path}.remediation_options", issues
    )
    evidence_keys = _validate_source_evidence(
        value.get("evidence_references"), f"{path}.evidence_references", issues
    )
    for label, keys_to_check in (
        ("dependency path", path_keys),
        ("remediation option", option_keys),
        ("evidence", evidence_keys),
    ):
        if len(keys_to_check) != len(set(keys_to_check)):
            issue(issues, "schema.unique_arrays", f"{path} {label} source keys must be unique")
    return found


def _validate_advisories(value: Any, path: str, issues: list[ValidationIssue]) -> None:
    advisory_ids: list[str] = []
    if not bounded_list(value, 1, MAX_PATHS_PER_FINDING, path, issues):
        return
    for index, advisory in enumerate(value):
        item_path = f"{path}[{index}]"
        keys = {"advisory_id", "severity"}
        if not exact_keys(advisory, keys, keys, item_path, issues):
            continue
        advisory_id = advisory.get("advisory_id")
        if bounded_string(advisory_id, 1, 128, f"{item_path}.advisory_id", issues):
            advisory_ids.append(advisory_id)
        severity = advisory.get("severity")
        if severity is not None:
            closed_enum(
                severity,
                ("low", "moderate", "high", "critical"),
                f"{item_path}.severity",
                issues,
            )
    if len(advisory_ids) != len(set(advisory_ids)):
        issue(issues, "schema.unique_arrays", f"{path} advisory IDs must be unique")


def _validate_source_paths(value: Any, path: str, issues: list[ValidationIssue]) -> list[str]:
    source_keys: list[str] = []
    if not bounded_list(value, 1, 8, path, issues):
        return source_keys
    for index, item in enumerate(value):
        item_path = f"{path}[{index}]"
        keys = {"source_key", "package_chain", "relationship", "runtime_scope"}
        if not exact_keys(item, keys, keys, item_path, issues):
            continue
        source_key = item.get("source_key")
        if _source_key(source_key, f"{item_path}.source_key", issues):
            source_keys.append(source_key)
        chain = item.get("package_chain")
        if bounded_list(chain, 1, MAX_PATH_NODES, f"{item_path}.package_chain", issues):
            for chain_index, package in enumerate(chain):
                bounded_string(
                    package,
                    1,
                    MAX_PACKAGE_CHAIN_ITEM_SCALARS,
                    f"{item_path}.package_chain[{chain_index}]",
                    issues,
                )
        closed_enum(
            item.get("relationship"),
            ("direct", "transitive"),
            f"{item_path}.relationship",
            issues,
        )
        closed_enum(
            item.get("runtime_scope"),
            ("development_only", "production"),
            f"{item_path}.runtime_scope",
            issues,
        )
    return source_keys


def _validate_source_options(value: Any, path: str, issues: list[ValidationIssue]) -> list[str]:
    source_keys: list[str] = []
    if not bounded_list(value, 0, MAX_OPTIONS_PER_FINDING, path, issues):
        return source_keys
    for index, item in enumerate(value):
        item_path = f"{path}[{index}]"
        keys = {
            "source_key",
            "target_version",
            "availability",
            "affected_status",
            "compatibility",
        }
        if not exact_keys(item, keys, keys, item_path, issues):
            continue
        source_key = item.get("source_key")
        if _source_key(source_key, f"{item_path}.source_key", issues):
            source_keys.append(source_key)
        bounded_string(item.get("target_version"), 1, 64, f"{item_path}.target_version", issues)
        closed_enum(
            item.get("availability"),
            ("available", "unavailable"),
            f"{item_path}.availability",
            issues,
        )
        closed_enum(
            item.get("affected_status"),
            ("affected", "unaffected"),
            f"{item_path}.affected_status",
            issues,
        )
        closed_enum(
            item.get("compatibility"),
            ("compatible", "incompatible"),
            f"{item_path}.compatibility",
            issues,
        )
    return source_keys


def _validate_source_evidence(value: Any, path: str, issues: list[ValidationIssue]) -> list[str]:
    source_keys: list[str] = []
    if not bounded_list(value, 0, MAX_EVIDENCE_PER_FINDING, path, issues):
        return source_keys
    for index, item in enumerate(value):
        item_path = f"{path}[{index}]"
        keys = {"source_key", "subject_type", "subject_key", "snippet"}
        if not exact_keys(item, keys, keys, item_path, issues):
            continue
        source_key = item.get("source_key")
        if _source_key(source_key, f"{item_path}.source_key", issues):
            source_keys.append(source_key)
        _source_key(item.get("subject_key"), f"{item_path}.subject_key", issues)
        closed_enum(
            item.get("subject_type"),
            ("finding", "dependency_path", "remediation_option"),
            f"{item_path}.subject_type",
            issues,
        )
        bounded_string(item.get("snippet"), 1, 600, f"{item_path}.snippet", issues)
    return source_keys


def validate_output(value: Any, expected_task_id: str) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    keys = {
        "schema_version",
        "task_id",
        "verdict",
        "findings",
        "remediation_queue",
        "proposed_actions",
    }
    if not exact_keys(value, keys, keys, "$", issues):
        return issues
    if not is_integer(value.get("schema_version")) or value.get("schema_version") != 1:
        issue(issues, "schema.exact_version_identity", "$.schema_version must equal integer 1")
    task_id = value.get("task_id")
    if (
        not bounded_string(task_id, 1, 32, "$.task_id", issues, TASK_ID)
        or task_id != expected_task_id
    ):
        issue(issues, "schema.exact_version_identity", "$.task_id does not match the expected task")
    closed_enum(value.get("verdict"), ("action_required", "no_action"), "$.verdict", issues)
    finding_ids: list[str] = []
    actionable_ids: list[str] = []
    findings = value.get("findings")
    if bounded_list(findings, 0, MAX_FINDINGS, "$.findings", issues):
        for index, finding in enumerate(findings):
            item_path = f"$.findings[{index}]"
            item_keys = {
                "finding_id",
                "actionability",
                "remediation_disposition",
                "selected_option_id",
                "evidence_reference_ids",
            }
            if not exact_keys(finding, item_keys, item_keys, item_path, issues):
                continue
            finding_id = finding.get("finding_id")
            valid_finding_id = bounded_string(
                finding_id,
                1,
                32,
                f"{item_path}.finding_id",
                issues,
                CANONICAL_IDS["finding"],
            )
            if valid_finding_id:
                finding_ids.append(finding_id)
            actionability = finding.get("actionability")
            disposition = finding.get("remediation_disposition")
            option_id = finding.get("selected_option_id")
            valid_actionability = closed_enum(
                actionability,
                ("actionable", "no_action"),
                f"{item_path}.actionability",
                issues,
            )
            if valid_finding_id and valid_actionability and actionability == "actionable":
                actionable_ids.append(finding_id)
            closed_enum(
                disposition,
                ("upgrade", "no_safe_fix", "no_action"),
                f"{item_path}.remediation_disposition",
                issues,
            )
            if option_id is not None:
                bounded_string(
                    option_id,
                    1,
                    32,
                    f"{item_path}.selected_option_id",
                    issues,
                    CANONICAL_IDS["option"],
                )
            if (
                (disposition == "upgrade" and option_id is None)
                or (disposition != "upgrade" and option_id is not None)
                or (actionability == "no_action" and disposition != "no_action")
                or (actionability == "actionable" and disposition not in {"upgrade", "no_safe_fix"})
            ):
                issue(
                    issues,
                    "schema.conditional_consistency",
                    f"{item_path} actionability, disposition, and option are inconsistent",
                )
            evidence_ids = finding.get("evidence_reference_ids")
            if bounded_list(
                evidence_ids,
                0,
                16,
                f"{item_path}.evidence_reference_ids",
                issues,
                unique=True,
            ):
                for evidence_index, evidence_id in enumerate(evidence_ids):
                    bounded_string(
                        evidence_id,
                        1,
                        32,
                        f"{item_path}.evidence_reference_ids[{evidence_index}]",
                        issues,
                        CANONICAL_IDS["evidence"],
                    )
    if len(finding_ids) != len(set(finding_ids)):
        issue(issues, "schema.unique_arrays", "$.findings must use unique finding IDs")
    queue = value.get("remediation_queue")
    if bounded_list(queue, 0, MAX_FINDINGS, "$.remediation_queue", issues, unique=True):
        for index, finding_id in enumerate(queue):
            bounded_string(
                finding_id,
                1,
                32,
                f"$.remediation_queue[{index}]",
                issues,
                CANONICAL_IDS["finding"],
            )
        if set(queue) != set(actionable_ids):
            issue(
                issues,
                "schema.conditional_consistency",
                "queue IDs must exactly match returned actionable findings",
            )
    actions = value.get("proposed_actions")
    if bounded_list(actions, 0, 8, "$.proposed_actions", issues):
        for index, action in enumerate(actions):
            bounded_string(action, 1, 200, f"$.proposed_actions[{index}]", issues)
    verdict = value.get("verdict")
    if isinstance(queue, list) and (
        (verdict == "action_required" and not queue) or (verdict == "no_action" and queue)
    ):
        issue(issues, "schema.conditional_consistency", "verdict and queue are inconsistent")
    return issues


def validate_gold(
    value: Any,
    target_classes: set[str],
) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    keys = {
        "schema_version",
        "fixture_id",
        "task_id",
        "expected_verdict",
        "findings",
        "injection_markers",
    }
    if not exact_keys(value, keys, keys, "$", issues):
        return issues
    if not is_integer(value.get("schema_version")) or value.get("schema_version") != 1:
        issue(issues, "schema.exact_version_identity", "gold schema_version must equal integer 1")
    bounded_string(value.get("fixture_id"), 1, 32, "$.fixture_id", issues, FIXTURE_ID)
    bounded_string(value.get("task_id"), 1, 32, "$.task_id", issues, TASK_ID)
    closed_enum(
        value.get("expected_verdict"),
        ("action_required", "no_action"),
        "$.expected_verdict",
        issues,
    )
    finding_ids: list[str] = []
    findings = value.get("findings")
    if bounded_list(findings, 0, MAX_FINDINGS, "$.findings", issues):
        for index, finding in enumerate(findings):
            item_path = f"$.findings[{index}]"
            item_keys = {
                "finding_id",
                "actionability",
                "remediation",
                "queue",
                "evidence_reference_ids",
            }
            if not exact_keys(finding, item_keys, item_keys, item_path, issues):
                continue
            finding_id = finding.get("finding_id")
            if bounded_string(
                finding_id,
                1,
                32,
                f"{item_path}.finding_id",
                issues,
                CANONICAL_IDS["finding"],
            ):
                finding_ids.append(finding_id)
            _validate_gold_actionability(
                finding.get("actionability"), item_path, target_classes, issues
            )
            _validate_gold_remediation(
                finding.get("remediation"), item_path, target_classes, issues
            )
            _validate_gold_queue(finding.get("queue"), item_path, target_classes, issues)
            evidence_ids = finding.get("evidence_reference_ids")
            if bounded_list(
                evidence_ids,
                0,
                16,
                f"{item_path}.evidence_reference_ids",
                issues,
                unique=True,
            ):
                for evidence_index, evidence_id in enumerate(evidence_ids):
                    bounded_string(
                        evidence_id,
                        1,
                        32,
                        f"{item_path}.evidence_reference_ids[{evidence_index}]",
                        issues,
                        CANONICAL_IDS["evidence"],
                    )
    if len(finding_ids) != len(set(finding_ids)):
        issue(issues, "schema.unique_arrays", "gold finding IDs must be unique")
    _validate_injection_markers(value.get("injection_markers"), issues)
    return issues


def _validate_gold_actionability(
    value: Any,
    item_path: str,
    target_classes: set[str],
    issues: list[ValidationIssue],
) -> None:
    path = f"{item_path}.actionability"
    keys = {"value", "target_class"}
    if not exact_keys(value, keys, keys, path, issues):
        return
    closed_enum(value.get("value"), ("actionable", "no_action"), f"{path}.value", issues)
    allowed = target_classes & {
        "policy.runtime_scope",
        "policy.reachability",
        "policy.abstention",
    }
    closed_enum(value.get("target_class"), allowed, f"{path}.target_class", issues)


def _validate_gold_remediation(
    value: Any,
    item_path: str,
    target_classes: set[str],
    issues: list[ValidationIssue],
) -> None:
    path = f"{item_path}.remediation"
    keys = {"disposition", "selected_option_id", "target_class"}
    if not exact_keys(value, keys, keys, path, issues):
        return
    disposition = value.get("disposition")
    option_id = value.get("selected_option_id")
    closed_enum(
        disposition,
        ("upgrade", "no_safe_fix", "no_action"),
        f"{path}.disposition",
        issues,
    )
    if option_id is not None:
        bounded_string(
            option_id,
            1,
            32,
            f"{path}.selected_option_id",
            issues,
            CANONICAL_IDS["option"],
        )
    if (disposition == "upgrade") != (option_id is not None):
        issue(issues, "schema.conditional_consistency", f"{path} option is inconsistent")
    closed_enum(
        value.get("target_class"),
        target_classes & {"policy.remediation", "policy.abstention"},
        f"{path}.target_class",
        issues,
    )


def _validate_gold_queue(
    value: Any,
    item_path: str,
    target_classes: set[str],
    issues: list[ValidationIssue],
) -> None:
    path = f"{item_path}.queue"
    keys = {"member", "target_class", "grade"}
    if not exact_keys(value, keys, keys, path, issues):
        return
    if not isinstance(value.get("member"), bool):
        issue(issues, "schema.bounded_values", f"{path}.member must be boolean")
    closed_enum(
        value.get("target_class"),
        target_classes & {"policy.runtime_scope", "policy.reachability", "policy.abstention"},
        f"{path}.target_class",
        issues,
    )
    grade = value.get("grade")
    if not is_integer(grade) or not 0 <= grade <= _MAX_QUEUE_GRADE:
        issue(issues, "schema.bounded_values", f"{path}.grade must be an integer from 0 to 48")


def _validate_injection_markers(value: Any, issues: list[ValidationIssue]) -> None:
    path = "$.injection_markers"
    keys = {"task_ids", "finding_ids", "option_ids", "evidence_reference_ids", "phrases"}
    if not exact_keys(value, keys, keys, path, issues):
        return
    for field in keys:
        items = value.get(field)
        if bounded_list(items, 0, 32, f"{path}.{field}", issues, unique=True):
            for index, item in enumerate(items):
                bounded_string(item, 1, 200, f"{path}.{field}[{index}]", issues)
