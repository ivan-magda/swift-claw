"""Shared mechanics for worker-bridge scenarios; test narratives stay in each test."""

from __future__ import annotations

import stat
from pathlib import Path

from benchmark_core.canonical import canonical_sha256, dumps


def write_worker(
    path: Path, result_path: Path, result: dict[str, object], exit_code: int = 0
) -> None:
    """Create a one-shot fake that records argv and publishes its canonical result."""

    argv_path = path.with_suffix(".argv.json")
    script = (
        "#!/usr/bin/env python3\n"
        "import json, pathlib, sys\n"
        f"pathlib.Path({str(argv_path)!r}).write_text(json.dumps(sys.argv[1:]))\n"
        f"pathlib.Path({str(result_path)!r}).write_text({dumps(result)!r})\n"
        "print('diagnostic-' + 'x' * 4096)\n"
        f"raise SystemExit({exit_code})\n"
    )
    path.write_text(script, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def learning_core(root: Path, kind: str = "evaluator") -> dict[str, object]:
    """Return a closed Swift learning-call core with stable manifest and route bindings."""

    digest = "a" * 64
    return {
        "schema_version": 1,
        "execution_profile": "scheduled-learning-v1",
        "job_id": "job-1",
        "operation_id": f"{kind}-operation-1",
        "attempt_generation": 1,
        "provider_call_id": "123e4567-e89b-12d3-a456-426614174000",
        "kind": kind,
        "state_root": str(root / "evaluation" / "state"),
        "prompt": {"path": str(root / "prompt.md"), "sha256": digest},
        "carrier": {"path": str(root / "evaluation" / "carrier.json"), "sha256": "b" * 64},
        "result_path": str(root / "evaluation" / "state" / "result.json"),
        "manifest": {
            "repository_root": str(root),
            "evaluation_root": str(root / "evaluation"),
            "manifest_path": str(root / "manifest.json"),
            "manifest_sha256": "c" * 64,
            "owner_approval": {"path": str(root / "approval.json"), "sha256": "d" * 64},
        },
    }


def learning_result(core: dict[str, object], outcome: str = "response") -> dict[str, object]:
    """Return a valid evaluator/reflector result bound to ``core``."""

    kind = str(core["kind"])
    maximum = 512 if kind == "evaluator" else 768
    result: dict[str, object] = {
        "schema_version": 1,
        "job_id": core["job_id"],
        "operation_id": core["operation_id"],
        "attempt_generation": core["attempt_generation"],
        "provider_call_id": core["provider_call_id"],
        "kind": kind,
        "outcome": outcome,
        "failure_code": None,
        "output": "{}",
        "output_sha256": canonical_sha256("{}"),
        "finish_reason": "stop",
        "provider_reference": "chatgpt",
        "wire_model": "gpt-5",
        "reported_model": "gpt-5",
        "retry_budget": 3,
        "max_output_tokens": maximum,
        "max_output_utf8_bytes": 4096,
        "max_output_graphemes": 4096,
        "usage": {
            "provider_call_id": core["provider_call_id"],
            "responses_sends": 1,
            "proven_not_started_responses_sends": 0,
            "prompt_tokens": 10,
            "completion_tokens": maximum,
            "reported_total_tokens": 10 + maximum,
            "accounted_tokens": 10 + maximum,
            "is_estimated": False,
        },
        "provenance": {
            "request_sha256": canonical_sha256(core),
            "manifest_sha256": core["manifest"]["manifest_sha256"],  # type: ignore[index]
            "freeze_commit": "e" * 40,
            "executable_sha256": "f" * 64,
            "prompt_sha256": core["prompt"]["sha256"],  # type: ignore[index]
            "carrier_sha256": core["carrier"]["sha256"],  # type: ignore[index]
        },
    }
    return result


def task_core(root: Path) -> dict[str, object]:
    """Return the bridge-visible bindings for one completed task worker invocation."""

    return {
        "job_id": "job-1",
        "operation_id": "task-operation-1",
        "attempt_generation": 1,
        "provider_call_id": "123e4567-e89b-12d3-a456-426614174000",
        "carrier_digest": "a" * 64,
        "lesson_set_digest": "b" * 64,
        "initial_taint_receipt": "c" * 64,
        "configuration_path": str(root / "configuration.json"),
        "configuration_sha256": "d" * 64,
        "manifest_digest": "e" * 64,
        "freeze_commit": "f" * 40,
        "route": {"provider_reference": "chatgpt", "wire_model": "gpt-5", "retry_budget": 3},
    }


def task_result(core: dict[str, object]) -> dict[str, object]:
    """Return a task result with the bridge-visible result bindings."""

    return {
        "job_id": core["job_id"],
        "operation_id": core["operation_id"],
        "attempt_generation": core["attempt_generation"],
        "provider_call_id": core["provider_call_id"],
        "learning_carrier_sha256": core["carrier_digest"],
        "learning_lesson_set_sha256": core["lesson_set_digest"],
        "learning_initial_tainted": True,
        "initial_taint_receipt": core["initial_taint_receipt"],
        "process_uuid": "123e4567-e89b-12d3-a456-426614174001",
        "process_id": 12,
        "provider_reference": core["route"]["provider_reference"],  # type: ignore[index]
        "wire_model": core["route"]["wire_model"],  # type: ignore[index]
        "raw_output": "result",
        "usage": [{"provider_call_id": core["provider_call_id"], "total_tokens": 12}],
    }
