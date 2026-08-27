"""Frozen aggregate gate coordinator for the page-change experiment."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import sys
from typing import Any

from .canonical import SHA256_HEX, StrictJSONError, canonical_sha256, dumps, write
from .conformance import verify_receipt as verify_conformance_receipt
from .execution import validate_record_order, validate_run_order
from .gate_evaluation import evaluate_development, evaluate_regression, evaluate_sealed
from .manifest_artifacts import (
    PAGE_ROOT,
    category_digest,
    load_canonical_artifact,
    load_manifest,
    manifest_bound_fixtures,
    scorer_digest,
    verified_manifest_artifact,
    verified_manifest_json,
)
from .promotion import promote_candidate
from .records import load_record_bundle
from .synthesis import build_synthesis_input, canonical_run_id
from .validation import TARGET_CLASSES


GIT_OBJECT_ID = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
_GATE_DOMAIN = b"swift-claw/scheduled-task-learning/page-change/aggregate-gate/v1\x00"


def build_gate_receipt(
    stage: str,
    manifest_sha256: str,
    freeze_commit: str,
    run_order_sha256: str,
    records_sha256: str,
    fixtures: dict[str, dict[str, Any]],
    expected_scorer_digest: str,
    conformance_receipt_sha256: str,
    result: dict[str, Any],
) -> dict[str, Any]:
    bindings = {
        "schema_version": 1,
        "stage": stage,
        "manifest_sha256": manifest_sha256,
        "freeze_commit": freeze_commit,
        "run_order_sha256": run_order_sha256,
        "records_sha256": records_sha256,
        "fixture_bundle_sha256": canonical_sha256(fixtures),
        "scorer_digest": expected_scorer_digest,
        "conformance_receipt_sha256": conformance_receipt_sha256,
        "result": result,
    }
    gate_sha256 = hashlib.sha256(
        _GATE_DOMAIN + dumps(bindings).encode("utf-8")
    ).hexdigest()
    return {
        **bindings,
        "gate_id": f"gate-{gate_sha256[:12]}",
    }


def _validated_prior_gate(
    path: Path,
    stage: str,
    manifest_sha256: str,
    freeze_commit: str,
    run_order_sha256: str,
    records_sha256: str,
    fixtures: dict[str, dict[str, Any]],
    expected_scorer_digest: str,
    conformance_receipt_sha256: str,
    recomputed_result: dict[str, Any],
) -> dict[str, Any]:
    receipt = load_canonical_artifact(path)
    expected = build_gate_receipt(
        stage,
        manifest_sha256,
        freeze_commit,
        run_order_sha256,
        records_sha256,
        fixtures,
        expected_scorer_digest,
        conformance_receipt_sha256,
        recomputed_result,
    )
    if receipt != expected:
        raise ValueError(f"{stage} gate receipt differs from raw-record recomputation")
    return recomputed_result


def _development_run_projection(
    records: list[dict[str, Any]],
    fixtures: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    """Project accepted aggregate records into the sole synthesis run bundle."""

    runs: list[dict[str, Any]] = []
    for record in records:
        fixture = fixtures.get(record.get("fixture_id"))
        if not isinstance(fixture, dict) or not isinstance(fixture.get("source"), dict):
            raise ValueError("development record references an unknown fixture")
        source = fixture["source"]
        runs.append(
            {
                "run_id": canonical_run_id(source["task_id"], record["replicate"]),
                "fixture_id": record["fixture_id"],
                "replicate": record["replicate"],
                "attempt": record["attempt"],
                "parsed_output": record["parsed_output"],
                "score_result": record["score_result"],
            }
        )
    return runs


def _promotion_contract_from_artifacts(
    repository_root: Path,
    manifest: dict[str, Any],
    synthesis_input_path: Path,
    development_bundle_path: Path,
    synthesis_transcript_path: Path,
    lint_report_path: Path,
    promotion_receipt_path: Path,
    active_lesson_set_path: Path,
    k_page: list[str],
    development_records: list[dict[str, Any]],
    development_fixtures: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    synthesis_input = load_canonical_artifact(synthesis_input_path)
    development_bundle = load_canonical_artifact(development_bundle_path)
    synthesis_transcript = load_canonical_artifact(synthesis_transcript_path)
    lint_report = load_canonical_artifact(lint_report_path)
    promotion_receipt = load_canonical_artifact(promotion_receipt_path)
    active_lesson_set = load_canonical_artifact(active_lesson_set_path)

    lint_rules = verified_manifest_json(
        repository_root,
        manifest,
        "lesson_linter",
        str(PAGE_ROOT / "contracts/lesson-lint-rules.json"),
        "rules",
    )
    feedback_templates = verified_manifest_json(
        repository_root,
        manifest,
        "feedback",
        str(PAGE_ROOT / "contracts/feedback-templates.json"),
        "templates",
    )
    error_codes = verified_manifest_json(
        repository_root,
        manifest,
        "configuration",
        str(PAGE_ROOT / "contracts/error-codes.json"),
        "error_codes",
    )
    lesson_schema = verified_manifest_json(
        repository_root,
        manifest,
        "schemas",
        str(PAGE_ROOT / "schemas/lesson-set.schema.json"),
        "schema",
    )
    _, synthesis_prompt_bytes = verified_manifest_artifact(
        repository_root,
        manifest,
        "prompts",
        str(PAGE_ROOT / "prompts/synthesis.md"),
        "synthesis",
    )
    try:
        synthesis_prompt = synthesis_prompt_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("synthesis prompt is not UTF-8") from error
    categories = manifest.get("categories")
    model_category = categories.get("model") if isinstance(categories, dict) else None
    model_values = model_category.get("values") if isinstance(model_category, dict) else None
    if not isinstance(model_values, dict):
        raise ValueError("manifest model values are absent or malformed")
    expected_sources = [fixture["source"] for fixture in development_fixtures.values()]
    expected_golds = [fixture["gold"] for fixture in development_fixtures.values()]
    expected_runs = _development_run_projection(development_records, development_fixtures)
    if (
        not isinstance(development_bundle, dict)
        or set(development_bundle) != {"runs", "sources", "golds"}
        or development_bundle.get("runs") != expected_runs
        or development_bundle.get("sources") != expected_sources
        or development_bundle.get("golds") != expected_golds
    ):
        raise ValueError(
            "development bundle differs from accepted development records or manifest fixtures"
        )
    rebuilt_input = build_synthesis_input(
        development_bundle["runs"],
        expected_sources,
        expected_golds,
        error_codes,
        feedback_templates,
        lesson_schema,
        lint_rules,
        category_digest(manifest, "feedback"),
    )
    if synthesis_input != rebuilt_input:
        raise ValueError("synthesis input differs from deterministic recomputation")
    if synthesis_input.get("selected_target_classes") != k_page:
        raise ValueError("synthesis target classes differ from development K_page")
    if (
        synthesis_transcript.get("synthesis_prompt") != synthesis_prompt
        or synthesis_transcript.get("feedback_generator_sha256")
        != category_digest(manifest, "feedback")
        or synthesis_transcript.get("provider_reference")
        != model_values.get("provider_route")
        or synthesis_transcript.get("wire_model") != model_values.get("wire_model")
        or synthesis_transcript.get("lint_report") != lint_report
    ):
        raise ValueError("synthesis transcript differs from manifest-bound provenance")
    recomputed = promote_candidate(
        synthesis_input,
        development_bundle,
        lint_rules,
        synthesis_transcript,
        lint_report,
    )
    if (
        recomputed["promotion_receipt"] != promotion_receipt
        or recomputed["active_lesson_set"] != active_lesson_set
    ):
        raise ValueError("promotion artifact or receipt differs from recomputation")
    return {
        "active_lesson_set": active_lesson_set,
        "promotion_receipt": promotion_receipt,
        "promotion_receipt_sha256": recomputed["promotion_receipt_sha256"],
    }


def _validated_conformance_receipt(
    repository_root: Path,
    manifest: dict[str, Any],
    receipt_path: Path,
) -> str:
    verified_manifest_json(
        repository_root,
        manifest,
        "conformance",
        str(PAGE_ROOT / "conformance/cases.json"),
        "cases",
    )
    verified_manifest_json(
        repository_root,
        manifest,
        "conformance",
        str(PAGE_ROOT / "contracts/conformance-coverage.json"),
        "coverage",
    )
    receipt = load_canonical_artifact(receipt_path)
    return verify_conformance_receipt(repository_root / PAGE_ROOT, receipt)


def _add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--approved-manifest-sha256", required=True)
    parser.add_argument("--approved-freeze-commit", required=True)
    parser.add_argument("--run-order", required=True)
    parser.add_argument("--records", required=True)
    parser.add_argument("--conformance-receipt", required=True)
    parser.add_argument("--output")


def _add_promotion_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--development-receipt", required=True)
    parser.add_argument("--development-records", required=True)
    parser.add_argument("--synthesis-input", required=True)
    parser.add_argument("--development-bundle", required=True)
    parser.add_argument("--synthesis-transcript", required=True)
    parser.add_argument("--lint-report", required=True)
    parser.add_argument("--promotion-receipt", required=True)
    parser.add_argument("--active-lesson-set", required=True)


def _parse_arguments(arguments: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="stage", required=True)
    development = subparsers.add_parser("development")
    _add_common_arguments(development)
    regression = subparsers.add_parser("regression")
    _add_common_arguments(regression)
    _add_promotion_arguments(regression)
    sealed = subparsers.add_parser("sealed")
    _add_common_arguments(sealed)
    _add_promotion_arguments(sealed)
    sealed.add_argument("--regression-receipt", required=True)
    sealed.add_argument("--regression-records", required=True)
    sealed.add_argument("--lifecycle-receipt", required=True)
    return parser.parse_args(arguments)


def run_gate(arguments: argparse.Namespace) -> dict[str, Any]:
    repository_root = Path(arguments.root)
    manifest, manifest_sha256 = load_manifest(Path(arguments.manifest))
    if (
        not isinstance(arguments.approved_manifest_sha256, str)
        or SHA256_HEX.fullmatch(arguments.approved_manifest_sha256) is None
        or arguments.approved_manifest_sha256 != manifest_sha256
    ):
        raise ValueError("manifest digest differs from the approved D6 digest")
    if (
        not isinstance(arguments.approved_freeze_commit, str)
        or GIT_OBJECT_ID.fullmatch(arguments.approved_freeze_commit) is None
    ):
        raise ValueError("approved freeze commit is not a full lowercase Git object ID")
    fixtures_by_split = {
        split: manifest_bound_fixtures(repository_root, manifest, split)
        for split in ("development", "regression", "sealed")
    }
    run_order = load_canonical_artifact(Path(arguments.run_order))
    run_order_sha256 = validate_run_order(
        repository_root,
        manifest,
        manifest_sha256,
        {
            split: set(split_fixtures)
            for split, split_fixtures in fixtures_by_split.items()
        },
        run_order,
    )
    expected_scorer_digest = scorer_digest(manifest)
    conformance_receipt_sha256 = _validated_conformance_receipt(
        repository_root,
        manifest,
        Path(arguments.conformance_receipt),
    )
    records, records_sha256 = load_record_bundle(Path(arguments.records))
    fixtures = fixtures_by_split[arguments.stage]
    validate_record_order(records, run_order, arguments.stage)

    if arguments.stage == "development":
        result = evaluate_development(records, fixtures, expected_scorer_digest)
    else:
        development_fixtures = fixtures_by_split["development"]
        development_records, development_records_sha256 = load_record_bundle(
            Path(arguments.development_records)
        )
        validate_record_order(development_records, run_order, "development")
        recomputed_development = evaluate_development(
            development_records,
            development_fixtures,
            expected_scorer_digest,
        )
        development_result = _validated_prior_gate(
            Path(arguments.development_receipt),
            "development",
            manifest_sha256,
            arguments.approved_freeze_commit,
            run_order_sha256,
            development_records_sha256,
            development_fixtures,
            expected_scorer_digest,
            conformance_receipt_sha256,
            recomputed_development,
        )
        if (
            development_result.get("outcome") != "development_ready"
            or development_result.get("passed") is not True
        ):
            raise ValueError("development gate did not produce a promotable K_page")
        k_page = development_result.get("k_page")
        if (
            not isinstance(k_page, list)
            or not 2 <= len(k_page) <= 3
            or any(target not in TARGET_CLASSES for target in k_page)
            or len(set(k_page)) != len(k_page)
        ):
            raise ValueError("development K_page is invalid")
        carrier_contract = _promotion_contract_from_artifacts(
            repository_root,
            manifest,
            Path(arguments.synthesis_input),
            Path(arguments.development_bundle),
            Path(arguments.synthesis_transcript),
            Path(arguments.lint_report),
            Path(arguments.promotion_receipt),
            Path(arguments.active_lesson_set),
            k_page,
            development_records,
            development_fixtures,
        )
        if arguments.stage == "regression":
            result = evaluate_regression(
                records,
                fixtures,
                k_page,
                expected_scorer_digest,
                carrier_contract,
            )
        else:
            regression_fixtures = fixtures_by_split["regression"]
            regression_records, regression_records_sha256 = load_record_bundle(
                Path(arguments.regression_records)
            )
            validate_record_order(regression_records, run_order, "regression")
            recomputed_regression = evaluate_regression(
                regression_records,
                regression_fixtures,
                k_page,
                expected_scorer_digest,
                carrier_contract,
            )
            regression_result = _validated_prior_gate(
                Path(arguments.regression_receipt),
                "regression",
                manifest_sha256,
                arguments.approved_freeze_commit,
                run_order_sha256,
                regression_records_sha256,
                regression_fixtures,
                expected_scorer_digest,
                conformance_receipt_sha256,
                recomputed_regression,
            )
            if (
                regression_result.get("outcome")
                not in {"regression_promoted", "regression_promoted_not_testable"}
                or regression_result.get("passed") is not True
                or regression_result.get("k_page") != k_page
            ):
                raise ValueError("regression gate did not promote the bound candidate")
            lifecycle_receipt = load_canonical_artifact(Path(arguments.lifecycle_receipt))
            sealed_contract = {
                **carrier_contract,
                "lifecycle_receipt": lifecycle_receipt,
                "lifecycle_receipt_digest": canonical_sha256(lifecycle_receipt),
            }
            result = evaluate_sealed(
                records,
                fixtures,
                k_page,
                expected_scorer_digest,
                sealed_contract,
            )
    return build_gate_receipt(
        arguments.stage,
        manifest_sha256,
        arguments.approved_freeze_commit,
        run_order_sha256,
        records_sha256,
        fixtures,
        expected_scorer_digest,
        conformance_receipt_sha256,
        result,
    )


def main(arguments: list[str] | None = None) -> int:
    parsed = _parse_arguments(arguments)
    try:
        receipt = run_gate(parsed)
    except (
        KeyError,
        OSError,
        StrictJSONError,
        TypeError,
        UnicodeError,
        ValueError,
    ) as error:
        receipt = {
            "schema_version": 1,
            "stage": parsed.stage,
            "outcome": "invalid_batch",
            "passed": False,
            "gate_failures": ["aggregate.input_invalid"],
            "input_error": str(error),
        }
        status = 2
    else:
        status = 0
    if parsed.output:
        write(Path(parsed.output), receipt)
    else:
        print(dumps(receipt), end="")
    return status


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
