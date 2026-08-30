"""Fail-closed projection from committed result evidence to the frozen report schema."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256, load_object, write

_COMMIT_LENGTH = 40
_SHA256_LENGTH = 64


def build_final_report(root: Path) -> dict[str, object]:
    """Build and canonically publish the only final report for one result tree."""

    root = Path(root).resolve()
    report = _report(root)
    (root / "results").mkdir(parents=True, exist_ok=True)
    write(root / "results" / "final-report.json", report)
    return report


def report_projection(root: Path) -> dict[str, object]:
    """Recompute a report without mutating the evidence tree."""

    return _report(Path(root).resolve())


def _report(root: Path) -> dict[str, object]:
    manifest = _load(root / "freeze" / "manifest.json")
    approval = _load(root / "freeze" / "owner-budget-approval.json")
    replay_receipt = _load(root / "results" / "replay-receipt.json")
    decisions = _list(root / "results" / "decision-receipts.json")
    candidate = _load(root / "results" / "candidate.json")
    promotion = _load(root / "results" / "promotion-receipt.json")
    adapter = _load(root / "results" / "page-adapter-receipt.json")
    active = _load(root / "results" / "active-evidence.json")
    restart = _load(root / "results" / "restart-evidence.json")
    failure_present = (root / "results" / "failure.json").is_file()
    thresholds = _thresholds(manifest)
    candidate_digest = _digest(candidate.get("replacement_digest"))
    promoted_digest = _promotion_digest(promotion)
    active_evidence = _score_evidence(active, thresholds["minimum_active_score"])
    restart_evidence = _restart_evidence(
        restart,
        thresholds["minimum_restart_active_score"],
        promoted_digest,
    )
    adapter_digest = canonical_sha256(adapter) if adapter else None
    complete = bool(
        not failure_present
        and replay_receipt
        and candidate_digest
        and promoted_digest == candidate_digest
        and promotion in decisions
        and adapter.get("outcome") == "pass"
        and _adapter_matches_promotion(adapter, promotion)
        and active_evidence is not None
        and active_evidence["passed"]
        and restart_evidence is not None
        and restart_evidence["passed"]
        and restart_evidence["promoted_digest_matched"]
    )
    return {
        "schema_version": 1,
        "status": "complete" if complete else "incomplete_failed",
        "manifest_sha256": canonical_sha256(manifest),
        "freeze_commit": _freeze_commit(approval),
        "event_log_sha256": _digest(replay_receipt.get("events_sha256")) or canonical_sha256([]),
        "replay_receipt_sha256": (
            canonical_sha256(replay_receipt) if replay_receipt else canonical_sha256({})
        ),
        "decision_receipt_sha256s": [canonical_sha256(item) for item in decisions],
        "base_digest": _digest(candidate.get("base_digest"))
        or canonical_sha256({"schema_version": 1, "lessons": []}),
        "candidate_digest": candidate_digest,
        "promoted_digest": promoted_digest,
        "page_adapter_receipt_sha256": adapter_digest,
        "active_evidence": active_evidence,
        "restart_evidence": restart_evidence,
        "thresholds": thresholds,
        "m4_blocked": not complete,
    }


def _thresholds(manifest: dict[str, Any]) -> dict[str, object]:
    gates = manifest.get("gates")
    if not isinstance(gates, dict):
        gates = {}
    adapter = gates.get("adapter_pass_rule")
    active = gates.get("active_and_restart_gates")
    adapter = adapter if isinstance(adapter, dict) else {}
    active = active if isinstance(active, dict) else {}
    return {
        "minimum_candidate_score": _number(adapter.get("minimum_candidate_score")),
        "minimum_mean_delta": _number(adapter.get("minimum_mean_delta")),
        "minimum_active_score": _number(active.get("minimum_active_score")),
        "minimum_restart_active_score": _number(active.get("minimum_restart_active_score")),
    }


def _score_evidence(value: dict[str, Any], threshold: object) -> dict[str, object] | None:
    score = value.get("score")
    if not _is_number(score) or not _is_number(threshold):
        return None
    numeric_score = cast(int | float, score)
    numeric_threshold = cast(int | float, threshold)
    return {
        "score": numeric_score,
        "threshold": numeric_threshold,
        "passed": numeric_score >= numeric_threshold,
    }


def _restart_evidence(
    value: dict[str, Any], threshold: object, promoted_digest: str | None
) -> dict[str, object] | None:
    evidence = _score_evidence(value, threshold)
    if evidence is None:
        return None
    matched = bool(
        value.get("promoted_digest_matched") is True
        and promoted_digest is not None
        and value.get("promoted_digest") == promoted_digest
    )
    return {**evidence, "promoted_digest_matched": matched}


def _load(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    value = load_object(path)
    return value if isinstance(value, dict) else {}


def _list(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def _freeze_commit(approval: dict[str, Any]) -> str:
    value = approval.get("expected_freeze_commit")
    return (
        value if isinstance(value, str) and len(value) == _COMMIT_LENGTH else "0" * _COMMIT_LENGTH
    )


def _digest(value: object) -> str | None:
    return value if isinstance(value, str) and len(value) == _SHA256_LENGTH else None


def _promotion_digest(value: dict[str, Any]) -> str | None:
    identities = value.get("artifact_identities")
    if not isinstance(identities, dict):
        return None
    return _digest(identities.get("replacement_digest"))


def _adapter_matches_promotion(adapter: dict[str, Any], promotion: dict[str, Any]) -> bool:
    identities = promotion.get("artifact_identities")
    if not isinstance(identities, dict):
        return False
    receipt = identities.get("adapter_receipt")
    return bool(
        isinstance(receipt, dict)
        and receipt.get("outcome") == adapter.get("outcome")
        and receipt.get("receipt_digest") == canonical_sha256(adapter)
    )


def _number(value: object) -> int | float:
    return cast(int | float, value) if _is_number(value) else 0


def _is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)
