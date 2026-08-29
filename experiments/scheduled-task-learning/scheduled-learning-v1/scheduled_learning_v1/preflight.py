"""Closed owner approval and current-freeze verification before external work."""

from __future__ import annotations

import re
import subprocess
from datetime import UTC, datetime
from pathlib import Path

from benchmark_core.canonical import SHA256_HEX, canonical_sha256

from .freeze import verify_manifest
from .freeze_inputs import load_canonical_object
from .frozen_contract import (
    AGGREGATE_BUDGETS,
    APPROVAL_KEYS,
    SCHEMA_VERSION,
    json_exactly_matches,
)

_COMMIT = re.compile(r"^[0-9a-f]{40}$")
_RFC3339_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")


def verify_pre_run(root: Path, approval: dict[str, object]) -> dict[str, object]:
    """Verify the canonical manifest, exact owner budget, and checked-out freeze commit."""

    experiment_root = Path(root).resolve(strict=True)
    manifest = load_canonical_object(experiment_root / "freeze" / "manifest.json")
    verify_manifest(experiment_root, manifest)
    manifest_sha256 = canonical_sha256(manifest)
    _verify_approval(approval, manifest_sha256)
    head = _git_head(experiment_root)
    if approval["expected_freeze_commit"] != head:
        raise ValueError("owner approval names a different freeze commit than the checked-out HEAD")
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "verified",
        "manifest_sha256": manifest_sha256,
        "freeze_commit": head,
        "budgets": dict(AGGREGATE_BUDGETS),
        "owner_identity": approval["owner_identity"],
        "approved_at": approval["approved_at"],
    }


def _verify_approval(approval: dict[str, object], manifest_sha256: str) -> None:
    if set(approval) != set(APPROVAL_KEYS):
        raise ValueError("owner approval has wrong keys")
    if not json_exactly_matches(approval.get("schema_version"), SCHEMA_VERSION):
        raise ValueError("owner approval schema is invalid")
    digest = approval.get("manifest_sha256")
    if not isinstance(digest, str) or SHA256_HEX.fullmatch(digest) is None:
        raise ValueError("owner approval manifest_sha256 is invalid")
    if digest != manifest_sha256:
        raise ValueError("owner approval names a different manifest")
    if not json_exactly_matches(approval.get("budgets"), AGGREGATE_BUDGETS):
        raise ValueError("owner approval budgets differ from the frozen aggregate budget")
    commit = approval.get("expected_freeze_commit")
    if not isinstance(commit, str) or _COMMIT.fullmatch(commit) is None:
        raise ValueError("owner approval expected_freeze_commit is invalid")
    owner = approval.get("owner_identity")
    if not isinstance(owner, str) or not owner.strip():
        raise ValueError("owner approval owner_identity is invalid")
    timestamp = approval.get("approved_at")
    if not isinstance(timestamp, str) or _RFC3339_UTC.fullmatch(timestamp) is None:
        raise ValueError("owner approval approved_at must be an RFC-3339 UTC timestamp")
    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("owner approval approved_at must be an RFC-3339 UTC timestamp") from error
    if parsed.tzinfo != UTC:
        raise ValueError("owner approval approved_at must be UTC")


def _git_head(root: Path) -> str:
    completed = subprocess.run(  # noqa: S603 -- fixed Git operation with an absolute root
        ["git", "-C", str(root), "rev-parse", "HEAD"],  # noqa: S607
        check=False,
        capture_output=True,
        text=True,
    )
    head = completed.stdout.strip()
    if completed.returncode != 0 or _COMMIT.fullmatch(head) is None:
        raise ValueError("cannot resolve the current Git freeze commit")
    return head
