"""Protocol 0.6 chained recovery evidence and replacement-D6 admission."""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import Any, Optional

from . import artifacts
from .contract import (
    CATEGORY_NAMES,
    EXECUTABLE_PATH,
    EXPERIMENT,
    FIXED_ROLE_PATHS,
    HEX_SHA256,
    INVALID_BATCH_COMPOSITES,
    INVALID_BATCH_DEVELOPMENT_GATE_PATH,
    INVALID_BATCH_DEVELOPMENT_GATE_SHA256,
    INVALID_BATCH_EVIDENCE,
    INVALID_BATCH_JOURNAL_PATH,
    INVALID_BATCH_JOURNAL_SHA256,
    INVALID_BATCH_TERMINAL_RESULT_PATH,
    INVALID_BATCH_TERMINAL_RESULT_SHA256,
    INVALIDATED_MANIFEST_PATH,
    INVALIDATED_MANIFEST_SHA256,
    INVALIDATED_REPLACEMENT_DELTA_PATH,
    INVALIDATED_REPLACEMENT_DELTA_SHA256,
    INVALIDATION_REPORT_PATH,
    INVALIDATION_REPORT_SHA256,
    MANIFEST_DESCRIPTOR_PATH,
    PAGE_ROOT,
    PRIOR_INVALIDATED_MANIFEST_PATH,
    PRIOR_INVALIDATED_MANIFEST_SHA256,
    PRIOR_INVALID_BATCH_JOURNAL_PATH,
    PRIOR_INVALID_BATCH_JOURNAL_SHA256,
    PRIOR_INVALID_BATCH_TERMINAL_RESULT_PATH,
    PRIOR_INVALID_BATCH_TERMINAL_RESULT_SHA256,
    PRIOR_INVALIDATION_REPORT_PATH,
    PRIOR_INVALIDATION_REPORT_SHA256,
    PRIOR_RECOVERY_LEDGER_PATH,
    PRIOR_RECOVERY_LEDGER_SHA256,
    PROTOCOL_PATH,
    PROTOCOL_SHA256,
    PROTOCOL_VERSION,
    RECOVERY_LEDGER_PATH,
    REPLACEMENT_ADDED_CONFIGURATION_PATHS,
    REPLACEMENT_ADDED_HARNESS_PATHS,
    REPLACEMENT_CHANGED_CONFIGURATION_PATHS,
    REPLACEMENT_CHANGED_HARNESS_PATHS,
    REPLACEMENT_CHANGED_SCORER_PATHS,
    REPLACEMENT_DELTA_PATH,
    REPLACEMENT_EXACT_CANDIDATE_ARTIFACTS,
    REPLACEMENT_IMMUTABLE_CATEGORIES,
    canonical_json_bytes,
    canonical_json_line_bytes,
    exactly_equal,
    fail,
    load_json_bytes,
    require_object,
    sha256_hex,
)

LEDGER_KIND = "swift-claw.scheduled-task-learning.page-change.recovery-ledger"
DELTA_KIND = "swift-claw.scheduled-task-learning.page-change.replacement-delta"
PRIOR_EXPECTED_TOTAL = {
    "accounted_tokens": 28_159,
    "attempts": 12,
    "file_reads": 11,
    "responses_sends": 22,
}
PRIOR_EXPECTED_STAGES = [
    {
        "accounted_tokens": 9_550,
        "attempts": 4,
        "file_reads": 4,
        "name": "canary",
        "responses_sends": 8,
    },
    {
        "accounted_tokens": 18_609,
        "attempts": 8,
        "file_reads": 7,
        "name": "page_clean_development",
        "responses_sends": 14,
    },
]
EXPECTED_FRESH_TOTAL = {
    "accounted_tokens": 57_798,
    "attempts": 22,
    "file_reads": 22,
    "responses_sends": 44,
}
EXPECTED_FRESH_STAGES = [
    {
        "accounted_tokens": 9_548,
        "attempts": 4,
        "file_reads": 4,
        "name": "canary",
        "responses_sends": 8,
    },
    {
        "accounted_tokens": 48_250,
        "attempts": 18,
        "file_reads": 18,
        "name": "page_clean_development",
        "responses_sends": 36,
    },
]
EXPECTED_TOTAL = {
    "accounted_tokens": 85_957,
    "attempts": 34,
    "file_reads": 33,
    "responses_sends": 66,
}
EXPECTED_STAGES = [
    {
        "accounted_tokens": 19_098,
        "attempts": 8,
        "file_reads": 8,
        "name": "canary",
        "responses_sends": 16,
    },
    {
        "accounted_tokens": 66_859,
        "attempts": 26,
        "file_reads": 25,
        "name": "page_clean_development",
        "responses_sends": 50,
    },
]
RECOVERY_CAPS = {
    "canary_attempt_cap": (8, 12),
    "canary_responses_send_cap": (16, 24),
    "global_attempt_cap": (206, 228),
    "global_file_read_cap": (205, 227),
    "global_responses_send_cap": (410, 454),
    "page_attempt_cap": (84, 102),
    "page_responses_send_cap": (166, 202),
}


def _regular_bytes(repo_root: Path, path: str) -> bytes:
    root = repo_root.resolve(strict=True)
    return artifacts.rooted_regular_file(root, path).read_bytes()


def _exact_file(repo_root: Path, path: str, digest: str) -> bytes:
    raw = _regular_bytes(repo_root, path)
    if sha256_hex(raw) != digest:
        fail(f"recovery source has the wrong SHA-256: {path}")
    return raw


def _canonical_file(repo_root: Path, path: str) -> tuple[dict[str, Any], bytes]:
    raw = _regular_bytes(repo_root, path)
    value = require_object(load_json_bytes(raw, location=path), location=path)
    if canonical_json_bytes(value) != raw:
        fail(f"recovery source must be canonical JSON: {path}")
    return value, raw


def _canonical_source(
    repo_root: Path,
    path: str,
    digest: str,
    *,
    trailing_lf: bool = False,
) -> tuple[dict[str, Any], bytes]:
    raw = _exact_file(repo_root, path, digest)
    value = require_object(load_json_bytes(raw, location=path), location=path)
    expected = canonical_json_line_bytes(value) if trailing_lf else canonical_json_bytes(value)
    if expected != raw:
        fail(f"recovery source must be canonical JSON: {path}")
    return value, raw


def _journal_events(
    repo_root: Path,
    *,
    path: str,
    digest: str,
    manifest_sha256: str,
) -> tuple[list[dict[str, Any]], bytes]:
    raw = _exact_file(repo_root, path, digest)
    lines = raw.splitlines(keepends=True)
    if not lines or b"".join(lines) != raw:
        fail("recovery journal must contain complete newline-terminated events")
    events: list[dict[str, Any]] = []
    for index, line in enumerate(lines):
        value = require_object(
            load_json_bytes(line, location=f"recovery journal line {index + 1}"),
            location=f"recovery journal line {index + 1}",
        )
        if canonical_json_line_bytes(value) != line:
            fail(f"recovery journal line {index + 1} is not canonical JSONL")
        if value.get("manifest_sha256") != manifest_sha256:
            fail(f"recovery journal line {index + 1} names the wrong manifest")
        events.append(value)
    return events, raw


def _stage(attempt_id: str) -> str:
    if attempt_id.startswith("page-canary-"):
        return "canary"
    if attempt_id.startswith("page-development-"):
        return "page_clean_development"
    fail(f"invalidated attempt has an unknown stage: {attempt_id}")


def _launches(events: list[dict[str, Any]]) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    if events[0].get("kind") != "batch_started" or events[-1].get("kind") != "batch_completed":
        fail("recovery journal must have one complete batch boundary")
    launches: list[tuple[dict[str, Any], dict[str, Any]]] = []
    pending: dict[str, dict[str, Any]] = {}
    for event in events[1:-1]:
        kind = event.get("kind")
        invocation_id = event.get("invocation_id")
        if not isinstance(invocation_id, str) or not invocation_id:
            fail("recovery journal launch event lacks invocation_id")
        if kind == "launch_reserved":
            if invocation_id in pending:
                fail(f"duplicate recovery reservation: {invocation_id}")
            pending[invocation_id] = event
            continue
        if kind not in {"launch_completed", "launch_rejected"} or invocation_id not in pending:
            fail(f"unpaired recovery terminal event: {invocation_id}")
        reservation = pending.pop(invocation_id)
        if event.get("attempt_ids") != reservation.get("attempt_ids"):
            fail(f"recovery terminal attempt IDs differ from reservation: {invocation_id}")
        launches.append((reservation, event))
    if pending:
        fail(f"recovery journal has unterminated reservations: {sorted(pending)}")
    return launches


def _report_rows(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    raw_rows = report.get("invalidated_result_artifacts")
    if not isinstance(raw_rows, list):
        fail("invalidation report lacks result-artifact rows")
    rows: dict[str, dict[str, Any]] = {}
    for index, raw_row in enumerate(raw_rows):
        row = require_object(raw_row, location=f"invalidation result row {index}")
        attempt_id = row.get("attempt_id")
        if not isinstance(attempt_id, str) or attempt_id in rows:
            fail("invalidation report has an invalid or duplicate attempt row")
        for field in (
            "accounted_tokens",
            "bytes",
            "file_reads",
            "provider_usage_rows",
            "responses_sends",
        ):
            if type(row.get(field)) is not int or row[field] < 0:
                fail(f"invalidation result row has invalid {field}: {attempt_id}")
        digest = row.get("sha256")
        if not isinstance(digest, str) or not HEX_SHA256.fullmatch(digest):
            fail(f"invalidation result row has invalid SHA-256: {attempt_id}")
        rows[attempt_id] = row
    return rows


def _attempt_rows(
    launches: list[tuple[dict[str, Any], dict[str, Any]]],
    report_rows: dict[str, dict[str, Any]],
    rejected: dict[str, Any],
) -> list[dict[str, Any]]:
    attempts: list[dict[str, Any]] = []
    seen: set[str] = set()
    for reservation, terminal in launches:
        attempt_ids = reservation.get("attempt_ids")
        if not isinstance(attempt_ids, list) or not attempt_ids:
            fail("recovery reservation must contain attempt IDs")
        launch_totals = dict.fromkeys(("accounted_tokens", "file_reads", "responses_sends"), 0)
        for attempt_id in attempt_ids:
            if not isinstance(attempt_id, str) or attempt_id in seen:
                fail("recovery journal has an invalid or duplicate attempt ID")
            seen.add(attempt_id)
            result = report_rows.get(attempt_id)
            if terminal["kind"] == "launch_rejected":
                if result is not None or rejected.get("attempt_id") != attempt_id:
                    fail("rejected recovery attempt does not match invalidation evidence")
                if rejected.get("file_reads") != 0 or rejected.get("responses_sends") != 0:
                    fail("rejected recovery attempt must have zero accounting")
                row_values = dict.fromkeys(launch_totals, 0)
            else:
                if result is None:
                    fail(f"completed recovery attempt lacks result evidence: {attempt_id}")
                row_values = {name: result[name] for name in launch_totals}
            for name, value in row_values.items():
                launch_totals[name] += value
            attempts.append(
                {
                    "accounted_tokens": row_values["accounted_tokens"],
                    "attempt_id": attempt_id,
                    "file_reads": row_values["file_reads"],
                    "invocation_id": reservation["invocation_id"],
                    "reservation_event_id": reservation["event_id"],
                    "responses_sends": row_values["responses_sends"],
                    "result_bytes": result["bytes"] if result is not None else None,
                    "result_sha256": result["sha256"] if result is not None else None,
                    "stage": _stage(attempt_id),
                    "terminal_event_id": terminal["event_id"],
                    "terminal_kind": terminal["kind"],
                }
            )
        for name, value in launch_totals.items():
            if terminal.get(f"observed_{name}") != value:
                fail(f"journal terminal {name} disagrees with invalidation evidence")
    if set(report_rows) != {row["attempt_id"] for row in attempts if row["result_sha256"]}:
        fail("invalidation result rows do not equal completed journal attempts")
    return attempts


_ACCOUNTING_FIELDS = ("accounted_tokens", "attempts", "file_reads", "responses_sends")


def _attempt_summaries(
    attempts: list[dict[str, Any]],
    *,
    expected_stages: list[dict[str, Any]],
    expected_total: dict[str, Any],
    failure: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    values: dict[str, dict[str, int]] = defaultdict(
        lambda: {"accounted_tokens": 0, "attempts": 0, "file_reads": 0, "responses_sends": 0}
    )
    for row in attempts:
        stage = values[row["stage"]]
        stage["attempts"] += 1
        for name in ("accounted_tokens", "file_reads", "responses_sends"):
            stage[name] += row[name]
    stages = [{"name": name, **values[name]} for name in ("canary", "page_clean_development")]
    total = {
        name: sum(stage[name] for stage in stages)
        for name in ("accounted_tokens", "attempts", "file_reads", "responses_sends")
    }
    if stages != expected_stages or total != expected_total:
        fail(failure)
    return stages, total


def _verify_prior_terminal(
    terminal: dict[str, Any],
    attempts: list[dict[str, Any]],
    stages: list[dict[str, Any]],
) -> None:
    if terminal.get("journal_sha256") != PRIOR_INVALID_BATCH_JOURNAL_SHA256 \
            or terminal.get("outcome") != "invalid_batch" \
            or terminal.get("stop_reason") != "worker_nonzero_exit":
        fail("terminal recovery result does not bind the invalid journal outcome")
    for index, stage in enumerate(stages):
        field = ("canary_summary", "summary")[index]
        summary = require_object(terminal.get(field), location=f"terminal {field}")
        for name in ("accounted_tokens", "attempts", "file_reads", "responses_sends"):
            if summary.get(name) != stage[name]:
                fail(f"terminal {field}.{name} disagrees with recovery ledger")
        completed = [
            row["attempt_id"]
            for row in attempts
            if row["stage"] == stage["name"] and row["terminal_kind"] == "launch_completed"
        ]
        if summary.get("completed_attempt_ids") != completed:
            fail(f"terminal {field} completed attempt IDs disagree with recovery journal")


def build_prior_recovery_ledger(repo_root: Path) -> dict[str, Any]:
    root = repo_root.resolve(strict=True)
    _canonical_source(
        root, PRIOR_INVALIDATED_MANIFEST_PATH, PRIOR_INVALIDATED_MANIFEST_SHA256
    )
    report, report_raw = _canonical_source(
        root, PRIOR_INVALIDATION_REPORT_PATH, PRIOR_INVALIDATION_REPORT_SHA256
    )
    terminal, terminal_raw = _canonical_source(
        root,
        PRIOR_INVALID_BATCH_TERMINAL_RESULT_PATH,
        PRIOR_INVALID_BATCH_TERMINAL_RESULT_SHA256,
        trailing_lf=True,
    )
    events, journal_raw = _journal_events(
        root,
        path=PRIOR_INVALID_BATCH_JOURNAL_PATH,
        digest=PRIOR_INVALID_BATCH_JOURNAL_SHA256,
        manifest_sha256=PRIOR_INVALIDATED_MANIFEST_SHA256,
    )
    report_digests = require_object(
        report.get("artifact_digests"), location="invalidation report artifact digests"
    )
    if report_digests.get("journal_sha256") != PRIOR_INVALID_BATCH_JOURNAL_SHA256 \
            or report_digests.get("pipeline_result_sha256") \
            != PRIOR_INVALID_BATCH_TERMINAL_RESULT_SHA256:
        fail("invalidation report does not bind the preserved journal and terminal result")
    report_rows = _report_rows(report)
    closure = require_object(report.get("protected_closure_evidence"), location="closure evidence")
    rejected = require_object(closure.get("rejected_attempt"), location="rejected attempt")
    attempts = _attempt_rows(_launches(events), report_rows, rejected)
    if report.get("affected_attempts") != [row["attempt_id"] for row in attempts]:
        fail("invalidation report affected attempts differ from journal order")
    stages, total = _attempt_summaries(
        attempts,
        expected_stages=PRIOR_EXPECTED_STAGES,
        expected_total=PRIOR_EXPECTED_TOTAL,
        failure="recovery accounting does not reproduce the frozen 12/22/11/28159 seed",
    )
    _verify_prior_terminal(terminal, attempts, stages)
    if report.get("cumulative_accounting_seed") != {
        "source_manifest_sha256": PRIOR_INVALIDATED_MANIFEST_SHA256,
        "stages": stages,
        "total": total,
    }:
        fail("invalidation report recovery seed differs from recomputed accounting")
    return {
        "attempts": attempts,
        "experiment": EXPERIMENT,
        "kind": LEDGER_KIND,
        "schema_version": 1,
        "sources": {
            "controller_journal": {
                "bytes": len(journal_raw),
                "path": PRIOR_INVALID_BATCH_JOURNAL_PATH,
                "sha256": PRIOR_INVALID_BATCH_JOURNAL_SHA256,
            },
            "invalidated_manifest": {
                "path": PRIOR_INVALIDATED_MANIFEST_PATH,
                "sha256": PRIOR_INVALIDATED_MANIFEST_SHA256,
            },
            "invalidation_report": {
                "bytes": len(report_raw),
                "path": PRIOR_INVALIDATION_REPORT_PATH,
                "sha256": PRIOR_INVALIDATION_REPORT_SHA256,
            },
            "terminal_result": {
                "bytes": len(terminal_raw),
                "path": PRIOR_INVALID_BATCH_TERMINAL_RESULT_PATH,
                "sha256": PRIOR_INVALID_BATCH_TERMINAL_RESULT_SHA256,
            },
        },
        "stages": stages,
        "total": total,
    }


def verify_prior_recovery_ledger(repo_root: Path) -> tuple[dict[str, Any], bytes]:
    expected = build_prior_recovery_ledger(repo_root)
    value, raw = _canonical_file(repo_root, PRIOR_RECOVERY_LEDGER_PATH)
    if not exactly_equal(value, expected):
        fail("stored prior recovery ledger differs from recomputed journal accounting")
    if sha256_hex(raw) != PRIOR_RECOVERY_LEDGER_SHA256:
        fail("stored prior recovery ledger has the wrong SHA-256")
    return expected, raw


def _verify_evidence(
    repo_root: Path,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    sources: list[dict[str, Any]] = []
    values: dict[str, dict[str, Any]] = {}
    for role, path, digest, byte_count, trailing_lf in INVALID_BATCH_EVIDENCE:
        if role in {"canary_summary", "page_summary"}:
            raw = _exact_file(repo_root, path, digest)
            value = require_object(load_json_bytes(raw, location=path), location=path)
        elif role == "page_conformance":
            raw = _exact_file(repo_root, path, digest)
            value = require_object(
                load_json_bytes(raw, location=path, allow_floats=True),
                location=path,
            )
            if canonical_json_line_bytes(value, allow_floats=True) != raw:
                fail(f"recovery source must be canonical JSON: {path}")
        else:
            value, raw = _canonical_source(
                repo_root,
                path,
                digest,
                trailing_lf=trailing_lf,
            )
        if len(raw) != byte_count:
            fail(f"invalid-batch evidence has the wrong byte count: {path}")
        if role == "live_freeze_receipt":
            if value.get("status") != "verified" \
                    or value.get("freeze_commit") != "902868a7d163650f6a68178a0d692658c653dd95" \
                    or require_object(value.get("manifest"), location="live receipt manifest").get(
                        "sha256"
                    ) != INVALIDATED_MANIFEST_SHA256:
                fail("invalid-batch live receipt does not bind the approved freeze")
        elif role == "page_conformance":
            if value.get("passed") != 24 or value.get("total") != 24:
                fail("invalid-batch conformance receipt does not preserve 24/24")
        elif role == "run_order" and value.get("manifest_sha256") \
                != INVALIDATED_MANIFEST_SHA256:
            fail("invalid-batch run order does not bind the approved manifest")
        sources.append(
            {
                "bytes": byte_count,
                "path": path,
                "role": role,
                "sha256": digest,
            }
        )
        values[role] = value
    return sources, values


def _combine_stages(
    prior: list[dict[str, Any]], fresh: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    if [row["name"] for row in prior] != [row["name"] for row in fresh]:
        fail("recovery stage chains differ")
    stages = [
        {
            "name": old["name"],
            **{name: old[name] + new[name] for name in _ACCOUNTING_FIELDS},
        }
        for old, new in zip(prior, fresh)
    ]
    total = {name: sum(stage[name] for stage in stages) for name in _ACCOUNTING_FIELDS}
    if stages != EXPECTED_STAGES or total != EXPECTED_TOTAL:
        fail("recovery chain does not reproduce the frozen 34/66/33/85957 seed")
    return stages, total


def _verify_composites(repo_root: Path) -> list[dict[str, Any]]:
    sources: list[dict[str, Any]] = []
    for role, path, digest, byte_count, canonical_digest, canonical_byte_count in \
            INVALID_BATCH_COMPOSITES:
        raw = _exact_file(repo_root, path, digest)
        if len(raw) != byte_count:
            fail(f"invalid-batch composite has the wrong byte count: {path}")
        value = load_json_bytes(raw, location=path, allow_floats=True)
        canonical = canonical_json_line_bytes(value, allow_floats=True)
        if raw == canonical \
                or len(canonical) != canonical_byte_count \
                or sha256_hex(canonical) != canonical_digest:
            fail(f"invalid-batch composite does not reproduce its frozen mismatch: {path}")
        first_difference = next(
            (
                index
                for index, (actual_byte, canonical_byte) in enumerate(zip(raw, canonical))
                if actual_byte != canonical_byte
            ),
            min(len(raw), len(canonical)),
        )
        if role == "development_records":
            composite = require_object(value, location=path)
            records = composite.get("records")
            if not isinstance(records, list) or len(records) != 18:
                fail("invalid-batch development records must contain exactly 18 scores")
        sources.append(
            {
                "bytes": byte_count,
                "canonical_bytes": canonical_byte_count,
                "canonical_sha256": canonical_digest,
                "first_difference_offset": first_difference,
                "path": path,
                "role": role,
                "sha256": digest,
            }
        )
    return sources


def _verify_replacement_terminal(
    terminal: dict[str, Any],
    attempts: list[dict[str, Any]],
    cumulative_stages: list[dict[str, Any]],
) -> None:
    if terminal.get("journal_sha256") != INVALID_BATCH_JOURNAL_SHA256 \
            or terminal.get("outcome") != "invalid_batch" \
            or terminal.get("stop_reason") \
            != f"protected_artifact_failed:{PAGE_ROOT}/artifacts/page-aggregate":
        fail("terminal recovery result does not bind the canonicalization failure")
    if terminal.get("development_gate_sha256") != INVALID_BATCH_DEVELOPMENT_GATE_SHA256:
        fail("terminal recovery result does not bind the failed development gate")
    for index, stage in enumerate(cumulative_stages):
        field = ("canary_summary", "summary")[index]
        summary = require_object(terminal.get(field), location=f"terminal {field}")
        for name in _ACCOUNTING_FIELDS:
            if summary.get(name) != stage[name]:
                fail(f"terminal {field}.{name} disagrees with chained recovery ledger")
        completed = [
            attempt["attempt_id"]
            for attempt in attempts
            if attempt["stage"] == stage["name"]
        ]
        if summary.get("completed_attempt_ids") != completed:
            fail(f"terminal {field} completed attempt IDs disagree with recovery journal")


def build_recovery_ledger(repo_root: Path) -> dict[str, Any]:
    root = repo_root.resolve(strict=True)
    prior, prior_raw = verify_prior_recovery_ledger(root)
    _canonical_source(root, INVALIDATED_MANIFEST_PATH, INVALIDATED_MANIFEST_SHA256)
    invalidated_delta, invalidated_delta_raw = _canonical_source(
        root,
        INVALIDATED_REPLACEMENT_DELTA_PATH,
        INVALIDATED_REPLACEMENT_DELTA_SHA256,
    )
    if invalidated_delta.get("verdict") != "allowed" \
            or invalidated_delta.get("violations") != [] \
            or invalidated_delta.get("candidate_manifest") != {
                "path": "experiments/scheduled-task-learning/page-change/freeze/page-manifest.json",
                "sha256": INVALIDATED_MANIFEST_SHA256,
            } \
            or invalidated_delta.get("baseline_manifest") != {
                "path": PRIOR_INVALIDATED_MANIFEST_PATH,
                "sha256": PRIOR_INVALIDATED_MANIFEST_SHA256,
            }:
        fail("invalidated replacement delta does not bind the two prior freezes")
    report, report_raw = _canonical_source(
        root, INVALIDATION_REPORT_PATH, INVALIDATION_REPORT_SHA256, trailing_lf=True
    )
    terminal, terminal_raw = _canonical_source(
        root,
        INVALID_BATCH_TERMINAL_RESULT_PATH,
        INVALID_BATCH_TERMINAL_RESULT_SHA256,
        trailing_lf=True,
    )
    gate, gate_raw = _canonical_source(
        root,
        INVALID_BATCH_DEVELOPMENT_GATE_PATH,
        INVALID_BATCH_DEVELOPMENT_GATE_SHA256,
        trailing_lf=True,
    )
    if gate.get("outcome") != "invalid_batch" \
            or gate.get("gate_failures") != ["aggregate.input_invalid"]:
        fail("development gate does not reproduce the canonicalization invalidation")
    composites = _verify_composites(root)
    evidence, evidence_values = _verify_evidence(root)
    if evidence_values["canary_summary"] != terminal.get("canary_summary") \
            or evidence_values["page_summary"] != terminal.get("summary"):
        fail("preserved stage summaries differ from the terminal result")
    events, journal_raw = _journal_events(
        root,
        path=INVALID_BATCH_JOURNAL_PATH,
        digest=INVALID_BATCH_JOURNAL_SHA256,
        manifest_sha256=INVALIDATED_MANIFEST_SHA256,
    )
    launch_pairs = _launches(events)
    report_rows = _report_rows(report)
    attempts = _attempt_rows(launch_pairs, report_rows, {})
    fresh_stages, fresh_total = _attempt_summaries(
        attempts,
        expected_stages=EXPECTED_FRESH_STAGES,
        expected_total=EXPECTED_FRESH_TOTAL,
        failure="recovery accounting does not reproduce the frozen 22/44/22/57798 increment",
    )
    stages, total = _combine_stages(prior["stages"], fresh_stages)
    _verify_replacement_terminal(terminal, attempts, stages)

    expected_digests = {
        "development_bundle_sha256": INVALID_BATCH_COMPOSITES[2][2],
        "development_gate_sha256": INVALID_BATCH_DEVELOPMENT_GATE_SHA256,
        "development_records_sha256": INVALID_BATCH_COMPOSITES[0][2],
        "development_runs_sha256": INVALID_BATCH_COMPOSITES[1][2],
        "journal_sha256": INVALID_BATCH_JOURNAL_SHA256,
        "prior_invalidation_report_sha256": PRIOR_INVALIDATION_REPORT_SHA256,
        "prior_recovery_ledger_sha256": PRIOR_RECOVERY_LEDGER_SHA256,
        "pipeline_result_sha256": INVALID_BATCH_TERMINAL_RESULT_SHA256,
        "replacement_delta_sha256": INVALIDATED_REPLACEMENT_DELTA_SHA256,
        **{f"{role}_sha256": digest for role, _, digest, _, _ in INVALID_BATCH_EVIDENCE},
    }
    report_digests = require_object(
        report.get("artifact_digests"), location="invalidation report artifact digests"
    )
    if report_digests != expected_digests:
        fail("invalidation report does not bind the preserved canonicalization evidence")
    if report.get("batch") != {
        "approval_body_sha256": "f7c673cb633e237472aa2eaf6dcfb47518eb6637e7176c1fecd99267d5e920c7",
        "approval_comment_id": 5_450_724_909,
        "executable_sha256": "a2fa94b53d72cbaebf4fe85b949f05d4719eeaf24c68d8c47b2a56b0693d0cee",
        "freeze_commit": "902868a7d163650f6a68178a0d692658c653dd95",
        "manifest_sha256": INVALIDATED_MANIFEST_SHA256,
        "protocol_sha256": "ac2628e7e57f1c013c6fdb8f337426dadff534e03b7e2ded67973970c9d7c12f",
        "protocol_version": "0.5",
    }:
        fail("invalidation report batch binding differs from the approved D6 freeze")
    affected = [attempt["attempt_id"] for attempt in attempts]
    if report.get("affected_attempts") != affected:
        fail("invalidation report affected attempts differ from journal order")
    expected_canonicalization = [
        {
            "actual_bytes": source["bytes"],
            "actual_sha256": source["sha256"],
            "canonical_bytes": source["canonical_bytes"],
            "canonical_sha256": source["canonical_sha256"],
            "first_difference_offset": source["first_difference_offset"],
            "path": source["path"],
            "role": source["role"],
        }
        for source in composites
    ]
    if report.get("canonicalization_evidence") != expected_canonicalization:
        fail("invalidation report canonicalization evidence differs from recomputation")
    if report.get("fresh_accounting") != {
        "source_manifest_sha256": INVALIDATED_MANIFEST_SHA256,
        "stages": fresh_stages,
        "total": fresh_total,
    }:
        fail("invalidation report fresh accounting differs from the journal")
    if report.get("cumulative_accounting_seed") != {
        "prior_recovery_ledger_sha256": PRIOR_RECOVERY_LEDGER_SHA256,
        "source_manifest_sha256": INVALIDATED_MANIFEST_SHA256,
        "stages": stages,
        "total": total,
    }:
        fail("invalidation report cumulative accounting differs from the recovery chain")
    prior_outputs = sum(
        attempt["terminal_kind"] == "launch_completed" for attempt in prior["attempts"]
    )
    if report.get("outputs_exposed_before_discovery") != {
        "cumulative": {
            "accounted_tokens": total["accounted_tokens"],
            "file_reads": total["file_reads"],
            "provider_usage_rows": 66,
            "responses_sends": total["responses_sends"],
            "task_outputs": prior_outputs + len(attempts),
        },
        "fresh": {
            "development_score_records": 18,
            "task_output_ids": affected,
            "task_outputs": len(attempts),
        },
        "gate_accepted_scored_outputs": [],
        "sealed_content_exposed": False,
    }:
        fail("invalidation report output exposure differs from recomputation")
    if sum(row["provider_usage_rows"] for row in report_rows.values()) != 44:
        fail("invalidation report provider usage rows differ from result evidence")
    if report.get("protected_closure_evidence") != {
        "aggregate_failure": "aggregate.input_invalid",
        "completed_attempts": len(attempts),
        "completed_launches": len(launch_pairs),
        "development_score_records": 18,
        "journal_events": len(events),
        "regression_reservations": 0,
        "sealed_reservations": 0,
        "synthesis_reservations": 0,
    }:
        fail("invalidation report protected-closure evidence differs from recomputation")
    if report.get("classification") != "invalid_batch" \
            or report.get("experiment") != EXPERIMENT \
            or report.get("kind") \
            != "swift-claw.scheduled-task-learning.page-change.invalidation-report" \
            or report.get("schema_version") != 2:
        fail("invalidation report has the wrong identity or classification")

    return {
        "cumulative": {"stages": stages, "total": total},
        "experiment": EXPERIMENT,
        "fresh": {"attempts": attempts, "stages": fresh_stages, "total": fresh_total},
        "kind": LEDGER_KIND,
        "prior": {
            "path": PRIOR_RECOVERY_LEDGER_PATH,
            "sha256": sha256_hex(prior_raw),
            "stages": prior["stages"],
            "total": prior["total"],
        },
        "schema_version": 2,
        "sources": {
            "composites": composites,
            "controller_journal": {
                "bytes": len(journal_raw),
                "path": INVALID_BATCH_JOURNAL_PATH,
                "sha256": INVALID_BATCH_JOURNAL_SHA256,
            },
            "development_gate": {
                "bytes": len(gate_raw),
                "path": INVALID_BATCH_DEVELOPMENT_GATE_PATH,
                "sha256": INVALID_BATCH_DEVELOPMENT_GATE_SHA256,
            },
            "evidence": evidence,
            "invalidated_manifest": {
                "path": INVALIDATED_MANIFEST_PATH,
                "sha256": INVALIDATED_MANIFEST_SHA256,
            },
            "invalidated_replacement_delta": {
                "bytes": len(invalidated_delta_raw),
                "path": INVALIDATED_REPLACEMENT_DELTA_PATH,
                "sha256": INVALIDATED_REPLACEMENT_DELTA_SHA256,
            },
            "invalidation_report": {
                "bytes": len(report_raw),
                "path": INVALIDATION_REPORT_PATH,
                "sha256": INVALIDATION_REPORT_SHA256,
            },
            "terminal_result": {
                "bytes": len(terminal_raw),
                "path": INVALID_BATCH_TERMINAL_RESULT_PATH,
                "sha256": INVALID_BATCH_TERMINAL_RESULT_SHA256,
            },
        },
    }


def verify_recovery_ledger(
    repo_root: Path,
    *,
    expected_sha256: Optional[str] = None,
) -> tuple[dict[str, Any], bytes]:
    expected = build_recovery_ledger(repo_root)
    value, raw = _canonical_file(repo_root, RECOVERY_LEDGER_PATH)
    if not exactly_equal(value, expected):
        fail("stored recovery ledger differs from recomputed journal accounting")
    digest = sha256_hex(raw)
    if expected_sha256 is not None and digest != expected_sha256:
        fail("stored recovery ledger does not match the approved SHA-256")
    return expected, raw


def recovery_seed(ledger: dict[str, Any]) -> dict[str, Any]:
    cumulative = ledger["cumulative"]
    stages = {
        stage["name"]: {key: value for key, value in stage.items() if key != "name"}
        for stage in cumulative["stages"]
    }
    return {**stages, "total": cumulative["total"]}


def _artifact_map(category: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["path"]: item for item in category["artifacts"]}


def _compare_category_artifacts(
    name: str,
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    *,
    changed_paths: frozenset[str],
    added_paths: frozenset[str],
    added_roles: dict[str, str],
    compare_values: bool = True,
) -> list[str]:
    violations: list[str] = []
    old_items = _artifact_map(baseline)
    new_items = _artifact_map(candidate)
    if compare_values and not exactly_equal(baseline["values"], candidate["values"]):
        violations.append(f"{name}.values changed")
    for path, old in old_items.items():
        new = new_items.get(path)
        if new is None:
            violations.append(f"{name} removed {path}")
        elif old != new and (path not in changed_paths or old["role"] != new["role"]):
            violations.append(f"{name} changed forbidden path {path}")
    for path, new in new_items.items():
        if path not in old_items and (
            path not in added_paths or new["role"] != added_roles.get(path)
        ):
            violations.append(f"{name} added forbidden path {path}")
    return violations


def compare_replacement_manifests(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    *,
    baseline_sha256: str,
    candidate_sha256: str,
) -> dict[str, Any]:
    violations: list[str] = []
    for field in ("schema_version", "manifest_kind", "decision", "experiment", "swift_package"):
        if not exactly_equal(baseline.get(field), candidate.get(field)):
            violations.append(f"root field changed: {field}")
    old_protocol = baseline.get("protocol")
    new_protocol = candidate.get("protocol")
    if not isinstance(old_protocol, dict) or old_protocol.get("version") != "0.5":
        violations.append("baseline protocol is not version 0.5")
    if not isinstance(new_protocol, dict) or new_protocol != {
        "bytes": new_protocol.get("bytes") if isinstance(new_protocol, dict) else None,
        "path": PROTOCOL_PATH,
        "sha256": PROTOCOL_SHA256,
        "version": PROTOCOL_VERSION,
    }:
        violations.append("candidate protocol is not the exact version 0.6 binding")
    old_categories = baseline.get("categories")
    new_categories = candidate.get("categories")
    if (
        not isinstance(old_categories, dict)
        or not isinstance(new_categories, dict)
        or set(old_categories) != set(CATEGORY_NAMES)
        or set(new_categories) != set(CATEGORY_NAMES)
    ):
        fail("replacement manifests must contain the exact category set")
    for name in REPLACEMENT_IMMUTABLE_CATEGORIES:
        if not exactly_equal(old_categories[name], new_categories[name]):
            violations.append(f"immutable category changed: {name}")
    violations.extend(
        _compare_category_artifacts(
            "scorer",
            old_categories["scorer"],
            new_categories["scorer"],
            changed_paths=REPLACEMENT_CHANGED_SCORER_PATHS,
            added_paths=frozenset(),
            added_roles={},
        )
    )
    violations.extend(
        _compare_category_artifacts(
            "harness_sources",
            old_categories["harness_sources"],
            new_categories["harness_sources"],
            changed_paths=REPLACEMENT_CHANGED_HARNESS_PATHS,
            added_paths=REPLACEMENT_ADDED_HARNESS_PATHS,
            added_roles=dict.fromkeys(REPLACEMENT_ADDED_HARNESS_PATHS, "source"),
        )
    )
    violations.extend(
        _compare_category_artifacts(
            "configuration",
            old_categories["configuration"],
            new_categories["configuration"],
            changed_paths=REPLACEMENT_CHANGED_CONFIGURATION_PATHS,
            added_paths=REPLACEMENT_ADDED_CONFIGURATION_PATHS,
            added_roles=dict.fromkeys(
                REPLACEMENT_ADDED_CONFIGURATION_PATHS, "freeze_verifier_source"
            ),
        )
    )
    budget = new_categories["budget"]
    old_budget = old_categories["budget"]
    expected_values = dict(old_budget["values"])
    for key, (old, new) in RECOVERY_CAPS.items():
        if expected_values.get(key) != old:
            violations.append(f"baseline budget has unexpected {key}")
        expected_values[key] = new
    seed = budget["values"].get("recovery_accounting_seed")
    expected_values["recovery_accounting_seed"] = seed
    if not exactly_equal(budget["values"], expected_values):
        violations.append("budget values changed outside recovery accounting")
    old_budget_paths = set(_artifact_map(old_budget))
    expected_budget_roles = {path: role for role, path in FIXED_ROLE_PATHS["budget"]}
    added_budget_paths = frozenset(set(expected_budget_roles) - old_budget_paths)
    violations.extend(
        _compare_category_artifacts(
            "budget",
            old_budget,
            budget,
            changed_paths=frozenset(),
            added_paths=added_budget_paths,
            added_roles={path: expected_budget_roles[path] for path in added_budget_paths},
            compare_values=False,
        )
    )
    observed_budget_roles = {
        path: item["role"] for path, item in _artifact_map(budget).items()
    }
    if observed_budget_roles != expected_budget_roles:
        violations.append("budget recovery artifact membership changed")
    executable = new_categories["executable"]
    old_executable = old_categories["executable"]
    if not exactly_equal(executable["values"], old_executable["values"]) \
            or set(_artifact_map(executable)) != {EXECUTABLE_PATH} \
            or set(_artifact_map(old_executable)) != {EXECUTABLE_PATH}:
        violations.append("executable category membership changed")
    for category, path, role, byte_count, digest in REPLACEMENT_EXACT_CANDIDATE_ARTIFACTS:
        expected = {
            "bytes": byte_count,
            "path": path,
            "role": role,
            "sha256": digest,
        }
        if _artifact_map(new_categories[category]).get(path) != expected:
            violations.append(
                f"{category} candidate artifact differs from frozen version 0.6 bytes: {path}"
            )
    changed_categories = [
        {
            "category": name,
            "new_sha256": new_categories[name]["sha256"],
            "old_sha256": old_categories[name]["sha256"],
        }
        for name in sorted(CATEGORY_NAMES)
        if not exactly_equal(old_categories[name], new_categories[name])
    ]
    changed_artifacts: list[dict[str, Any]] = []
    for name in CATEGORY_NAMES:
        old_items = _artifact_map(old_categories[name])
        new_items = _artifact_map(new_categories[name])
        for path in sorted(set(old_items) | set(new_items)):
            old_digest = old_items.get(path, {}).get("sha256")
            new_digest = new_items.get(path, {}).get("sha256")
            if old_digest != new_digest:
                changed_artifacts.append(
                    {
                        "category": name,
                        "new_sha256": new_digest,
                        "old_sha256": old_digest,
                        "path": path,
                    }
                )
    changed_artifacts.append(
        {
            "category": "protocol",
            "new_sha256": new_protocol.get("sha256") if isinstance(new_protocol, dict) else None,
            "old_sha256": old_protocol.get("sha256") if isinstance(old_protocol, dict) else None,
            "path": PROTOCOL_PATH,
        }
    )
    return {
        "baseline_manifest": {
            "path": INVALIDATED_MANIFEST_PATH,
            "sha256": baseline_sha256,
        },
        "candidate_manifest": {
            "path": f"{MANIFEST_DESCRIPTOR_PATH.rsplit('/', 1)[0]}/page-manifest.json",
            "sha256": candidate_sha256,
        },
        "changed_artifacts": changed_artifacts,
        "changed_categories": changed_categories,
        "experiment": EXPERIMENT,
        "kind": DELTA_KIND,
        "schema_version": 1,
        "verdict": "allowed" if not violations else "forbidden",
        "violations": sorted(violations),
    }


def build_replacement_delta(
    repo_root: Path,
    candidate: dict[str, Any],
    candidate_raw: bytes,
) -> dict[str, Any]:
    root = repo_root.resolve(strict=True)
    baseline, baseline_raw = _canonical_source(
        root,
        INVALIDATED_MANIFEST_PATH,
        INVALIDATED_MANIFEST_SHA256,
    )
    ledger, _ledger_raw = verify_recovery_ledger(root)
    if candidate["categories"]["budget"]["values"].get("recovery_accounting_seed") \
            != recovery_seed(ledger):
        fail("candidate manifest does not bind the recomputed recovery seed")
    budget_items = _artifact_map(candidate["categories"]["budget"])
    for role, path in FIXED_ROLE_PATHS["budget"]:
        if role.startswith("replacement_"):
            item = budget_items.get(path, {})
            manifest_record = {key: item.get(key) for key in ("bytes", "path", "sha256")}
            if item.get("role") != role \
                    or manifest_record != artifacts.artifact(root, path):
                fail("candidate manifest does not bind exact replacement evidence bytes")
    return compare_replacement_manifests(
        baseline,
        candidate,
        baseline_sha256=sha256_hex(baseline_raw),
        candidate_sha256=sha256_hex(candidate_raw),
    )


def verify_replacement_admission(
    repo_root: Path,
    candidate: dict[str, Any],
    candidate_raw: bytes,
    *,
    replacement_delta_sha256: str,
    recovery_ledger_sha256: str,
    invalidation_report_sha256: str,
) -> dict[str, Any]:
    if invalidation_report_sha256 != INVALIDATION_REPORT_SHA256:
        fail("approval does not bind the frozen invalidation report")
    ledger, ledger_raw = verify_recovery_ledger(
        repo_root,
        expected_sha256=recovery_ledger_sha256,
    )
    expected_delta = build_replacement_delta(repo_root, candidate, candidate_raw)
    delta, delta_raw = _canonical_file(repo_root, REPLACEMENT_DELTA_PATH)
    if not exactly_equal(delta, expected_delta):
        fail("replacement delta differs from the recomputed manifest comparison")
    if sha256_hex(delta_raw) != replacement_delta_sha256:
        fail("replacement delta does not match the approved SHA-256")
    if expected_delta["verdict"] != "allowed":
        fail("replacement D6 changes forbidden decision-bearing artifacts")
    return {
        "invalidation_report_sha256": INVALIDATION_REPORT_SHA256,
        "recovery_ledger_sha256": sha256_hex(ledger_raw),
        "recovery_seed": recovery_seed(ledger),
        "replacement_delta_sha256": sha256_hex(delta_raw),
    }
