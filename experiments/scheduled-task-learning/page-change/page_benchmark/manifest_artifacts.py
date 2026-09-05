"""Canonical loading and manifest binding for page benchmark artifacts."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from .canonical import SHA256_HEX, dumps, loads_object
from .fixtures import validate_fixture

PAGE_ROOT = Path("experiments/scheduled-task-learning/page-change")


def load_canonical_artifact(path: Path) -> dict[str, Any]:
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ValueError(f"canonical JSON must not contain a BOM: {path}")
    try:
        value = loads_object(raw.decode("utf-8"))
    except UnicodeDecodeError as error:
        raise ValueError(f"canonical JSON must be UTF-8: {path}") from error
    if raw != dumps(value).encode("utf-8"):
        raise ValueError(f"JSON artifact is not compact sorted JSON plus one LF: {path}")
    return value


def load_manifest(path: Path) -> tuple[dict[str, Any], str]:
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ValueError("manifest must not contain a BOM")
    try:
        manifest = loads_object(raw.decode("utf-8"))
    except UnicodeDecodeError as error:
        raise ValueError("manifest must be UTF-8") from error
    if raw != dumps(manifest).encode("utf-8").removesuffix(b"\n"):
        raise ValueError("manifest is not canonical compact sorted JSON")
    return manifest, hashlib.sha256(raw).hexdigest()


def verified_manifest_artifact(
    repository_root: Path,
    manifest: dict[str, Any],
    category_name: str,
    relative_path: str,
    role: str,
) -> tuple[Path, bytes]:
    categories = manifest.get("categories")
    category = categories.get(category_name) if isinstance(categories, dict) else None
    artifacts = category.get("artifacts") if isinstance(category, dict) else None
    if not isinstance(artifacts, list):
        raise ValueError(f"manifest category is absent or malformed: {category_name}")
    matching = [
        artifact
        for artifact in artifacts
        if isinstance(artifact, dict)
        and artifact.get("path") == relative_path
        and artifact.get("role") == role
    ]
    if len(matching) != 1:
        raise ValueError(f"manifest must bind exactly one {role} artifact: {relative_path}")
    artifact = matching[0]
    if set(artifact) != {"bytes", "path", "role", "sha256"}:
        raise ValueError(f"manifest artifact record is not closed: {relative_path}")
    path = repository_root / relative_path
    resolved_root = repository_root.resolve()
    resolved_path = path.resolve()
    try:
        resolved_path.relative_to(resolved_root)
    except ValueError as error:
        raise ValueError(f"manifest artifact escapes the repository: {relative_path}") from error
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"manifest artifact is missing or is a symlink: {relative_path}")
    raw = path.read_bytes()
    if artifact["bytes"] != len(raw) or artifact["sha256"] != hashlib.sha256(raw).hexdigest():
        raise ValueError(f"manifest artifact bytes changed: {relative_path}")
    return path, raw


def verified_manifest_json(
    repository_root: Path,
    manifest: dict[str, Any],
    category_name: str,
    relative_path: str,
    role: str,
) -> dict[str, Any]:
    _, raw = verified_manifest_artifact(
        repository_root,
        manifest,
        category_name,
        relative_path,
        role,
    )
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ValueError(f"manifest JSON artifact has a BOM: {relative_path}")
    try:
        return loads_object(raw.decode("utf-8"))
    except UnicodeDecodeError as error:
        raise ValueError(f"manifest JSON artifact is not UTF-8: {relative_path}") from error


def manifest_bound_fixtures(
    repository_root: Path,
    manifest: dict[str, Any],
    split: str,
) -> dict[str, dict[str, Any]]:
    split_path = str(PAGE_ROOT / "contracts/splits.json")
    split_contract = verified_manifest_json(
        repository_root,
        manifest,
        "splits",
        split_path,
        "splits",
    )
    split_entries = split_contract.get("splits")
    entries = split_entries.get(split) if isinstance(split_entries, dict) else None
    if not isinstance(entries, list):
        raise ValueError(f"split contract does not define {split}")
    fixtures: dict[str, dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "fixture_id",
            "family_id",
            "source",
            "gold",
        }:
            raise ValueError(f"{split} split entry is malformed")
        source_path = str(PAGE_ROOT / entry["source"])
        gold_path = str(PAGE_ROOT / entry["gold"])
        source = verified_manifest_json(
            repository_root,
            manifest,
            "fixtures",
            source_path,
            "source",
        )
        gold = verified_manifest_json(
            repository_root,
            manifest,
            "gold",
            gold_path,
            "gold",
        )
        validate_fixture(source, gold)
        fixture_id = entry["fixture_id"]
        if (
            fixture_id in fixtures
            or source.get("fixture_id") != fixture_id
            or source.get("family_id") != entry["family_id"]
            or source.get("split") != split
        ):
            raise ValueError(f"{split} fixture identity is inconsistent")
        fixtures[fixture_id] = {
            "family_id": entry["family_id"],
            "source": source,
            "gold": gold,
        }
    return fixtures


def scorer_digest(manifest: dict[str, Any]) -> str:
    return category_digest(manifest, "scorer")


def category_digest(manifest: dict[str, Any], name: str) -> str:
    categories = manifest.get("categories")
    category = categories.get(name) if isinstance(categories, dict) else None
    digest = category.get("sha256") if isinstance(category, dict) else None
    if not isinstance(digest, str) or SHA256_HEX.fullmatch(digest) is None:
        raise ValueError(f"manifest {name} category digest is missing or invalid")
    return digest
