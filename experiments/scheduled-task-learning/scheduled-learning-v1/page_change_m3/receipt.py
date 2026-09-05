"""Canonical full page receipts and neutral adapter envelopes."""

from __future__ import annotations

from pathlib import Path

from benchmark_core.canonical import canonical_sha256

from .adapter import outcome_for_pairs, receipt_metrics
from .identities import calculate_page_identities
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
    calculated = calculate_page_identities(_PROJECT_ROOT)
    return {key: value for key, value in calculated.items() if key != "adapter_digest"}


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
