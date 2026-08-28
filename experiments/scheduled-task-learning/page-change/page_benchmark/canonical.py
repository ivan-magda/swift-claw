"""Compatibility exports for scenario-neutral canonical JSON primitives."""

from benchmark_core.canonical import (
    SHA256_HEX,
    StrictJSONError,
    canonical_sha256,
    dumps,
    load_object,
    loads_object,
    write,
)

__all__ = [
    "SHA256_HEX",
    "StrictJSONError",
    "canonical_sha256",
    "dumps",
    "load_object",
    "loads_object",
    "write",
]
