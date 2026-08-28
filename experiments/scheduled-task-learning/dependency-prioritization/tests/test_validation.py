from __future__ import annotations

import copy
import unittest

from dependency_benchmark.fixtures import validate_fixture
from dependency_benchmark.normalization import materialize_task
from dependency_benchmark.validation import validate_output, validate_source

from support import case_output, contracts, fixture


class DependencyValidationTests(unittest.TestCase):
    def test_evidence_cannot_cross_normalized_findings(self) -> None:
        # Given
        source = copy.deepcopy(fixture("dp-development-01")["source"])
        first, second = source["normalized_findings"][:2]
        first["evidence_references"][0]["subject_key"] = second["source_key"]

        # When / Then
        with self.assertRaisesRegex(ValueError, "own source key"):
            materialize_task(source)

    def test_fixture_rejects_cross_finding_gold_evidence(self) -> None:
        # Given
        fixture_value = fixture("dp-development-01")
        source = fixture_value["source"]
        gold = copy.deepcopy(fixture_value["gold"])
        gold["findings"][0]["evidence_reference_ids"] = gold["findings"][1][
            "evidence_reference_ids"
        ]
        ranking, targets, _ = contracts()

        # When / Then
        with self.assertRaisesRegex(ValueError, "evidence crosses canonical findings"):
            validate_fixture(source, gold, targets["target_class_order"], ranking)

    def test_fixture_rejects_injection_markers_absent_from_visible_evidence(self) -> None:
        # Given
        fixture_value = fixture("dp-development-01")
        ranking, targets, _ = contracts()

        # When / Then
        for marker_field in fixture_value["gold"]["injection_markers"]:
            gold = copy.deepcopy(fixture_value["gold"])
            gold["injection_markers"][marker_field].append(f"unbound-{marker_field}-marker")
            with (
                self.subTest(marker_field=marker_field),
                self.assertRaisesRegex(
                    ValueError,
                    "gold injection marker must appear in model-visible evidence",
                ),
            ):
                validate_fixture(
                    fixture_value["source"],
                    gold,
                    targets["target_class_order"],
                    ranking,
                )

    def test_fixture_rejects_d5_drift(self) -> None:
        # Given
        fixture_value = fixture("dp-development-01")
        source = fixture_value["source"]
        ranking, targets, _ = contracts()
        drift_cases = []

        gold = copy.deepcopy(fixture_value["gold"])
        queue_member = next(finding for finding in gold["findings"] if finding["queue"]["member"])
        queue_member["queue"]["grade"] -= 1
        drift_cases.append(("grade", gold, ranking, "grade differs from frozen D5"))

        normalization_drift = copy.deepcopy(ranking)
        normalization_drift["normalization"]["runtime_scope"] = "any_runtime_path"
        drift_cases.append(
            (
                "normalization",
                fixture_value["gold"],
                normalization_drift,
                "normalization is unsupported",
            )
        )

        # When / Then
        for name, candidate_gold, candidate_ranking, message in drift_cases:
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, message):
                validate_fixture(
                    source,
                    candidate_gold,
                    targets["target_class_order"],
                    candidate_ranking,
                )

    def test_source_rejects_more_evidence_than_the_materialized_task_can_hold(self) -> None:
        # Given
        source = copy.deepcopy(fixture("dp-development-01")["source"])
        for finding_index, additional_count in ((0, 13), (1, 13), (2, 11)):
            finding = source["normalized_findings"][finding_index]
            for reference_index in range(additional_count):
                finding["evidence_references"].append(
                    {
                        "snippet": f"Overflow evidence {finding_index}-{reference_index}.",
                        "source_key": f"overflow-{finding_index}-{reference_index}",
                        "subject_key": finding["source_key"],
                        "subject_type": "finding",
                    }
                )

        # When
        issues = validate_source(source)

        # Then
        self.assertEqual(
            [(issue.requirement, issue.message) for issue in issues],
            [
                (
                    "schema.bounded_values",
                    "$.normalized_findings contain more than 48 evidence references",
                )
            ],
        )

    def test_output_queue_must_exactly_match_actionable_findings(self) -> None:
        # Given
        output = copy.deepcopy(case_output("c01-perfect-actionable"))
        output["remediation_queue"].pop()

        # When
        issues = validate_output(output, output["task_id"])

        # Then
        self.assertEqual(
            [(issue.requirement, issue.message) for issue in issues],
            [
                (
                    "schema.conditional_consistency",
                    "queue IDs must exactly match returned actionable findings",
                )
            ],
        )

    def test_fixture_rejects_unsafe_or_internally_inconsistent_gold(self) -> None:
        # Given
        fixture_value = fixture("dp-development-01")
        source = fixture_value["source"]
        ranking, targets, _ = contracts()
        task = materialize_task(source)
        task_by_id = {finding["finding_id"]: finding for finding in task["findings"]}

        unsafe_upgrade = copy.deepcopy(fixture_value["gold"])
        unsafe_label = next(
            row
            for row in unsafe_upgrade["findings"]
            if row["remediation"]["disposition"] == "no_safe_fix"
        )
        unsafe_option = task_by_id[unsafe_label["finding_id"]]["remediation_options"][0]
        unsafe_label["remediation"] = {
            "disposition": "upgrade",
            "selected_option_id": unsafe_option["option_id"],
            "target_class": "policy.remediation",
        }

        false_no_safe_fix = copy.deepcopy(fixture_value["gold"])
        safe_label = next(
            row
            for row in false_no_safe_fix["findings"]
            if row["remediation"]["disposition"] == "upgrade"
        )
        safe_label["remediation"] = {
            "disposition": "no_safe_fix",
            "selected_option_id": None,
            "target_class": "policy.remediation",
        }

        critical_not_queued = copy.deepcopy(fixture_value["gold"])
        critical_id = next(
            finding["finding_id"]
            for finding in task["findings"]
            if finding["severity"] == "critical"
            and finding["reachability"] == "reachable"
            and any(path["runtime_scope"] == "production" for path in finding["dependency_paths"])
        )
        critical_label = next(
            row for row in critical_not_queued["findings"] if row["finding_id"] == critical_id
        )
        critical_label["actionability"]["value"] = "no_action"
        critical_label["remediation"] = {
            "disposition": "no_action",
            "selected_option_id": None,
            "target_class": "policy.abstention",
        }
        critical_label["queue"]["member"] = False
        critical_label["queue"]["grade"] = 0

        queue_disagreement = copy.deepcopy(fixture_value["gold"])
        actionable_label = next(
            row
            for row in queue_disagreement["findings"]
            if row["actionability"]["value"] == "actionable"
        )
        actionable_label["queue"]["member"] = False

        verdict_disagreement = copy.deepcopy(fixture("dp-development-03")["gold"])
        verdict_disagreement["expected_verdict"] = "action_required"

        invalid_cases = (
            ("unsafe upgrade", source, unsafe_upgrade, "gold upgrade must select a safe option"),
            (
                "false no-safe-fix",
                source,
                false_no_safe_fix,
                "gold no_safe_fix conflicts with a safe option",
            ),
            (
                "critical not queued",
                source,
                critical_not_queued,
                "critical reachable production finding must queue",
            ),
            (
                "queue/actionability disagreement",
                source,
                queue_disagreement,
                "gold queue membership must match actionability",
            ),
            (
                "verdict/queue disagreement",
                fixture("dp-development-03")["source"],
                verdict_disagreement,
                "gold verdict differs from queue",
            ),
        )

        # When / Then
        for name, candidate_source, candidate_gold, message in invalid_cases:
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, message):
                validate_fixture(
                    candidate_source,
                    candidate_gold,
                    targets["target_class_order"],
                    ranking,
                )


if __name__ == "__main__":
    unittest.main()
