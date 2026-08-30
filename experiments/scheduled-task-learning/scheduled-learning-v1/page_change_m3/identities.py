"""Canonical page-adapter identity derivation shared by receipts and freeze manifests."""

from __future__ import annotations

from pathlib import Path

from benchmark_core.canonical import canonical_sha256, load_object

from .fixtures import FRESH_SPLIT_FIXTURE_IDS, fresh_gold_path, fresh_source_path


def calculate_page_identities(root: Path) -> dict[str, str]:
    """Derive every frozen page identity from one experiment root."""

    adapter = load_object(root / "contracts" / "adapter-identity.json")
    adapter_id = _required_string(adapter.get("adapter_id"), "adapter_id")
    adapter_version = _required_string(adapter.get("adapter_version"), "adapter_version")
    return {
        "adapter_id": adapter_id,
        "adapter_version": adapter_version,
        "adapter_digest": canonical_sha256(adapter),
        "dataset_digest": _dataset_digest(root),
        "oracle_digest": _oracle_digest(root),
        "gates_digest": canonical_sha256(load_object(root / "contracts" / "gates.json")),
        "execution_surface_digest": _execution_surface_digest(root),
    }


def _dataset_digest(root: Path) -> str:
    return canonical_sha256(
        {
            "splits": FRESH_SPLIT_FIXTURE_IDS,
            "sources": [
                load_object(fresh_source_path(root, split, fixture_id))
                for split, fixture_ids in FRESH_SPLIT_FIXTURE_IDS.items()
                for fixture_id in fixture_ids
            ],
            "gold": [
                load_object(fresh_gold_path(root, split, fixture_id))
                for split, fixture_ids in FRESH_SPLIT_FIXTURE_IDS.items()
                for fixture_id in fixture_ids
            ],
        }
    )


def _oracle_digest(root: Path) -> str:
    return canonical_sha256(
        {
            "scorer": _source_digest(root, "../page-change/page_benchmark/scorer.py"),
            "records": _source_digest(root, "../page-change/page_benchmark/records.py"),
        }
    )


def _execution_surface_digest(root: Path) -> str:
    return canonical_sha256(
        {
            "adapter": _source_digest(root, "page_change_m3/adapter.py"),
            "oracle": _source_digest(root, "page_change_m3/oracle.py"),
            "receipt": _source_digest(root, "page_change_m3/receipt.py"),
        }
    )


def _source_digest(root: Path, relative_path: str) -> str:
    return canonical_sha256((root / relative_path).read_text(encoding="utf-8"))


def _required_string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"page adapter {field} must be a nonempty string")
    return value
