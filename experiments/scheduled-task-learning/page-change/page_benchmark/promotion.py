"""One-shot deterministic promotion from a recorded synthesis transcript."""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path
from typing import Any

from .canonical import SHA256_HEX, canonical_sha256, dumps, load_object, loads_object, write
from .lessons import lint_candidate
from .validation import FROZEN_PROVIDER_REFERENCE, FROZEN_WIRE_MODEL, TARGET_CLASSES

_CANDIDATE_DOMAIN = b"swift-claw/scheduled-task-learning/page-change/candidate/v1\x00"
_LESSON_DOMAIN = b"swift-claw/scheduled-task-learning/page-change/lesson/v1\x00"
_PROMOTION_DOMAIN = b"swift-claw/scheduled-task-learning/page-change/promotion/v1\x00"
_SYNTHESIS_INPUT_KEYS = {
    "schema_version",
    "selected_target_classes",
    "development_runs",
    "error_ledger",
    "normalized_feedback",
    "feedback_generator",
    "error_code_definitions",
    "lesson_schema",
    "lint_rules",
}
_DEVELOPMENT_BUNDLE_KEYS = {"runs", "sources", "golds"}
_TRANSCRIPT_KEYS = {
    "schema_version",
    "synthesis_prompt",
    "synthesis_prompt_sha256",
    "synthesis_input",
    "synthesis_input_sha256",
    "selected_target_classes",
    "feedback_generator_version",
    "feedback_generator_sha256",
    "provider_reference",
    "wire_model",
    "attempts",
    "lint_report",
    "lint_report_sha256",
}
_TRANSCRIPT_ATTEMPT_KEYS = {
    "attempt_index",
    "attempt_id",
    "process_uuid",
    "conversation_id",
    "runtime_outcome",
    "raw_output",
}
PROMOTION_RECEIPT_KEYS = {
    "schema_version",
    "promotion_id",
    "development_bundle_sha256",
    "synthesis_input_sha256",
    "synthesis_transcript_sha256",
    "synthesis_prompt_sha256",
    "feedback_generator_version",
    "feedback_generator_sha256",
    "provider_reference",
    "wire_model",
    "selected_target_classes",
    "lint_rules_sha256",
    "lint_report_sha256",
    "candidate_sha256",
    "active_lesson_set_sha256",
    "active_lesson_set_id",
    "lesson_ids",
    "canonical_byte_count",
}
_CONTENT_ID = re.compile(r"^(?:promotion|set|lesson)-[0-9a-f]{12}$")
_MAX_ACTIVE_LESSONS = 3
_MAX_LESSON_TEXT_LENGTH = 400
_MAX_SYNTHESIS_ATTEMPTS = 2


def _domain_sha256(domain: bytes, value: Any) -> str:
    return hashlib.sha256(domain + dumps(value).encode("utf-8")).hexdigest()


def validate_promotion_artifacts(
    active_lesson_set: dict[str, Any],
    promotion_receipt: dict[str, Any],
) -> None:
    """Reject any receipt that does not bind the exact active artifact bytes."""

    if not isinstance(active_lesson_set, dict) or set(active_lesson_set) != {
        "schema_version",
        "lesson_set_id",
        "lessons",
    }:
        raise ValueError("active lesson set has unknown or missing fields")
    lessons = active_lesson_set.get("lessons")
    if (
        active_lesson_set.get("schema_version") != 1
        or isinstance(active_lesson_set.get("schema_version"), bool)
        or not isinstance(active_lesson_set.get("lesson_set_id"), str)
        or _CONTENT_ID.fullmatch(active_lesson_set["lesson_set_id"]) is None
        or not isinstance(lessons, list)
        or not 1 <= len(lessons) <= _MAX_ACTIVE_LESSONS
    ):
        raise ValueError("active lesson set identity or lesson count is invalid")

    candidate_lessons: list[dict[str, str]] = []
    expected_lesson_ids: list[str] = []
    seen_classes: set[str] = set()
    for lesson in lessons:
        if not isinstance(lesson, dict) or set(lesson) != {"lesson_id", "target_class", "text"}:
            raise ValueError("active lesson has unknown or missing fields")
        lesson_id = lesson.get("lesson_id")
        target_class = lesson.get("target_class")
        text = lesson.get("text")
        if (
            not isinstance(lesson_id, str)
            or _CONTENT_ID.fullmatch(lesson_id) is None
            or not isinstance(target_class, str)
            or target_class not in TARGET_CLASSES
            or target_class in seen_classes
            or not isinstance(text, str)
            or not 1 <= len(text) <= _MAX_LESSON_TEXT_LENGTH
        ):
            raise ValueError("active lesson fields are invalid")
        seen_classes.add(target_class)
        candidate_lesson = {"target_class": target_class, "text": text}
        candidate_lessons.append(candidate_lesson)
        lesson_sha256 = _domain_sha256(_LESSON_DOMAIN, candidate_lesson)
        expected_lesson_ids.append(f"lesson-{lesson_sha256[:12]}")
    actual_lesson_ids = [lesson["lesson_id"] for lesson in lessons]
    if actual_lesson_ids != expected_lesson_ids:
        raise ValueError("active lesson IDs do not match their content")

    if not isinstance(promotion_receipt, dict) or set(promotion_receipt) != PROMOTION_RECEIPT_KEYS:
        raise ValueError("promotion receipt has unknown or missing fields")
    sha_fields = {
        "development_bundle_sha256",
        "synthesis_input_sha256",
        "synthesis_transcript_sha256",
        "synthesis_prompt_sha256",
        "feedback_generator_sha256",
        "lint_rules_sha256",
        "lint_report_sha256",
        "candidate_sha256",
        "active_lesson_set_sha256",
    }
    if (
        promotion_receipt.get("schema_version") != 1
        or isinstance(promotion_receipt.get("schema_version"), bool)
        or any(
            not isinstance(promotion_receipt.get(field), str)
            or SHA256_HEX.fullmatch(promotion_receipt[field]) is None
            for field in sha_fields
        )
        or not isinstance(promotion_receipt.get("promotion_id"), str)
        or _CONTENT_ID.fullmatch(promotion_receipt["promotion_id"]) is None
        or promotion_receipt.get("active_lesson_set_id") != active_lesson_set["lesson_set_id"]
        or promotion_receipt.get("lesson_ids") != actual_lesson_ids
        or not isinstance(promotion_receipt.get("feedback_generator_version"), str)
        or not promotion_receipt["feedback_generator_version"]
        or not isinstance(promotion_receipt.get("provider_reference"), str)
        or not promotion_receipt["provider_reference"]
        or not isinstance(promotion_receipt.get("wire_model"), str)
        or not promotion_receipt["wire_model"]
        or not isinstance(promotion_receipt.get("selected_target_classes"), list)
        or promotion_receipt["selected_target_classes"]
        != [lesson["target_class"] for lesson in lessons]
        or not isinstance(promotion_receipt.get("canonical_byte_count"), int)
        or isinstance(promotion_receipt.get("canonical_byte_count"), bool)
    ):
        raise ValueError("promotion receipt fields are invalid")

    candidate = {"schema_version": 1, "lessons": candidate_lessons}
    candidate_sha256 = _domain_sha256(_CANDIDATE_DOMAIN, candidate)
    active_bytes = dumps(active_lesson_set).encode("utf-8")
    if (
        promotion_receipt["candidate_sha256"] != candidate_sha256
        or active_lesson_set["lesson_set_id"] != f"set-{candidate_sha256[:12]}"
        or promotion_receipt["active_lesson_set_sha256"] != hashlib.sha256(active_bytes).hexdigest()
        or promotion_receipt["canonical_byte_count"] != len(active_bytes)
    ):
        raise ValueError("promotion receipt does not bind the active artifact")

    receipt_bindings = {
        key: value for key, value in promotion_receipt.items() if key != "promotion_id"
    }
    promotion_sha256 = _domain_sha256(_PROMOTION_DOMAIN, receipt_bindings)
    if promotion_receipt["promotion_id"] != f"promotion-{promotion_sha256[:12]}":
        raise ValueError("promotion ID does not match the receipt content")


def _candidate_from_transcript(
    synthesis_transcript: dict[str, Any],
    synthesis_input: dict[str, Any],
    lint_report: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(synthesis_transcript, dict) or set(synthesis_transcript) != _TRANSCRIPT_KEYS:
        raise ValueError("synthesis transcript has unknown or missing fields")
    synthesis_input_sha256 = canonical_sha256(synthesis_input)
    prompt = synthesis_transcript.get("synthesis_prompt")
    feedback_generator = synthesis_input.get("feedback_generator")
    attempts = synthesis_transcript.get("attempts")
    if (
        synthesis_transcript.get("schema_version") != 1
        or isinstance(synthesis_transcript.get("schema_version"), bool)
        or not isinstance(prompt, str)
        or not prompt
        or synthesis_transcript.get("synthesis_prompt_sha256")
        != hashlib.sha256(prompt.encode("utf-8")).hexdigest()
        or synthesis_transcript.get("synthesis_input") != synthesis_input
        or synthesis_transcript.get("synthesis_input_sha256") != synthesis_input_sha256
        or synthesis_transcript.get("selected_target_classes")
        != synthesis_input.get("selected_target_classes")
        or not isinstance(feedback_generator, dict)
        or set(feedback_generator) != {"version", "sha256", "templates_sha256"}
        or any(
            not isinstance(feedback_generator.get(field), str)
            or SHA256_HEX.fullmatch(feedback_generator[field]) is None
            for field in ("sha256", "templates_sha256")
        )
        or synthesis_transcript.get("feedback_generator_version")
        != feedback_generator.get("version")
        or synthesis_transcript.get("feedback_generator_sha256") != feedback_generator.get("sha256")
        or synthesis_transcript.get("provider_reference") != FROZEN_PROVIDER_REFERENCE
        or synthesis_transcript.get("wire_model") != FROZEN_WIRE_MODEL
        or synthesis_transcript.get("lint_report") != lint_report
        or synthesis_transcript.get("lint_report_sha256") != canonical_sha256(lint_report)
        or not isinstance(attempts, list)
        or not 1 <= len(attempts) <= _MAX_SYNTHESIS_ATTEMPTS
    ):
        raise ValueError("synthesis transcript identity or attempt count is invalid")

    candidates: list[dict[str, Any]] = []
    semantic_output_seen = False
    seen_attempt_ids: set[str] = set()
    seen_process_uuids: set[str] = set()
    seen_conversation_ids: set[str] = set()
    for expected_index, attempt in enumerate(attempts, start=1):
        if not isinstance(attempt, dict) or set(attempt) != _TRANSCRIPT_ATTEMPT_KEYS:
            raise ValueError("synthesis transcript attempt has unknown or missing fields")
        attempt_index = attempt.get("attempt_index")
        attempt_id = attempt.get("attempt_id")
        process_uuid = attempt.get("process_uuid")
        conversation_id = attempt.get("conversation_id")
        runtime_outcome = attempt.get("runtime_outcome")
        raw_output = attempt.get("raw_output")
        if (
            attempt_index != expected_index
            or isinstance(attempt_index, bool)
            or not isinstance(attempt_id, str)
            or not attempt_id
            or attempt_id in seen_attempt_ids
        ):
            raise ValueError("synthesis transcript attempt identity is invalid")
        seen_attempt_ids.add(attempt_id)
        if isinstance(process_uuid, str):
            if process_uuid in seen_process_uuids:
                raise ValueError("synthesis replacement must use a fresh process")
            seen_process_uuids.add(process_uuid)
        if isinstance(conversation_id, str):
            if conversation_id in seen_conversation_ids:
                raise ValueError("synthesis replacement must use a fresh conversation")
            seen_conversation_ids.add(conversation_id)
        if runtime_outcome == "transport_failure":
            identities_are_valid = (process_uuid is None and conversation_id is None) or (
                isinstance(process_uuid, str)
                and bool(process_uuid)
                and isinstance(conversation_id, str)
                and bool(conversation_id)
            )
            if raw_output is not None or semantic_output_seen or not identities_are_valid:
                raise ValueError("a transport retry may precede semantic output only")
            continue
        if (
            runtime_outcome != "completed"
            or not isinstance(raw_output, str)
            or not isinstance(process_uuid, str)
            or not process_uuid
            or not isinstance(conversation_id, str)
            or not conversation_id
        ):
            raise ValueError("synthesis attempts must be transport_failure or completed")
        semantic_output_seen = True
        candidates.append(loads_object(raw_output))

    if len(candidates) != 1 or attempts[-1].get("runtime_outcome") != "completed":
        raise ValueError("promotion requires exactly one semantic candidate")
    return candidates[0]


def promote_candidate(
    synthesis_input: dict[str, Any],
    development_bundle: dict[str, Any],
    lint_rules: dict[str, Any],
    synthesis_transcript: dict[str, Any],
    lint_report: dict[str, Any],
) -> dict[str, Any]:
    """Recompute lint and return a content-addressed active lesson set."""

    if not isinstance(synthesis_input, dict) or set(synthesis_input) != _SYNTHESIS_INPUT_KEYS:
        raise ValueError("synthesis input has unknown or missing fields")
    if synthesis_input.get("schema_version") != 1 or isinstance(
        synthesis_input.get("schema_version"),
        bool,
    ):
        raise ValueError("synthesis input schema_version must equal integer 1")
    if (
        not isinstance(development_bundle, dict)
        or set(development_bundle) != _DEVELOPMENT_BUNDLE_KEYS
    ):
        raise ValueError("development bundle has unknown or missing fields")
    if synthesis_input.get("lint_rules") != lint_rules:
        raise ValueError("lint rules differ from the synthesis input")

    synthesis_input_sha256 = canonical_sha256(synthesis_input)
    candidate = _candidate_from_transcript(
        synthesis_transcript,
        synthesis_input,
        lint_report,
    )
    recomputed_lint = lint_candidate(
        candidate,
        synthesis_input["selected_target_classes"],
        development_bundle["runs"],
        development_bundle["sources"],
        development_bundle["golds"],
        lint_rules,
    )
    if lint_report != recomputed_lint:
        raise ValueError("lint report differs from deterministic recomputation")
    if recomputed_lint.get("accepted") is not True:
        raise ValueError("only a deterministically accepted candidate may be promoted")

    candidate_sha256 = _domain_sha256(_CANDIDATE_DOMAIN, candidate)
    lessons = []
    for lesson in candidate["lessons"]:
        lesson_sha256 = _domain_sha256(_LESSON_DOMAIN, lesson)
        lessons.append(
            {
                "lesson_id": f"lesson-{lesson_sha256[:12]}",
                "target_class": lesson["target_class"],
                "text": lesson["text"],
            }
        )
    active_lesson_set = {
        "schema_version": 1,
        "lesson_set_id": f"set-{candidate_sha256[:12]}",
        "lessons": lessons,
    }
    canonical_bytes = dumps(active_lesson_set).encode("utf-8")
    receipt_bindings = {
        "schema_version": 1,
        "development_bundle_sha256": canonical_sha256(development_bundle),
        "synthesis_input_sha256": synthesis_input_sha256,
        "synthesis_transcript_sha256": canonical_sha256(synthesis_transcript),
        "synthesis_prompt_sha256": synthesis_transcript["synthesis_prompt_sha256"],
        "feedback_generator_version": synthesis_transcript["feedback_generator_version"],
        "feedback_generator_sha256": synthesis_transcript["feedback_generator_sha256"],
        "provider_reference": synthesis_transcript["provider_reference"],
        "wire_model": synthesis_transcript["wire_model"],
        "selected_target_classes": synthesis_input["selected_target_classes"],
        "lint_rules_sha256": canonical_sha256(lint_rules),
        "lint_report_sha256": canonical_sha256(recomputed_lint),
        "candidate_sha256": candidate_sha256,
        "active_lesson_set_sha256": hashlib.sha256(canonical_bytes).hexdigest(),
        "active_lesson_set_id": active_lesson_set["lesson_set_id"],
        "lesson_ids": [lesson["lesson_id"] for lesson in lessons],
        "canonical_byte_count": len(canonical_bytes),
    }
    promotion_sha256 = _domain_sha256(_PROMOTION_DOMAIN, receipt_bindings)
    promotion_receipt = {
        **receipt_bindings,
        "promotion_id": f"promotion-{promotion_sha256[:12]}",
    }
    return {
        "active_lesson_set": active_lesson_set,
        "promotion_receipt": promotion_receipt,
        "promotion_receipt_sha256": canonical_sha256(promotion_receipt),
        "lint_report": recomputed_lint,
        "candidate": candidate,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--synthesis-input", required=True)
    parser.add_argument("--development-bundle", required=True)
    parser.add_argument("--lint-rules", required=True)
    parser.add_argument("--synthesis-transcript", required=True)
    parser.add_argument("--lint-report", required=True)
    parser.add_argument("--artifact-output", required=True)
    parser.add_argument("--receipt-output", required=True)
    arguments = parser.parse_args()
    result = promote_candidate(
        load_object(arguments.synthesis_input),
        load_object(arguments.development_bundle),
        load_object(arguments.lint_rules),
        load_object(arguments.synthesis_transcript),
        load_object(arguments.lint_report),
    )
    write(Path(arguments.artifact_output), result["active_lesson_set"])
    write(Path(arguments.receipt_output), result["promotion_receipt"])


if __name__ == "__main__":
    main()
