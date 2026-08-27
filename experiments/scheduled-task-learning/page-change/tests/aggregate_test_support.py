from __future__ import annotations

import copy
import hashlib

from page_benchmark.canonical import canonical_sha256, dumps, load_object
from page_benchmark.execution import stage_attempts
from page_benchmark.gate_evaluation import (
    CANONICAL_EMPTY_LESSON_DIGEST,
)
from page_benchmark.gate_evaluation import (
    evaluate_development as _evaluate_development,
)
from page_benchmark.gate_evaluation import (
    evaluate_regression as _evaluate_regression,
)
from page_benchmark.gate_evaluation import (
    evaluate_sealed as _evaluate_sealed,
)
from page_benchmark.lessons import lint_candidate
from page_benchmark.materialize import materialize
from page_benchmark.promotion import promote_candidate
from page_benchmark.records import seal_score_receipts
from page_benchmark.scorer import score
from page_benchmark.synthesis import build_synthesis_input, canonical_run_id
from page_benchmark.validation import (
    FROZEN_PROVIDER_REFERENCE,
    FROZEN_WIRE_MODEL,
    SUCCESSFUL_FILE_READ_EVENT,
)

from path_test_support import PAGE_ROOT

# Re-exported for other test modules; mypy's strict reexport check requires this
# to be explicit since the aliases above rename their source symbols.
__all__ = [
    "PAGE_ROOT",
    "_evaluate_development",
    "_evaluate_regression",
    "_evaluate_sealed",
]

SCORER_DIGEST = hashlib.sha256(b"page-change-test-scorer").hexdigest()
FEEDBACK_GENERATOR_DIGEST = hashlib.sha256(b"page-change-test-feedback-generator").hexdigest()
REPOSITORY_ROOT = PAGE_ROOT.parents[2]
FREEZE_COMMIT = "f" * 40
VALID_LESSON_TEXTS = {
    "noise.volatile_value": (
        "Treat volatile counters and rotating telemetry as cosmetic when meaning is preserved."
    ),
    "noise.time_or_build_metadata": (
        "Ignore generated timestamp and build metadata when user-facing state is unchanged."
    ),
    "noise.structure_or_order": (
        "Classify layout or reorder changes as cosmetic when items and meaning are preserved."
    ),
}


def evaluate_development(records: list[dict], fixtures: dict[str, dict]) -> dict:
    _rescore(records, fixtures)
    return _evaluate_development(records, fixtures, SCORER_DIGEST)


def evaluate_regression(records: list[dict], fixtures: dict[str, dict], k_page: list[str]) -> dict:
    _rescore(records, fixtures)
    return _evaluate_regression(
        records,
        fixtures,
        k_page,
        SCORER_DIGEST,
        copy.deepcopy(PROMOTION_CONTRACT),
    )


def evaluate_sealed(records: list[dict], fixtures: dict[str, dict], k_page: list[str]) -> dict:
    _rescore(records, fixtures)
    return _evaluate_sealed(records, fixtures, k_page, SCORER_DIGEST, _carrier_contract(records))


def _noise_atoms(fixture: dict, *, excluding_target_class: str | None = None) -> list[dict]:
    return [
        atom
        for atom in fixture["gold"]["atoms"]
        if atom["kind"] == "noise" and atom["target_class"] != excluding_target_class
    ]


def _fixture_id_for_verdict(fixtures: dict[str, dict], verdict: str) -> str:
    return next(
        fixture_id
        for fixture_id, fixture in fixtures.items()
        if fixture["gold"]["expected_verdict"] == verdict
    )


def _first_family_ids(fixtures: dict[str, dict], count: int) -> set[str]:
    return {fixture["family_id"] for fixture in list(fixtures.values())[:count]}


def _valid_lesson_candidate(target_classes: list[str]) -> dict:
    return {
        "schema_version": 1,
        "lessons": [
            {"target_class": target_class, "text": VALID_LESSON_TEXTS[target_class]}
            for target_class in target_classes
        ],
    }


def _records(
    fixtures: dict[str, dict],
    conditions: tuple[str, ...],
    *,
    scorer_digest: str = SCORER_DIGEST,
) -> list[dict]:
    records: list[dict] = []
    stage_order_indexes: dict[str, int] = {}
    stage_blocks: dict[str, dict[tuple[str, int], int]] = {}
    for fixture_id, fixture in fixtures.items():
        material = [atom for atom in fixture["gold"]["atoms"] if atom["kind"] == "material"]
        noise = _noise_atoms(fixture)
        for replicate in (1, 2, 3):
            for condition in conditions:
                split = fixture["source"]["split"]
                stage = {
                    "development": "development",
                    "regression": "regression",
                }.get(
                    split,
                    (
                        "sealed-post-restart"
                        if condition == "post-restart lesson-conditioned"
                        else "sealed-pre-restart"
                    ),
                )
                order_index = stage_order_indexes.get(stage, 0)
                stage_order_indexes[stage] = order_index + 1
                blocks = stage_blocks.setdefault(stage, {})
                block_identity = (fixture_id, replicate)
                block_index = blocks.setdefault(block_identity, len(blocks))
                block_order_key = hashlib.sha256(
                    f"block:{stage}:{fixture_id}:{replicate}".encode()
                ).hexdigest()
                frozen_order_key = hashlib.sha256(
                    f"attempt:{stage}:{block_index}:{condition}".encode()
                ).hexdigest()
                attempt_id = f"attempt-{frozen_order_key[:12]}"
                false_positives = noise if condition == "clean" else []
                selected = material + false_positives
                output = {
                    "schema_version": 1,
                    "task_id": fixture["gold"]["task_id"],
                    "verdict": "material" if selected else fixture["gold"]["expected_verdict"],
                    "material_region_ids": [atom["region_id"] for atom in selected],
                    "ignored_region_ids": [
                        atom["region_id"] for atom in noise if atom not in false_positives
                    ],
                    "evidence": [
                        {
                            "region_id": atom["region_id"],
                            "before": atom["before"],
                            "after": atom["after"],
                        }
                        for atom in selected
                    ],
                }
                lesson_source = {
                    "clean": "clean",
                    "lesson-conditioned": "artifact",
                    "post-restart lesson-conditioned": "durable_active",
                }[condition]
                if condition == "clean":
                    lesson_digest = CANONICAL_EMPTY_LESSON_DIGEST
                    lesson_ids = []
                    lesson_set_id = "empty"
                    active_lesson_set = {
                        "schema_version": 1,
                        "lesson_set_id": "empty",
                        "lessons": [],
                    }
                    promotion_receipt_sha256 = None
                else:
                    receipt = PROMOTION_CONTRACT["promotion_receipt"]
                    lesson_digest = receipt["active_lesson_set_sha256"]
                    lesson_ids = receipt["lesson_ids"]
                    lesson_set_id = receipt["active_lesson_set_id"]
                    active_lesson_set = PROMOTION_CONTRACT["active_lesson_set"]
                    promotion_receipt_sha256 = PROMOTION_CONTRACT["promotion_receipt_sha256"]
                process_uuid = f"process-{condition}-{fixture_id}-{replicate}"
                lock_acquisition_id = f"lock-{condition}-{fixture_id}-{replicate}"
                conversation_id = f"conversation-{condition}-{fixture_id}-{replicate}"
                carrier_receipt = {
                    "source_sha256": hashlib.sha256(
                        dumps(fixture["source"]).encode("utf-8")
                    ).hexdigest(),
                    "task_id": fixture["source"]["task_id"],
                    "lesson_source": lesson_source,
                    "lesson_set_sha256": lesson_digest,
                    "lesson_set_id": lesson_set_id,
                    "lesson_ids": lesson_ids,
                    "input_sha256": canonical_sha256(
                        materialize(fixture["source"], active_lesson_set)
                    ),
                    "promotion_receipt_sha256": promotion_receipt_sha256,
                }
                attempt = {
                    "runtime_outcome": "completed",
                    "raw_output": dumps(output).rstrip("\n"),
                    "tool_events": [dict(SUCCESSFUL_FILE_READ_EVENT)],
                    "responses_requests": [
                        {
                            "sequence": 1,
                            "requested_model": FROZEN_WIRE_MODEL,
                            "body_byte_count": 1_024,
                            "body_sha256": hashlib.sha256(b"page-change-first-request").hexdigest(),
                            "normalized_structure_sha256": hashlib.sha256(
                                b"page-change-first-request"
                            ).hexdigest(),
                            "untrusted_fence_present": False,
                            "untrusted_payload_sha256": None,
                        },
                        {
                            "sequence": 2,
                            "requested_model": FROZEN_WIRE_MODEL,
                            "body_byte_count": 2_048,
                            "body_sha256": hashlib.sha256(
                                f"page-change-second-request:{condition}:{fixture_id}:{replicate}".encode()
                            ).hexdigest(),
                            "normalized_structure_sha256": hashlib.sha256(
                                f"page-change-second-structure:{condition}:{fixture_id}".encode()
                            ).hexdigest(),
                            "untrusted_fence_present": True,
                            "untrusted_payload_sha256": carrier_receipt["input_sha256"],
                        },
                    ],
                }
                result_or_envelope_sha256 = hashlib.sha256(
                    dumps({"attempt_id": attempt_id, "attempt": attempt}).encode("utf-8")
                ).hexdigest()
                records.append(
                    {
                        "attempt_id": attempt_id,
                        "fixture_id": fixture_id,
                        "family_id": fixture["family_id"],
                        "stage": stage,
                        "frozen_order_index": order_index,
                        "frozen_order_key": frozen_order_key,
                        "block_index": block_index,
                        "block_order_key": block_order_key,
                        "condition": condition,
                        "replicate": replicate,
                        "parsed_output": output,
                        "attempt": attempt,
                        "score_result": score(fixture["source"], fixture["gold"], attempt),
                        "process_uuid": process_uuid,
                        "lock_acquisition_id": lock_acquisition_id,
                        "conversation_id": conversation_id,
                        "lesson_digest": lesson_digest,
                        "lesson_set_id": lesson_set_id,
                        "lesson_ids": lesson_ids,
                        "attempt_digest": "",
                        "scorer_digest": "",
                        "score_receipt_digest": "",
                        "lifecycle_generation": "post-restart"
                        if condition.startswith("post-restart")
                        else "pre-restart",
                        "lifecycle_receipt_digest": "",
                        "carrier_receipt": carrier_receipt,
                        "carrier_receipt_sha256": "",
                        "result_or_envelope_sha256": result_or_envelope_sha256,
                        "replacement_of_attempt_id": None,
                        "replacement_ordinal": 0,
                        "original_attempt_evidence_sha256": None,
                    }
                )
    if "post-restart lesson-conditioned" in conditions:
        _bind_lifecycle_receipt(records)
    seal_score_receipts(records, fixtures, scorer_digest)
    return records


def _rescore(
    records: list[dict],
    fixtures: dict[str, dict],
    *,
    scorer_digest: str = SCORER_DIGEST,
) -> None:
    for record in records:
        if isinstance(record.get("parsed_output"), dict):
            record["attempt"]["raw_output"] = dumps(record["parsed_output"]).rstrip("\n")
    seal_score_receipts(records, fixtures, scorer_digest)


def _bind_lifecycle_receipt(
    records: list[dict],
    *,
    durable_lesson_digest: str | None = None,
    durable_lesson_set_id: str | None = None,
    durable_lesson_ids: list[str] | None = None,
    replace_existing: bool = True,
) -> tuple[dict, str]:
    if durable_lesson_digest is None:
        lesson_digests = {
            record["lesson_digest"] for record in records if record["condition"] != "clean"
        }
        if len(lesson_digests) != 1:
            raise AssertionError("test lifecycle requires one lesson digest")
        durable_lesson_digest = next(iter(lesson_digests))
    if durable_lesson_set_id is None:
        lesson_set_ids = {
            record["lesson_set_id"] for record in records if record["condition"] != "clean"
        }
        if len(lesson_set_ids) != 1:
            raise AssertionError("test lifecycle requires one lesson-set ID")
        durable_lesson_set_id = next(iter(lesson_set_ids))
    if durable_lesson_ids is None:
        ordered_lesson_ids = {
            tuple(record["lesson_ids"]) for record in records if record["condition"] != "clean"
        }
        if len(ordered_lesson_ids) != 1:
            raise AssertionError("test lifecycle requires one ordered lesson-ID list")
        durable_lesson_ids = list(next(iter(ordered_lesson_ids)))
    lesson_records = [record for record in records if record["condition"] == "lesson-conditioned"]
    restart_records = [
        record for record in records if record["condition"] == "post-restart lesson-conditioned"
    ]
    publisher = max(lesson_records, key=lambda record: record["frozen_order_index"])
    first_reload = min(restart_records, key=lambda record: record["frozen_order_index"])
    lifecycle = {
        "schema_version": 1,
        "publisher_attempt_id": publisher["attempt_id"],
        "publisher_frozen_order_key": publisher["frozen_order_key"],
        "publisher_process_uuid": publisher["process_uuid"],
        "publisher_lock_acquisition_id": publisher["lock_acquisition_id"],
        "first_reload_attempt_id": first_reload["attempt_id"],
        "first_reload_frozen_order_key": first_reload["frozen_order_key"],
        "first_reload_process_uuid": first_reload["process_uuid"],
        "first_reload_lock_acquisition_id": first_reload["lock_acquisition_id"],
        "durable_lesson_digest": durable_lesson_digest,
        "durable_lesson_set_id": durable_lesson_set_id,
        "durable_lesson_ids": durable_lesson_ids,
        "workspace_was_empty": True,
        "input_was_regenerated": True,
        "lock_was_released": True,
        "lock_was_reacquired": True,
    }
    lifecycle_digest = canonical_sha256(lifecycle)
    for record in records:
        if replace_existing or not record["lifecycle_receipt_digest"]:
            record["lifecycle_receipt_digest"] = lifecycle_digest
    return lifecycle, lifecycle_digest


def _carrier_contract(records: list[dict]) -> dict:
    lifecycle, lifecycle_digest = _bind_lifecycle_receipt(
        records,
        durable_lesson_digest=LESSON_DIGEST,
        replace_existing=False,
    )
    return {
        **copy.deepcopy(PROMOTION_CONTRACT),
        "lifecycle_receipt": lifecycle,
        "lifecycle_receipt_digest": lifecycle_digest,
    }


def _condition(records: list[dict], name: str) -> list[dict]:
    return [record for record in records if record["condition"] == name]


def _actual_fixtures(split: str) -> dict[str, dict]:
    split_contract = load_object(PAGE_ROOT / "contracts/splits.json")
    fixtures: dict[str, dict] = {}
    for entry in split_contract["splits"][split]:
        source = load_object(PAGE_ROOT / entry["source"])
        gold = load_object(PAGE_ROOT / entry["gold"])
        fixtures[entry["fixture_id"]] = {
            "family_id": entry["family_id"],
            "source": source,
            "gold": gold,
        }
    return fixtures


def _bind_records_to_run_order(
    records: list[dict],
    fixtures: dict[str, dict],
    run_order: dict,
    stage: str,
) -> list[dict]:
    by_identity = {
        (record["fixture_id"], record["replicate"], record["condition"]): record
        for record in records
    }
    ordered = []
    for attempt in stage_attempts(run_order, stage):
        identity = (
            attempt["fixture_id"],
            attempt["replicate_index"],
            attempt["condition"],
        )
        record = by_identity[identity]
        record["stage"] = (
            "sealed-pre-restart"
            if stage == "sealed" and attempt["condition"] != "post-restart lesson-conditioned"
            else "sealed-post-restart"
            if stage == "sealed"
            else stage
        )
        record["frozen_order_index"] = attempt["order_index"]
        record["frozen_order_key"] = attempt["attempt_order_key"]
        record["block_index"] = attempt["block_index"]
        record["block_order_key"] = attempt["block_order_key"]
        record["attempt_id"] = f"attempt-{attempt['attempt_order_key'][:12]}"
        record["result_or_envelope_sha256"] = hashlib.sha256(
            dumps(
                {
                    "attempt_id": record["attempt_id"],
                    "attempt": record["attempt"],
                }
            ).encode("utf-8")
        ).hexdigest()
        ordered.append(record)
    if len(ordered) != len(records):
        raise AssertionError("test records differ from the derived run order")
    if ordered:
        seal_score_receipts(ordered, fixtures, ordered[0]["scorer_digest"])
    return ordered


def _development_bundle(
    records: list[dict],
    fixtures: dict[str, dict],
) -> dict:
    runs = []
    for record in records:
        source = fixtures[record["fixture_id"]]["source"]
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
    return {
        "runs": runs,
        "sources": [fixture["source"] for fixture in fixtures.values()],
        "golds": [fixture["gold"] for fixture in fixtures.values()],
    }


def _synthesis_transcript(
    synthesis_input: dict,
    candidate: dict,
    lint_report: dict,
) -> dict:
    prompt = (PAGE_ROOT / "prompts/synthesis.md").read_text(encoding="utf-8")
    feedback_generator = synthesis_input["feedback_generator"]
    return {
        "schema_version": 1,
        "synthesis_prompt": prompt,
        "synthesis_prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
        "synthesis_input": synthesis_input,
        "synthesis_input_sha256": canonical_sha256(synthesis_input),
        "selected_target_classes": synthesis_input["selected_target_classes"],
        "feedback_generator_version": feedback_generator["version"],
        "feedback_generator_sha256": feedback_generator["sha256"],
        "provider_reference": FROZEN_PROVIDER_REFERENCE,
        "wire_model": FROZEN_WIRE_MODEL,
        "attempts": [
            {
                "attempt_index": 1,
                "attempt_id": "synthesis-attempt-1",
                "process_uuid": "synthesis-process-1",
                "conversation_id": "synthesis-conversation-1",
                "runtime_outcome": "completed",
                "raw_output": dumps(candidate).rstrip("\n"),
            }
        ],
        "lint_report": lint_report,
        "lint_report_sha256": canonical_sha256(lint_report),
    }


def _promotion_from_development(
    bundle: dict,
    *,
    feedback_generator_digest: str = FEEDBACK_GENERATOR_DIGEST,
) -> tuple[dict, dict, dict, dict]:
    error_codes = load_object(PAGE_ROOT / "contracts/error-codes.json")
    feedback_templates = load_object(PAGE_ROOT / "contracts/feedback-templates.json")
    lesson_schema = load_object(PAGE_ROOT / "schemas/lesson-set.schema.json")
    lint_rules = load_object(PAGE_ROOT / "contracts/lesson-lint-rules.json")
    synthesis_input = build_synthesis_input(
        bundle["runs"],
        bundle["sources"],
        bundle["golds"],
        error_codes,
        feedback_templates,
        lesson_schema,
        lint_rules,
        feedback_generator_digest,
    )
    candidate = _valid_lesson_candidate(synthesis_input["selected_target_classes"])
    lint_report = lint_candidate(
        candidate,
        synthesis_input["selected_target_classes"],
        bundle["runs"],
        bundle["sources"],
        bundle["golds"],
        lint_rules,
    )
    transcript = _synthesis_transcript(synthesis_input, candidate, lint_report)
    promotion = promote_candidate(
        synthesis_input,
        bundle,
        lint_rules,
        transcript,
        lint_report,
    )
    return synthesis_input, transcript, lint_report, promotion


def _default_promotion_contract() -> dict:
    fixtures = _actual_fixtures("development")
    records = _records(fixtures, ("clean",))
    bundle = _development_bundle(records, fixtures)
    _, _, _, promotion = _promotion_from_development(bundle)
    return {
        "active_lesson_set": promotion["active_lesson_set"],
        "promotion_receipt": promotion["promotion_receipt"],
        "promotion_receipt_sha256": promotion["promotion_receipt_sha256"],
    }


PROMOTION_CONTRACT = _default_promotion_contract()
LESSON_DIGEST = PROMOTION_CONTRACT["promotion_receipt"]["active_lesson_set_sha256"]


def _bind_promotion(
    records: list[dict],
    fixtures: dict[str, dict],
    promotion: dict,
    *,
    scorer_digest: str = SCORER_DIGEST,
) -> None:
    active = promotion["active_lesson_set"]
    receipt = promotion["promotion_receipt"]
    for record in records:
        if record["condition"] == "clean":
            continue
        record["lesson_digest"] = receipt["active_lesson_set_sha256"]
        record["lesson_set_id"] = receipt["active_lesson_set_id"]
        record["lesson_ids"] = receipt["lesson_ids"]
        carrier = record["carrier_receipt"]
        carrier["lesson_set_sha256"] = record["lesson_digest"]
        carrier["lesson_set_id"] = record["lesson_set_id"]
        carrier["lesson_ids"] = record["lesson_ids"]
        carrier["promotion_receipt_sha256"] = promotion["promotion_receipt_sha256"]
        carrier["input_sha256"] = canonical_sha256(
            materialize(fixtures[record["fixture_id"]]["source"], active)
        )
        record["attempt"]["responses_requests"][1]["untrusted_payload_sha256"] = carrier[
            "input_sha256"
        ]
    seal_score_receipts(records, fixtures, scorer_digest)


def _classify(
    record: dict,
    fixture: dict,
    *,
    selected_noise: list[dict] | None = None,
    include_material: bool = True,
) -> None:
    material = [atom for atom in fixture["gold"]["atoms"] if atom["kind"] == "material"]
    selected = (material if include_material else []) + (selected_noise or [])
    ignored = [atom for atom in fixture["gold"]["atoms"] if atom not in selected]
    record["parsed_output"].update(
        verdict="material" if selected else fixture["gold"]["expected_verdict"],
        material_region_ids=[atom["region_id"] for atom in selected],
        ignored_region_ids=[atom["region_id"] for atom in ignored],
        evidence=[
            {"region_id": atom["region_id"], "before": atom["before"], "after": atom["after"]}
            for atom in selected
        ],
    )
