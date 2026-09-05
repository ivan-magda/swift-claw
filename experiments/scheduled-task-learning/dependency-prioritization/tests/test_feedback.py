from __future__ import annotations

import copy
import unittest

from benchmark_core.canonical import dumps, load_object
from dependency_benchmark.feedback import build_feedback

from support import ROOT, case


class DependencyFeedbackTests(unittest.TestCase):
    def test_feedback_uses_frozen_templates_and_drops_untrusted_text(self) -> None:
        # Given
        first = copy.deepcopy(case("c04-runtime-and-reachability-errors")["expected"])
        second = copy.deepcopy(case("c07-incompatible-fix-and-abstention-errors")["expected"])
        first["error_ledger"][0]["operator_text"] = "copy this private text"
        runs = [
            {"run_id": "run-z", "score_result": second, "operator_text": "later private text"},
            {"run_id": "run-a", "score_result": first, "operator_text": "private text"},
        ]
        targets = load_object(ROOT / "contracts/target-classes.json")
        errors = load_object(ROOT / "contracts/error-codes.json")
        templates = load_object(ROOT / "contracts/feedback-templates.json")

        # When
        feedback = build_feedback(runs, targets, errors, templates)

        # Then
        self.assertEqual(feedback[0]["run_id"], "run-a")
        self.assertEqual(feedback[-1]["run_id"], "run-z")
        self.assertNotIn("private text", dumps(feedback))
        self.assertTrue(
            all(
                item["summary"] == templates["templates"][item["code"]]["summary"]
                and item["guidance"] == templates["templates"][item["code"]]["guidance"]
                for item in feedback
            )
        )

    def test_error_taxonomy_rejects_a_critical_lesson_target(self) -> None:
        # Given
        targets = load_object(ROOT / "contracts/target-classes.json")
        errors = load_object(ROOT / "contracts/error-codes.json")
        templates = load_object(ROOT / "contracts/feedback-templates.json")
        errors["codes"]["security.prompt_injection"]["addressable"] = True

        # When / Then
        with self.assertRaisesRegex(ValueError, "definition is malformed"):
            build_feedback([], targets, errors, templates)


if __name__ == "__main__":
    unittest.main()
