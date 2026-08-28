"""Materialize immutable canonical task facts from frozen normalized records."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from benchmark_core.canonical import canonical_sha256
from benchmark_core.contract_validation import require_valid

from .validation import validate_source

_SEVERITY_ORDER = {"low": 0, "moderate": 1, "high": 2, "critical": 3}


@dataclass(frozen=True, slots=True)
class IdBinding:
    source_key: str
    canonical_id: str


@dataclass(frozen=True, slots=True)
class FindingBindings:
    source_key: str
    finding_id: str
    paths: tuple[IdBinding, ...]
    options: tuple[IdBinding, ...]
    evidence: tuple[IdBinding, ...]


@dataclass(frozen=True, slots=True)
class NormalizationBindings:
    findings: tuple[FindingBindings, ...]

    def finding_id(self, source_key: str) -> str:
        return self._finding(source_key).finding_id

    def path_id(self, finding_source_key: str, path_source_key: str) -> str:
        return self._resolve(self._finding(finding_source_key).paths, path_source_key, "path")

    def option_id(self, finding_source_key: str, option_source_key: str) -> str:
        return self._resolve(
            self._finding(finding_source_key).options,
            option_source_key,
            "option",
        )

    def evidence_id(self, finding_source_key: str, evidence_source_key: str) -> str:
        return self._resolve(
            self._finding(finding_source_key).evidence,
            evidence_source_key,
            "evidence",
        )

    def _finding(self, source_key: str) -> FindingBindings:
        for binding in self.findings:
            if binding.source_key == source_key:
                return binding
        raise KeyError(f"unknown finding source key: {source_key}")

    @staticmethod
    def _resolve(bindings: tuple[IdBinding, ...], source_key: str, label: str) -> str:
        for binding in bindings:
            if binding.source_key == source_key:
                return binding.canonical_id
        raise KeyError(f"unknown {label} source key: {source_key}")


@dataclass(frozen=True, slots=True)
class Materialization:
    task: dict[str, Any]
    bindings: NormalizationBindings


def _canonical_id(prefix: str, value: Any) -> str:
    return f"{prefix}-{canonical_sha256({'domain': prefix, 'value': value})[:10]}"


def materialize(source: dict[str, Any]) -> Materialization:
    """Return canonical task facts and their sole source-key binding."""

    require_valid(source, validate_source)
    findings: list[dict[str, Any]] = []
    evidence_references: list[dict[str, Any]] = []
    finding_bindings: list[FindingBindings] = []
    observed_ids: dict[str, set[str]] = {
        "finding": set(),
        "path": set(),
        "option": set(),
        "evidence": set(),
    }
    for raw_finding in source["normalized_findings"]:
        advisory_ids = sorted(advisory["advisory_id"] for advisory in raw_finding["advisories"])
        package_id = _canonical_id(
            "package",
            {"ecosystem": raw_finding["ecosystem"], "name": raw_finding["package_name"]},
        )
        alias_cluster_id = _canonical_id("alias", advisory_ids)
        finding_id = _canonical_id(
            "finding",
            {
                "alias_cluster_id": alias_cluster_id,
                "installed_version": raw_finding["installed_version"],
                "package_id": package_id,
            },
        )
        path_ids: dict[str, str] = {}
        paths: list[dict[str, Any]] = []
        for raw_path in raw_finding["dependency_paths"]:
            path_id = _canonical_id(
                "path",
                {
                    "finding_id": finding_id,
                    "package_chain": raw_path["package_chain"],
                    "relationship": raw_path["relationship"],
                    "runtime_scope": raw_path["runtime_scope"],
                },
            )
            path_ids[raw_path["source_key"]] = path_id
            paths.append(
                {
                    "path_id": path_id,
                    "relationship": raw_path["relationship"],
                    "runtime_scope": raw_path["runtime_scope"],
                }
            )
        option_ids: dict[str, str] = {}
        options: list[dict[str, Any]] = []
        for raw_option in raw_finding["remediation_options"]:
            option_id = _canonical_id(
                "option",
                {"finding_id": finding_id, "target_version": raw_option["target_version"]},
            )
            option_ids[raw_option["source_key"]] = option_id
            options.append(
                {
                    "option_id": option_id,
                    "target_version": raw_option["target_version"],
                    "availability": raw_option["availability"],
                    "affected_status": raw_option["affected_status"],
                    "compatibility": raw_option["compatibility"],
                }
            )
        evidence_ids_by_source: dict[str, str] = {}
        for raw_evidence in raw_finding["evidence_references"]:
            subject_type = raw_evidence["subject_type"]
            subject_id: str | None
            if subject_type == "finding":
                if raw_evidence["subject_key"] != raw_finding["source_key"]:
                    raise ValueError("finding evidence must reference its own source key")
                subject_id = finding_id
            elif subject_type == "dependency_path":
                subject_id = path_ids.get(raw_evidence["subject_key"])
            else:
                subject_id = option_ids.get(raw_evidence["subject_key"])
            if subject_id is None:
                raise ValueError("evidence subject key does not resolve within its finding")
            evidence_id = _canonical_id(
                "evidence",
                {
                    "finding_id": finding_id,
                    "snippet": raw_evidence["snippet"],
                    "subject_id": subject_id,
                    "subject_type": subject_type,
                },
            )
            evidence_ids_by_source[raw_evidence["source_key"]] = evidence_id
            evidence_references.append(
                {
                    "evidence_reference_id": evidence_id,
                    "finding_id": finding_id,
                    "subject_type": subject_type,
                    "subject_id": subject_id,
                    "snippet": raw_evidence["snippet"],
                }
            )

        severities = [
            advisory["severity"]
            for advisory in raw_finding["advisories"]
            if advisory["severity"] is not None
        ]
        if not severities:
            raise ValueError("normalized alias component has no supported severity")
        finding = {
            "finding_id": finding_id,
            "alias_cluster_id": alias_cluster_id,
            "package_id": package_id,
            "installed_version": raw_finding["installed_version"],
            "affected_status": raw_finding["affected_status"],
            "severity": max(
                severities,
                key=_SEVERITY_ORDER.__getitem__,
            ),
            "reachability": raw_finding["reachability"],
            "dependency_paths": sorted(paths, key=lambda item: item["path_id"]),
            "remediation_options": sorted(options, key=lambda item: item["option_id"]),
        }
        findings.append(finding)
        finding_bindings.append(
            FindingBindings(
                source_key=raw_finding["source_key"],
                finding_id=finding_id,
                paths=_id_bindings(path_ids),
                options=_id_bindings(option_ids),
                evidence=_id_bindings(evidence_ids_by_source),
            )
        )
        for namespace, values in (
            ("finding", [finding_id]),
            ("path", list(path_ids.values())),
            ("option", list(option_ids.values())),
        ):
            if observed_ids[namespace] & set(values):
                raise ValueError(
                    f"normalized facts collapse to a duplicate canonical {namespace} ID"
                )
            observed_ids[namespace].update(values)

    evidence_ids = [item["evidence_reference_id"] for item in evidence_references]
    if len(evidence_ids) != len(set(evidence_ids)):
        raise ValueError("normalized facts collapse to a duplicate canonical evidence ID")
    return Materialization(
        task={
            "findings": sorted(findings, key=lambda item: item["finding_id"]),
            "evidence_references": sorted(
                evidence_references,
                key=lambda item: item["evidence_reference_id"],
            ),
        },
        bindings=NormalizationBindings(
            findings=tuple(sorted(finding_bindings, key=lambda item: item.source_key))
        ),
    )


def materialize_task(source: dict[str, Any]) -> dict[str, Any]:
    """Return the canonical model-visible task, excluding author-only source keys."""

    return materialize(source).task


def _id_bindings(values: dict[str, str]) -> tuple[IdBinding, ...]:
    return tuple(
        IdBinding(source_key=source_key, canonical_id=canonical_id)
        for source_key, canonical_id in sorted(values.items())
    )
