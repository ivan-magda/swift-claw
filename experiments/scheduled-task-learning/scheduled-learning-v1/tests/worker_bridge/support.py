"""Canonical Swift wire fixtures for worker-bridge scenarios."""

from __future__ import annotations

import hashlib
import json
import stat
from pathlib import Path
from typing import cast

from benchmark_core.canonical import canonical_sha256, dumps

PROVIDER_CALL_ID = "123e4567-e89b-12d3-a456-426614174000"
PROVIDER_REFERENCE = "openai-chatgpt/gpt-5.6-sol"
WIRE_MODEL = "gpt-5.6-sol"


def write_worker(
    path: Path,
    result_path: Path,
    result: dict[str, object],
    exit_code: int = 0,
    *,
    publish_result: bool = True,
) -> None:
    """Create a fake that records argv and optionally publishes one result."""

    argv_path = path.with_suffix(".argv.jsonl")
    script = (
        "#!/usr/bin/env python3\n"
        "import hashlib, json, pathlib, sys\n"
        f"argv_path = pathlib.Path({str(argv_path)!r})\n"
        "with argv_path.open('a', encoding='utf-8') as stream:\n"
        "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n"
        f"result = json.loads({dumps(result)!r})\n"
        "provenance = result.get('provenance')\n"
        "if isinstance(provenance, dict) and provenance.get('request_sha256') == 'AUTO':\n"
        "    request_bytes = pathlib.Path(sys.argv[-1]).read_bytes()\n"
        "    provenance['request_sha256'] = hashlib.sha256(request_bytes).hexdigest()\n"
        f"result_path = pathlib.Path({str(result_path)!r})\n"
        "result_text = json.dumps(result, sort_keys=True, separators=(',', ':')) + '\\n'\n"
        + ("result_path.write_text(result_text)\n" if publish_result else "")
        + "print('diagnostic-' + 'x' * 4096)\n"
        f"raise SystemExit({exit_code})\n"
    )
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def write_malformed_result_worker(path: Path, result_path: Path) -> None:
    """Create a zero-exit fake that publishes malformed result bytes."""

    script = (
        "#!/usr/bin/env python3\n"
        "import pathlib\n"
        f"pathlib.Path({str(result_path)!r}).write_text('{{', encoding='utf-8')\n"
    )
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def argv_records(executable: Path) -> list[list[str]]:
    return [
        json.loads(line) for line in executable.with_suffix(".argv.jsonl").read_text().splitlines()
    ]


def learning_core(root: Path, kind: str = "evaluator") -> dict[str, object]:
    """Return the exact authorization-free Swift learning-call core."""

    _, manifest_binding = _manifest(root)
    operation_id = "c" * 64 if kind == "reflector" else f"{kind}-operation-1"
    return {
        "schema_version": 1,
        "execution_profile": "scheduled-learning-v1",
        "job_id": "job-1",
        "operation_id": operation_id,
        "attempt_generation": 1,
        "provider_call_id": PROVIDER_CALL_ID,
        "kind": kind,
        "state_root": str(root / "evaluation" / "state"),
        "prompt": {"path": str(root / "prompt.md"), "sha256": "a" * 64},
        "carrier": {"path": str(root / "evaluation" / "carrier.json"), "sha256": "b" * 64},
        "result_path": str(root / "evaluation" / "state" / "result.json"),
        "manifest": manifest_binding,
    }


def authorized_request(core: dict[str, object]) -> dict[str, object]:
    return {
        **core,
        "authorization": {
            "event_path": str(Path(str(core["state_root"])).parent / "events" / "start.json"),
            "event_sha256": "d" * 64,
        },
    }


def write_authorized_request(path: Path, core: dict[str, object]) -> dict[str, object]:
    request = authorized_request(core)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(dumps(request), encoding="utf-8")
    return request


def learning_result(
    core: dict[str, object], outcome: str = "response", *, request_sha256: str | None = None
) -> dict[str, object]:
    """Return the exact Swift evaluator/reflector result schema."""

    kind = str(core["kind"])
    maximum = 512 if kind == "evaluator" else 768
    output = "{}" if outcome == "response" else None
    usage: dict[str, object] | None = {
        "provider_call_id": core["provider_call_id"],
        "responses_sends": 1,
        "proven_not_started_responses_sends": 0,
        "prompt_tokens": 10,
        "completion_tokens": maximum,
        "reported_total_tokens": 10 + maximum,
        "accounted_tokens": 10 + maximum,
        "is_estimated": False,
    }
    failure_code: str | None = None
    finish_reason: str | None = "stop"
    reported_model: str | None = WIRE_MODEL
    if outcome == "failed_no_call":
        failure_code = "provider_failure"
        finish_reason = None
        reported_model = None
        usage = None
    elif outcome == "failed":
        failure_code = "provider_failure"
        finish_reason = None
        reported_model = None
    manifest = _dict(core["manifest"])
    manifest_document = _load_object(Path(str(manifest["manifest_path"])))
    execution = _dict(manifest_document["swift_execution"])
    approval_binding = _dict(manifest["owner_approval"])
    approval = _load_object(Path(str(approval_binding["path"])))
    prompt = _dict(core["prompt"])
    carrier = _dict(core["carrier"])
    return {
        "schema_version": 1,
        "job_id": core["job_id"],
        "operation_id": core["operation_id"],
        "attempt_generation": core["attempt_generation"],
        "provider_call_id": core["provider_call_id"],
        "kind": kind,
        "outcome": outcome,
        "failure_code": failure_code,
        "output": output,
        "output_sha256": None if output is None else hashlib.sha256(output.encode()).hexdigest(),
        "finish_reason": finish_reason,
        "provider_reference": PROVIDER_REFERENCE,
        "wire_model": WIRE_MODEL,
        "reported_model": reported_model,
        "retry_budget": 3,
        "max_output_tokens": maximum,
        "max_output_utf8_bytes": 4096,
        "max_output_graphemes": 4096,
        "usage": usage,
        "provenance": {
            "request_sha256": request_sha256 or "AUTO",
            "manifest_sha256": manifest["manifest_sha256"],
            "freeze_commit": approval["expected_freeze_commit"],
            "executable_sha256": execution["executable_sha256"],
            "prompt_sha256": prompt["sha256"],
            "carrier_sha256": carrier["sha256"],
        },
    }


def task_core(root: Path) -> dict[str, object]:
    """Return the exact authorization-free Swift task invocation core."""

    _, manifest_binding = _manifest(root)
    approval = _task_approval(str(manifest_binding["manifest_sha256"]))
    carrier = {
        "active_lessons": {"schema_version": 1, "lessons": ["Keep edits localized."]},
        "schema_version": 1,
        "task": {
            "before_html": "<main>before</main>",
            "after_html": "<main>after</main>",
            "region_ids": ["main"],
        },
        "task_id": "page-123456789abc",
    }
    carrier_path = root / "carrier.json"
    carrier_path.write_text(dumps(carrier), encoding="utf-8")
    carrier_sha256 = canonical_sha256(carrier)
    lesson_digest = canonical_sha256(carrier["active_lessons"])
    provenance = _provenance()
    configuration = {
        "execution_profile": "scheduled-learning-v1",
        "carrier_path": str(carrier_path),
        "carrier_sha256": carrier_sha256,
        "schema_version": 1,
        "attempt_id": "attempt-1",
        "fixture_id": "fixture-1",
        "task_id": carrier["task_id"],
        "split": "regression",
        "stage": "regression",
        "frozen_order_index": 0,
        "frozen_order_key": "1" * 64,
        "replicate": 1,
        "condition": "lesson_conditioned",
        "evaluation_root": str(root / "evaluation"),
        "source_artifact_path": str(root / "source.json"),
        "source_sha256": "2" * 64,
        "input_sha256": carrier_sha256,
        "lesson_source": "artifact",
        "lesson_artifact_path": str(root / "lessons.json"),
        "promotion_receipt_path": None,
        "promotion_receipt_sha256": None,
        "publish_lesson_as_active": False,
        "task_prompt_path": str(root / "task.md"),
        "task_prompt_sha256": "3" * 64,
        "result_path": str(root / "result.json"),
        "fixed_timestamp": "2026-08-29T00:00:00Z",
        "protocol_sha256": "4" * 64,
        "lesson_set_digest": lesson_digest,
        "expected_policy_version": "a" * 16,
        "provider_reference": PROVIDER_REFERENCE,
        "wire_model": WIRE_MODEL,
        "transport_mode": "streaming_sse",
        "fallback_reference": None,
        "approval": approval,
        "provenance": provenance,
        "replacement_of_attempt_id": None,
        "replacement_ordinal": 0,
    }
    configuration_path = root / "configuration.json"
    configuration_path.write_text(dumps(configuration), encoding="utf-8")
    return {
        "schema_version": 1,
        "execution_profile": "scheduled-learning-v1",
        "job_id": "job-1",
        "operation_id": "task-operation-1",
        "attempt_generation": 1,
        "provider_call_id": PROVIDER_CALL_ID,
        "configuration_path": str(configuration_path),
        "configuration_sha256": canonical_sha256(configuration),
        "manifest": manifest_binding,
        "budget": {
            "stage_accounted_tokens": 0,
            "global_accounted_tokens": 0,
            "stage_responses_sends": 0,
            "global_responses_sends": 0,
            "stage_accounted_token_threshold": 1000,
            "global_accounted_token_threshold": 4_350_000,
            "stage_responses_send_cap": 3,
            "global_responses_send_cap": 454,
        },
    }


def task_result(core: dict[str, object]) -> dict[str, object]:
    """Return the exact bridge-relevant Swift task result schema."""

    configuration = _load_object(Path(str(core["configuration_path"])))
    carrier = _load_object(Path(str(configuration["carrier_path"])))
    carrier_sha256 = str(configuration["carrier_sha256"])
    lesson_digest = str(configuration["lesson_set_digest"])
    receipt = {
        "source_sha256": configuration["source_sha256"],
        "task_id": configuration["task_id"],
        "lesson_source": configuration["lesson_source"],
        "lesson_set_sha256": lesson_digest,
        "lesson_set_id": "",
        "lesson_ids": [],
        "input_sha256": carrier_sha256,
        "promotion_receipt_sha256": configuration["promotion_receipt_sha256"],
    }
    receipt_sha256 = canonical_sha256(receipt)
    workspace = {
        "workspace_was_empty_at_start": True,
        "input_was_regenerated": False,
        "input_path": str(Path(str(configuration["evaluation_root"])) / "workspace" / "input.json"),
        "input_sha256": carrier_sha256,
        "input_byte_count": len(dumps(carrier).encode()),
        "source_artifact_path": configuration["source_artifact_path"],
        "source_sha256": configuration["source_sha256"],
        "task_id": configuration["task_id"],
        "lesson_source": configuration["lesson_source"],
        "lesson_set_path": configuration["lesson_artifact_path"],
        "lesson_set_digest": lesson_digest,
        "lesson_set_id": "",
        "lesson_ids": [],
        "carrier_receipt": receipt,
        "carrier_receipt_sha256": receipt_sha256,
    }
    usage = [
        {
            "provider_call_id": core["provider_call_id"],
            "run_id": 7,
            "session_id": 8,
            "model": WIRE_MODEL,
            "prompt_tokens": 10,
            "completion_tokens": 2,
            "total_tokens": 12,
            "is_estimated": False,
            "cost_usd": 0.0,
            "cost_source": "reported",
            "timestamp": "2026-08-29T00:00:00Z",
        }
    ]
    responses = [
        {
            "sequence": 1,
            "requested_model": WIRE_MODEL,
            "body_byte_count": 100,
            "body_sha256": "5" * 64,
            "normalized_structure_sha256": "6" * 64,
            "untrusted_fence_present": True,
            "untrusted_payload_sha256": lesson_digest,
        }
    ]
    return {
        "schema_version": 1,
        "attempt_id": configuration["attempt_id"],
        "fixture_id": configuration["fixture_id"],
        "task_id": configuration["task_id"],
        "split": configuration["split"],
        "stage": configuration["stage"],
        "frozen_order_index": configuration["frozen_order_index"],
        "frozen_order_key": configuration["frozen_order_key"],
        "replicate": configuration["replicate"],
        "condition": configuration["condition"],
        "process_uuid": "123e4567-e89b-12d3-a456-426614174001",
        "process_id": 12,
        "lock_acquisition_id": "123e4567-e89b-12d3-a456-426614174002",
        "run_id": 7,
        "session_id": 8,
        "conversation_id": (f"123e4567-e89b-12d3-a456-426614174001:{configuration['attempt_id']}"),
        "started_at": "2026-08-29T00:00:00Z",
        "finished_at": "2026-08-29T00:00:01Z",
        "duration_milliseconds": 1000,
        "protocol_sha256": configuration["protocol_sha256"],
        "manifest_sha256": _dict(core["manifest"])["manifest_sha256"],
        "approval": configuration["approval"],
        "provenance": configuration["provenance"],
        "input_sha256": configuration["input_sha256"],
        "task_prompt_sha256": configuration["task_prompt_sha256"],
        "lesson_set_digest": lesson_digest,
        "lesson_set_id": "",
        "lesson_ids": [],
        "carrier_receipt": receipt,
        "carrier_receipt_sha256": receipt_sha256,
        "policy_version": configuration["expected_policy_version"],
        "provider_reference": configuration["provider_reference"],
        "wire_model": configuration["wire_model"],
        "transport_mode": configuration["transport_mode"],
        "outcome": "completed",
        "raw_output": "result",
        "model_observations": [],
        "http": {
            "responsesSends": responses,
            "provenNotStartedResponsesSends": 0,
            "credentialHTTPCalls": 0,
            "integrityFailures": [],
        },
        "output_counts": {"utf8Bytes": 6, "graphemes": 6, "limitExceeded": False},
        "tools": [],
        "audit": [],
        "usage": usage,
        "accounted_tokens": 12,
        "replacement_disposition": "ineligible",
        "replacement_reason": "scorable_output_exists",
        "replacement_ordinal": configuration["replacement_ordinal"],
        "workspace": workspace,
        "learning_carrier_sha256": carrier_sha256,
        "learning_lesson_set_sha256": lesson_digest,
        "learning_initial_tainted": bool(_dict(carrier["active_lessons"])["lessons"]),
        "learning_carrier_verified": True,
    }


def _manifest(root: Path) -> tuple[dict[str, object], dict[str, object]]:
    budgets = {
        "task_attempts": 1,
        "evaluator_calls": 1,
        "reflector_calls": 1,
        "responses_sends": 3,
        "accounted_tokens": 1000,
    }
    learning_route = {
        "provider_reference": PROVIDER_REFERENCE,
        "wire_model": WIRE_MODEL,
        "retry_budget": 3,
        "max_output_tokens": 512,
        "max_output_utf8_bytes": 4096,
        "max_output_graphemes": 4096,
    }
    task_route = {
        "provider_reference": PROVIDER_REFERENCE,
        "wire_model": WIRE_MODEL,
        "retry_budget": 1,
        "max_output_tokens": 4096,
        "max_output_utf8_bytes": 32_768,
        "max_output_graphemes": 16_384,
    }
    manifest = {
        "budgets": budgets,
        "swift_execution": {
            "task_route": task_route,
            "evaluator_route": learning_route,
            "reflector_route": {**learning_route, "max_output_tokens": 768},
            "executable_sha256": "f" * 64,
            "missing_usage_token_proxy": 132_768,
        },
    }
    manifest_path = root / "manifest.json"
    manifest_path.write_text(dumps(manifest), encoding="utf-8")
    approval = {
        "schema_version": 1,
        "manifest_sha256": canonical_sha256(manifest),
        "expected_freeze_commit": "e" * 40,
        "budgets": budgets,
        "owner_identity": "owner",
        "approved_at": "2026-08-29T00:00:00Z",
    }
    approval_path = root / "approval.json"
    approval_path.write_text(dumps(approval), encoding="utf-8")
    binding: dict[str, object] = {
        "repository_root": str(root),
        "evaluation_root": str(root / "evaluation"),
        "manifest_path": str(manifest_path),
        "manifest_sha256": canonical_sha256(manifest),
        "owner_approval": {"path": str(approval_path), "sha256": canonical_sha256(approval)},
    }
    return approval, binding


def _provenance() -> dict[str, object]:
    return {
        "freeze_commit": "e" * 40,
        "executable_sha256": "f" * 64,
        "runtime_sources_sha256": "7" * 64,
        "harness_sources_sha256": "8" * 64,
        "dependencies_sha256": "9" * 64,
        "configuration_sha256": "a" * 64,
        "model_sha256": "b" * 64,
        "retry_sha256": "c" * 64,
        "output_sha256": "d" * 64,
        "prompts_sha256": "e" * 64,
        "schemas_sha256": "f" * 64,
        "scorer_sha256": "0" * 64,
        "splits_sha256": "1" * 64,
        "run_order_sha256": "2" * 64,
        "system_prompt_sha256": "3" * 64,
        "proactive_system_prompt_sha256": "4" * 64,
    }


def _task_approval(manifest_sha256: str) -> dict[str, object]:
    return {
        "comment_id": 118001,
        "comment_node_id": "comment-node",
        "author_login": "owner",
        "author_id": 42,
        "author_node_id": "owner-node",
        "created_at": "2026-08-29T00:00:00Z",
        "updated_at": "2026-08-29T00:00:00Z",
        "manifest_sha256": manifest_sha256,
        "approved_manifest_sha256": manifest_sha256,
        "approval_comment_url": (
            "https://github.com/ivan-magda/swift-claw/issues/118#issuecomment-118001"
        ),
        "approval_body_sha256": "5" * 64,
    }


def _dict(value: object) -> dict[str, object]:
    return cast(dict[str, object], value)


def _load_object(path: Path) -> dict[str, object]:
    return cast(dict[str, object], json.loads(path.read_text(encoding="utf-8")))
