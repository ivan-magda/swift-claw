"""Cross-file dependency source, gold, and ranking-policy validation."""

from __future__ import annotations

from typing import Any

from benchmark_core.contract_validation import ContractError, ValidationIssue, require_valid

from .normalization import materialize_task
from .policy import finding_grade, is_safe_remediation_option, validate_ranking_policy
from .validation import validate_gold, validate_source


def _fail(message: str) -> None:
    raise ContractError((ValidationIssue("fixture.contract", message),))


def validate_fixture(
    source: dict[str, Any],
    gold: dict[str, Any],
    target_classes: list[str],
    ranking_policy: dict[str, Any],
) -> dict[str, Any]:
    require_valid(source, validate_source)
    require_valid(gold, lambda value: validate_gold(value, set(target_classes)))
    validate_ranking_policy(ranking_policy)
    if source["fixture_id"] != gold["fixture_id"] or source["task_id"] != gold["task_id"]:
        _fail("source and gold identity differ")
    task = materialize_task(source)
    evidence_snippets = [reference["snippet"] for reference in task["evidence_references"]]
    for marker_values in gold["injection_markers"].values():
        for marker in marker_values:
            if not any(marker in snippet for snippet in evidence_snippets):
                _fail("gold injection marker must appear in model-visible evidence")
    findings_by_id = {finding["finding_id"]: finding for finding in task["findings"]}
    gold_by_id = {finding["finding_id"]: finding for finding in gold["findings"]}
    if set(findings_by_id) != set(gold_by_id):
        _fail("gold must label every canonical finding exactly once")
    evidence_by_finding: dict[str, set[str]] = {}
    for reference in task["evidence_references"]:
        evidence_by_finding.setdefault(reference["finding_id"], set()).add(
            reference["evidence_reference_id"]
        )
    queue_members: list[str] = []
    for finding_id, finding in findings_by_id.items():
        label = gold_by_id[finding_id]
        options = {option["option_id"]: option for option in finding["remediation_options"]}
        remediation = label["remediation"]
        selected_option_id = remediation["selected_option_id"]
        safe_options = {
            option_id for option_id, option in options.items() if is_safe_remediation_option(option)
        }
        if remediation["disposition"] == "upgrade" and selected_option_id not in safe_options:
            _fail("gold upgrade must select a safe option")
        if remediation["disposition"] == "no_safe_fix" and safe_options:
            _fail("gold no_safe_fix conflicts with a safe option")
        actionable = label["actionability"]["value"] == "actionable"
        if label["queue"]["member"] != actionable:
            _fail("gold queue membership must match actionability")
        if actionable and remediation["disposition"] == "no_action":
            _fail("actionable gold needs a remediation disposition")
        if not actionable and remediation["disposition"] != "no_action":
            _fail("no-action gold cannot select remediation")
        expected_evidence = evidence_by_finding.get(finding_id, set())
        if not set(label["evidence_reference_ids"]).issubset(expected_evidence):
            _fail("gold evidence crosses canonical findings")
        expected_grade = finding_grade(finding, label["queue"]["member"], ranking_policy)
        if label["queue"]["grade"] != expected_grade:
            _fail("gold queue grade differs from frozen D5")
        critical_runtime = (
            finding["affected_status"] == "affected"
            and finding["severity"] == "critical"
            and finding["reachability"] == "reachable"
            and any(path["runtime_scope"] == "production" for path in finding["dependency_paths"])
        )
        if critical_runtime and not actionable:
            _fail("critical reachable production finding must queue")
        if label["queue"]["member"]:
            queue_members.append(finding_id)
    expected_verdict = "action_required" if queue_members else "no_action"
    if gold["expected_verdict"] != expected_verdict:
        _fail("gold verdict differs from queue")
    return task
