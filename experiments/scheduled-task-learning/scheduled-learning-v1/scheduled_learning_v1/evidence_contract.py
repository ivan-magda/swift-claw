"""Pure canonical artifact helpers shared by writers and offline auditors."""

from __future__ import annotations

import json
from pathlib import Path
from typing import cast

from benchmark_core.canonical import canonical_sha256, dumps, loads_object, write


def canonical_object(path: Path, name: str) -> dict[str, object]:
    """Load one canonical JSON object without interpreting its provenance."""

    try:
        raw = path.read_bytes()
        value = loads_object(raw.decode("utf-8"))
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError(f"{name} must be canonical JSON") from error
    if dumps(value).encode("utf-8") != raw:
        raise ValueError(f"{name} must be canonical JSON")
    return cast(dict[str, object], value)


def canonical_file_sha256(path: Path, name: str) -> str:
    """Hash one canonical object file after proving its byte representation."""

    return canonical_sha256(canonical_object(path, name))


def terminal_path(result_path: Path) -> Path:
    """Name the durable terminal carrier adjacent to its absent result."""

    return result_path.parent / "terminal.json"


def publish_terminal(result_path: Path, terminal: dict[str, object]) -> Path:
    """Canonically publish a no-result terminal exactly once."""

    path = terminal_path(result_path)
    if path.exists():
        raise ValueError("terminal carrier already exists")
    write(path, terminal)
    return path


def operation_usage(value: dict[str, object]) -> tuple[int, int, object | None]:
    """Project aggregate counters and the exact usage object hashed by the bridge."""

    usage = value.get("usage")
    if isinstance(usage, dict):
        sends = _nonnegative_integer(usage.get("responses_sends"), "responses_sends")
        tokens = _nonnegative_integer(usage.get("accounted_tokens"), "accounted_tokens")
        return sends, tokens, usage
    if isinstance(usage, list):
        http = value.get("http")
        if not isinstance(http, dict) or not isinstance(http.get("responsesSends"), list):
            raise ValueError("task result usage has no Responses-send carrier")
        tokens = _nonnegative_integer(value.get("accounted_tokens"), "accounted_tokens")
        return len(cast(list[object], http["responsesSends"])), tokens, usage
    explicit_sends = value.get("responses_sends", 0)
    explicit_tokens = value.get("accounted_tokens", 0)
    sends = _nonnegative_integer(explicit_sends, "responses_sends")
    tokens = _nonnegative_integer(explicit_tokens, "accounted_tokens")
    return sends, tokens, None


def _nonnegative_integer(value: object, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError(f"{name} must be a nonnegative integer")
    return value
