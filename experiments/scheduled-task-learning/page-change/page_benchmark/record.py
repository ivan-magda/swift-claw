"""Seal one controller attempt into a canonical aggregate record."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Any

from .canonical import SHA256_HEX, StrictJSONError, dumps, write
from .manifest_artifacts import (
    load_canonical_artifact,
    load_manifest,
    scorer_digest,
    verified_manifest_json,
)
from .records import SKELETON_KEYS, STAGE_CONDITIONS, seal_score_receipts, validate_records


def _parse_arguments(arguments: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--approved-manifest-sha256", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--gold", required=True)
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--carrier", required=True)
    parser.add_argument("--skeleton", required=True)
    parser.add_argument("--output")
    return parser.parse_args(arguments)


def seal_record(arguments: argparse.Namespace) -> dict[str, Any]:
    repository_root = Path(arguments.root)
    manifest, manifest_sha256 = load_manifest(Path(arguments.manifest))
    if (
        not isinstance(arguments.approved_manifest_sha256, str)
        or SHA256_HEX.fullmatch(arguments.approved_manifest_sha256) is None
        or arguments.approved_manifest_sha256 != manifest_sha256
    ):
        raise ValueError("manifest digest differs from the approved D6 digest")
    source = verified_manifest_json(
        repository_root,
        manifest,
        "fixtures",
        arguments.source,
        "source",
    )
    gold = verified_manifest_json(
        repository_root,
        manifest,
        "gold",
        arguments.gold,
        "gold",
    )
    attempt = load_canonical_artifact(Path(arguments.attempt))
    carrier = load_canonical_artifact(Path(arguments.carrier))
    skeleton = load_canonical_artifact(Path(arguments.skeleton))
    if set(skeleton) != SKELETON_KEYS:
        raise ValueError("record skeleton has unknown or missing fields")
    stage = skeleton.get("stage")
    condition = skeleton.get("condition")
    if (
        not isinstance(stage, str)
        or stage not in STAGE_CONDITIONS
        or not isinstance(condition, str)
        or condition not in STAGE_CONDITIONS[stage]
        or source.get("split") != (
            "sealed" if stage.startswith("sealed-") else stage
        )
        or skeleton.get("lifecycle_generation")
        != (
            "post-restart"
            if stage == "sealed-post-restart"
            else "pre-restart"
        )
    ):
        raise ValueError("record skeleton stage, split, condition, or lifecycle is invalid")
    expected_scorer_digest = scorer_digest(manifest)
    record = {
        **skeleton,
        "fixture_id": source["fixture_id"],
        "family_id": source["family_id"],
        "parsed_output": None,
        "attempt": attempt,
        "score_result": {},
        "lesson_digest": carrier.get("lesson_set_sha256"),
        "lesson_set_id": carrier.get("lesson_set_id"),
        "lesson_ids": carrier.get("lesson_ids"),
        "attempt_digest": "",
        "scorer_digest": expected_scorer_digest,
        "score_receipt_digest": "",
        "carrier_receipt": carrier,
        "carrier_receipt_sha256": "",
    }
    fixtures = {
        source["fixture_id"]: {
            "family_id": source["family_id"],
            "source": source,
            "gold": gold,
        }
    }
    seal_score_receipts([record], fixtures, expected_scorer_digest)
    failures = validate_records(
        [record],
        fixtures,
        (condition,),
        expected_scorer_digest,
        require_complete=False,
    )
    if failures:
        raise ValueError(f"sealed record failed its closed contract: {failures}")
    return record


def main(arguments: list[str] | None = None) -> int:
    parsed = _parse_arguments(arguments)
    try:
        record = seal_record(parsed)
    except (
        KeyError,
        OSError,
        StrictJSONError,
        TypeError,
        UnicodeError,
        ValueError,
    ):
        print(
            dumps(
                {
                    "schema_version": 1,
                    "status": "invalid",
                    "error": "page_record.input_invalid",
                }
            ),
            end="",
        )
        return 2
    if parsed.output:
        write(Path(parsed.output), record)
    else:
        print(dumps(record), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
