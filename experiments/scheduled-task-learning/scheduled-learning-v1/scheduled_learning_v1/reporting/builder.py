"""Fail-closed projection from committed result evidence to the frozen report schema."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256, dumps, load_object, write

_COMMIT = re.compile(r"^[0-9a-f]{40}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


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
    manifest_path = root / "freeze" / "manifest.json"
    approval_path = root / "freeze" / "owner-budget-approval.json"
    replay_path = root / "results" / "replay-receipt.json"
    decisions_path = root / "results" / "decision-receipts.json"
    candidate_path = root / "results" / "candidate.json"
    promotion_path = root / "results" / "promotion-receipt.json"
    adapter_path = root / "results" / "page-adapter-receipt.json"
    active_path = root / "results" / "active-evidence.json"
    restart_path = root / "results" / "restart-evidence.json"
    failure_path = root / "results" / "failure.json"
    manifest = _load(manifest_path)
    approval = _load(approval_path)
    replay_receipt = _load(replay_path)
    decisions = _list(decisions_path)
    candidate = _load(candidate_path)
    promotion = _load(promotion_path)
    adapter = _load(adapter_path)
    active = _load(active_path)
    restart = _load(restart_path)
    failure_present = failure_path.is_file()
    thresholds = _thresholds(manifest)
    candidate_digest = _digest(candidate.get("replacement_digest"))
    promoted_digest = _promotion_digest(promotion)
    active_threshold = thresholds.get("minimum_active_score") if thresholds else None
    restart_threshold = thresholds.get("minimum_restart_active_score") if thresholds else None
    active_evidence = _score_evidence(active, active_threshold)
    restart_evidence = _restart_evidence(
        restart,
        restart_threshold,
        promoted_digest,
    )
    adapter_evidence = _adapter_evidence(adapter)
    manifest_sha256 = _raw_sha256(manifest_path)
    owner_approval_sha256 = _raw_sha256(approval_path)
    freeze_commit = _freeze_commit(approval)
    event_log_sha256 = _digest(replay_receipt.get("events_sha256"))
    replay_receipt_sha256 = _raw_sha256(replay_path)
    decision_receipts_sha256 = _raw_sha256(decisions_path)
    decision_receipt_sha256s = (
        [canonical_sha256(item) for item in decisions] if decisions is not None else None
    )
    base_digest = _digest(candidate.get("base_digest"))
    candidate_artifact_sha256 = _raw_sha256(candidate_path)
    promotion_receipt_sha256 = _raw_sha256(promotion_path)
    page_adapter_receipt_sha256 = _raw_sha256(adapter_path)
    active_evidence_sha256 = _raw_sha256(active_path)
    restart_evidence_sha256 = _raw_sha256(restart_path)
    failure_sha256 = _raw_sha256(failure_path)
    complete = bool(
        not failure_present
        and manifest_sha256
        and owner_approval_sha256
        and freeze_commit
        and event_log_sha256
        and replay_receipt_sha256
        and decision_receipts_sha256
        and decision_receipt_sha256s is not None
        and base_digest
        and candidate_artifact_sha256
        and promotion_receipt_sha256
        and page_adapter_receipt_sha256
        and active_evidence_sha256
        and restart_evidence_sha256
        and failure_sha256 is None
        and _replay_matches_decisions(replay_receipt, decisions)
        and candidate_digest
        and _candidate_lessons_match(candidate, candidate_digest)
        and promoted_digest == candidate_digest
        and decisions is not None
        and promotion in decisions
        and _adapter_passes(adapter, adapter_evidence, thresholds)
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
        "manifest_sha256": manifest_sha256,
        "owner_approval_sha256": owner_approval_sha256,
        "freeze_commit": freeze_commit,
        "event_log_sha256": event_log_sha256,
        "replay_receipt_sha256": replay_receipt_sha256,
        "decision_receipts_sha256": decision_receipts_sha256,
        "decision_receipt_sha256s": decision_receipt_sha256s,
        "base_digest": base_digest,
        "candidate_digest": candidate_digest,
        "candidate_artifact_sha256": candidate_artifact_sha256,
        "promoted_digest": promoted_digest,
        "promotion_receipt_sha256": promotion_receipt_sha256,
        "page_adapter_receipt_sha256": page_adapter_receipt_sha256,
        "adapter_evidence": adapter_evidence,
        "active_evidence_sha256": active_evidence_sha256,
        "active_evidence": active_evidence,
        "restart_evidence_sha256": restart_evidence_sha256,
        "restart_evidence": restart_evidence,
        "failure_sha256": failure_sha256,
        "thresholds": thresholds,
        "m4_blocked": not complete,
    }


def _thresholds(manifest: dict[str, Any]) -> dict[str, object] | None:
    gates = manifest.get("gates")
    if not isinstance(gates, dict):
        return None
    adapter = gates.get("adapter_pass_rule")
    active = gates.get("active_and_restart_gates")
    adapter_keys = {
        "minimum_valid_pairs",
        "maximum_valid_pairs",
        "minimum_candidate_score",
        "minimum_mean_delta",
        "allow_critical_result",
        "allow_negative_delta",
    }
    active_keys = {"minimum_active_score", "minimum_restart_active_score"}
    if (
        not isinstance(adapter, dict)
        or set(adapter) != adapter_keys
        or not isinstance(active, dict)
        or set(active) != active_keys
    ):
        return None
    if (
        not _is_integer(adapter["minimum_valid_pairs"])
        or not _is_integer(adapter["maximum_valid_pairs"])
        or not _is_number(adapter["minimum_candidate_score"])
        or not _is_number(adapter["minimum_mean_delta"])
        or not isinstance(adapter["allow_critical_result"], bool)
        or not isinstance(adapter["allow_negative_delta"], bool)
        or not _is_number(active["minimum_active_score"])
        or not _is_number(active["minimum_restart_active_score"])
    ):
        return None
    return {
        "adapter_pass_rule": {key: adapter[key] for key in sorted(adapter_keys)},
        "minimum_active_score": active["minimum_active_score"],
        "minimum_restart_active_score": active["minimum_restart_active_score"],
    }


def _adapter_evidence(value: dict[str, Any]) -> dict[str, object] | None:
    pairs = value.get("pairs")
    outcome = value.get("outcome")
    if not isinstance(pairs, list) or not isinstance(outcome, str):
        return None
    valid = [pair for pair in pairs if _complete_pair(pair)]
    candidate_scores = [
        cast(int | float, cast(dict[str, Any], pair["candidate"])["score"]) for pair in valid
    ]
    deltas = [
        float(cast(dict[str, Any], pair["candidate"])["score"])
        - float(cast(dict[str, Any], pair["clean"])["score"])
        for pair in valid
    ]
    critical = any(
        bool(cast(dict[str, Any], pair[condition])["critical_codes"])
        for pair in valid
        for condition in ("clean", "candidate")
    )
    return {
        "outcome": outcome,
        "pair_count": len(pairs),
        "valid_pair_count": len(valid),
        "minimum_candidate_score": min(candidate_scores) if candidate_scores else None,
        "mean_delta": sum(deltas) / len(deltas) if deltas else None,
        "critical_result_present": critical,
        "negative_delta_present": any(delta < 0 for delta in deltas),
    }


def _adapter_passes(
    receipt: dict[str, Any],
    evidence: dict[str, object] | None,
    thresholds: dict[str, object] | None,
) -> bool:
    if evidence is None or thresholds is None or evidence.get("outcome") != "pass":
        return False
    gate = thresholds.get("adapter_pass_rule")
    if not isinstance(gate, dict):
        return False
    pair_count = evidence.get("pair_count")
    valid_count = evidence.get("valid_pair_count")
    candidate_score = evidence.get("minimum_candidate_score")
    mean_delta = evidence.get("mean_delta")
    return bool(
        _is_integer(pair_count)
        and _is_integer(valid_count)
        and pair_count == valid_count
        and receipt.get("pair_count") == pair_count
        and receipt.get("valid_pair_count") == valid_count
        and receipt.get("mean_delta") == mean_delta
        and cast(int, gate["minimum_valid_pairs"])
        <= cast(int, valid_count)
        <= cast(int, gate["maximum_valid_pairs"])
        and _is_number(candidate_score)
        and cast(int | float, candidate_score) >= cast(int | float, gate["minimum_candidate_score"])
        and _is_number(mean_delta)
        and cast(int | float, mean_delta) >= cast(int | float, gate["minimum_mean_delta"])
        and (
            gate["allow_critical_result"] is True
            or evidence.get("critical_result_present") is False
        )
        and (
            gate["allow_negative_delta"] is True or evidence.get("negative_delta_present") is False
        )
    )


def _complete_pair(value: object) -> bool:
    if not isinstance(value, dict):
        return False
    for condition in ("clean", "candidate"):
        score = value.get(condition)
        if (
            not isinstance(score, dict)
            or not _is_number(score.get("score"))
            or not isinstance(score.get("critical_codes"), list)
        ):
            return False
    return True


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
    try:
        value = load_object(path)
    except (OSError, RecursionError, UnicodeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _list(path: Path) -> list[dict[str, Any]] | None:
    if not path.is_file():
        return None
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
        canonical = dumps(value).encode("utf-8")
    except (OSError, RecursionError, TypeError, UnicodeError, ValueError):
        return None
    if raw != canonical:
        return None
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        return None
    return cast(list[dict[str, Any]], value)


def _freeze_commit(approval: dict[str, Any]) -> str | None:
    value = approval.get("expected_freeze_commit")
    return value if isinstance(value, str) and _COMMIT.fullmatch(value) else None


def _digest(value: object) -> str | None:
    return value if isinstance(value, str) and _SHA256.fullmatch(value) else None


def _promotion_digest(value: dict[str, Any]) -> str | None:
    identities = value.get("artifact_identities")
    if not isinstance(identities, dict):
        return None
    return _digest(identities.get("replacement_digest"))


def _candidate_lessons_match(value: dict[str, Any], declared_digest: str) -> bool:
    lessons = value.get("lessons")
    return bool(
        isinstance(lessons, list)
        and all(isinstance(item, str) for item in lessons)
        and canonical_sha256({"schema_version": 1, "lessons": lessons}) == declared_digest
    )


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


def _replay_matches_decisions(
    replay_receipt: dict[str, Any], decisions: list[dict[str, Any]] | None
) -> bool:
    return bool(
        decisions is not None
        and replay_receipt.get("decision_receipt_sha256s")
        == [canonical_sha256(item) for item in decisions]
    )


def _raw_sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def _is_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)
