"""Frozen input binding for offline score verification."""

from __future__ import annotations

import unittest
from typing import Any, cast

from benchmark_core.canonical import canonical_sha256, load_object, write
from page_change_m3.oracle import sealed_score
from scheduled_learning_v1.freeze import build_manifest
from scheduled_learning_v1.reporting import verify_results
from scheduled_learning_v1.score_evidence import score_evidence_projection

from tests.execution.support import _perfect_attempt
from tests.freeze.support import create_repository


class FrozenScoreIdentityTests(unittest.TestCase):
    def test_valid_active_score_evidence_uses_full_protocol_attempt_envelope(self) -> None:
        # given
        repository = create_repository()
        self.addCleanup(repository.cleanup)
        root = repository.experiment_root
        manifest = build_manifest(root)
        source = load_object(root / "corpus" / "sealed" / "pc-sealed-05.source.json")
        gold = load_object(root / "gold" / "sealed" / "pc-sealed-05.gold.json")
        base_attempt = _perfect_attempt(source, gold)
        responses_requests = [
            {
                "sequence": 1,
                "requested_model": "gpt-5.6-sol",
                "body_byte_count": 100,
                "body_sha256": "a" * 64,
                "normalized_structure_sha256": "b" * 64,
                "untrusted_fence_present": True,
                "untrusted_payload_sha256": "c" * 64,
            }
        ]
        attempt = {**base_attempt, "responses_requests": responses_requests}
        task_result = {
            "outcome": base_attempt["runtime_outcome"],
            "raw_output": base_attempt["raw_output"],
            "tools": [
                {
                    **cast(list[dict[str, object]], base_attempt["tool_events"])[0],
                    "session_tainted": False,
                }
            ],
            "http": {"responsesSends": responses_requests},
        }
        result_path = root / "results" / "task-attempts" / "task-8" / "result.json"
        result_path.parent.mkdir(parents=True)
        write(result_path, task_result)
        score = sealed_score(
            {"source": source, "gold": gold, "attempt": attempt},
            "active",
        )
        evidence = {
            "schema_version": 1,
            **score,
            "operation_id": "task-8",
            "task_id": source["task_id"],
            "task_result_digest": canonical_sha256(task_result),
            "fixture_id": "pc-sealed-05",
            "condition": "active",
            "scoring_condition": "active",
            "source_sha256": canonical_sha256(source),
            "gold_sha256": canonical_sha256(gold),
            "attempt_sha256": canonical_sha256(attempt),
            "oracle_digest": cast(dict[str, str], manifest["identities"])["oracle_digest"],
            "promoted_digest": "f" * 64,
        }
        gates = cast(dict[str, Any], manifest["gates"])
        thresholds = cast(dict[str, Any], gates["active_and_restart_gates"])

        # when
        projection = score_evidence_projection(
            root,
            cast(dict[str, Any], manifest),
            evidence,
            thresholds["minimum_active_score"],
            8,
            "f" * 64,
            expected_result_digest=canonical_sha256(task_result),
        )

        # then
        self.assertIsNotNone(projection)

    def test_active_score_evidence_requires_frozen_source_bytes(self) -> None:
        # given
        repository = create_repository()
        self.addCleanup(repository.cleanup)
        root = repository.experiment_root
        manifest = build_manifest(root)
        write(root / "freeze" / "manifest.json", manifest)
        source_path = root / "corpus" / "sealed" / "pc-sealed-05.source.json"
        source = load_object(source_path)
        source["family_id"] = "tampered-warehouse-inventory-panel"
        write(source_path, source)
        gold = load_object(root / "gold" / "sealed" / "pc-sealed-05.gold.json")
        base_attempt = _perfect_attempt(source, gold)
        attempt = {**base_attempt, "responses_requests": []}
        task_result = {
            "outcome": base_attempt["runtime_outcome"],
            "raw_output": base_attempt["raw_output"],
            "tools": base_attempt["tool_events"],
            "http": {"responsesSends": []},
        }
        result_path = root / "results" / "task-attempts" / "task-8" / "result.json"
        result_path.parent.mkdir(parents=True)
        write(result_path, task_result)
        score = sealed_score(
            {"source": source, "gold": gold, "attempt": attempt},
            "active",
        )
        evidence_path = root / "results" / "active-evidence.json"
        evidence = {
            "schema_version": 1,
            **score,
            "operation_id": "task-8",
            "task_id": source["task_id"],
            "task_result_digest": canonical_sha256(task_result),
            "fixture_id": "pc-sealed-05",
            "condition": "active",
            "scoring_condition": "active",
            "source_sha256": canonical_sha256(source),
            "gold_sha256": canonical_sha256(gold),
            "attempt_sha256": canonical_sha256(attempt),
            "oracle_digest": cast(dict[str, str], manifest["identities"])["oracle_digest"],
            "promoted_digest": "f" * 64,
        }
        write(evidence_path, evidence)
        gates = cast(dict[str, Any], manifest["gates"])
        thresholds = cast(dict[str, Any], gates["active_and_restart_gates"])
        self.assertIsNotNone(
            score_evidence_projection(
                root,
                cast(dict[str, Any], manifest),
                evidence,
                thresholds["minimum_active_score"],
                8,
                "f" * 64,
                expected_result_digest=canonical_sha256(task_result),
            )
        )

        # when / then
        with self.assertRaisesRegex(ValueError, "input file changed"):
            verify_results(root, manifest)


if __name__ == "__main__":
    unittest.main()
