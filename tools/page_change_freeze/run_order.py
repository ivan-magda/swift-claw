"""Deterministic page-change run-order contract derived from the manifest digest."""

from __future__ import annotations

import copy
from pathlib import Path
import re
from typing import Any, Optional

from .contract import (
    CANARY_BASE_TASK_PATH,
    CANARY_CLEAN_LESSONS_PATH,
    CANARY_CONFIGURATION_PATH,
    CANARY_FIXTURE_ID,
    CANARY_NONEMPTY_LESSONS_PATH,
    CANARY_TASK_ID,
    HEX_SHA256,
    SPLITS_PATH,
    SYNTHESIS_PROMPT_PATH,
    canonical_json_bytes,
    exactly_equal,
    fail,
    load_json,
    require_keys,
    require_object,
    sha256_hex,
)
from .artifacts import rooted_regular_file


RUN_ORDER_DOMAIN = b"swift-claw.scheduled-task-learning.page-change.run-order.v1"
FIXTURE_ID = re.compile(r"^pc-(development|regression|sealed)-[0-9]{2}$")
_FIXTURE_COUNTS = {"development": 6, "regression": 3, "sealed": 4}

RUN_ORDER_VALUES = {
    "algorithm": "sha256-length-prefixed-counterbalanced-stage-order",
    "algorithm_version": 2,
    "manifest_digest_source": "external_final_manifest_sha256",
    "replicate_indices": [1, 2, 3],
    "conditions_by_stage": {
        "development": ["clean"],
        "regression": ["clean", "lesson-conditioned"],
        "sealed-pre-restart": ["clean", "lesson-conditioned"],
        "sealed-post-restart": ["post-restart lesson-conditioned"],
    },
    "condition_block_policy": "same_fixture_replicate_permutation_for_every_condition",
    "counterbalance_policy": {
        "algorithm": "alternating_first_condition_by_manifest_derived_phase",
        "maximum_first_position_imbalance": 1,
        "applies_to": ["regression", "sealed-pre-restart"],
    },
    "canary_contract": {
        "fixture_id": CANARY_FIXTURE_ID,
        "attempts": [
            {"process": "A", "condition": "clean", "lesson_source": "clean", "publish_active": False},
            {"process": "A", "condition": "nonempty", "lesson_source": "artifact", "publish_active": True},
            {"process": "B", "condition": "clean", "lesson_source": "clean", "publish_active": False},
            {"process": "B", "condition": "nonempty", "lesson_source": "durable_active", "publish_active": False},
        ],
        "restart_after_attempt": 2,
    },
    "stage_sequence": [
        "canary", "development", "synthesis", "lesson-freeze-barrier", "regression",
        "regression-unseal-barrier", "sealed-pre-restart",
        "sealed-full-process-restart-barrier", "sealed-post-restart",
        "sealed-joint-unseal-barrier",
    ],
    "synthesis_position": "after_development_before_lesson_freeze_and_regression",
    "worker_topology": {
        "canary_processes": 2,
        "canary_attempts_per_process": 2,
        "task_attempt_process_policy": "fresh_os_process_per_attempt",
        "task_conversation_policy": "fresh_per_attempt",
        "task_workspace_policy": "reset_to_exactly_input_json_per_attempt",
        "restart_lesson_source": "durable_active",
    },
    "restart_policy": "new_os_process_reloads_durable_lesson_before_restart_attempts",
    "unseal_policy": "sealed_clean_lesson_and_restart_outputs_unseal_together",
    "realized_order_storage": "external_run_provenance",
}

_PLANNED_ATTEMPTS = {
    "canary": 4,
    "page_task": 72,
    "page_synthesis": 1,
}
_PLANNED_ATTEMPTS["page_task_or_synthesis"] = (
    _PLANNED_ATTEMPTS["page_task"] + _PLANNED_ATTEMPTS["page_synthesis"]
)


def blocks_from_splits(repo_root: Path) -> list[dict[str, Any]]:
    value, _ = load_json(rooted_regular_file(repo_root, SPLITS_PATH))
    root = require_object(value, location=SPLITS_PATH)
    splits = require_object(root.get("splits"), location=f"{SPLITS_PATH}.splits")
    if set(splits) != set(_FIXTURE_COUNTS):
        fail("protected splits contract has wrong split keys")
    identities: dict[str, str] = {}
    for split, count in _FIXTURE_COUNTS.items():
        entries = splits[split]
        if not isinstance(entries, list) or len(entries) != count:
            fail(f"protected splits contract has wrong {split} fixture count")
        for index, raw in enumerate(entries):
            entry = require_object(raw, location=f"{SPLITS_PATH}.{split}[{index}]")
            fixture_id = entry.get("fixture_id")
            if (not isinstance(fixture_id, str) or not FIXTURE_ID.fullmatch(fixture_id)
                    or not fixture_id.startswith(f"pc-{split}-") or fixture_id in identities):
                fail(f"protected splits contract has invalid fixture identity in {split}")
            identities[fixture_id] = split
    return [
        {"split": split, "fixture_id": fixture_id, "replicate_index": replicate}
        for split in _FIXTURE_COUNTS
        for fixture_id in sorted(key for key, value in identities.items() if value == split)
        for replicate in RUN_ORDER_VALUES["replicate_indices"]
    ]


def manifest_values(repo_root: Path) -> dict[str, Any]:
    values = copy.deepcopy(RUN_ORDER_VALUES)
    values["blocks"] = blocks_from_splits(repo_root)
    return values


def validate_manifest_values(value: Any) -> dict[str, Any]:
    root = require_object(value, location="manifest.categories.run_order.values")
    require_keys(root, set(RUN_ORDER_VALUES) | {"blocks"},
                 location="manifest.categories.run_order.values")
    if not exactly_equal({key: root[key] for key in RUN_ORDER_VALUES}, RUN_ORDER_VALUES):
        fail("manifest run-order derivation controls differ from the frozen protocol")
    blocks = root["blocks"]
    if not isinstance(blocks, list):
        fail("manifest run-order blocks must be an array")
    counts = {split: 0 for split in _FIXTURE_COUNTS}
    seen: set[tuple[str, int]] = set()
    prior: Optional[tuple[int, str, int]] = None
    split_order = {split: index for index, split in enumerate(_FIXTURE_COUNTS)}
    for index, raw in enumerate(blocks):
        block = require_object(raw, location=f"run-order blocks[{index}]")
        require_keys(block, {"split", "fixture_id", "replicate_index"},
                     location=f"run-order blocks[{index}]")
        split, fixture, replicate = block["split"], block["fixture_id"], block["replicate_index"]
        if not isinstance(split, str) or split not in split_order \
                or not isinstance(fixture, str) or not FIXTURE_ID.fullmatch(fixture):
            fail("manifest run-order block has invalid split or fixture_id")
        if (
            not fixture.startswith(f"pc-{split}-")
            or type(replicate) is not int
            or replicate not in RUN_ORDER_VALUES["replicate_indices"]
        ):
            fail("manifest run-order block identity is inconsistent")
        identity = (fixture, replicate)
        if identity in seen:
            fail(f"duplicate manifest run-order block: {identity}")
        seen.add(identity)
        counts[split] += 1
        sort_key = (split_order[split], fixture, replicate)
        if prior is not None and sort_key <= prior:
            fail("manifest run-order input blocks must be sorted")
        prior = sort_key
    expected_counts = {
        split: fixture_count * len(RUN_ORDER_VALUES["replicate_indices"])
        for split, fixture_count in _FIXTURE_COUNTS.items()
    }
    if counts != expected_counts:
        fail(f"manifest run-order blocks have wrong split counts: {counts}")
    return root


def _key(digest: bytes, *components: Any) -> str:
    material = RUN_ORDER_DOMAIN + b"\x00" + digest
    for component in components:
        if isinstance(component, int) and not isinstance(component, bool):
            raw = component.to_bytes(8, "big", signed=True)
        elif isinstance(component, str):
            raw = component.encode()
        else:
            fail("run-order key components must be strings or integers")
        material += len(raw).to_bytes(4, "big") + raw
    return sha256_hex(material)


def _ordered_blocks(values: dict[str, Any], digest: bytes, split: str) -> list[dict[str, Any]]:
    blocks = [
        {**block, "order_key": _key(digest, "scored-block", split,
                                     block["replicate_index"], block["fixture_id"])}
        for block in values["blocks"] if block["split"] == split
    ]
    return sorted(blocks, key=lambda item: (item["order_key"], item["fixture_id"], item["replicate_index"]))


def _attempt_stage(values: dict[str, Any], digest: bytes, *, name: str, split: str,
                   conditions: list[str], counterbalanced: bool) -> dict[str, Any]:
    blocks = _ordered_blocks(values, digest, split)
    phase = int(_key(digest, "counterbalance-phase", name), 16) & 1 if counterbalanced else None
    attempts = []
    for block_index, block in enumerate(blocks):
        order = list(conditions)
        if phase is not None and (block_index + phase) % 2:
            order.reverse()
        for condition in order:
            lesson_source = "clean" if condition == "clean" else (
                "durable_active" if condition.startswith("post-restart") else "artifact"
            )
            attempts.append({
                "order_index": len(attempts), "block_index": block_index, "split": split,
                "fixture_id": block["fixture_id"], "replicate_index": block["replicate_index"],
                "condition": condition, "lesson_source": lesson_source,
                "worker_process_key": _key(digest, "worker-process", name, block_index, condition),
                "conversation_policy": "fresh", "workspace_policy": "reset-to-exactly-input-json",
                "block_order_key": block["order_key"],
                "attempt_order_key": _key(digest, "attempt", name, block_index, condition,
                                          block["fixture_id"], block["replicate_index"]),
            })
    return {"name": name, "kind": "task-attempts", "split": split,
            "worker_process_policy": "fresh-os-process-per-attempt",
            "counterbalance_phase": phase, "attempts": attempts}


def _barrier(digest: bytes, name: str, barrier: str) -> dict[str, Any]:
    return {"name": name, "kind": "barrier", "barrier": barrier,
            "order_key": _key(digest, "barrier", name, barrier)}


def _canary(values: dict[str, Any], digest: bytes) -> dict[str, Any]:
    contract = values["canary_contract"]
    events = []
    for index, attempt in enumerate(contract["attempts"], start=1):
        lesson_path = {"clean": CANARY_CLEAN_LESSONS_PATH,
                       "artifact": CANARY_NONEMPTY_LESSONS_PATH}.get(attempt["lesson_source"])
        events.append({
            "kind": "attempt", "attempt_index": index, "fixture_id": contract["fixture_id"],
            "task_id": CANARY_TASK_ID, "process": attempt["process"],
            "worker_process_key": _key(digest, "canary-worker-process", attempt["process"]),
            "condition": attempt["condition"], "lesson_source": attempt["lesson_source"],
            "lesson_artifact_path": lesson_path, "publish_active": attempt["publish_active"],
            "source_path": CANARY_BASE_TASK_PATH, "configuration_path": CANARY_CONFIGURATION_PATH,
            "order_key": _key(digest, "canary-attempt", index, attempt["process"], attempt["condition"]),
        })
        if index == contract["restart_after_attempt"]:
            events.append({"kind": "barrier", "barrier": "full-process-restart",
                           "from_process": "A", "to_process": "B",
                           "order_key": _key(digest, "canary-barrier", "full-process-restart")})
    return {"name": "canary", "kind": "canary-events", "worker_process_count": 2,
            "attempts_per_worker_process": 2, "events": events}


def derive(manifest: dict[str, Any], manifest_sha256: str) -> dict[str, Any]:
    if not isinstance(manifest_sha256, str) or not HEX_SHA256.fullmatch(manifest_sha256):
        fail("manifest SHA-256 must be 64 lowercase hexadecimal characters")
    if sha256_hex(canonical_json_bytes(manifest)) != manifest_sha256:
        fail("manifest SHA-256 does not match the supplied canonical manifest")
    root = require_object(manifest, location="manifest")
    categories = require_object(root.get("categories"), location="manifest.categories")
    category = require_object(categories.get("run_order"),
                              location="manifest.categories.run_order")
    values = validate_manifest_values(category.get("values"))
    digest = bytes.fromhex(manifest_sha256)
    stages = [
        _canary(values, digest),
        _attempt_stage(values, digest, name="development", split="development",
                       conditions=values["conditions_by_stage"]["development"], counterbalanced=False),
        {"name": "synthesis", "kind": "synthesis-attempt", "condition": "synthesis",
         "prompt_path": SYNTHESIS_PROMPT_PATH, "worker_process_policy": "fresh-os-process",
         "worker_process_key": _key(digest, "synthesis-worker-process"),
         "order_key": _key(digest, "synthesis-attempt")},
        _barrier(digest, "lesson-freeze-barrier", "freeze-one-semantic-lesson-set-before-regression"),
        _attempt_stage(values, digest, name="regression", split="regression",
                       conditions=values["conditions_by_stage"]["regression"], counterbalanced=True),
        _barrier(digest, "regression-unseal-barrier", "jointly-unseal-both-regression-conditions-and-apply-admission-gate"),
        _attempt_stage(values, digest, name="sealed-pre-restart", split="sealed",
                       conditions=values["conditions_by_stage"]["sealed-pre-restart"], counterbalanced=True),
        _barrier(digest, "sealed-full-process-restart-barrier", "publish-flush-exit-release-lock-and-start-new-os-process"),
        _attempt_stage(values, digest, name="sealed-post-restart", split="sealed",
                       conditions=values["conditions_by_stage"]["sealed-post-restart"], counterbalanced=False),
        _barrier(digest, "sealed-joint-unseal-barrier", "jointly-unseal-clean-lesson-and-post-restart-sealed-conditions"),
    ]
    if [stage["name"] for stage in stages] != values["stage_sequence"]:
        fail("derived run-order stage sequence differs from its frozen contract")
    task_count = sum(len(stage["attempts"]) for stage in stages if stage["kind"] == "task-attempts")
    if task_count != _PLANNED_ATTEMPTS["page_task"]:
        fail("derived run-order attempt counts differ from the frozen protocol")
    return {"schema_version": 2, "algorithm": values["algorithm"],
            "algorithm_version": values["algorithm_version"], "manifest_sha256": manifest_sha256,
            "planned_attempts": dict(_PLANNED_ATTEMPTS), "stages": stages}
