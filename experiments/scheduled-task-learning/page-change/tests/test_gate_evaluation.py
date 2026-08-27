from __future__ import annotations

import copy
import hashlib
import unittest

from aggregate_test_support import (
    LESSON_DIGEST,
    PAGE_ROOT,
    SCORER_DIGEST,
    _actual_fixtures,
    _carrier_contract,
    _classify,
    _condition,
    _evaluate_sealed,
    _first_family_ids,
    _fixture_id_for_verdict,
    _noise_atoms,
    _records,
    evaluate_development,
    evaluate_regression,
    evaluate_sealed,
)
from page_benchmark.canonical import canonical_sha256, load_object
from page_benchmark.gate_evaluation import RESTART_LIFECYCLE_RECEIPT_KEYS
from page_benchmark.validation import TARGET_CLASSES


class GateEvaluationTests(unittest.TestCase):
    def test_restart_lifecycle_schema_matches_closed_validator_contract(self) -> None:
        # Given
        schema = load_object(
            PAGE_ROOT / "schemas/restart-lifecycle-receipt.schema.json"
        )

        # When
        required_keys = set(schema["required"])
        property_keys = set(schema["properties"])

        # Then
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(required_keys, RESTART_LIFECYCLE_RECEIPT_KEYS)
        self.assertEqual(property_keys, RESTART_LIFECYCLE_RECEIPT_KEYS)

    def test_restart_receipt_rejects_valid_identities_from_non_designated_slots(self) -> None:
        # Given
        fixtures = _actual_fixtures("sealed")
        records = _records(
            fixtures,
            ("clean", "lesson-conditioned", "post-restart lesson-conditioned"),
        )
        lesson_records = _condition(records, "lesson-conditioned")
        restart_records = _condition(records, "post-restart lesson-conditioned")
        alternate_publisher = min(
            lesson_records,
            key=lambda record: record["frozen_order_index"],
        )
        alternate_reload = max(
            restart_records,
            key=lambda record: record["frozen_order_index"],
        )
        alternate_values = {
            "publisher_attempt_id": alternate_publisher["attempt_id"],
            "publisher_frozen_order_key": alternate_publisher["frozen_order_key"],
            "publisher_process_uuid": alternate_publisher["process_uuid"],
            "publisher_lock_acquisition_id": alternate_publisher[
                "lock_acquisition_id"
            ],
            "first_reload_attempt_id": alternate_reload["attempt_id"],
            "first_reload_frozen_order_key": alternate_reload["frozen_order_key"],
            "first_reload_process_uuid": alternate_reload["process_uuid"],
            "first_reload_lock_acquisition_id": alternate_reload[
                "lock_acquisition_id"
            ],
        }

        # When
        outcomes = {}
        for field, value in alternate_values.items():
            candidate_records = copy.deepcopy(records)
            contract = copy.deepcopy(_carrier_contract(candidate_records))
            contract["lifecycle_receipt"][field] = value
            lifecycle_digest = canonical_sha256(contract["lifecycle_receipt"])
            contract["lifecycle_receipt_digest"] = lifecycle_digest
            for record in candidate_records:
                record["lifecycle_receipt_digest"] = lifecycle_digest
            outcomes[field] = _evaluate_sealed(
                candidate_records,
                fixtures,
                list(TARGET_CLASSES),
                SCORER_DIGEST,
                contract,
            )

        # Then
        for field, outcome in outcomes.items():
            with self.subTest(field=field):
                self.assertEqual(outcome["outcome"], "carrier_failure")
                self.assertIn("restart.boundary_processes", outcome["gate_failures"])

    def test_development_selects_k_page_and_reports_insufficient_headroom(self) -> None:
        # Given
        fixtures = _actual_fixtures("development")
        records = _records(fixtures, ("clean",))

        # When
        ready = evaluate_development(records, fixtures)

        # Then
        self.assertEqual(ready["outcome"], "development_ready")
        self.assertEqual(ready["k_page"], list(TARGET_CLASSES))

        no_headroom = copy.deepcopy(records)
        for record in no_headroom:
            _classify(record, fixtures[record["fixture_id"]])
        result = evaluate_development(no_headroom, fixtures)
        self.assertEqual(result["outcome"], "insufficient_development_headroom")

        invalid = _records(fixtures, ("clean",))
        invalid[0]["attempt"]["raw_output"] = "not json"
        invalid[0]["parsed_output"] = None
        result = evaluate_development(invalid, fixtures)
        self.assertEqual(result["outcome"], "page_task_specific_failure")
        self.assertIn("development.schema_validity", result["gate_failures"])

    def test_protocol_replicate_mean_range_reports_dispersion(self) -> None:
        # Given
        fixtures = _actual_fixtures("development")
        stable_records = _records(fixtures, ("clean",))

        # When
        stable = evaluate_development(stable_records, fixtures)

        # Then
        stable_metrics = stable["metrics"]["clean"]
        self.assertEqual(stable_metrics["replicate_mean_range_r_x"], 0.0)
        self.assertEqual(set(stable_metrics["replicate_mean_scores"]), {"1", "2", "3"})

        dispersed_records = copy.deepcopy(stable_records)
        for record in dispersed_records:
            if record["replicate"] == 1:
                _classify(record, fixtures[record["fixture_id"]])
        dispersed = evaluate_development(dispersed_records, fixtures)
        means = dispersed["metrics"]["clean"]["replicate_mean_scores"]
        expected_range = round(max(means.values()) - min(means.values()), 6)
        self.assertGreater(expected_range, 0)
        self.assertEqual(
            dispersed["metrics"]["clean"]["replicate_mean_range_r_x"],
            expected_range,
        )

    def test_regression_safety_precedes_headroom_and_nonregression(self) -> None:
        # Given
        fixtures = _actual_fixtures("regression")
        records = _records(fixtures, ("clean", "lesson-conditioned"))
        for record in _condition(records, "clean"):
            _classify(record, fixtures[record["fixture_id"]])
        unsafe = _condition(records, "lesson-conditioned")[0]
        unsafe["attempt"]["tool_events"] = []
        missed = next(
            record
            for record in _condition(records, "lesson-conditioned")
            if any(
                atom["kind"] == "material"
                for atom in fixtures[record["fixture_id"]]["gold"]["atoms"]
            )
        )
        _classify(missed, fixtures[missed["fixture_id"]], include_material=False)

        # When
        result = evaluate_regression(records, fixtures, list(TARGET_CLASSES))

        # Then
        self.assertEqual(result["outcome"], "safety_failure")
        self.assertEqual(result["gate_failures"], ["security.cross_task"])

    def test_one_send_tool_deviation_is_not_masked_by_carrier_parity(self) -> None:
        # Given
        fixtures = _actual_fixtures("regression")
        records = _records(fixtures, ("clean", "lesson-conditioned"))
        unsafe = _condition(records, "lesson-conditioned")[0]
        unsafe["attempt"]["tool_events"] = []
        unsafe["attempt"]["responses_requests"] = unsafe["attempt"][
            "responses_requests"
        ][:1]

        # When
        result = evaluate_regression(records, fixtures, list(TARGET_CLASSES))

        # Then
        self.assertEqual(result["outcome"], "safety_failure")
        self.assertEqual(result["gate_failures"], ["security.cross_task"])

    def test_identity_reuse_is_a_carrier_failure(self) -> None:
        # Given
        fixtures = _actual_fixtures("regression")
        mutations = (
            (
                "process",
                "carrier.process_uuid_reused",
                lambda records: records[1].update(
                    process_uuid=records[0]["process_uuid"]
                ),
            ),
            (
                "conversation",
                "carrier.conversation_reused",
                lambda records: records[1].update(
                    conversation_id=records[0]["conversation_id"]
                ),
            ),
        )

        for name, expected, mutate in mutations:
            with self.subTest(mutant=name):
                records = _records(fixtures, ("clean", "lesson-conditioned"))
                mutate(records)

                # When
                result = evaluate_regression(records, fixtures, list(TARGET_CLASSES))

                # Then
                self.assertEqual(result["outcome"], "carrier_failure")
                self.assertIn(expected, result["gate_failures"])

    def test_regression_schema_critical_and_nonregression_gates(self) -> None:
        # Given
        fixtures = _actual_fixtures("regression")
        baseline = _records(fixtures, ("clean", "lesson-conditioned"))

        for condition in ("clean", "lesson-conditioned"):
            with self.subTest(mutant=f"{condition}_schema"):
                records = copy.deepcopy(baseline)
                invalid = _condition(records, condition)[0]
                invalid["attempt"]["raw_output"] = "not json"
                invalid["parsed_output"] = None

                # When
                result = evaluate_regression(records, fixtures, list(TARGET_CLASSES))

                # Then
                self.assertEqual(result["outcome"], "page_task_specific_failure")
                self.assertIn("regression.schema_validity", result["gate_failures"])

        critical = copy.deepcopy(baseline)
        missed = next(
            record
            for record in _condition(critical, "lesson-conditioned")
            if any(
                atom["kind"] == "material"
                for atom in fixtures[record["fixture_id"]]["gold"]["atoms"]
            )
        )
        _classify(missed, fixtures[missed["fixture_id"]], include_material=False)
        missed["parsed_output"]["verdict"] = "cosmetic"
        critical_result = evaluate_regression(critical, fixtures, list(TARGET_CLASSES))
        self.assertIn("regression.zero_critical", critical_result["gate_failures"])

        nonregressing = copy.deepcopy(baseline)
        for record in _condition(nonregressing, "clean"):
            _classify(record, fixtures[record["fixture_id"]])
        lost_fixture = next(iter(fixtures))
        for record in _condition(nonregressing, "lesson-conditioned"):
            if record["fixture_id"] == lost_fixture:
                fixture = fixtures[lost_fixture]
                _classify(record, fixture, selected_noise=_noise_atoms(fixture))
        nonregression_result = evaluate_regression(
            nonregressing,
            fixtures,
            list(TARGET_CLASSES),
        )
        self.assertIn(
            "regression.task_success_nonregression",
            nonregression_result["gate_failures"],
        )
        self.assertIn(
            "regression.fixture_success_nonregression",
            nonregression_result["gate_failures"],
        )

    def test_regression_not_testable_promotes_after_safety_and_nonregression(self) -> None:
        # Given
        fixtures = _actual_fixtures("regression")
        records = _records(fixtures, ("clean", "lesson-conditioned"))
        for record in _condition(records, "clean"):
            _classify(record, fixtures[record["fixture_id"]])

        # When
        result = evaluate_regression(records, fixtures, list(TARGET_CLASSES))

        # Then
        self.assertEqual(result["outcome"], "regression_promoted_not_testable")

    def test_regression_promotion_and_each_gate_family(self) -> None:
        # Given
        fixtures = _actual_fixtures("regression")
        baseline = _records(fixtures, ("clean", "lesson-conditioned"))

        # When
        promoted = evaluate_regression(baseline, fixtures, list(TARGET_CLASSES))

        # Then
        self.assertEqual(promoted["outcome"], "regression_promoted")

        material_failure = copy.deepcopy(baseline)
        lesson = _condition(material_failure, "lesson-conditioned")[0]
        _classify(lesson, fixtures[lesson["fixture_id"]], include_material=False)
        self.assertIn("regression.material_recall", evaluate_regression(material_failure, fixtures, list(TARGET_CLASSES))["gate_failures"])

        efficacy_failure = copy.deepcopy(baseline)
        for record in _condition(efficacy_failure, "lesson-conditioned"):
            fixture = fixtures[record["fixture_id"]]
            noise = _noise_atoms(fixture)
            _classify(record, fixture, selected_noise=noise)
        result = evaluate_regression(efficacy_failure, fixtures, list(TARGET_CLASSES))
        self.assertIn("regression.absolute_fpr_reduction", result["gate_failures"])
        self.assertIn("regression.positive_families", result["gate_failures"])
        self.assertIn("regression.class_transfer", result["gate_failures"])

    def test_sealed_carrier_and_security_precedence(self) -> None:
        # Given
        fixtures = _actual_fixtures("sealed")
        records = _records(fixtures, ("clean", "lesson-conditioned", "post-restart lesson-conditioned"))
        for record in _condition(records, "clean"):
            _classify(record, fixtures[record["fixture_id"]])
        records[0]["attempt"]["tool_events"] = []
        wrong_digest = hashlib.sha256(b"wrong").hexdigest()
        wrong = _condition(records, "post-restart lesson-conditioned")[0]
        wrong["lesson_digest"] = wrong_digest
        wrong["carrier_receipt"]["lesson_set_sha256"] = wrong_digest

        # When
        carrier = evaluate_sealed(records, fixtures, list(TARGET_CLASSES))

        # Then
        self.assertEqual(carrier["outcome"], "carrier_failure")

        for record in _condition(records, "post-restart lesson-conditioned"):
            record["lesson_digest"] = LESSON_DIGEST
            record["carrier_receipt"]["lesson_set_sha256"] = LESSON_DIGEST
        safety = evaluate_sealed(records, fixtures, list(TARGET_CLASSES))
        self.assertEqual(safety["outcome"], "safety_failure")

        def wrong_clean_ids(values: list[dict]) -> None:
            values[0]["lesson_ids"] = ["unexpected"]
            values[0]["carrier_receipt"]["lesson_ids"] = ["unexpected"]

        for mutator, expected in (
            (wrong_clean_ids, "carrier.clean_not_canonical_empty"),
            (lambda values: values[-1].update(lifecycle_generation="pre-restart"), "restart.post_generation"),
            (
                lambda values: values[-1]["carrier_receipt"].update(lesson_source="artifact"),
                "carrier.lesson_promotion_identity",
            ),
            (
                lambda values: values[-1]["carrier_receipt"].update(input_sha256="0" * 64),
                "carrier.input_digest",
            ),
        ):
            candidate = _records(fixtures, ("clean", "lesson-conditioned", "post-restart lesson-conditioned"))
            mutator(candidate)
            self.assertIn(expected, evaluate_sealed(candidate, fixtures, list(TARGET_CLASSES))["gate_failures"])

        records = _records(fixtures, ("clean", "lesson-conditioned", "post-restart lesson-conditioned"))
        malformed_contract = _carrier_contract(records)
        malformed_contract = copy.deepcopy(malformed_contract)
        malformed_contract["active_lesson_set"]["lessons"][0]["text"] = "tampered"
        result = _evaluate_sealed(records, fixtures, list(TARGET_CLASSES), SCORER_DIGEST, malformed_contract)
        self.assertIn("carrier.promotion_artifacts", result["gate_failures"])

        forged_receipt = copy.deepcopy(_carrier_contract(records))
        forged_receipt["lifecycle_receipt"]["input_was_regenerated"] = False
        result = _evaluate_sealed(records, fixtures, list(TARGET_CLASSES), SCORER_DIGEST, forged_receipt)
        self.assertIn("restart.lifecycle_receipt", result["gate_failures"])

        for field in ("durable_lesson_set_id", "durable_lesson_ids"):
            missing_identity = copy.deepcopy(_carrier_contract(records))
            del missing_identity["lifecycle_receipt"][field]
            missing_identity["lifecycle_receipt_digest"] = canonical_sha256(
                missing_identity["lifecycle_receipt"]
            )
            result = _evaluate_sealed(
                records,
                fixtures,
                list(TARGET_CLASSES),
                SCORER_DIGEST,
                missing_identity,
            )
            self.assertIn("restart.lifecycle_receipt", result["gate_failures"])

        wrong_set_id = copy.deepcopy(_carrier_contract(records))
        wrong_set_id["lifecycle_receipt"]["durable_lesson_set_id"] = "set-000000000000"
        wrong_set_id["lifecycle_receipt_digest"] = canonical_sha256(
            wrong_set_id["lifecycle_receipt"]
        )
        result = _evaluate_sealed(
            records,
            fixtures,
            list(TARGET_CLASSES),
            SCORER_DIGEST,
            wrong_set_id,
        )
        self.assertIn("restart.lifecycle_receipt", result["gate_failures"])

        reordered_ids = copy.deepcopy(_carrier_contract(records))
        reordered_ids["lifecycle_receipt"]["durable_lesson_ids"] = list(
            reversed(reordered_ids["lifecycle_receipt"]["durable_lesson_ids"])
        )
        reordered_ids["lifecycle_receipt_digest"] = canonical_sha256(
            reordered_ids["lifecycle_receipt"]
        )
        result = _evaluate_sealed(
            records,
            fixtures,
            list(TARGET_CLASSES),
            SCORER_DIGEST,
            reordered_ids,
        )
        self.assertIn("restart.lifecycle_receipt", result["gate_failures"])

        clean_publisher = copy.deepcopy(_carrier_contract(records))
        clean_publisher["lifecycle_receipt"]["publisher_process_uuid"] = next(
            record["process_uuid"]
            for record in records
            if record["condition"] == "clean"
        )
        clean_publisher["lifecycle_receipt_digest"] = canonical_sha256(
            clean_publisher["lifecycle_receipt"]
        )
        result = _evaluate_sealed(
            records,
            fixtures,
            list(TARGET_CLASSES),
            SCORER_DIGEST,
            clean_publisher,
        )
        self.assertIn("restart.boundary_processes", result["gate_failures"])

    def test_sealed_headroom_and_full_validation_with_diagnostics(self) -> None:
        # Given
        fixtures = _actual_fixtures("sealed")
        baseline = _records(fixtures, ("clean", "lesson-conditioned", "post-restart lesson-conditioned"))

        # When
        validated = evaluate_sealed(baseline, fixtures, list(TARGET_CLASSES))

        # Then
        self.assertEqual(validated["outcome"], "page_validated")
        self.assertEqual(validated["diagnostics"]["bootstrap_4_to_4"]["sample_count"], 256)
        self.assertEqual(validated["diagnostics"]["sign_flip_2_to_4"]["sample_count"], 16)
        self.assertEqual(validated["diagnostics"]["sign_flip_2_to_4"]["one_sided_p"], 0.125)

        no_headroom = copy.deepcopy(baseline)
        for record in _condition(no_headroom, "clean"):
            _classify(record, fixtures[record["fixture_id"]])
        result = evaluate_sealed(no_headroom, fixtures, list(TARGET_CLASSES))
        self.assertEqual(result["outcome"], "insufficient_sealed_headroom")

    def test_sealed_schema_and_zero_critical_gates_precede_headroom(self) -> None:
        # Given
        fixtures = _actual_fixtures("sealed")
        conditions = (
            "clean",
            "lesson-conditioned",
            "post-restart lesson-conditioned",
        )
        baseline = _records(fixtures, conditions)

        for condition in conditions:
            with self.subTest(mutant=f"{condition}_schema"):
                records = copy.deepcopy(baseline)
                for clean in _condition(records, "clean"):
                    _classify(clean, fixtures[clean["fixture_id"]])
                invalid = _condition(records, condition)[0]
                invalid["attempt"]["raw_output"] = "not json"
                invalid["parsed_output"] = None

                # When
                result = evaluate_sealed(records, fixtures, list(TARGET_CLASSES))

                # Then
                self.assertEqual(result["outcome"], "page_task_specific_failure")
                self.assertIn("sealed.schema_validity", result["gate_failures"])

        for condition, expected in (
            ("lesson-conditioned", "sealed.lesson.zero_critical"),
            (
                "post-restart lesson-conditioned",
                "sealed.restart.zero_critical",
            ),
        ):
            with self.subTest(mutant=f"{condition}_critical"):
                records = copy.deepcopy(baseline)
                for clean in _condition(records, "clean"):
                    _classify(clean, fixtures[clean["fixture_id"]])
                missed = next(
                    record
                    for record in _condition(records, condition)
                    if any(
                        atom["kind"] == "material"
                        for atom in fixtures[record["fixture_id"]]["gold"]["atoms"]
                    )
                )
                _classify(missed, fixtures[missed["fixture_id"]], include_material=False)
                missed["parsed_output"]["verdict"] = "cosmetic"

                result = evaluate_sealed(records, fixtures, list(TARGET_CLASSES))

                self.assertEqual(result["outcome"], "page_task_specific_failure")
                self.assertIn(expected, result["gate_failures"])

    def test_all_lesson_sealed_acceptance_gates_are_enforced(self) -> None:
        # Given
        fixtures = _actual_fixtures("sealed")
        baseline = _records(fixtures, ("clean", "lesson-conditioned", "post-restart lesson-conditioned"))

        # When
        verdict = copy.deepcopy(baseline)
        noise_only_id = _fixture_id_for_verdict(fixtures, "cosmetic")
        for record in [item for item in _condition(verdict, "lesson-conditioned") if item["fixture_id"] == noise_only_id][:2]:
            fixture = fixtures[record["fixture_id"]]
            _classify(record, fixture, selected_noise=fixture["gold"]["atoms"])
        # Then
        self.assertIn("sealed.lesson.verdict_accuracy", evaluate_sealed(verdict, fixtures, list(TARGET_CLASSES))["gate_failures"])

        task_success = copy.deepcopy(baseline)
        for record in _condition(task_success, "lesson-conditioned")[:4]:
            fixture = fixtures[record["fixture_id"]]
            noise = _noise_atoms(fixture)
            _classify(record, fixture, selected_noise=noise[:3])
        self.assertIn("sealed.lesson.task_success", evaluate_sealed(task_success, fixtures, list(TARGET_CLASSES))["gate_failures"])

        success_nonregression = copy.deepcopy(baseline)
        selected_fixture = list(fixtures)[0]
        for record in _condition(success_nonregression, "clean"):
            if record["fixture_id"] == selected_fixture:
                _classify(record, fixtures[record["fixture_id"]])
        for record in _condition(success_nonregression, "lesson-conditioned"):
            if record["fixture_id"] == selected_fixture:
                fixture = fixtures[record["fixture_id"]]
                noise = _noise_atoms(fixture)
                _classify(record, fixture, selected_noise=noise[:3])
        self.assertIn(
            "sealed.lesson.success_nonregression",
            evaluate_sealed(success_nonregression, fixtures, list(TARGET_CLASSES))["gate_failures"],
        )

        median_failure = copy.deepcopy(baseline)
        fixture_id = next(iter(fixtures))
        for record in median_failure:
            if record["fixture_id"] == fixture_id and record["condition"] == "clean":
                _classify(record, fixtures[fixture_id])
            elif record["fixture_id"] == fixture_id and record["condition"] == "lesson-conditioned":
                noise = _noise_atoms(fixtures[fixture_id])
                _classify(record, fixtures[fixture_id], selected_noise=noise[:2])
        self.assertIn("sealed.lesson.fixture_medians", evaluate_sealed(median_failure, fixtures, list(TARGET_CLASSES))["gate_failures"])

        exact_five = copy.deepcopy(baseline)
        for record in exact_five:
            if record["fixture_id"] == fixture_id and record["condition"] == "clean":
                _classify(record, fixtures[fixture_id])
            elif record["fixture_id"] == fixture_id and record["condition"] == "lesson-conditioned":
                noise = _noise_atoms(fixtures[fixture_id])
                _classify(record, fixtures[fixture_id], selected_noise=noise[:1])
        self.assertIn("sealed.lesson.fixture_medians", evaluate_sealed(exact_five, fixtures, list(TARGET_CLASSES))["gate_failures"])

        no_transfer = copy.deepcopy(baseline)
        for record in _condition(no_transfer, "lesson-conditioned"):
            fixture = fixtures[record["fixture_id"]]
            selected_noise = _noise_atoms(
                fixture,
                excluding_target_class=TARGET_CLASSES[0],
            )
            _classify(record, fixture, selected_noise=selected_noise)
        transfer_result = evaluate_sealed(no_transfer, fixtures, list(TARGET_CLASSES))
        self.assertIn("sealed.lesson.fpr_reduction", transfer_result["gate_failures"])
        self.assertIn("sealed.lesson.class_transfer", transfer_result["gate_failures"])

        two_families = copy.deepcopy(baseline)
        improved_families = _first_family_ids(fixtures, 2)
        for record in _condition(two_families, "lesson-conditioned"):
            if record["family_id"] not in improved_families:
                fixture = fixtures[record["fixture_id"]]
                noise = _noise_atoms(fixture)
                _classify(record, fixture, selected_noise=noise)
        self.assertIn(
            "sealed.lesson.positive_families",
            evaluate_sealed(two_families, fixtures, list(TARGET_CLASSES))["gate_failures"],
        )

        material_loss = copy.deepcopy(baseline)
        record = _condition(material_loss, "lesson-conditioned")[0]
        _classify(record, fixtures[record["fixture_id"]], include_material=False)
        self.assertIn(
            "sealed.lesson.material_recall",
            evaluate_sealed(material_loss, fixtures, list(TARGET_CLASSES))[
                "gate_failures"
            ],
        )

    def test_all_restart_acceptance_gates_are_enforced(self) -> None:
        # Given
        fixtures = _actual_fixtures("sealed")
        baseline = _records(fixtures, ("clean", "lesson-conditioned", "post-restart lesson-conditioned"))

        # When
        drift = copy.deepcopy(baseline)
        for record in _condition(drift, "post-restart lesson-conditioned"):
            fixture = fixtures[record["fixture_id"]]
            noise = _noise_atoms(fixture)
            _classify(record, fixture, selected_noise=noise[:1])
        # Then
        self.assertIn("sealed.restart.fpr_drift", evaluate_sealed(drift, fixtures, list(TARGET_CLASSES))["gate_failures"])

        no_restart_transfer = copy.deepcopy(baseline)
        for record in _condition(no_restart_transfer, "post-restart lesson-conditioned"):
            fixture = fixtures[record["fixture_id"]]
            selected_noise = _noise_atoms(
                fixture,
                excluding_target_class=TARGET_CLASSES[0],
            )
            _classify(record, fixture, selected_noise=selected_noise)
        restart_transfer_result = evaluate_sealed(no_restart_transfer, fixtures, list(TARGET_CLASSES))
        self.assertIn("sealed.restart.fpr_reduction", restart_transfer_result["gate_failures"])
        self.assertIn("sealed.restart.class_transfer", restart_transfer_result["gate_failures"])

        two_restart_families = copy.deepcopy(baseline)
        improved_families = _first_family_ids(fixtures, 2)
        for record in _condition(two_restart_families, "post-restart lesson-conditioned"):
            if record["family_id"] not in improved_families:
                fixture = fixtures[record["fixture_id"]]
                noise = _noise_atoms(fixture)
                _classify(record, fixture, selected_noise=noise)
        self.assertIn(
            "sealed.restart.positive_families",
            evaluate_sealed(two_restart_families, fixtures, list(TARGET_CLASSES))["gate_failures"],
        )

        verdict = copy.deepcopy(baseline)
        noise_only_id = _fixture_id_for_verdict(fixtures, "cosmetic")
        for record in [item for item in _condition(verdict, "post-restart lesson-conditioned") if item["fixture_id"] == noise_only_id][:2]:
            fixture = fixtures[record["fixture_id"]]
            _classify(record, fixture, selected_noise=fixture["gold"]["atoms"])
        self.assertIn("sealed.restart.verdict_accuracy", evaluate_sealed(verdict, fixtures, list(TARGET_CLASSES))["gate_failures"])

        medians = copy.deepcopy(baseline)
        fixture_id = next(iter(fixtures))
        for record in _condition(medians, "post-restart lesson-conditioned"):
            if record["fixture_id"] == fixture_id:
                noise = _noise_atoms(fixtures[fixture_id])
                _classify(record, fixtures[fixture_id], selected_noise=noise[:2])
        self.assertIn("sealed.restart.fixture_medians", evaluate_sealed(medians, fixtures, list(TARGET_CLASSES))["gate_failures"])

        exact_five = copy.deepcopy(baseline)
        for record in _condition(exact_five, "post-restart lesson-conditioned"):
            if record["fixture_id"] == fixture_id:
                noise = _noise_atoms(fixtures[fixture_id])
                _classify(record, fixtures[fixture_id], selected_noise=noise[:1])
        self.assertIn("sealed.restart.fixture_medians", evaluate_sealed(exact_five, fixtures, list(TARGET_CLASSES))["gate_failures"])

        success = copy.deepcopy(baseline)
        improved_clean = next(
            record
            for record in _condition(success, "clean")
            if fixtures[record["fixture_id"]]["gold"]["expected_verdict"] != "none"
        )
        _classify(improved_clean, fixtures[improved_clean["fixture_id"]])
        restart_with_noise = [
            record
            for record in _condition(success, "post-restart lesson-conditioned")
            if fixtures[record["fixture_id"]]["gold"]["expected_verdict"] != "none"
        ]
        for record in restart_with_noise:
            fixture = fixtures[record["fixture_id"]]
            noise = _noise_atoms(fixture)
            _classify(record, fixture, selected_noise=noise[:3])
        self.assertIn("sealed.restart.task_success", evaluate_sealed(success, fixtures, list(TARGET_CLASSES))["gate_failures"])


if __name__ == "__main__":
    unittest.main()
