"""Build the sealed lesson-synthesis input from development records only."""

from __future__ import annotations

import argparse
import hashlib
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from .canonical import dumps, load_object, loads_object, write
from .feedback import feedback_generator_identity, normalize_feedback
from .lessons import support_by_class
from .scorer import score
from .validation import MODEL_SPLIT_MARKER, TARGET_CLASSES, validate_output

DEVELOPMENT_RUN_COUNT = 18
DEVELOPMENT_FIXTURE_COUNT = 6
MINIMUM_ELIGIBLE_TARGET_CLASSES = 2


def canonical_run_id(task_id: str, replicate: int) -> str:
    value = hashlib.sha256(f"{task_id}:{replicate}".encode()).hexdigest()[:12]
    return f"run-{value}"


def _validate_development_runs(
    runs: list[dict[str, Any]],
    sources: list[dict[str, Any]],
    golds: list[dict[str, Any]],
    error_codes: dict[str, Any],
) -> None:
    if len(runs) != DEVELOPMENT_RUN_COUNT:
        raise ValueError("page synthesis requires exactly 18 development runs")
    if len(sources) != DEVELOPMENT_FIXTURE_COUNT or any(
        source.get("split") != "development" for source in sources
    ):
        raise ValueError("source bundle may contain only the six development fixtures")
    development_ids = {source["fixture_id"] for source in sources}
    if len(development_ids) != DEVELOPMENT_FIXTURE_COUNT:
        raise ValueError("development source bundle must contain exactly six fixtures")
    gold_by_fixture = {gold["fixture_id"]: gold for gold in golds}
    if set(gold_by_fixture) != development_ids:
        raise ValueError("gold bundle must contain exactly the six development fixtures")
    source_by_fixture = {source["fixture_id"]: source for source in sources}
    seen_run_ids: set[str] = set()
    replicates: dict[str, set[int]] = defaultdict(set)
    for run in runs:
        required = {"run_id", "fixture_id", "replicate", "attempt", "parsed_output", "score_result"}
        if set(run) != required:
            raise ValueError(f"development run has wrong keys: {run.get('run_id', '<unknown>')}")
        if run["run_id"] in seen_run_ids:
            raise ValueError(f"duplicate run ID {run['run_id']}")
        seen_run_ids.add(run["run_id"])
        fixture_id = run["fixture_id"]
        if fixture_id not in development_ids:
            raise ValueError("synthesis input may reference development runs only")
        if run["replicate"] not in (1, 2, 3):
            raise ValueError("replicate must be 1, 2, or 3")
        model_task_id = source_by_fixture[fixture_id]["task_id"]
        if run["run_id"] != canonical_run_id(model_task_id, run["replicate"]):
            raise ValueError("run ID must be the canonical opaque task-and-replicate ID")
        replicates[fixture_id].add(run["replicate"])
        output_issues = validate_output(run["parsed_output"], model_task_id)
        if output_issues:
            raise ValueError("parsed development output does not match the strict output contract")
        if loads_object(run["attempt"]["raw_output"]) != run["parsed_output"]:
            raise ValueError("parsed output does not match the attempt raw output")
        recomputed = score(
            source_by_fixture[fixture_id], gold_by_fixture[fixture_id], run["attempt"]
        )
        if recomputed != run["score_result"]:
            raise ValueError("stored score result does not match deterministic recomputation")
        score_result = run["score_result"]
        score_keys = {
            "schema_version",
            "task_id",
            "schema_valid",
            "score",
            "components",
            "success",
            "critical_codes",
            "error_ledger",
            "requirement_hits",
        }
        if not isinstance(score_result, dict) or set(score_result) != score_keys:
            raise ValueError("score result has unknown or missing fields")
        if score_result["schema_version"] != 1 or score_result["task_id"] != model_task_id:
            raise ValueError("score result identity mismatch")
        allowed_codes = set(error_codes["codes"])
        ledger_keys = {
            "code",
            "critical",
            "points_lost",
            "requirement",
            "atom_id",
            "region_id",
            "target_class",
        }
        for entry in score_result["error_ledger"]:
            if (
                not isinstance(entry, dict)
                or not {"code", "critical", "points_lost"}.issubset(entry)
                or not set(entry).issubset(ledger_keys)
            ):
                raise ValueError("score ledger contains unknown or missing fields")
            if entry["code"] not in allowed_codes:
                raise ValueError("score ledger contains an unknown error code")
        if not run["score_result"]["schema_valid"]:
            raise ValueError("all 18 page development outputs must be schema-valid")
    if any(replicates[fixture_id] != {1, 2, 3} for fixture_id in development_ids):
        raise ValueError("every development fixture must have replicates 1, 2, and 3")


def select_target_classes(
    runs: list[dict[str, Any]],
    sources: list[dict[str, Any]],
) -> list[str]:
    support = support_by_class(runs, sources)
    recoverable_points: Counter[str] = Counter()
    for run in runs:
        for entry in run["score_result"]["error_ledger"]:
            if entry["code"] in TARGET_CLASSES:
                recoverable_points[entry["code"]] += entry["points_lost"]
    eligible = [
        target_class for target_class in TARGET_CLASSES if support[target_class]["supported"]
    ]
    eligible.sort(
        key=lambda target_class: (
            -recoverable_points[target_class],
            TARGET_CLASSES.index(target_class),
        )
    )
    if len(eligible) < MINIMUM_ELIGIBLE_TARGET_CLASSES:
        raise ValueError("inconclusive: insufficient development headroom")
    return eligible[:3]


def build_synthesis_input(
    runs: list[dict[str, Any]],
    sources: list[dict[str, Any]],
    golds: list[dict[str, Any]],
    error_codes: dict[str, Any],
    feedback_templates: dict[str, Any],
    lesson_schema: dict[str, Any],
    lint_rules: dict[str, Any],
    feedback_generator_sha256: str,
) -> dict[str, Any]:
    _validate_development_runs(runs, sources, golds, error_codes)
    selected = select_target_classes(runs, sources)
    ordered_runs = sorted(runs, key=lambda item: item["run_id"])
    development_runs = [
        {"run_id": run["run_id"], "output": run["parsed_output"]} for run in ordered_runs
    ]
    flattened_ledger: list[dict[str, Any]] = []
    for run in ordered_runs:
        for index, entry in enumerate(run["score_result"]["error_ledger"]):
            flattened_ledger.append(
                {
                    "run_id": run["run_id"],
                    "ledger_index": index,
                    "entry": entry,
                }
            )
    result = {
        "schema_version": 1,
        "selected_target_classes": selected,
        "development_runs": development_runs,
        "error_ledger": flattened_ledger,
        "normalized_feedback": normalize_feedback(ordered_runs, feedback_templates),
        "feedback_generator": feedback_generator_identity(
            feedback_templates,
            feedback_generator_sha256,
        ),
        "error_code_definitions": error_codes,
        "lesson_schema": lesson_schema,
        "lint_rules": lint_rules,
    }
    rendered = dumps(result)
    if MODEL_SPLIT_MARKER.search(rendered):
        raise ValueError("split identity leaked into the model-facing synthesis input")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", required=True)
    parser.add_argument("--development-bundle", required=True)
    parser.add_argument("--error-codes", required=True)
    parser.add_argument("--feedback-templates", required=True)
    parser.add_argument("--lesson-schema", required=True)
    parser.add_argument("--lint-rules", required=True)
    parser.add_argument("--feedback-generator-sha256", required=True)
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()
    runs_payload = load_object(arguments.runs)
    bundle = load_object(arguments.development_bundle)
    result = build_synthesis_input(
        runs_payload["runs"],
        bundle["sources"],
        bundle["golds"],
        load_object(arguments.error_codes),
        load_object(arguments.feedback_templates),
        load_object(arguments.lesson_schema),
        load_object(arguments.lint_rules),
        arguments.feedback_generator_sha256,
    )
    write(Path(arguments.output), result)


if __name__ == "__main__":
    main()
