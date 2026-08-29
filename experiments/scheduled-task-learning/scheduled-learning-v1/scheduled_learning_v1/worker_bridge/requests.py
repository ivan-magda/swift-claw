"""Closed worker records and the bound manifest/configuration projections."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, cast

from benchmark_core.canonical import canonical_sha256, dumps


@dataclass(frozen=True)
class TaskAttemptCall:
    invocation_core: dict[str, object]
    invocation_path: Path
    result_path: Path


@dataclass(frozen=True)
class LearningCall:
    kind: Literal["evaluator", "reflector"]
    request_core: dict[str, object]
    request_path: Path
    result_path: Path


def core_digest(core: dict[str, object]) -> str:
    return canonical_sha256(core)


def bind_authorization(
    core: dict[str, object], event_path: Path, event_sha256: str
) -> dict[str, object]:
    return {**core, "authorization": {"event_path": str(event_path), "event_sha256": event_sha256}}


def write_closed_input(path: Path, value: dict[str, object]) -> None:
    if not path.is_absolute():
        raise ValueError("worker input path must be absolute")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(dumps(value), encoding="utf-8")


def bound_contract(core: dict[str, object], kind: str) -> dict[str, object]:
    """Read the immutable artifacts Swift admission itself uses for this launch."""

    manifest = _object(core.get("manifest"))
    manifest_data = _absolute(manifest.get("manifest_path")).read_bytes()
    if _sha256(manifest_data) != manifest.get("manifest_sha256"):
        raise ValueError("manifest digest does not bind to core")
    manifest_document = _json_object(manifest_data)
    approval = _object(manifest.get("owner_approval"))
    approval_data = _absolute(approval.get("path")).read_bytes()
    if _sha256(approval_data) != approval.get("sha256"):
        raise ValueError("owner approval digest does not bind to core")
    approval_document = _json_object(approval_data)
    execution = _object(manifest_document.get("swift_execution"))
    route = _object(execution.get(f"{kind}_route"))
    if not route:
        raise ValueError("manifest has no selected route")
    projection: dict[str, object] = {
        "route": route,
        "freeze_commit": approval_document.get("expected_freeze_commit"),
        "executable_sha256": execution.get("executable_sha256"),
        "missing_usage_token_proxy": execution.get("missing_usage_token_proxy"),
    }
    if kind == "task":
        configuration_data = _absolute(core.get("configuration_path")).read_bytes()
        if _sha256(configuration_data) != core.get("configuration_sha256"):
            raise ValueError("configuration digest does not bind to invocation")
        projection["configuration"] = _json_object(configuration_data)
    return projection


def _absolute(value: object) -> Path:
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise ValueError("bound artifact path must be absolute")
    return Path(value)


def _json_object(data: bytes) -> dict[str, object]:
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError("bound artifact must be an object")
    return cast(dict[str, object], value)


def _object(value: object) -> dict[str, object]:
    return cast(dict[str, object], value) if isinstance(value, dict) else {}


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
