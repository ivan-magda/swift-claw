"""Canonical full page receipts and neutral adapter envelopes."""

from __future__ import annotations

from pathlib import Path

from benchmark_core.canonical import canonical_sha256, load_object

from .adapter import outcome_for_pairs, receipt_metrics
from .fixtures import FRESH_SPLIT_FIXTURE_IDS, fresh_gold_path, fresh_source_path
from .materialize import normalize_lesson_text

_PROJECT_ROOT = Path(__file__).resolve().parents[1]


def build_adapter_receipt(
    candidate_lessons: list[str],
    pairs: list[dict[str, object]],
    frozen_identities: dict[str, str] | None = None,
) -> tuple[dict[str, object], dict[str, object]]:
    """Build a full page receipt and the opaque envelope handed to the generic reducer."""

    outcome = outcome_for_pairs(pairs)
    receipt = {
        "schema_version": 1,
        "outcome": outcome,
        "pairs": pairs,
        **receipt_metrics(pairs),
    }
    identities = _frozen_identities() if frozen_identities is None else frozen_identities
    _require_identity_shape(identities)
    envelope: dict[str, object] = {
        "adapter_id": identities["adapter_id"],
        "adapter_version": identities["adapter_version"],
        "candidate_digest": canonical_sha256(
            {
                "schema_version": 1,
                "lessons": [normalize_lesson_text(lesson) for lesson in candidate_lessons],
            }
        ),
        "dataset_digest": identities["dataset_digest"],
        "oracle_digest": identities["oracle_digest"],
        "gates_digest": identities["gates_digest"],
        "execution_surface_digest": identities["execution_surface_digest"],
        "outcome": outcome,
        "receipt_digest": canonical_sha256(receipt),
    }
    return receipt, envelope


def _frozen_identities() -> dict[str, str]:
    adapter_identity = load_object(_PROJECT_ROOT / "contracts" / "adapter-identity.json")
    return {
        "adapter_id": adapter_identity["adapter_id"],
        "adapter_version": adapter_identity["adapter_version"],
        "dataset_digest": _dataset_digest(),
        "oracle_digest": _oracle_digest(),
        "gates_digest": canonical_sha256(load_object(_PROJECT_ROOT / "contracts" / "gates.json")),
        "execution_surface_digest": _execution_surface_digest(),
    }


def _require_identity_shape(identities: dict[str, str]) -> None:
    expected = {
        "adapter_id",
        "adapter_version",
        "dataset_digest",
        "oracle_digest",
        "gates_digest",
        "execution_surface_digest",
    }
    if set(identities) != expected or any(not value for value in identities.values()):
        raise ValueError("frozen page adapter identities must have the exact required fields")


def _dataset_digest() -> str:
    return canonical_sha256(
        {
            "splits": FRESH_SPLIT_FIXTURE_IDS,
            "sources": [
                load_object(fresh_source_path(_PROJECT_ROOT, split, fixture_id))
                for split, fixture_ids in FRESH_SPLIT_FIXTURE_IDS.items()
                for fixture_id in fixture_ids
            ],
            "gold": [
                load_object(fresh_gold_path(_PROJECT_ROOT, split, fixture_id))
                for split, fixture_ids in FRESH_SPLIT_FIXTURE_IDS.items()
                for fixture_id in fixture_ids
            ],
        }
    )


def _oracle_digest() -> str:
    return canonical_sha256(
        {
            "scorer": _source_digest("../page-change/page_benchmark/scorer.py"),
            "records": _source_digest("../page-change/page_benchmark/records.py"),
        }
    )


def _execution_surface_digest() -> str:
    return canonical_sha256(
        {
            "adapter": _source_digest("page_change_m3/adapter.py"),
            "oracle": _source_digest("page_change_m3/oracle.py"),
            "receipt": _source_digest("page_change_m3/receipt.py"),
        }
    )


def _source_digest(relative_path: str) -> str:
    return canonical_sha256((_PROJECT_ROOT / relative_path).read_text(encoding="utf-8"))
