"""Closed identifiers and strict JSON primitives for the page-change freeze."""

from __future__ import annotations

import hashlib
import json
import math
import re
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn

MANIFEST_KIND = "swift-claw.scheduled-task-learning.page-change.freeze"
MANIFEST_SCHEMA_VERSION = 1
DESCRIPTOR_SCHEMA_VERSION = 1
APPROVAL_SCHEMA_VERSION = 2
DECISION = "D6"
EXPERIMENT = "page-change"

PROTOCOL_VERSION = "0.5"
PROTOCOL_PATH = "docs/research/118-validation-protocol.md"
PROTOCOL_SHA256 = "ac2628e7e57f1c013c6fdb8f337426dadff534e03b7e2ded67973970c9d7c12f"
PACKAGE_MANIFEST_PATH = "Package.swift"
PACKAGE_RESOLVED_PATH = "Package.resolved"
SWIFT_EXECUTABLE_TARGET = "claw-eval"
SWIFT_HARNESS_LIBRARY_TARGET = "ClawEvaluation"
SWIFT_HARNESS_TARGETS = frozenset({SWIFT_EXECUTABLE_TARGET, SWIFT_HARNESS_LIBRARY_TARGET})

PAGE_ROOT = "experiments/scheduled-task-learning/page-change"
EXECUTABLE_PATH = f"{PAGE_ROOT}/artifacts/claw-eval-macos-arm64"
RUNTIME_CONFIGURATION_PATH = f"{PAGE_ROOT}/config/runtime.json"
CANARY_CONFIGURATION_PATH = f"{PAGE_ROOT}/config/canary.json"
CANARY_BASE_TASK_PATH = f"{PAGE_ROOT}/config/canary-base-task.json"
CANARY_CLEAN_LESSONS_PATH = f"{PAGE_ROOT}/config/canary-clean-lessons.json"
CANARY_NONEMPTY_LESSONS_PATH = f"{PAGE_ROOT}/config/canary-nonempty-lessons.json"
CANARY_FIXTURE_ID = "pc-development-00"
CANARY_TASK_ID = "page-7af01fe15924"
MANIFEST_DESCRIPTOR_PATH = f"{PAGE_ROOT}/freeze/page-manifest-descriptor.json"
REPLACEMENT_DELTA_PATH = f"{PAGE_ROOT}/freeze/replacement-delta.json"
INVALIDATED_MANIFEST_SHA256 = "d5ae7dcef1c20f4c95f22cad9d23c7c1f37409abb3d2a02349a951c7647faad8"
INVALIDATED_MANIFEST_PATH = (
    f"{PAGE_ROOT}/provenance/invalidated-page-manifest-d5ae7dcef1c2.json"
)
INVALID_BATCH_JOURNAL_SHA256 = "377b6c1c9e5161fc10e41e723906ca1492fd60256ba2715d5bc109df39ace3cb"
INVALID_BATCH_JOURNAL_PATH = (
    f"{PAGE_ROOT}/provenance/invalid-batch-controller-journal-d5ae7dcef1c2.jsonl"
)
INVALID_BATCH_TERMINAL_RESULT_SHA256 = (
    "ceda3f4995d3bc2655faa68d5aeb29efc6b31e4a0f4db73404c20c9415b367d8"
)
INVALID_BATCH_TERMINAL_RESULT_PATH = (
    f"{PAGE_ROOT}/provenance/invalid-batch-terminal-result-d5ae7dcef1c2.json"
)
INVALIDATION_REPORT_SHA256 = "7f663a34f284ff4e98ea7f6cacad6d371b7cbb9f5e02a01f65083113cfaf4559"
INVALIDATION_REPORT_PATH = f"{PAGE_ROOT}/provenance/invalidation-report-d5ae7dcef1c2.json"
RECOVERY_LEDGER_PATH = f"{PAGE_ROOT}/provenance/recovery-ledger-d5ae7dcef1c2.json"
TASK_PROMPT_PATH = f"{PAGE_ROOT}/prompts/task.md"
SYNTHESIS_PROMPT_PATH = f"{PAGE_ROOT}/prompts/synthesis.md"
LESSON_LINT_RULES_PATH = f"{PAGE_ROOT}/contracts/lesson-lint-rules.json"
FEEDBACK_TEMPLATES_PATH = f"{PAGE_ROOT}/contracts/feedback-templates.json"
SPLITS_PATH = f"{PAGE_ROOT}/contracts/splits.json"
CONFORMANCE_CASES_PATH = f"{PAGE_ROOT}/conformance/cases.json"
CONFORMANCE_COVERAGE_PATH = f"{PAGE_ROOT}/contracts/conformance-coverage.json"
CANONICAL_JSON_VECTOR_PATH = f"{PAGE_ROOT}/contracts/canonical-json-vector.json"
BENCHMARK_PACKAGE_ROOT = f"{PAGE_ROOT}/page_benchmark"
BENCHMARK_CORE_ROOT = "experiments/scheduled-task-learning/benchmark-core/benchmark_core"
BENCHMARK_CORE_SOURCE_NAMES = (
    "__init__.py",
    "attempt.py",
    "canonical.py",
    "conformance.py",
    "contract_validation.py",
    "feedback.py",
)
BENCHMARK_CORE_CATEGORY_SOURCES = {
    "feedback": frozenset({"__init__.py", "canonical.py", "feedback.py"}),
    "lesson_linter": frozenset(
        {"__init__.py", "attempt.py", "canonical.py", "contract_validation.py", "feedback.py"}
    ),
    "scorer": frozenset(BENCHMARK_CORE_SOURCE_NAMES),
}

FEEDBACK_EXECUTABLE_PATH = f"{PAGE_ROOT}/artifacts/page-feedback"
BENCHMARK_BOOTSTRAP_PATH = f"{PAGE_ROOT}/artifacts/page-bootstrap"
BENCHMARK_BOOTSTRAP_ROLE = "bootstrap"
SCORER_EXECUTABLE_PATHS = frozenset(
    {
        f"{PAGE_ROOT}/artifacts/page-aggregate",
        f"{PAGE_ROOT}/artifacts/page-record",
        f"{PAGE_ROOT}/artifacts/page-scorer",
    }
)
LESSON_EXECUTABLE_PATHS = frozenset(
    {
        f"{PAGE_ROOT}/artifacts/page-lesson-lint",
        f"{PAGE_ROOT}/artifacts/page-promotion",
        f"{PAGE_ROOT}/artifacts/page-synthesis",
    }
)
CONFORMANCE_EXECUTABLE_PATH = f"{PAGE_ROOT}/artifacts/page-conformance"

FREEZE_PACKAGE_ROOT = "tools/page_change_freeze"
FREEZE_VERIFIER_PATH = f"{FREEZE_PACKAGE_ROOT}/freeze.py"
FREEZE_MODULE_PATHS = frozenset(
    f"{FREEZE_PACKAGE_ROOT}/{name}"
    for name in (
        "__init__.py",
        "approval.py",
        "artifacts.py",
        "cli.py",
        "contract.py",
        "manifest.py",
        "recovery.py",
        "freeze.py",
        "run_order.py",
    )
)

CATEGORY_NAMES = (
    "runtime_sources", "harness_sources", "dependencies", "executable",
    "configuration", "budget", "model", "retry", "output", "prompts",
    "schemas", "lesson_linter", "feedback", "scorer", "fixtures", "gold",
    "splits", "conformance", "run_order",
)

# Counts are deliberately structural. Domain semantics are owned by the protected
# benchmark and Swift runtime, not duplicated by this freeze tool.
CATEGORY_ROLE_RULES = {
    "runtime_sources": {"source": (1, None), "resource": (0, None)},
    "harness_sources": {"source": (1, None), "resource": (0, None)},
    "dependencies": {"package_manifest": (1, 1), "resolved_dependencies": (1, 1)},
    "executable": {"executable": (1, 1)},
    "configuration": {
        "runtime": (1, 1), "canary": (1, 1), "canary_base_task": (1, 1),
        "canary_clean_lessons": (1, 1), "canary_nonempty_lessons": (1, 1),
        "error_codes": (1, 1), "target_classes": (1, 1),
        "canonical_json_vector": (1, 1),
        "freeze_verifier_source": (len(FREEZE_MODULE_PATHS), len(FREEZE_MODULE_PATHS)),
        "manifest_descriptor": (1, 1),
    },
    "budget": {
        "controller_journal": (1, 1),
        "invalidated_manifest": (1, 1),
        "invalidation_report": (1, 1),
        "recovery_ledger": (1, 1),
        "terminal_result": (1, 1),
    },
    "model": {}, "retry": {}, "output": {},
    "prompts": {"task": (1, 1), "synthesis": (1, 1)},
    "schemas": {"schema": (1, None)},
    "lesson_linter": {
        "source": (1, None), "rules": (1, 1), "executable": (3, 3),
        BENCHMARK_BOOTSTRAP_ROLE: (1, 1),
    },
    "feedback": {
        "source": (1, None), "executable": (1, 1), "templates": (1, 1),
        BENCHMARK_BOOTSTRAP_ROLE: (1, 1),
    },
    "scorer": {
        "source": (1, None), "executable": (3, 3),
        BENCHMARK_BOOTSTRAP_ROLE: (1, 1),
    },
    "fixtures": {"source": (1, None)},
    "gold": {"gold": (1, None)},
    "splits": {"splits": (1, 1)},
    "conformance": {
        "cases": (1, 1), "coverage": (1, 1), "executable": (1, 1),
        BENCHMARK_BOOTSTRAP_ROLE: (1, 1),
    },
    "run_order": {},
}

FIXED_ROLE_PATHS = {
    "budget": {
        ("controller_journal", INVALID_BATCH_JOURNAL_PATH),
        ("invalidated_manifest", INVALIDATED_MANIFEST_PATH),
        ("invalidation_report", INVALIDATION_REPORT_PATH),
        ("recovery_ledger", RECOVERY_LEDGER_PATH),
        ("terminal_result", INVALID_BATCH_TERMINAL_RESULT_PATH),
    },
    "dependencies": {
        ("package_manifest", PACKAGE_MANIFEST_PATH),
        ("resolved_dependencies", PACKAGE_RESOLVED_PATH),
    },
    "executable": {("executable", EXECUTABLE_PATH)},
    "configuration": {
        ("runtime", RUNTIME_CONFIGURATION_PATH),
        ("canary", CANARY_CONFIGURATION_PATH),
        ("canary_base_task", CANARY_BASE_TASK_PATH),
        ("canary_clean_lessons", CANARY_CLEAN_LESSONS_PATH),
        ("canary_nonempty_lessons", CANARY_NONEMPTY_LESSONS_PATH),
        ("error_codes", f"{PAGE_ROOT}/contracts/error-codes.json"),
        ("target_classes", f"{PAGE_ROOT}/contracts/target-classes.json"),
        ("canonical_json_vector", CANONICAL_JSON_VECTOR_PATH),
        *(("freeze_verifier_source", path) for path in FREEZE_MODULE_PATHS),
        ("manifest_descriptor", MANIFEST_DESCRIPTOR_PATH),
    },
    "prompts": {("task", TASK_PROMPT_PATH), ("synthesis", SYNTHESIS_PROMPT_PATH)},
    "lesson_linter": {
        *(("executable", path) for path in LESSON_EXECUTABLE_PATHS),
        (BENCHMARK_BOOTSTRAP_ROLE, BENCHMARK_BOOTSTRAP_PATH),
        ("rules", LESSON_LINT_RULES_PATH),
    },
    "feedback": {
        (BENCHMARK_BOOTSTRAP_ROLE, BENCHMARK_BOOTSTRAP_PATH),
        ("executable", FEEDBACK_EXECUTABLE_PATH),
        ("templates", FEEDBACK_TEMPLATES_PATH),
    },
    "scorer": {
        *(("executable", path) for path in SCORER_EXECUTABLE_PATHS),
        (BENCHMARK_BOOTSTRAP_ROLE, BENCHMARK_BOOTSTRAP_PATH),
    },
    "splits": {("splits", SPLITS_PATH)},
    "conformance": {
        ("cases", CONFORMANCE_CASES_PATH),
        ("coverage", CONFORMANCE_COVERAGE_PATH),
        (BENCHMARK_BOOTSTRAP_ROLE, BENCHMARK_BOOTSTRAP_PATH),
        ("executable", CONFORMANCE_EXECUTABLE_PATH),
    },
}

REPLACEMENT_IMMUTABLE_CATEGORIES = frozenset(
    {
        "conformance",
        "dependencies",
        "feedback",
        "fixtures",
        "gold",
        "lesson_linter",
        "model",
        "output",
        "prompts",
        "retry",
        "run_order",
        "runtime_sources",
        "schemas",
        "scorer",
        "splits",
    }
)
REPLACEMENT_CHANGED_HARNESS_PATHS = frozenset(
    {
        "Sources/ClawEvaluation/Controller/EvaluationControllerExecution.swift",
        "Sources/ClawEvaluation/Controller/EvaluationControllerValidation.swift",
        "Sources/ClawEvaluation/Infrastructure/EvaluationFreezeVerification.swift",
        "Sources/ClawEvaluation/Page/EvaluationCanaryExecution.swift",
        "Sources/ClawEvaluation/Page/EvaluationContract.swift",
        "Sources/ClawEvaluation/Page/Experiment/EvaluationPageExperiment.swift",
        "Sources/ClawEvaluation/Runtime/EvaluationRuntimeConfiguration.swift",
        "Sources/ClawEvaluation/Runtime/EvaluationWorker.swift",
    }
)
REPLACEMENT_ADDED_HARNESS_PATHS = frozenset(
    {"Sources/ClawEvaluation/Runtime/EvaluationExperimentProfile.swift"}
)
REPLACEMENT_CHANGED_CONFIGURATION_PATHS = frozenset(
    {
        MANIFEST_DESCRIPTOR_PATH,
        f"{FREEZE_PACKAGE_ROOT}/approval.py",
        f"{FREEZE_PACKAGE_ROOT}/artifacts.py",
        f"{FREEZE_PACKAGE_ROOT}/cli.py",
        f"{FREEZE_PACKAGE_ROOT}/contract.py",
    }
)
REPLACEMENT_ADDED_CONFIGURATION_PATHS = frozenset(
    {f"{FREEZE_PACKAGE_ROOT}/recovery.py"}
)

RESERVED_METADATA_KEYS = frozenset(
    {"commit", "freeze_commit", "git_commit", "git_revision", "head_commit",
     "revision", "source_revision", "treeish"}
)
VOLATILE_MANIFEST_KEYS = frozenset(
    {"generated_at", "generatedAt", "created_at", "createdAt", "updated_at", "updatedAt"}
)
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
GIT_OBJECT_ID = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")


class FreezeError(Exception):
    """Deterministic freeze validation failure."""


def fail(message: str) -> NoReturn:
    raise FreezeError(message)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _reject_number(raw: str) -> NoReturn:
    fail(f"unsupported JSON number: {raw}")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_json(value: Any, *, location: str, allow_floats: bool = False) -> None:
    if value is None or isinstance(value, bool) or isinstance(value, str):
        if isinstance(value, str):
            try:
                value.encode("utf-8")
            except UnicodeEncodeError:
                fail(f"string is not valid Unicode at {location}")
        return
    if isinstance(value, int) and not isinstance(value, bool):
        if not -(2**63) <= value <= 2**63 - 1:
            fail(f"integer outside signed 64-bit range at {location}")
        return
    if isinstance(value, float):
        if not allow_floats or not math.isfinite(value):
            fail(f"unsupported JSON number at {location}: {value}")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            validate_json(item, location=f"{location}[{index}]", allow_floats=allow_floats)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or not key or not key.isascii():
                fail(f"JSON object keys must be non-empty ASCII strings at {location}")
            validate_json(item, location=f"{location}.{key}", allow_floats=allow_floats)
        return
    fail(f"unsupported JSON value at {location}: {type(value).__name__}")


def load_json_bytes(raw: bytes, *, location: str, allow_floats: bool = False) -> Any:
    if raw.startswith(b"\xef\xbb\xbf"):
        fail(f"UTF-8 byte-order marks are forbidden: {location}")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"JSON is not UTF-8: {location}: {error}")
    try:
        value = json.loads(text, object_pairs_hook=_unique_object,
                           parse_float=float if allow_floats else _reject_number,
                           parse_constant=_reject_number)
    except FreezeError:
        raise
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {location}: {error}")
    validate_json(value, location=location, allow_floats=allow_floats)
    return value


def load_json(path: Path) -> tuple[Any, bytes]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        fail(f"cannot read {path}: {error}")
    return load_json_bytes(raw, location=str(path)), raw


def canonical_json_bytes(value: Any, *, allow_floats: bool = False) -> bytes:
    validate_json(value, location="canonical JSON", allow_floats=allow_floats)
    try:
        return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True,
                          separators=(",", ":")).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        fail(f"cannot encode canonical JSON: {error}")


def canonical_json_line_bytes(value: Any, *, allow_floats: bool = False) -> bytes:
    return canonical_json_bytes(value, allow_floats=allow_floats) + b"\n"


def exactly_equal(left: Any, right: Any) -> bool:
    if type(left) is not type(right):
        return False
    if isinstance(left, list):
        return len(left) == len(right) and all(map(lambda pair: exactly_equal(*pair), zip(left, right)))
    if isinstance(left, dict):
        return set(left) == set(right) and all(exactly_equal(left[key], right[key]) for key in left)
    return left == right


def require_object(value: Any, *, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{location} must be an object")
    return value


def require_keys(value: dict[str, Any], expected: set[str], *, location: str) -> None:
    actual = set(value)
    if actual != expected:
        fail(f"{location} has wrong keys; missing={sorted(expected-actual)}, extra={sorted(actual-expected)}")


def reject_reserved_keys(value: Any, *, location: str) -> None:
    if isinstance(value, list):
        for index, item in enumerate(value):
            reject_reserved_keys(item, location=f"{location}[{index}]")
    elif isinstance(value, dict):
        for key, item in value.items():
            if key in RESERVED_METADATA_KEYS or key.endswith("_commit"):
                fail(f"{key} is externally bound and must not appear inside {location}")
            if key in VOLATILE_MANIFEST_KEYS:
                fail(f"volatile field {key} must not appear inside {location}")
            reject_reserved_keys(item, location=f"{location}.{key}")


def normalized_path(raw: Any, *, location: str) -> str:
    if not isinstance(raw, str) or not raw or "\\" in raw or "\x00" in raw:
        fail(f"{location} must be a non-empty printable POSIX path")
    path = PurePosixPath(raw)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"{location} must be a normalized repository-relative path: {raw}")
    if path.as_posix() != raw or any(ord(character) < 0x20 for character in raw):
        fail(f"{location} must be normalized: {raw}")
    return raw
