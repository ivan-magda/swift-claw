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
