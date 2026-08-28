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

PROTOCOL_VERSION = "0.6"
PROTOCOL_PATH = "docs/research/118-validation-protocol.md"
PROTOCOL_SHA256 = "777343c73654256df50081c5b2be81fb41db529fbf98d2e067d41139bc39bc7e"
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
PRIOR_INVALIDATED_MANIFEST_SHA256 = (
    "d5ae7dcef1c20f4c95f22cad9d23c7c1f37409abb3d2a02349a951c7647faad8"
)
PRIOR_INVALIDATED_MANIFEST_PATH = (
    f"{PAGE_ROOT}/provenance/invalidated-page-manifest-d5ae7dcef1c2.json"
)
PRIOR_INVALID_BATCH_JOURNAL_SHA256 = (
    "377b6c1c9e5161fc10e41e723906ca1492fd60256ba2715d5bc109df39ace3cb"
)
PRIOR_INVALID_BATCH_JOURNAL_PATH = (
    f"{PAGE_ROOT}/provenance/invalid-batch-controller-journal-d5ae7dcef1c2.jsonl"
)
PRIOR_INVALID_BATCH_TERMINAL_RESULT_SHA256 = (
    "ceda3f4995d3bc2655faa68d5aeb29efc6b31e4a0f4db73404c20c9415b367d8"
)
PRIOR_INVALID_BATCH_TERMINAL_RESULT_PATH = (
    f"{PAGE_ROOT}/provenance/invalid-batch-terminal-result-d5ae7dcef1c2.json"
)
PRIOR_INVALIDATION_REPORT_SHA256 = (
    "7f663a34f284ff4e98ea7f6cacad6d371b7cbb9f5e02a01f65083113cfaf4559"
)
PRIOR_INVALIDATION_REPORT_PATH = (
    f"{PAGE_ROOT}/provenance/invalidation-report-d5ae7dcef1c2.json"
)
PRIOR_RECOVERY_LEDGER_SHA256 = (
    "bec9cfe583a73844f0952c77c05abffa10f496196f15e57ca34931c9cc387f3d"
)
PRIOR_RECOVERY_LEDGER_PATH = f"{PAGE_ROOT}/provenance/recovery-ledger-d5ae7dcef1c2.json"

INVALIDATED_MANIFEST_SHA256 = "40a848a3dc290fa203fe084ec9a18bc5c9b4416ca2eff5ecd55f65bd450ad63f"
INVALIDATED_MANIFEST_PATH = (
    f"{PAGE_ROOT}/provenance/invalidated-page-manifest-40a848a3dc29.json"
)
INVALID_BATCH_JOURNAL_SHA256 = (
    "ecb119808f5cc49d64b53f6b0a61c8ba7524bd861d117478c5ff7f769b9d0846"
)
INVALID_BATCH_JOURNAL_PATH = (
    f"{PAGE_ROOT}/provenance/invalid-batch-controller-journal-40a848a3dc29.jsonl"
)
INVALID_BATCH_TERMINAL_RESULT_SHA256 = (
    "854bd5593f8fa1342e03b8e1713420931a048720fa33fb75ec7bc93308eda7c3"
)
INVALID_BATCH_TERMINAL_RESULT_PATH = (
    f"{PAGE_ROOT}/provenance/invalid-batch-terminal-result-40a848a3dc29.json"
)
INVALIDATION_REPORT_SHA256 = "ad312cf9f93ab58df3a12caa5032087ab8c929a41b14df7c794be5039cd45056"
INVALIDATION_REPORT_PATH = f"{PAGE_ROOT}/provenance/invalidation-report-40a848a3dc29.json"
RECOVERY_LEDGER_PATH = f"{PAGE_ROOT}/provenance/recovery-ledger-40a848a3dc29.json"
INVALIDATED_REPLACEMENT_DELTA_SHA256 = (
    "60d7edc9d6ad55fc29a75bff71c1ad3c1bac65ea75977a4da7af84bc03bed899"
)
INVALIDATED_REPLACEMENT_DELTA_PATH = (
    f"{PAGE_ROOT}/provenance/invalidated-replacement-delta-40a848a3dc29.json"
)
INVALID_BATCH_DEVELOPMENT_GATE_SHA256 = (
    "7f8d40d6206c4a055df1b0abbba5ab6d628849d55ae7f8af443048d6a9486154"
)
INVALID_BATCH_DEVELOPMENT_GATE_PATH = (
    f"{PAGE_ROOT}/provenance/invalid-batch-development-gate-40a848a3dc29.json"
)
INVALID_BATCH_COMPOSITES = (
    (
        "development_records",
        f"{PAGE_ROOT}/provenance/invalid-batch-development-records-40a848a3dc29.json",
        "be08920443960330d682933a3b1feb3c96ec3c93d9f53ea1cb322b8cf0d65c42",
        68_893,
        "c307aa3de22d6cd2f0d7bb23a80c8c2446d6f5df2129011d67753febc95200b9",
        68_816,
    ),
    (
        "development_runs",
        f"{PAGE_ROOT}/provenance/invalid-batch-development-runs-40a848a3dc29.json",
        "7bffb183dbceaf847611b6da99c8342dfc9dfcc4ad0d6191312fc8ed25608076",
        39_350,
        "33cdc6fb39564f05cdcda6bc463b3014a99331d6360b9ef37f5542794c6815e5",
        39_273,
    ),
    (
        "development_bundle",
        f"{PAGE_ROOT}/provenance/invalid-batch-development-bundle-40a848a3dc29.json",
        "0d15886cd51726cef9c493c5517022dd12cf7a1a53aac90f3e8b3799204a4cc1",
        51_114,
        "ff32467069101ab729da701c8f65c3f25c7db2d467d06c796291f9ed26103d06",
        51_037,
    ),
)
INVALID_BATCH_EVIDENCE = (
    (
        "canary_summary",
        f"{PAGE_ROOT}/provenance/invalid-batch-canary-summary-40a848a3dc29.json",
        "434b7ffda44d7842f603748cef9e25413d3ad459f94af87fc2e4a9a653bc9791",
        314,
        False,
    ),
    (
        "live_freeze_receipt",
        f"{PAGE_ROOT}/provenance/invalid-batch-live-freeze-receipt-40a848a3dc29.json",
        "d1f8325cf339ede48c0ff1f17b57a6a5edce88ed28be82b284f56f57f7e80682",
        2_490,
        True,
    ),
    (
        "page_conformance",
        f"{PAGE_ROOT}/provenance/invalid-batch-page-conformance-40a848a3dc29.json",
        "585056a9d06443e433494c52bc2d63755303b7d7faedfa36f74fb1eab9d5b87c",
        16_135,
        True,
    ),
    (
        "page_summary",
        f"{PAGE_ROOT}/provenance/invalid-batch-page-summary-40a848a3dc29.json",
        "215d791c6a1db27ea61e3cfab56a63a90c8054e7a056a6468ad7d97a40aa9c55",
        940,
        False,
    ),
    (
        "run_order",
        f"{PAGE_ROOT}/provenance/invalid-batch-run-order-40a848a3dc29.json",
        "518c85a65f5551f5ab3d713ba116735ff17c0b1da9cbe4d0d409be600f78b8c9",
        40_738,
        True,
    ),
)
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
        "replacement_controller_journal": (1, 1),
        "replacement_canary_summary": (1, 1),
        "replacement_development_bundle": (1, 1),
        "replacement_development_gate": (1, 1),
        "replacement_development_records": (1, 1),
        "replacement_development_runs": (1, 1),
        "replacement_invalidated_manifest": (1, 1),
        "replacement_invalidated_delta": (1, 1),
        "replacement_invalidation_report": (1, 1),
        "replacement_live_freeze_receipt": (1, 1),
        "replacement_page_conformance": (1, 1),
        "replacement_page_summary": (1, 1),
        "replacement_recovery_ledger": (1, 1),
        "replacement_run_order": (1, 1),
        "replacement_terminal_result": (1, 1),
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
        ("controller_journal", PRIOR_INVALID_BATCH_JOURNAL_PATH),
        ("invalidated_manifest", PRIOR_INVALIDATED_MANIFEST_PATH),
        ("invalidation_report", PRIOR_INVALIDATION_REPORT_PATH),
        ("recovery_ledger", PRIOR_RECOVERY_LEDGER_PATH),
        ("terminal_result", PRIOR_INVALID_BATCH_TERMINAL_RESULT_PATH),
        ("replacement_controller_journal", INVALID_BATCH_JOURNAL_PATH),
        ("replacement_canary_summary", INVALID_BATCH_EVIDENCE[0][1]),
        ("replacement_development_bundle", INVALID_BATCH_COMPOSITES[2][1]),
        ("replacement_development_gate", INVALID_BATCH_DEVELOPMENT_GATE_PATH),
        ("replacement_development_records", INVALID_BATCH_COMPOSITES[0][1]),
        ("replacement_development_runs", INVALID_BATCH_COMPOSITES[1][1]),
        ("replacement_invalidated_manifest", INVALIDATED_MANIFEST_PATH),
        ("replacement_invalidated_delta", INVALIDATED_REPLACEMENT_DELTA_PATH),
        ("replacement_invalidation_report", INVALIDATION_REPORT_PATH),
        ("replacement_live_freeze_receipt", INVALID_BATCH_EVIDENCE[1][1]),
        ("replacement_page_conformance", INVALID_BATCH_EVIDENCE[2][1]),
        ("replacement_page_summary", INVALID_BATCH_EVIDENCE[3][1]),
        ("replacement_recovery_ledger", RECOVERY_LEDGER_PATH),
        ("replacement_run_order", INVALID_BATCH_EVIDENCE[4][1]),
        ("replacement_terminal_result", INVALID_BATCH_TERMINAL_RESULT_PATH),
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
        "splits",
    }
)
REPLACEMENT_EXACT_CANDIDATE_ARTIFACTS = (
    (
        "executable",
        EXECUTABLE_PATH,
        "executable",
        16_722_896,
        "9a3ed6df83430e746ba4dd344b3f01ce136ac05bd84ba28e01b07c0f489b5702",
    ),
    (
        "harness_sources",
        "Sources/ClawEvaluation/Page/EvaluationContract.swift",
        "source",
        8_842,
        "96e3a816dbb19543fea5dc4714605286769b4d57554e705f33012c8f7fd57cba",
    ),
    (
        "harness_sources",
        "Sources/ClawEvaluation/Page/EvaluationPageRecords.swift",
        "source",
        12_674,
        "e62977f9118633f91a4b765ccce49bcfb638d9fe008e472193820066b79cbd51",
    ),
    (
        "harness_sources",
        "Sources/ClawEvaluation/Runtime/EvaluationHTTPRecorder.swift",
        "source",
        9_408,
        "fa0517a97f3bf2273c802a4d97df5b7f8cae844450576148332532ab5cdbe9e7",
    ),
    (
        "harness_sources",
        "Sources/ClawEvaluation/Page/Experiment/EvaluationPageExperiment.swift",
        "source",
        21_608,
        "0f0ea2fa14804459b5aa335c177ac221685e41c6d45ef2ef7f41cef112f03181",
    ),
    (
        "harness_sources",
        "Sources/ClawEvaluation/Runtime/EvaluationExperimentProfile.swift",
        "source",
        3_207,
        "7ddfe2a4f39ad0fb704ba65c4dbec6ca60519ba0e2d2d289141219429a4b1bb3",
    ),
    (
        "scorer",
        f"{BENCHMARK_PACKAGE_ROOT}/record.py",
        "source",
        5_882,
        "0ea3deb22aa1f920131dc0413241f50b866e175130e06ad0d55aa71927d0674c",
    ),
)
REPLACEMENT_CHANGED_HARNESS_PATHS = frozenset(
    path
    for category, path, _role, _byte_count, _digest
    in REPLACEMENT_EXACT_CANDIDATE_ARTIFACTS
    if category == "harness_sources"
)
REPLACEMENT_ADDED_HARNESS_PATHS = frozenset()
REPLACEMENT_CHANGED_SCORER_PATHS = frozenset(
    path
    for category, path, _role, _byte_count, _digest
    in REPLACEMENT_EXACT_CANDIDATE_ARTIFACTS
    if category == "scorer"
)
REPLACEMENT_CHANGED_CONFIGURATION_PATHS = frozenset(
    {
        MANIFEST_DESCRIPTOR_PATH,
        f"{FREEZE_PACKAGE_ROOT}/contract.py",
        f"{FREEZE_PACKAGE_ROOT}/recovery.py",
    }
)
REPLACEMENT_ADDED_CONFIGURATION_PATHS = frozenset()

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
