"""Evaluator/reflector carrier visibility: closed exclusions and exact nested key sets."""

from __future__ import annotations

import unittest

from page_change_m3 import build_evaluator_carrier, build_reflector_carrier, materialize_task

from . import support

_FORBIDDEN_EVALUATOR_FIELDS = {
    "active_lessons",
    "lessons",
    "candidate_digest",
    "trial",
    "score",
    "gold",
    "oracle",
}
_FORBIDDEN_REFLECTOR_FIELDS = {
    "candidate_digest",
    "trial",
    "score",
    "gold",
    "oracle",
    "promotion",
    "expected_direction",
}


class EvaluatorCarrierVisibilityTests(unittest.TestCase):
    def test_evaluator_carrier_excludes_lessons_and_scoring_context(self) -> None:
        # given
        source = support.real_fresh_source("pc-development-07", "development")
        task = materialize_task(source, ["Ignore volatile counters."])

        # when
        carrier = build_evaluator_carrier(task, "raw model completion text")

        # then
        self.assertTrue(_FORBIDDEN_EVALUATOR_FIELDS.isdisjoint(carrier))

    def test_evaluator_carrier_has_the_exact_top_level_and_run_key_sets(self) -> None:
        # given
        source = support.real_fresh_source("pc-development-08", "development")
        task = materialize_task(source, [])

        # when
        carrier = build_evaluator_carrier(task, "raw model completion text")

        # then
        self.assertEqual(set(carrier), {"schema_version", "task_id", "task", "raw_output", "run"})
        self.assertEqual(set(carrier["run"]), {"run_id"})
        self.assertNotIn("candidate_digest", carrier["run"])

    def test_evaluator_carrier_never_leaks_the_task_carriers_active_lessons(self) -> None:
        # given
        source = support.real_fresh_source("pc-regression-06", "regression")
        task = materialize_task(source, ["A lesson that must not reach the evaluator."])

        # when
        carrier = build_evaluator_carrier(task, "raw output")

        # then
        self.assertNotIn("active_lessons", carrier)
        self.assertNotIn("A lesson that must not reach the evaluator.", str(carrier))


class ReflectorCarrierVisibilityTests(unittest.TestCase):
    def test_reflector_carrier_excludes_candidate_and_scoring_context(self) -> None:
        # given
        evaluations = [
            {
                "task_id": "page-17a3e9219b0e",
                "outcome": "reusable_issue",
                "issue_codes": ["dup-noise"],
            }
        ]

        # when
        carrier = build_reflector_carrier(
            ["Treat volatile counters as noise."], evaluations, ["dup-noise"], ["owner note"]
        )

        # then
        self.assertTrue(_FORBIDDEN_REFLECTOR_FIELDS.isdisjoint(carrier))

    def test_reflector_carrier_strips_an_oracle_field_from_an_evaluation_summary(self) -> None:
        # given
        evaluations = [
            {
                "task_id": "page-17a3e9219b0e",
                "outcome": "reusable_issue",
                "issue_codes": ["dup-noise"],
                "oracle": {"expected_verdict": "none"},
                "score": 42,
            }
        ]

        # when
        carrier = build_reflector_carrier(
            ["Treat volatile counters as noise."], evaluations, ["dup-noise"], []
        )

        # then
        self.assertEqual(set(carrier["evaluations"][0]), {"task_id", "outcome", "issue_codes"})
        self.assertNotIn("oracle", carrier["evaluations"][0])
        self.assertNotIn("score", carrier["evaluations"][0])

    def test_reflector_carrier_has_the_exact_top_level_key_set(self) -> None:
        # given / when
        carrier = build_reflector_carrier(["A stable lesson."], [], [], [])

        # then
        self.assertEqual(
            set(carrier),
            {"schema_version", "stable_lessons", "evaluations", "issue_codes", "owner_payloads"},
        )

    def test_reflector_carrier_fences_stable_lessons_and_owner_payloads_as_untrusted(self) -> None:
        # given / when
        carrier = build_reflector_carrier(["A stable lesson."], [], [], ["An owner-provided note."])

        # then
        self.assertIn("A stable lesson.", carrier["stable_lessons"][0])
        self.assertNotEqual(carrier["stable_lessons"][0], "A stable lesson.")
        self.assertIn("An owner-provided note.", carrier["owner_payloads"][0])
        self.assertNotEqual(carrier["owner_payloads"][0], "An owner-provided note.")


if __name__ == "__main__":
    unittest.main()
