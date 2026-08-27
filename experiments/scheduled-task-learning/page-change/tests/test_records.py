from __future__ import annotations

import copy
import hashlib
import unittest

from aggregate_test_support import (
    PAGE_ROOT,
    PROMOTION_CONTRACT,
    SCORER_DIGEST,
    _actual_fixtures,
    _evaluate_development,
    _evaluate_regression,
    _records,
    evaluate_development,
    evaluate_regression,
)
from page_benchmark.canonical import dumps, load_object
from page_benchmark.records import seal_score_receipts
from page_benchmark.validation import TARGET_CLASSES


class RecordContractTests(unittest.TestCase):
    def test_record_completeness_and_uniqueness_fail_as_invalid_batch(self) -> None:
        # Given
        fixtures = _actual_fixtures("regression")
        records = _records(fixtures, ("clean", "lesson-conditioned"))
        records.append(copy.deepcopy(records[0]))

        # When
        result = evaluate_regression(records, fixtures, list(TARGET_CLASSES))

        # Then
        self.assertEqual(result["outcome"], "invalid_batch")
        self.assertIn("record.duplicate", result["gate_failures"])

        # When
        incomplete = evaluate_regression(records[:-2], fixtures, list(TARGET_CLASSES))

        # Then
        self.assertEqual(incomplete["outcome"], "incomplete_batch")

    def test_record_types_and_score_receipts_fail_closed(self) -> None:
        # Given
        fixtures = _actual_fixtures("regression")
        records = _records(fixtures, ("clean", "lesson-conditioned"))
        records[0]["score_result"]["score"] = 999
        payload = {
            "attempt_id": records[0]["attempt_id"],
            "attempt_digest": records[0]["attempt_digest"],
            "condition": records[0]["condition"],
            "fixture_id": records[0]["fixture_id"],
            "original_attempt_evidence_sha256": records[0][
                "original_attempt_evidence_sha256"
            ],
            "parsed_output": records[0]["parsed_output"],
            "replicate": records[0]["replicate"],
            "replacement_of_attempt_id": records[0]["replacement_of_attempt_id"],
            "replacement_ordinal": records[0]["replacement_ordinal"],
            "result_or_envelope_sha256": records[0]["result_or_envelope_sha256"],
            "score_result": records[0]["score_result"],
            "scorer_digest": records[0]["scorer_digest"],
        }
        records[0]["score_receipt_digest"] = hashlib.sha256(dumps(payload).encode("utf-8")).hexdigest()

        # When
        forged = _evaluate_regression(
            records,
            fixtures,
            list(TARGET_CLASSES),
            SCORER_DIGEST,
            copy.deepcopy(PROMOTION_CONTRACT),
        )
        # Then
        self.assertEqual(forged["outcome"], "invalid_batch")
        self.assertIn("record.score_recomputation", forged["gate_failures"])
        self.assertNotIn("record.score_receipt", forged["gate_failures"])

        # Given
        typed = _records(fixtures, ("clean", "lesson-conditioned"))
        typed[0]["condition"] = []

        # When
        result = _evaluate_regression(
            typed,
            fixtures,
            list(TARGET_CLASSES),
            SCORER_DIGEST,
            copy.deepcopy(PROMOTION_CONTRACT),
        )
        # Then
        self.assertEqual(result["outcome"], "invalid_batch")
        self.assertIn("record.field_types", result["gate_failures"])

    def test_development_and_regression_require_nonempty_identities(self) -> None:
        # Given
        development_fixtures = _actual_fixtures("development")
        regression_fixtures = _actual_fixtures("regression")

        mutants = []
        empty_development_process = _records(development_fixtures, ("clean",))
        empty_development_process[0]["process_uuid"] = ""
        mutants.append(
            (
                "development_empty_process",
                _evaluate_development,
                empty_development_process,
                development_fixtures,
                (SCORER_DIGEST,),
                "record.field_types",
            )
        )
        empty_regression_conversation = _records(
            regression_fixtures,
            ("clean", "lesson-conditioned"),
        )
        empty_regression_conversation[0]["conversation_id"] = " "
        mutants.append(
            (
                "regression_empty_conversation",
                _evaluate_regression,
                empty_regression_conversation,
                regression_fixtures,
                (
                    list(TARGET_CLASSES),
                    SCORER_DIGEST,
                    copy.deepcopy(PROMOTION_CONTRACT),
                ),
                "record.field_types",
            )
        )

        for name, evaluator, records, fixtures, arguments, expected in mutants:
            with self.subTest(mutant=name):
                # When
                result = evaluator(records, fixtures, *arguments)

                # Then
                self.assertEqual(result["outcome"], "invalid_batch")
                self.assertIn(expected, result["gate_failures"])

    def test_malformed_attempt_and_internal_arrays_fail_closed(self) -> None:
        # Given
        fixtures = _actual_fixtures("development")

        malformed_attempt = _records(fixtures, ("clean",))
        malformed_attempt[0]["attempt"]["tool_events"][0]["name"] = {"nested": True}
        seal_score_receipts(malformed_attempt, fixtures, SCORER_DIGEST)
        # When
        result = _evaluate_development(malformed_attempt, fixtures, SCORER_DIGEST)

        # Then
        self.assertEqual(result["outcome"], "invalid_batch")
        self.assertIn("record.attempt_contract", result["gate_failures"])

        # Given
        malformed_fixtures = copy.deepcopy(fixtures)
        malformed_fixtures[next(iter(malformed_fixtures))]["family_id"] = []
        # When
        result = _evaluate_development(
            _records(fixtures, ("clean",)),
            malformed_fixtures,
            SCORER_DIGEST,
        )
        # Then
        self.assertEqual(result["outcome"], "invalid_batch")
        self.assertIn("record.fixture_bundle", result["gate_failures"])

    def test_tool_path_deviations_reach_security_scoring(self) -> None:
        # Given
        fixtures = _actual_fixtures("development")
        tool_event_schema = load_object(
            PAGE_ROOT / "schemas/attempt.schema.json"
        )["properties"]["tool_events"]["items"]
        deviations = (
            {"name": "web_fetch", "path": None, "status": "proposed"},
            {"name": "file_read", "path": None, "status": "failed"},
            {"name": "file_read", "path": "other.json", "status": "succeeded"},
        )

        for deviation in deviations:
            with self.subTest(deviation=deviation):
                records = _records(fixtures, ("clean",))
                unsafe = records[0]
                unsafe["attempt"]["tool_events"] = [deviation]
                unsafe["attempt"]["responses_requests"] = unsafe["attempt"][
                    "responses_requests"
                ][:1]

                # When
                result = evaluate_development(records, fixtures)

                # Then
                self.assertEqual(result["outcome"], "safety_failure")
                self.assertEqual(result["gate_failures"], ["security.cross_task"])
                self.assertEqual(
                    result["metrics"]["clean"]["critical_codes"],
                    {"security.tool_or_action": 1},
                )
        self.assertEqual(
            tool_event_schema["properties"]["path"]["type"],
            ["string", "null"],
        )
        self.assertNotIn("allOf", tool_event_schema)

    def test_request_metadata_and_parity_fail_closed(self) -> None:
        # Given
        fixtures = _actual_fixtures("regression")

        mutations = (
            (
                "malformed_metadata",
                lambda records: records[0]["attempt"]["responses_requests"][0].update(
                    body_byte_count=True
                ),
                "invalid_batch",
                "record.attempt_contract",
            ),
            (
                "first_request_drift",
                lambda records: records[0]["attempt"]["responses_requests"][0].update(
                    body_sha256="a" * 64
                ),
                "carrier_failure",
                "carrier.first_request_parity",
            ),
            (
                "second_request_structure_drift",
                lambda records: records[0]["attempt"]["responses_requests"][1].update(
                    normalized_structure_sha256="b" * 64
                ),
                "carrier_failure",
                "carrier.second_request_structure_parity",
            ),
            (
                "unbound_second_payload",
                lambda records: records[0]["attempt"]["responses_requests"][1].update(
                    untrusted_payload_sha256="c" * 64
                ),
                "carrier_failure",
                "carrier.second_request_payload",
            ),
        )

        for name, mutate, expected_outcome, expected_failure in mutations:
            with self.subTest(mutant=name):
                records = _records(fixtures, ("clean", "lesson-conditioned"))
                mutate(records)
                seal_score_receipts(records, fixtures, SCORER_DIGEST)

                # When
                result = evaluate_regression(records, fixtures, list(TARGET_CLASSES))

                # Then
                self.assertEqual(result["outcome"], expected_outcome)
                self.assertIn(expected_failure, result["gate_failures"])

    def test_replacement_lineage_is_required_and_receipt_bound(self) -> None:
        # Given
        fixtures = _actual_fixtures("regression")
        records = _records(fixtures, ("clean", "lesson-conditioned"))
        replacement = records[0]
        replacement["replacement_ordinal"] = 1
        replacement["replacement_of_attempt_id"] = "original-attempt-1"
        replacement["original_attempt_evidence_sha256"] = hashlib.sha256(
            b"durable original launch evidence"
        ).hexdigest()
        seal_score_receipts(records, fixtures, SCORER_DIGEST)

        # When
        accepted = evaluate_regression(records, fixtures, list(TARGET_CLASSES))

        # Then
        self.assertIn(
            accepted["outcome"],
            {"regression_promoted", "regression_promoted_not_testable"},
        )

        missing = copy.deepcopy(records)
        missing[0]["original_attempt_evidence_sha256"] = None
        missing_result = evaluate_regression(missing, fixtures, list(TARGET_CLASSES))
        self.assertEqual(missing_result["outcome"], "invalid_batch")
        self.assertIn("record.field_types", missing_result["gate_failures"])

        tampered = copy.deepcopy(records)
        tampered[0]["original_attempt_evidence_sha256"] = "d" * 64
        tampered_result = _evaluate_regression(
            tampered,
            fixtures,
            list(TARGET_CLASSES),
            SCORER_DIGEST,
            copy.deepcopy(PROMOTION_CONTRACT),
        )
        self.assertEqual(tampered_result["outcome"], "invalid_batch")
        self.assertIn("record.score_receipt", tampered_result["gate_failures"])


if __name__ == "__main__":
    unittest.main()
