"""Closed aggregate record contract and deterministic receipt sealing."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .canonical import SHA256_HEX, StrictJSONError, canonical_sha256, loads_object
from .manifest_artifacts import load_canonical_artifact
from .scorer import score
from .validation import validate_attempt

RECORD_KEYS = {
    "attempt_id",
    "fixture_id",
    "family_id",
    "stage",
    "frozen_order_index",
    "frozen_order_key",
    "block_index",
    "block_order_key",
    "condition",
    "replicate",
    "parsed_output",
    "attempt",
    "score_result",
    "process_uuid",
    "conversation_id",
    "lesson_digest",
    "lesson_set_id",
    "lesson_ids",
    "lock_acquisition_id",
    "attempt_digest",
    "scorer_digest",
    "score_receipt_digest",
    "lifecycle_generation",
    "lifecycle_receipt_digest",
    "carrier_receipt",
    "carrier_receipt_sha256",
    "result_or_envelope_sha256",
    "replacement_of_attempt_id",
    "replacement_ordinal",
    "original_attempt_evidence_sha256",
}
CARRIER_RECEIPT_KEYS = {
    "source_sha256",
    "task_id",
    "lesson_source",
    "lesson_set_sha256",
    "lesson_set_id",
    "lesson_ids",
    "input_sha256",
    "promotion_receipt_sha256",
}
SKELETON_KEYS = {
    "attempt_id",
    "stage",
    "frozen_order_index",
    "frozen_order_key",
    "block_index",
    "block_order_key",
    "condition",
    "replicate",
    "process_uuid",
    "conversation_id",
    "lifecycle_generation",
    "lifecycle_receipt_digest",
    "lock_acquisition_id",
    "result_or_envelope_sha256",
    "replacement_of_attempt_id",
    "replacement_ordinal",
    "original_attempt_evidence_sha256",
}
STAGE_CONDITIONS = {
    "development": {"clean"},
    "regression": {"clean", "lesson-conditioned"},
    "sealed-pre-restart": {"clean", "lesson-conditioned"},
    "sealed-post-restart": {"post-restart lesson-conditioned"},
}


def _score_receipt_payload(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "attempt_id": record["attempt_id"],
        "attempt_digest": record["attempt_digest"],
        "condition": record["condition"],
        "fixture_id": record["fixture_id"],
        "original_attempt_evidence_sha256": record["original_attempt_evidence_sha256"],
        "parsed_output": record["parsed_output"],
        "replicate": record["replicate"],
        "replacement_of_attempt_id": record["replacement_of_attempt_id"],
        "replacement_ordinal": record["replacement_ordinal"],
        "result_or_envelope_sha256": record["result_or_envelope_sha256"],
        "score_result": record["score_result"],
        "scorer_digest": record["scorer_digest"],
    }


def validate_records(
    records: list[dict[str, Any]],
    fixtures: dict[str, dict[str, Any]],
    conditions: tuple[str, ...],
    expected_scorer_digest: str,
    *,
    require_complete: bool = True,
) -> list[str]:
    failures: list[str] = []
    if not isinstance(records, list):
        return ["record.batch_shape"]
    if not isinstance(fixtures, dict) or any(not isinstance(key, str) for key in fixtures):
        return ["record.fixture_bundle"]
    expected = {
        (condition, fixture_id, replicate)
        for condition in conditions
        for fixture_id in fixtures
        for replicate in (1, 2, 3)
    }
    seen: set[tuple[str, str, int]] = set()
    for record in records:
        if not isinstance(record, dict) or set(record) != RECORD_KEYS:
            failures.append("record.shape")
            continue
        if (
            not isinstance(record["attempt_id"], str)
            or not record["attempt_id"]
            or not isinstance(record["stage"], str)
            or not record["stage"]
            or not isinstance(record["frozen_order_index"], int)
            or isinstance(record["frozen_order_index"], bool)
            or record["frozen_order_index"] < 0
            or not isinstance(record["frozen_order_key"], str)
            or SHA256_HEX.fullmatch(record["frozen_order_key"]) is None
            or not isinstance(record["block_index"], int)
            or isinstance(record["block_index"], bool)
            or record["block_index"] < 0
            or not isinstance(record["block_order_key"], str)
            or SHA256_HEX.fullmatch(record["block_order_key"]) is None
            or not isinstance(record["condition"], str)
            or not isinstance(record["fixture_id"], str)
            or not isinstance(record["family_id"], str)
            or not isinstance(record["replicate"], int)
            or isinstance(record["replicate"], bool)
            or not isinstance(record["process_uuid"], str)
            or not record["process_uuid"].strip()
            or not isinstance(record["conversation_id"], str)
            or not record["conversation_id"].strip()
            or not isinstance(record["lock_acquisition_id"], str)
            or not record["lock_acquisition_id"].strip()
            or not isinstance(record["lesson_digest"], str)
            or not isinstance(record["lesson_set_id"], str)
            or not isinstance(record["attempt_digest"], str)
            or not isinstance(record["scorer_digest"], str)
            or not isinstance(record["score_receipt_digest"], str)
            or not isinstance(record["lifecycle_generation"], str)
            or not isinstance(record["lifecycle_receipt_digest"], str)
            or not isinstance(record["carrier_receipt_sha256"], str)
            or not isinstance(record["result_or_envelope_sha256"], str)
            or SHA256_HEX.fullmatch(record["result_or_envelope_sha256"]) is None
            or (
                record["replacement_of_attempt_id"] is not None
                and (
                    not isinstance(record["replacement_of_attempt_id"], str)
                    or not record["replacement_of_attempt_id"]
                )
            )
            or not isinstance(record["replacement_ordinal"], int)
            or isinstance(record["replacement_ordinal"], bool)
            or record["replacement_ordinal"] not in (0, 1)
            or (
                (record["replacement_ordinal"] == 0)
                != (record["replacement_of_attempt_id"] is None)
            )
            or (
                (record["replacement_ordinal"] == 0)
                != (record["original_attempt_evidence_sha256"] is None)
            )
            or (
                record["original_attempt_evidence_sha256"] is not None
                and (
                    not isinstance(record["original_attempt_evidence_sha256"], str)
                    or SHA256_HEX.fullmatch(record["original_attempt_evidence_sha256"]) is None
                )
            )
            or record["replacement_of_attempt_id"] == record["attempt_id"]
            or not isinstance(record["lesson_ids"], list)
            or any(not isinstance(value, str) for value in record["lesson_ids"])
        ):
            failures.append("record.field_types")
            continue
        key = (record["condition"], record["fixture_id"], record["replicate"])
        if key in seen:
            failures.append("record.duplicate")
        seen.add(key)
        fixture = fixtures.get(record["fixture_id"])
        fixture_is_valid = (
            isinstance(fixture, dict)
            and set(fixture) == {"family_id", "source", "gold"}
            and isinstance(fixture.get("family_id"), str)
            and isinstance(fixture.get("source"), dict)
            and isinstance(fixture.get("gold"), dict)
        )
        if not fixture_is_valid:
            failures.append("record.fixture_bundle")
            fixture = None
        elif isinstance(fixture, dict) and record["family_id"] != fixture["family_id"]:
            failures.append("record.fixture_identity")
        if record["condition"] not in conditions or record["replicate"] not in (1, 2, 3):
            failures.append("record.condition_or_replicate")
        if (
            not isinstance(record["score_result"], dict)
            or (
                record["parsed_output"] is not None
                and not isinstance(record["parsed_output"], dict)
            )
            or not isinstance(record["attempt"], dict)
        ):
            failures.append("record.result_shape")
        elif validate_attempt(record["attempt"], require_request_provenance=True):
            failures.append("record.attempt_contract")
        if len(set(record["lesson_ids"])) != len(record["lesson_ids"]):
            failures.append("record.lesson_ids")
        if record["scorer_digest"] != expected_scorer_digest:
            failures.append("record.scorer_digest")
        carrier = record["carrier_receipt"]
        if not isinstance(carrier, dict) or set(carrier) != CARRIER_RECEIPT_KEYS:
            failures.append("record.carrier_receipt_shape")
        elif (
            any(
                not isinstance(carrier[field], str) or not carrier[field]
                for field in CARRIER_RECEIPT_KEYS - {"lesson_ids", "promotion_receipt_sha256"}
            )
            or not isinstance(carrier["lesson_ids"], list)
            or any(not isinstance(value, str) for value in carrier["lesson_ids"])
            or (
                carrier["promotion_receipt_sha256"] is not None
                and (
                    not isinstance(carrier["promotion_receipt_sha256"], str)
                    or SHA256_HEX.fullmatch(carrier["promotion_receipt_sha256"]) is None
                )
            )
            or carrier["lesson_source"] not in {"clean", "artifact", "durable_active"}
            or SHA256_HEX.fullmatch(carrier["source_sha256"]) is None
            or SHA256_HEX.fullmatch(carrier["lesson_set_sha256"]) is None
            or SHA256_HEX.fullmatch(carrier["input_sha256"]) is None
        ):
            failures.append("record.carrier_receipt_fields")
        else:
            if record["carrier_receipt_sha256"] != canonical_sha256(carrier):
                failures.append("record.carrier_receipt_digest")
            if (
                carrier["lesson_set_sha256"] != record["lesson_digest"]
                or carrier["lesson_set_id"] != record["lesson_set_id"]
                or carrier["lesson_ids"] != record["lesson_ids"]
            ):
                failures.append("record.carrier_receipt_lesson_identity")
        try:
            actual_attempt_digest = canonical_sha256(record["attempt"])
        except (TypeError, ValueError, UnicodeError):
            failures.append("record.attempt_payload")
            continue
        if record["attempt_digest"] != actual_attempt_digest:
            failures.append("record.attempt_digest")
        if fixture is not None:
            expected_source_digest = canonical_sha256(fixture["source"])
            if (
                isinstance(carrier, dict)
                and set(carrier) == CARRIER_RECEIPT_KEYS
                and (
                    carrier["source_sha256"] != expected_source_digest
                    or carrier["task_id"] != fixture["source"].get("task_id")
                )
            ):
                failures.append("record.carrier_receipt_source_identity")
            try:
                recomputed_result = score(fixture["source"], fixture["gold"], record["attempt"])
            except (KeyError, TypeError, ValueError, UnicodeError):
                failures.append("record.scorer_recomputation")
            else:
                raw_output = record["attempt"].get("raw_output")
                try:
                    recomputed_output = (
                        loads_object(raw_output) if isinstance(raw_output, str) else None
                    )
                except StrictJSONError:
                    recomputed_output = None
                if recomputed_result != record["score_result"]:
                    failures.append("record.score_recomputation")
                if recomputed_output != record["parsed_output"]:
                    failures.append("record.parsed_output_recomputation")
        try:
            expected_receipt = canonical_sha256(_score_receipt_payload(record))
        except (TypeError, ValueError, UnicodeError):
            failures.append("record.score_receipt_payload")
            continue
        if record["score_receipt_digest"] != expected_receipt:
            failures.append("record.score_receipt")
    if require_complete:
        missing = expected - seen
        extra = seen - expected
        if missing:
            failures.append("record.missing")
        if extra:
            failures.append("record.extra")
    return list(dict.fromkeys(failures))


def seal_score_receipts(
    records: list[dict[str, Any]],
    fixtures: dict[str, dict[str, Any]],
    scorer_digest: str,
) -> None:
    """Regenerate frozen score artifacts, then add their provenance receipt."""

    for record in records:
        fixture = fixtures[record["fixture_id"]]
        record["score_result"] = score(fixture["source"], fixture["gold"], record["attempt"])
        raw_output = record["attempt"].get("raw_output")
        try:
            record["parsed_output"] = (
                loads_object(raw_output) if isinstance(raw_output, str) else None
            )
        except StrictJSONError:
            record["parsed_output"] = None
        record["attempt_digest"] = canonical_sha256(record["attempt"])
        record["carrier_receipt_sha256"] = canonical_sha256(record["carrier_receipt"])
        record["scorer_digest"] = scorer_digest
        record["score_receipt_digest"] = canonical_sha256(_score_receipt_payload(record))


def load_record_bundle(path: Path) -> tuple[list[dict[str, Any]], str]:
    payload = load_canonical_artifact(path)
    if (
        set(payload) != {"schema_version", "records"}
        or payload.get("schema_version") != 1
        or isinstance(payload.get("schema_version"), bool)
        or not isinstance(payload.get("records"), list)
    ):
        raise ValueError("aggregate record bundle has unknown, missing, or invalid fields")
    return payload["records"], canonical_sha256(payload)
