"""Shared fixture/source construction for the page_change_m3 test suite.

Keeps every SUT call and observable assertion in the test bodies themselves;
this module only builds inputs.
"""

from __future__ import annotations

import copy
from pathlib import Path
from typing import Any

from benchmark_core.canonical import load_object
from page_benchmark.canonical import dumps
from page_benchmark.validation import SUCCESSFUL_FILE_READ_EVENT

PROJECT_ROOT = Path(__file__).resolve().parents[2]
PROTOCOL_06_ROOT = PROJECT_ROOT.parent / "page-change"


def real_fresh_source(fixture_id: str, split: str) -> dict[str, Any]:
    """Load one committed fresh M3 source from the real corpus tree."""

    path = PROJECT_ROOT / "corpus" / split / f"{fixture_id}.source.json"
    return load_object(path)


def real_fresh_gold(fixture_id: str, split: str) -> dict[str, Any]:
    """Load one committed fresh M3 gold record from the real gold tree."""

    path = PROJECT_ROOT / "gold" / split / f"{fixture_id}.gold.json"
    return load_object(path)


def protocol_06_source(fixture_id: str, split: str) -> dict[str, Any]:
    """Load one real Protocol 0.6 source, used only to prove independence."""

    path = PROTOCOL_06_ROOT / "sources" / split / f"{fixture_id}.source.json"
    return load_object(path)


def source_with_invalid_region_id(
    fixture_id: str = "pc-development-07", split: str = "development"
) -> dict[str, Any]:
    """A superficially well-shaped but page-invalid source.

    Every top-level key is present and correctly typed; one region ID breaks
    the frozen `^region-[0-9a-f]{10}$` pattern the reused page validator
    enforces.
    """

    source = copy.deepcopy(real_fresh_source(fixture_id, split))
    source["task"]["region_ids"][0] = "not-a-valid-region-id"
    return source


def source_with_foreign_fixture_id() -> dict[str, Any]:
    """A page-valid source shaped like a Protocol 0.6 fixture ID, outside the fresh M3 set."""

    source = copy.deepcopy(real_fresh_source("pc-development-07", "development"))
    source["fixture_id"] = "pc-development-01"
    return source


def complete_attempt(gold: dict[str, Any]) -> dict[str, Any]:
    """Build one valid raw page attempt that classifies every frozen gold atom."""

    material = [atom for atom in gold["atoms"] if atom["kind"] == "material"]
    noise = [atom for atom in gold["atoms"] if atom["kind"] == "noise"]
    output = {
        "schema_version": 1,
        "task_id": gold["task_id"],
        "verdict": gold["expected_verdict"],
        "material_region_ids": [atom["region_id"] for atom in material],
        "ignored_region_ids": [atom["region_id"] for atom in noise],
        "evidence": [
            {
                "region_id": atom["region_id"],
                "before": atom["before"],
                "after": atom["after"],
            }
            for atom in material
        ],
    }
    return {
        "runtime_outcome": "completed",
        "raw_output": dumps(output).rstrip("\n"),
        "tool_events": [dict(SUCCESSFUL_FILE_READ_EVENT)],
    }


def scored_pair(
    clean_score: float,
    candidate_score: float,
    *,
    candidate_critical: bool = False,
) -> dict[str, object]:
    """Build an already sealed-score-shaped pair for adapter gate scenarios."""

    return {
        "clean": {"score": clean_score, "critical_codes": []},
        "candidate": {
            "score": candidate_score,
            "critical_codes": ["schema.invalid"] if candidate_critical else [],
        },
        "delta": candidate_score - clean_score,
    }
