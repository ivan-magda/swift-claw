"""Exact scheduled-learning task configuration for the existing Swift worker."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256
from page_change_m3.fixtures import fresh_source_path

_SYSTEM_PROMPT_SOURCE = Path("Sources/ClawAgent/Context/SystemPrompt.swift")
_SWIFT_MULTILINE = re.compile(
    r"(?:public|private) static let (\w+) = \"\"\"\n(.*?)\n    \"\"\"", re.DOTALL
)
_SWIFT_INTERPOLATION = re.compile(r"\\\((\w+)\)")
_SWIFT_SYSTEM_NAMES = {"minimal", "proactive", "toolUsePolicy", "skillsPolicy"}
_TASK_PROVENANCE_FIELDS = (
    "runtime_sources_sha256",
    "harness_sources_sha256",
    "dependencies_sha256",
    "configuration_sha256",
    "model_sha256",
    "retry_sha256",
    "output_sha256",
    "prompts_sha256",
    "schemas_sha256",
    "scorer_sha256",
    "splits_sha256",
    "run_order_sha256",
)
_FILE_READ_PARAMETERS = {
    "type": "object",
    "properties": {
        "path": {
            "type": "string",
            "description": "Workspace-relative file path, e.g. notes/plan.md",
        }
    },
    "required": ["path"],
}
_OPENAI_CHATGPT_EGRESS = (
    "llm_egress:managed:openai-chatgpt:https://chatgpt.com/backend-api/codex/responses"
)


def build_task_configuration(
    root: Path,
    manifest: dict[str, object],
    approval: dict[str, object],
    row: dict[str, object],
    source: dict[str, Any],
    carrier_path: Path,
    lesson_path: Path | None,
    promotion_receipt: Path | None,
    result_path: Path,
) -> dict[str, object]:
    """Construct the closed Swift configuration from frozen facts and materialized artifacts."""

    condition = str(row["condition"])
    active = condition == "active"
    restart = condition == "post_restart_active"
    clean = condition in {"clean", "clean_control"}
    route = _object(
        _object(manifest.get("swift_execution"), "swift execution").get("task_route"),
        "task route",
    )
    prompt_path = root / "prompts" / "task.md"
    approval_digest = canonical_sha256(approval)
    promotion_digest = _sha256(promotion_receipt) if promotion_receipt is not None else None
    manifest_digest = canonical_sha256(manifest)
    freeze_commit = str(approval["expected_freeze_commit"])
    evaluation_root = root / "results"
    runtime_identity = swift_runtime_identity(root.parents[2], evaluation_root)
    provenance = _provenance(manifest, route, runtime_identity, freeze_commit)
    order_index = row["order_index"]
    if not isinstance(order_index, int) or isinstance(order_index, bool):
        raise ValueError("run-order index must be an integer")
    attempt_id = f"m3-{order_index:02d}-{row['fixture_id']}"
    return {
        "execution_profile": "scheduled-learning-v1",
        "carrier_path": str(carrier_path),
        "carrier_sha256": _sha256(carrier_path),
        "schema_version": 1,
        "attempt_id": attempt_id,
        "fixture_id": row["fixture_id"],
        "task_id": source["task_id"],
        "split": _split(row),
        "stage": (
            "sealed-post-restart" if restart else "sealed-pre-restart" if active else row["stage"]
        ),
        "frozen_order_index": row["order_index"],
        "frozen_order_key": canonical_sha256(row),
        "replicate": 1,
        "condition": (
            "clean"
            if clean
            else "post_restart_lesson_conditioned"
            if restart
            else "lesson_conditioned"
        ),
        "evaluation_root": str(evaluation_root),
        "source_artifact_path": str(fresh_source_path(root, _split(row), str(row["fixture_id"]))),
        "source_sha256": canonical_sha256(source),
        "input_sha256": _sha256(carrier_path),
        "lesson_source": "clean" if clean else "durable_active" if restart else "artifact",
        "lesson_artifact_path": str(lesson_path) if lesson_path is not None else None,
        "promotion_receipt_path": str(promotion_receipt) if promotion_receipt is not None else None,
        "promotion_receipt_sha256": promotion_digest,
        "publish_lesson_as_active": False,
        "task_prompt_path": str(prompt_path),
        "task_prompt_sha256": _sha256(prompt_path),
        "result_path": str(result_path),
        "fixed_timestamp": str(approval["approved_at"]),
        "protocol_sha256": canonical_sha256(manifest["protocol"]),
        "lesson_set_digest": canonical_sha256(
            {"schema_version": 1, "lessons": _carrier_lessons(carrier_path)}
        ),
        "expected_policy_version": runtime_identity["policy_version"],
        "provider_reference": route["provider_reference"],
        "wire_model": route["wire_model"],
        "transport_mode": "streaming_sse",
        "fallback_reference": None,
        "approval": {
            "comment_id": 118001,
            "comment_node_id": "scheduled-learning-v1-owner-comment",
            "author_login": str(approval["owner_identity"]),
            "author_id": 1,
            "author_node_id": "scheduled-learning-v1-owner",
            "created_at": approval["approved_at"],
            "updated_at": approval["approved_at"],
            "manifest_sha256": manifest_digest,
            "approved_manifest_sha256": manifest_digest,
            "approval_comment_url": (
                "https://github.com/ivan-magda/swift-claw/issues/118#issuecomment-118001"
            ),
            "approval_body_sha256": approval_digest,
        },
        "provenance": provenance,
        "replacement_of_attempt_id": None,
        "replacement_ordinal": 0,
    }


def swift_runtime_identity(repository_root: Path, evaluation_root: Path) -> dict[str, str]:
    """Reproduce Swift's system-prompt digests and root-sensitive policy version."""

    prompts = _system_prompts(repository_root / _SYSTEM_PROMPT_SOURCE)
    minimal = prompts["minimal"]
    proactive = prompts["proactive"]
    parameter_json = json.dumps(
        _FILE_READ_PARAMETERS,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).replace("/", r"\/")
    workspace_root = str(evaluation_root / "workspace")
    static_subhash = _length_prefixed_sha256(
        [
            "file_read",
            parameter_json,
            "trusted",
            "safe",
            "file_read",
            "none",
            "",
            _OPENAI_CHATGPT_EGRESS,
            "search:absent",
            workspace_root,
            "webfetch_exempt:",
            "exec.enabled:false",
            "exec.image:absent",
            "exec.registries:cgr.dev",
            "exec.memory_mib:1024",
            "exec.cpus:4",
            "exec.timeout_s:30",
            "exec.allow_egress:false",
        ]
    )
    policy_version = _length_prefixed_sha256([static_subhash, minimal, proactive, "", "", ""])[:16]
    return {
        "policy_version": policy_version,
        "system_prompt_sha256": hashlib.sha256(minimal.encode()).hexdigest(),
        "proactive_system_prompt_sha256": hashlib.sha256(proactive.encode()).hexdigest(),
    }


def manifest_binding(
    root: Path, manifest: dict[str, object], approval_path: Path
) -> dict[str, object]:
    """Bind one Swift invocation to the exact frozen artifacts and result root."""

    return {
        "repository_root": str(root.parents[2]),
        "evaluation_root": str(root / "results"),
        "manifest_path": str(root / "freeze" / "manifest.json"),
        "manifest_sha256": canonical_sha256(manifest),
        "owner_approval": {"path": str(approval_path), "sha256": _sha256(approval_path)},
    }


def executable_path(root: Path, manifest: dict[str, object]) -> Path:
    """Select the manifest's unique frozen release executable."""

    inputs = _object(manifest.get("inputs"), "manifest inputs")
    groups = _object(inputs.get("groups"), "manifest input groups")
    members = groups.get("executable")
    if not isinstance(members, list) or len(members) != 1 or not isinstance(members[0], str):
        raise ValueError("manifest has no unique executable input")
    return root.parents[2] / members[0]


def _provenance(
    manifest: dict[str, object],
    route: dict[str, Any],
    runtime_identity: dict[str, str],
    freeze_commit: str,
) -> dict[str, object]:
    group_names = {
        "runtime_sources_sha256": "swift_evaluation",
        "harness_sources_sha256": "harness_sources",
        "dependencies_sha256": "swift_package",
        "prompts_sha256": "prompt_schema",
        "schemas_sha256": "prompt_schema",
        "scorer_sha256": "reused_scorer",
    }
    values: dict[str, object] = {
        key: _group_digest(manifest, name) for key, name in group_names.items()
    }
    values.update(
        {
            "configuration_sha256": canonical_sha256(manifest["swift_execution"]),
            "model_sha256": canonical_sha256(
                {
                    "provider_reference": route["provider_reference"],
                    "wire_model": route["wire_model"],
                }
            ),
            "retry_sha256": canonical_sha256(route["retry_budget"]),
            "output_sha256": canonical_sha256(
                {
                    key: route[key]
                    for key in (
                        "max_output_tokens",
                        "max_output_utf8_bytes",
                        "max_output_graphemes",
                    )
                }
            ),
            "splits_sha256": canonical_sha256(manifest["fixture_split"]),
            "run_order_sha256": canonical_sha256(manifest["run_order"]),
        }
    )
    if set(values) != set(_TASK_PROVENANCE_FIELDS):
        raise ValueError("task provenance projection is incomplete")
    return {
        "freeze_commit": freeze_commit,
        "executable_sha256": _object(manifest.get("swift_execution"), "swift execution")[
            "executable_sha256"
        ],
        **values,
        "system_prompt_sha256": runtime_identity["system_prompt_sha256"],
        "proactive_system_prompt_sha256": runtime_identity["proactive_system_prompt_sha256"],
    }


def _group_digest(manifest: dict[str, object], name: str) -> str:
    inputs = _object(manifest.get("inputs"), "manifest inputs")
    groups = _object(inputs.get("groups"), "manifest input groups")
    members = groups.get(name)
    files = inputs.get("files")
    if not isinstance(members, list) or not isinstance(files, list):
        raise ValueError(f"manifest input group {name} is unavailable")
    selected = [
        record
        for member in members
        for record in files
        if isinstance(record, dict) and record.get("path") == member
    ]
    if len(selected) != len(members):
        raise ValueError(f"manifest input group {name} has an unbound member")
    return canonical_sha256(selected)


def _system_prompts(path: Path) -> dict[str, str]:
    matches = dict(_SWIFT_MULTILINE.findall(path.read_text(encoding="utf-8")))
    if set(matches) != _SWIFT_SYSTEM_NAMES:
        raise ValueError("Swift system-prompt source has an unexpected constant set")
    rendered: dict[str, str] = {}

    def render(name: str) -> str:
        if name in rendered:
            return rendered[name]
        value = "\n".join(
            line[4:] if line.startswith("    ") else line for line in matches[name].splitlines()
        )
        value = re.sub(r"\\\n[ \t]*", "", value)
        value = value.replace(r"\(WorkspaceSkills.fenceLabel)", "skills")
        value = _SWIFT_INTERPOLATION.sub(lambda match: render(match.group(1)), value)
        if r"\(" in value:
            raise ValueError("Swift system-prompt interpolation is unsupported")
        rendered[name] = value
        return value

    return {name: render(name) for name in _SWIFT_SYSTEM_NAMES}


def _length_prefixed_sha256(parts: list[str]) -> str:
    digest = hashlib.sha256()
    for part in parts:
        encoded = part.encode()
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
    return digest.hexdigest()


def _carrier_lessons(path: Path) -> list[str]:
    from benchmark_core.canonical import load_object  # noqa: PLC0415

    carrier = load_object(path)
    active = _object(carrier.get("active_lessons"), "active lessons")
    lessons = active.get("lessons")
    if not isinstance(lessons, list) or any(not isinstance(item, str) for item in lessons):
        raise ValueError("task carrier lesson set is invalid")
    return cast(list[str], lessons)


def _split(row: dict[str, object]) -> str:
    stage = row.get("stage")
    if stage in {"active", "restart"}:
        return "sealed"
    if stage not in {"development", "regression"}:
        raise ValueError("run-order stage is invalid")
    return str(stage)


def _object(value: object, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return cast(dict[str, Any], value)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()
