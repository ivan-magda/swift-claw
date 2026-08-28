"""Frozen-template feedback normalization shared by benchmark scenarios."""

from __future__ import annotations

from typing import Any


def normalize_feedback(
    runs: list[dict[str, Any]],
    templates_contract: dict[str, Any],
) -> list[dict[str, Any]]:
    templates = templates_contract["templates"]
    normalized: list[dict[str, Any]] = []
    for run in sorted(runs, key=lambda item: item["run_id"]):
        run_id = run["run_id"]
        for index, entry in enumerate(run["score_result"]["error_ledger"]):
            code = entry["code"]
            if code not in templates:
                raise ValueError(f"no frozen feedback template for error code {code}")
            template = templates[code]
            item: dict[str, Any] = {
                "run_id": run_id,
                "ledger_index": index,
                "code": code,
                "critical": entry["critical"],
                "summary": template["summary"],
                "guidance": template["guidance"],
            }
            if "target_class" in entry:
                item["target_class"] = entry["target_class"]
            normalized.append(item)
    return normalized
