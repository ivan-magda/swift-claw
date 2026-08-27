from __future__ import annotations

import copy
import hashlib
import unittest

from aggregate_test_support import (
    FEEDBACK_GENERATOR_DIGEST,
    _actual_fixtures,
    _development_bundle,
    _records,
    _synthesis_transcript,
    _valid_lesson_candidate,
)
from page_benchmark.canonical import canonical_sha256, dumps, load_object
from page_benchmark.feedback import normalize_feedback
from page_benchmark.lessons import lint_candidate
from page_benchmark.promotion import promote_candidate
from page_benchmark.synthesis import build_synthesis_input
from path_test_support import PAGE_ROOT as ROOT

class SynthesisContractTests(unittest.TestCase):
    def setUp(self) -> None:
        fixtures = _actual_fixtures("development")
        bundle = _development_bundle(_records(fixtures, ("clean",)), fixtures)
        self.runs = bundle["runs"]
        self.sources = bundle["sources"]
        self.golds = bundle["golds"]
        self.error_codes = load_object(ROOT / "contracts/error-codes.json")
        self.templates = load_object(ROOT / "contracts/feedback-templates.json")
        self.lesson_schema = load_object(ROOT / "schemas/lesson-set.schema.json")
        self.rules = load_object(ROOT / "contracts/lesson-lint-rules.json")

    def _build(self) -> dict:
        return build_synthesis_input(
            self.runs,
            self.sources,
            self.golds,
            self.error_codes,
            self.templates,
            self.lesson_schema,
            self.rules,
            FEEDBACK_GENERATOR_DIGEST,
        )

    def test_builder_selects_supported_classes_and_excludes_model_facing_data(self) -> None:
        # Given — the complete development bundle loaded by setUp

        # When
        synthesis_input = self._build()
        rendered = dumps(synthesis_input)

        # Then
        self.assertEqual(
            set(synthesis_input["selected_target_classes"]),
            {"noise.volatile_value", "noise.time_or_build_metadata", "noise.structure_or_order"},
        )
        self.assertEqual(len(synthesis_input["development_runs"]), 18)
        self.assertNotIn("before_html", rendered)
        self.assertNotIn("pc-development", " ".join(run["run_id"] for run in synthesis_input["development_runs"]))
        self.assertEqual(dumps(self._build()), rendered)

    def test_feedback_is_only_frozen_code_specific_text(self) -> None:
        # Given — development runs and frozen templates loaded by setUp

        # When
        feedback = normalize_feedback(self.runs, self.templates)

        # Then
        expected_mapping = [
            (run["run_id"], index, entry["code"])
            for run in sorted(self.runs, key=lambda item: item["run_id"])
            for index, entry in enumerate(run["score_result"]["error_ledger"])
        ]
        self.assertEqual(
            [(item["run_id"], item["ledger_index"], item["code"]) for item in feedback],
            expected_mapping,
        )
        for item in feedback:
            template = self.templates["templates"][item["code"]]
            self.assertEqual(item["summary"], template["summary"])
            self.assertEqual(item["guidance"], template["guidance"])
            self.assertNotIn("operator_text", item)
        self.assertEqual(feedback, normalize_feedback(list(reversed(self.runs)), self.templates))

    def test_dynamic_linter_accepts_one_general_rule_per_selected_class(self) -> None:
        # Given
        selected = self._build()["selected_target_classes"]
        candidate = _valid_lesson_candidate(selected)

        # When
        report = lint_candidate(candidate, selected, self.runs, self.sources, self.golds, self.rules)

        # Then
        self.assertTrue(report["accepted"], report["errors"])

    def test_dynamic_linter_rejects_example_leakage_and_wrong_class_set(self) -> None:
        # Given
        selected = self._build()["selected_target_classes"]
        candidate = {
            "schema_version": 1,
            "lessons": [
                {
                    "target_class": selected[0],
                    "text": "Treat OrbitDesk and 1,204 teams online as a volatile counter.",
                }
            ],
        }

        # When
        report = lint_candidate(candidate, selected, self.runs, self.sources, self.golds, self.rules)

        # Then
        self.assertFalse(report["accepted"])
        self.assertIn("lesson.class_set", {error["code"] for error in report["errors"]})
        self.assertIn("lesson.example_leakage", {error["code"] for error in report["errors"]})

    def test_dynamic_linter_rejects_invisible_and_substring_rule_bypasses(self) -> None:
        # Given
        selected = self._build()["selected_target_classes"]
        baseline = {
            "schema_version": 1,
            "lessons": [
                {"target_class": selected[0], "text": "Treat vola\u200btile counters as cosmetic when meaning is unchanged."},
                {"target_class": selected[1], "text": "Mistreat generated timestamp metadata when user-facing state is unchanged."},
                {"target_class": selected[2], "text": "Classify counterfeit layout reorderings as cosmetic when meaning is unchanged."},
            ],
        }

        # When
        report = lint_candidate(baseline, selected, self.runs, self.sources, self.golds, self.rules)
        codes = {error["code"] for error in report["errors"]}

        # Then
        self.assertIn("lesson.invisible_or_control", codes)
        self.assertIn("lesson.rule_grammar", codes)
        self.assertIn("lesson.class_concept", codes)

    def test_linter_consumes_complete_declared_rule_grammar(self) -> None:
        # Given
        selected = self._build()["selected_target_classes"]
        candidate = _valid_lesson_candidate(selected)
        for mutation in ("omitted", "changed"):
            with self.subTest(mutation=mutation):
                rules = copy.deepcopy(self.rules)
                if mutation == "omitted":
                    del rules["rule_grammar"]
                else:
                    rules["rule_grammar"]["style"] = "free_form"

                # When
                with self.assertRaises(ValueError) as raised:
                    lint_candidate(candidate, selected, self.runs, self.sources, self.golds, rules)

                # Then
                self.assertRegex(str(raised.exception), "rule grammar|top-level fields")

    def test_builder_recomputes_and_rejects_tampered_score_result(self) -> None:
        # Given
        tampered = copy.deepcopy(self.runs)
        tampered[0]["score_result"]["score"] = 99.0

        # When
        with self.assertRaises(ValueError) as raised:
            build_synthesis_input(
                tampered,
                self.sources,
                self.golds,
                self.error_codes,
                self.templates,
                self.lesson_schema,
                self.rules,
                FEEDBACK_GENERATOR_DIGEST,
            )

        # Then
        self.assertRegex(str(raised.exception), "deterministic recomputation")

    def test_accepted_candidate_is_promoted_once_to_byte_stable_active_artifact(self) -> None:
        # Given
        synthesis_input = self._build()
        selected = synthesis_input["selected_target_classes"]
        candidate = _valid_lesson_candidate(selected)
        lint_report = lint_candidate(candidate, selected, self.runs, self.sources, self.golds, self.rules)
        development_bundle = {
            "runs": self.runs,
            "sources": self.sources,
            "golds": self.golds,
        }
        transcript = _synthesis_transcript(synthesis_input, candidate, lint_report)

        # When
        results = [
            promote_candidate(
                synthesis_input,
                development_bundle,
                self.rules,
                transcript,
                lint_report,
            )
            for _ in range(2)
        ]

        # Then
        self.assertEqual(dumps(results[0]), dumps(results[1]))
        artifact = results[0]["active_lesson_set"]
        artifact_bytes = dumps(artifact).encode("utf-8")
        self.assertEqual(
            results[0]["promotion_receipt"]["active_lesson_set_sha256"],
            hashlib.sha256(artifact_bytes).hexdigest(),
        )
        self.assertEqual([lesson["target_class"] for lesson in artifact["lessons"]], selected)
        self.assertTrue(artifact["lesson_set_id"].startswith("set-"))
        self.assertTrue(all(lesson["lesson_id"].startswith("lesson-") for lesson in artifact["lessons"]))

        receipt = results[0]["promotion_receipt"]
        self.assertEqual(receipt["active_lesson_set_id"], artifact["lesson_set_id"])
        self.assertEqual(receipt["lesson_ids"], [lesson["lesson_id"] for lesson in artifact["lessons"]])
        self.assertEqual(receipt["synthesis_input_sha256"], canonical_sha256(synthesis_input))
        self.assertEqual(receipt["lint_report_sha256"], canonical_sha256(lint_report))

        # Given
        forged_lint = copy.deepcopy(lint_report)
        forged_lint["support"] = {}
        forged_transcript = copy.deepcopy(transcript)
        forged_transcript["lint_report"] = forged_lint
        forged_transcript["lint_report_sha256"] = canonical_sha256(forged_lint)
        # When
        with self.assertRaises(ValueError) as raised:
            promote_candidate(
                synthesis_input,
                development_bundle,
                self.rules,
                forged_transcript,
                forged_lint,
            )

        # Then
        self.assertRegex(str(raised.exception), "deterministic recomputation")

    def test_builder_rejects_a_cardinality_preserving_held_out_substitution(self) -> None:
        # Given
        regression_fixtures = _actual_fixtures("regression")
        regression_bundle = _development_bundle(
            _records(regression_fixtures, ("clean",)),
            regression_fixtures,
        )
        removed_fixture_id = self.sources[-1]["fixture_id"]
        held_out_fixture_id = regression_bundle["sources"][0]["fixture_id"]
        sources = self.sources[:-1] + [regression_bundle["sources"][0]]
        golds = self.golds[:-1] + [regression_bundle["golds"][0]]
        runs = [
            run for run in self.runs if run["fixture_id"] != removed_fixture_id
        ] + [
            run
            for run in regression_bundle["runs"]
            if run["fixture_id"] == held_out_fixture_id
        ]
        self.assertEqual((len(runs), len(sources), len(golds)), (18, 6, 6))

        # When
        with self.assertRaises(ValueError) as raised:
            build_synthesis_input(
                runs,
                sources,
                golds,
                self.error_codes,
                self.templates,
                self.lesson_schema,
                self.rules,
                FEEDBACK_GENERATOR_DIGEST,
            )

        # Then
        self.assertRegex(str(raised.exception), "only the six development")

    def test_promotion_requires_complete_exact_synthesis_provenance(self) -> None:
        # Given
        synthesis_input = self._build()
        candidate = _valid_lesson_candidate(
            synthesis_input["selected_target_classes"]
        )
        lint_report = lint_candidate(
            candidate,
            synthesis_input["selected_target_classes"],
            self.runs,
            self.sources,
            self.golds,
            self.rules,
        )
        bundle = {"runs": self.runs, "sources": self.sources, "golds": self.golds}
        transcript = _synthesis_transcript(synthesis_input, candidate, lint_report)

        transport_retry = copy.deepcopy(transcript)
        transport_retry["attempts"] = [
            {
                "attempt_index": 1,
                "attempt_id": "synthesis-attempt-transport",
                "process_uuid": None,
                "conversation_id": None,
                "runtime_outcome": "transport_failure",
                "raw_output": None,
            },
            {
                **transport_retry["attempts"][0],
                "attempt_index": 2,
            },
        ]

        # When
        promoted = promote_candidate(
            synthesis_input,
            bundle,
            self.rules,
            transport_retry,
            lint_report,
        )

        # Then
        self.assertEqual(promoted["candidate"], candidate)

        def append_second_candidate(value: dict) -> None:
            value["attempts"].append(
                {
                    "attempt_index": 2,
                    "attempt_id": "synthesis-attempt-2",
                    "process_uuid": "synthesis-process-2",
                    "conversation_id": "synthesis-conversation-2",
                    "runtime_outcome": "completed",
                    "raw_output": dumps(candidate).rstrip("\n"),
                }
            )

        def reuse_retry_identity(value: dict) -> None:
            completed = value["attempts"][0]
            value["attempts"] = [
                {
                    "attempt_index": 1,
                    "attempt_id": "synthesis-attempt-transport",
                    "process_uuid": completed["process_uuid"],
                    "conversation_id": completed["conversation_id"],
                    "runtime_outcome": "transport_failure",
                    "raw_output": None,
                },
                {**completed, "attempt_index": 2},
            ]

        mutations = (
            ("unknown_field", lambda value: value.update(human_edited=False), "unknown or missing fields"),
            ("prompt", lambda value: value.update(synthesis_prompt="changed"), "identity or attempt count"),
            ("input", lambda value: value.update(synthesis_input={}), "identity or attempt count"),
            ("selected_classes", lambda value: value.update(selected_target_classes=[]), "identity or attempt count"),
            ("feedback_version", lambda value: value.update(feedback_generator_version="other"), "identity or attempt count"),
            ("feedback_digest", lambda value: value.update(feedback_generator_sha256="0" * 64), "identity or attempt count"),
            ("provider", lambda value: value.update(provider_reference="other"), "identity or attempt count"),
            ("wire_model", lambda value: value.update(wire_model="other"), "identity or attempt count"),
            ("attempt_identity", lambda value: value["attempts"][0].update(process_uuid=None), "transport_failure or completed"),
            ("retry_identity_reuse", reuse_retry_identity, "fresh process"),
            ("lint", lambda value: value.update(lint_report={}), "identity or attempt count"),
            ("no_candidate", lambda value: value.update(attempts=[]), "identity or attempt count"),
            ("second_candidate", append_second_candidate, "exactly one semantic candidate"),
        )

        for name, mutate, expected_error in mutations:
            with self.subTest(mutant=name):
                broken = copy.deepcopy(transcript)
                mutate(broken)

                # When
                with self.assertRaises(ValueError) as raised:
                    promote_candidate(
                        synthesis_input,
                        bundle,
                        self.rules,
                        broken,
                        lint_report,
                    )

                # Then
                self.assertRegex(str(raised.exception), expected_error)

    def test_linter_enforces_each_frozen_prohibition_category(self) -> None:
        # Given
        selected = self._build()["selected_target_classes"]
        valid = _valid_lesson_candidate(selected)

        long_candidate = copy.deepcopy(valid)
        for lesson in long_candidate["lessons"]:
            stem = lesson["text"][:-1]
            while len(stem) < 340:
                stem += " and context remains stable"
            lesson["text"] = stem + "."
        self.assertGreater(
            sum(len(lesson["text"]) for lesson in long_candidate["lessons"]),
            1_000,
        )

        categorical_mutations = (
            ("total", long_candidate, "lesson.total_length", None),
            (
                "nfkc",
                {
                    **copy.deepcopy(valid),
                    "lessons": [
                        {
                            **copy.deepcopy(valid["lessons"][0]),
                            "text": valid["lessons"][0]["text"].replace("volatile", "ｖolatile"),
                        },
                        *copy.deepcopy(valid["lessons"][1:]),
                    ],
                },
                "lesson.non_nfkc",
                None,
            ),
            (
                "forbidden_pattern",
                self._candidate_with_suffix(valid, " and level 7"),
                "lesson.forbidden_pattern",
                None,
            ),
            (
                "not_rule",
                self._candidate_with_text(
                    valid,
                    "Observe volatile counters as cosmetic when meaning is preserved.",
                ),
                "lesson.not_rule",
                None,
            ),
            (
                "dynamic_identifier",
                self._candidate_with_suffix(valid, " across subscription-pricing"),
                "lesson.example_leakage",
                "fixture_task_region_atom_mechanism_and_family_ids",
            ),
            (
                "dynamic_selector",
                self._candidate_with_suffix(valid, " within pricing-shell"),
                "lesson.example_leakage",
                "urls_and_html_selector_values",
            ),
            (
                "dynamic_proper_phrase",
                self._candidate_with_suffix(valid, " for OrbitDesk"),
                "lesson.example_leakage",
                "before_after_literals_and_derived_proper_phrases",
            ),
        )

        for name, candidate, expected_code, expected_category in categorical_mutations:
            with self.subTest(mutant=name):
                # When
                report = lint_candidate(
                    candidate,
                    selected,
                    self.runs,
                    self.sources,
                    self.golds,
                    self.rules,
                )

                # Then
                matching = [
                    error for error in report["errors"] if error["code"] == expected_code
                ]
                self.assertTrue(matching, report["errors"])
                if expected_category is not None:
                    self.assertIn(
                        expected_category,
                        {error.get("category") for error in matching},
                    )

    @staticmethod
    def _candidate_with_suffix(candidate: dict, suffix: str) -> dict:
        mutated = copy.deepcopy(candidate)
        mutated["lessons"][0]["text"] = (
            mutated["lessons"][0]["text"][:-1] + suffix + "."
        )
        return mutated

    @staticmethod
    def _candidate_with_text(candidate: dict, text: str) -> dict:
        mutated = copy.deepcopy(candidate)
        mutated["lessons"][0]["text"] = text
        return mutated

    def test_builder_rejects_incomplete_runs(self) -> None:
        # Given
        incomplete = copy.deepcopy(self.runs[:-1])

        # When
        with self.assertRaises(ValueError) as raised:
            build_synthesis_input(
                incomplete,
                self.sources,
                self.golds,
                self.error_codes,
                self.templates,
                self.lesson_schema,
                self.rules,
                FEEDBACK_GENERATOR_DIGEST,
            )

        # Then
        self.assertRegex(str(raised.exception), "exactly 18")

if __name__ == "__main__":
    unittest.main()
