"""Strict JSON parsing and canonical serialization.

The benchmark deliberately does not depend on a permissive command-line JSON
tool.  In particular, duplicate object keys and any bytes around the one root
object are rejected before schema validation.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any, Iterable


SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")


class StrictJSONError(ValueError):
    """Raised when input is not exactly one duplicate-free JSON object."""

    def __init__(self, message: str, requirements: Iterable[str] = ()) -> None:
        super().__init__(message)
        self.requirements = tuple(dict.fromkeys(requirements))


def _object_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise StrictJSONError(
                f"duplicate object key: {key}",
                ("schema.single_object",),
            )
        result[key] = value
    return result


def _reject_non_json_constant(value: str) -> None:
    raise StrictJSONError(
        f"non-JSON numeric constant is not allowed: {value}",
        ("schema.single_object",),
    )


def loads_object(raw: str) -> dict[str, Any]:
    """Parse exactly one JSON object, rejecting duplicate keys and prose."""

    if not isinstance(raw, str):
        raise StrictJSONError("JSON input must be text", ("schema.single_object",))
    decoder = json.JSONDecoder(
        object_pairs_hook=_object_without_duplicates,
        parse_constant=_reject_non_json_constant,
    )
    leading = len(raw) - len(raw.lstrip())
    if leading >= len(raw) or raw[leading] != "{":
        raise StrictJSONError(
            "exactly one JSON object with no surrounding text is required",
            ("schema.single_object", "schema.no_surrounding_text"),
        )
    try:
        value, end = decoder.raw_decode(raw, leading)
    except StrictJSONError:
        raise
    except json.JSONDecodeError as error:
        raise StrictJSONError(
            f"invalid JSON: {error.msg}",
            ("schema.single_object",),
        ) from error
    if raw[end:].strip():
        raise StrictJSONError(
            "surrounding text or a second JSON value is not allowed",
            ("schema.single_object", "schema.no_surrounding_text"),
        )
    if not isinstance(value, dict):
        raise StrictJSONError(
            "the root JSON value must be an object",
            ("schema.single_object",),
        )
    return value


def load_object(path: str | Path) -> dict[str, Any]:
    return loads_object(Path(path).read_text(encoding="utf-8"))


def dumps(value: Any) -> str:
    """Serialize canonical, byte-stable UTF-8 JSON with a final newline."""

    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ) + "\n"


def canonical_sha256(value: Any) -> str:
    """Return SHA-256 over the benchmark's canonical JSON bytes."""

    return hashlib.sha256(dumps(value).encode("utf-8")).hexdigest()


def write(path: str | Path, value: Any) -> None:
    target = Path(path)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=target.parent,
        prefix=f".{target.name}.",
        suffix=".tmp",
    )
    temporary = Path(temporary_name)
    try:
        stream = os.fdopen(descriptor, "w", encoding="utf-8", newline="\n")
        descriptor = None
        with stream:
            stream.write(dumps(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
        directory_descriptor = os.open(
            target.parent,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)
