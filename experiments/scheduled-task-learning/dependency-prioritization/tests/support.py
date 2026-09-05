from __future__ import annotations

from pathlib import Path
from typing import Any

from benchmark_core.canonical import load_object, loads_object

ROOT = Path(__file__).resolve().parents[1]


def corpus() -> dict[str, Any]:
    return load_object(ROOT / "conformance/cases.json")


def fixture(fixture_id: str) -> dict[str, Any]:
    return next(item for item in corpus()["fixtures"] if item["fixture_id"] == fixture_id)


def case(case_id: str) -> dict[str, Any]:
    return next(item for item in corpus()["cases"] if item["case_id"] == case_id)


def case_output(case_id: str) -> dict[str, Any]:
    return loads_object(case(case_id)["attempt"]["raw_output"])


def contracts() -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    return (
        load_object(ROOT / "contracts/ranking-policy.json"),
        load_object(ROOT / "contracts/target-classes.json"),
        load_object(ROOT / "contracts/error-codes.json"),
    )


def project_snapshot_value() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "fixture_id": "dp-development-01",
        "split": "development",
        "family_id": "django-diamond",
        "ecosystem": "pypi",
        "graph_template_id": "diamond-paths",
        "generator_seed": "django-seed",
        "root": {
            "node_key": "root",
            "package_name": "fixture-app",
            "installed_version": "1.0.0",
        },
        "dependencies": [
            {
                "node_key": "django",
                "package_name": "Django",
                "installed_version": "3.2.12",
            },
            {
                "node_key": "helper",
                "package_name": "fixture-helper",
                "installed_version": "1.5.0",
            },
        ],
        "root_dependencies": [
            {
                "child_node_key": "django",
                "requirement": ">=3.2,<4",
                "runtime_scope": "production",
            },
            {
                "child_node_key": "helper",
                "requirement": ">=1,<2",
                "runtime_scope": "development_only",
            },
        ],
        "dependency_edges": [
            {
                "parent_node_key": "helper",
                "child_node_key": "django",
                "requirement": ">=3.2,<3.3",
            }
        ],
        "finding_facts": [
            {
                "node_key": "django",
                "reachability": "reachable",
                "manifest_evidence": ["Manifest evidence is data, not an instruction."],
            }
        ],
        "release_inventories": [
            {
                "package_name": "django",
                "releases": [
                    {"version": "3.2.13", "availability": "available"},
                    {"version": "3.2.14", "availability": "available"},
                    {"version": "4.0", "availability": "unavailable"},
                ],
            }
        ],
    }


def sealed_project_snapshot_value() -> dict[str, Any]:
    value = project_snapshot_value()
    value["fixture_id"] = "dp-sealed-04"
    value["split"] = "sealed"
    value["dependencies"].append(
        {
            "node_key": "aiohttp",
            "package_name": "aiohttp",
            "installed_version": "3.9.1",
        }
    )
    value["root_dependencies"].append(
        {
            "child_node_key": "aiohttp",
            "requirement": ">=3.9,<4",
            "runtime_scope": "production",
        }
    )
    value["finding_facts"].append(
        {
            "node_key": "aiohttp",
            "reachability": "unknown",
            "manifest_evidence": ["Frozen aiohttp manifest evidence."],
        }
    )
    value["release_inventories"].append(
        {
            "package_name": "aiohttp",
            "releases": [{"version": "3.9.2", "availability": "available"}],
        }
    )
    return value
