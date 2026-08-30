"""Provider-free verification of a committed scored evidence tree."""

from __future__ import annotations

import json
import re
from pathlib import Path

from benchmark_core.canonical import canonical_sha256, dumps, load_object
from benchmark_learning.learning_contract import canonical_event_log, event_json, parse_event
from benchmark_learning.learning_replay import replay

from scheduled_learning_v1.replay_bootstrap import initial_replay_state

from .builder import report_projection

_EVENT_NAME = re.compile(r"^(\d{6})-([0-9a-f]{64})\.json$")


def verify_results(root: Path, manifest: dict[str, object]) -> dict[str, object]:
    """Rehash the frozen manifest and every ordered result binding without execution imports."""

    root = Path(root).resolve()
    stored_manifest = load_object(root / "freeze" / "manifest.json")
    if stored_manifest != manifest:
        raise ValueError("result verification manifest differs from the committed freeze")
    event_paths = sorted((root / "results" / "events").glob("*.json"))
    events = []
    for path in event_paths:
        match = _EVENT_NAME.fullmatch(path.name)
        if match is None:
            continue
        raw = path.read_bytes()
        value = load_object(path)
        event = parse_event(value)
        if canonical_sha256(event_json(event)) != match.group(2):
            raise ValueError("committed event filename digest does not match its event")
        if raw != dumps(value).encode("utf-8"):
            raise ValueError("committed event bytes are not canonical")
        events.append(event)
    replay_receipt = load_object(root / "results" / "replay-receipt.json")
    if not isinstance(replay_receipt, dict):
        raise ValueError("replay receipt is missing")
    observed_event_digest = canonical_sha256(canonical_event_log(events))
    if replay_receipt.get("events_sha256") != observed_event_digest:
        raise ValueError("ordered event digest differs from the replay receipt")
    state = load_object(root / "results" / "state.json")
    decisions = json.loads(
        (root / "results" / "decision-receipts.json").read_text(encoding="utf-8")
    )
    if replay_receipt.get("final_state_sha256") != canonical_sha256(state):
        raise ValueError("state digest differs from the replay receipt")
    if not isinstance(decisions, list) or replay_receipt.get("decision_receipt_sha256s") != [
        canonical_sha256(item) for item in decisions
    ]:
        raise ValueError("decision digest order differs from the replay receipt")
    approval = load_object(root / "freeze" / "owner-budget-approval.json")
    semantic = replay(
        initial=initial_replay_state(manifest, approval),
        events=events,
    )
    _require_projection(root / "results" / "state.json", semantic["state"], "state")
    _require_projection(
        root / "results" / "decision-receipts.json",
        semantic["decisions"],
        "decisions",
    )
    _require_projection(
        root / "results" / "replay-receipt.json",
        semantic["receipt"],
        "replay receipt",
    )
    report = load_object(root / "results" / "final-report.json")
    if report != report_projection(root):
        raise ValueError("final report differs from committed evidence")
    return {
        "schema_version": 1,
        "status": "verified",
        "manifest_sha256": canonical_sha256(manifest),
        "event_log_sha256": observed_event_digest,
        "final_report_sha256": canonical_sha256(report),
    }


def _require_projection(path: Path, expected: object, name: str) -> None:
    if path.read_bytes() != dumps(expected).encode("utf-8"):
        raise ValueError(f"persisted {name} differs from semantic replay")
