from __future__ import annotations

import unittest
from collections import Counter

from dependency_benchmark.oracle import (
    recoverable_gain,
    select_target_codes,
    split_headroom,
    transform_output,
)

from support import case, case_output, contracts, fixture


class DependencyOracleTests(unittest.TestCase):
    def test_each_target_transform_changes_only_its_frozen_fields(self) -> None:
        # Given
        scenarios = {
            "policy.runtime_scope": "c04-runtime-and-reachability-errors",
            "policy.reachability": "c04-runtime-and-reachability-errors",
            "policy.remediation": "c07-incompatible-fix-and-abstention-errors",
            "policy.abstention": "c07-incompatible-fix-and-abstention-errors",
            "policy.ranking": "c08-ranking-and-evidence-omission",
        }
        owned_fields = {
            "policy.runtime_scope": {"actionability"},
            "policy.reachability": {"actionability"},
            "policy.remediation": {"remediation_disposition", "selected_option_id"},
            "policy.abstention": {
                "actionability",
                "remediation_disposition",
                "selected_option_id",
            },
            "policy.ranking": set(),
        }
        ranking, targets, errors = contracts()

        for target_code, case_id in scenarios.items():
            with self.subTest(target_code=target_code):
                case_value = case(case_id)
                fixture_value = fixture(case_value["fixture_id"])
                output = case_output(case_id)

                # When
                transformed = transform_output(output, fixture_value["gold"], [target_code])
                gain = recoverable_gain(
                    fixture_value["source"],
                    fixture_value["gold"],
                    output,
                    [target_code],
                    ranking,
                    targets,
                    errors,
                )

                # Then
                self.assertGreater(gain, 0.0)
                self.assertNotEqual(output, transformed)
                original_by_id = {row["finding_id"]: row for row in output["findings"]}
                transformed_by_id = {row["finding_id"]: row for row in transformed["findings"]}
                gold_by_id = {row["finding_id"]: row for row in fixture_value["gold"]["findings"]}
                for finding_id, original in original_by_id.items():
                    label = gold_by_id[finding_id]
                    mutable_fields = set()
                    if label["actionability"]["target_class"] == target_code:
                        mutable_fields.add("actionability")
                    if label["remediation"]["target_class"] == target_code:
                        mutable_fields.update({"remediation_disposition", "selected_option_id"})
                    for field, original_value in original.items():
                        if field not in owned_fields[target_code] or field not in mutable_fields:
                            self.assertEqual(transformed_by_id[finding_id][field], original_value)
                original_queue = output["remediation_queue"]
                transformed_queue = transformed["remediation_queue"]
                if target_code in {
                    "policy.runtime_scope",
                    "policy.reachability",
                    "policy.abstention",
                }:
                    target_owned_ids = {
                        row["finding_id"]
                        for row in fixture_value["gold"]["findings"]
                        if row["queue"]["target_class"] == target_code
                    }
                    self.assertLessEqual(
                        set(original_queue) ^ set(transformed_queue),
                        target_owned_ids,
                    )
                    self.assertEqual(len(transformed_queue), len(set(transformed_queue)))
                    transformed_ids = set(transformed_queue)
                    original_ids = set(original_queue)
                    self.assertEqual(
                        [item for item in transformed_queue if item in original_ids],
                        [item for item in original_queue if item in transformed_ids],
                    )
                elif target_code == "policy.remediation":
                    self.assertEqual(transformed_queue, original_queue)
                else:
                    self.assertEqual(Counter(transformed_queue), Counter(original_queue))
                self.assertEqual(output, case_output(case_id))

        ranking_output = case_output("c08-ranking-and-evidence-omission")
        non_gold_id = "finding-deadbeef00"
        non_gold_position = 1
        ranking_output["remediation_queue"].insert(non_gold_position, non_gold_id)

        ranked = transform_output(
            ranking_output,
            fixture("dp-development-01")["gold"],
            ["policy.ranking"],
        )

        self.assertEqual(
            Counter(ranked["remediation_queue"]),
            Counter(ranking_output["remediation_queue"]),
        )
        self.assertEqual(ranked["remediation_queue"][non_gold_position], non_gold_id)

    def test_split_headroom_uses_fixture_medians_before_the_cross_fixture_mean(self) -> None:
        # Given
        gains = [
            {"fixture_id": "fixture-a", "gain": 0.0},
            {"fixture_id": "fixture-a", "gain": 0.0},
            {"fixture_id": "fixture-a", "gain": 90.0},
            {"fixture_id": "fixture-b", "gain": 30.0},
            {"fixture_id": "fixture-b", "gain": 30.0},
            {"fixture_id": "fixture-b", "gain": 30.0},
        ]

        # When
        result = split_headroom(gains)

        # Then
        self.assertEqual(result, 15.0)

    def test_target_selection_requires_two_replicates_and_two_families(self) -> None:
        # Given
        target_order = [
            "policy.runtime_scope",
            "policy.reachability",
            "policy.remediation",
            "policy.abstention",
            "policy.ranking",
        ]
        stable_codes = {
            "policy.runtime_scope": 10.0,
            "policy.reachability": 12.0,
            "policy.abstention": 12.0,
            "policy.ranking": 50.0,
        }
        runs = []
        for family_id in ("family-a", "family-b"):
            for replicate in (1, 2):
                ledger = [
                    {"code": code, "policy_points_lost": loss}
                    for code, loss in stable_codes.items()
                ]
                if family_id == "family-a" or replicate == 1:
                    ledger.append({"code": "policy.remediation", "policy_points_lost": 100.0})
                runs.append(
                    {
                        "family_id": family_id,
                        "replicate": replicate,
                        "score_result": {"error_ledger": ledger},
                    }
                )

        # When
        selected = select_target_codes(list(reversed(runs)), target_order)

        # Then
        self.assertEqual(
            selected,
            ["policy.ranking", "policy.reachability", "policy.abstention"],
        )


if __name__ == "__main__":
    unittest.main()
