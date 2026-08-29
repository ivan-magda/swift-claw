"""Adapter gate outcomes over trusted sealed page-score pairs."""

from __future__ import annotations

import unittest

from page_change_m3 import build_adapter_receipt

from . import support

_CANDIDATE_DIGEST = "a" * 64


class AdapterGateTests(unittest.TestCase):
    def test_adapter_reports_each_distinct_gate_outcome(self) -> None:
        # given
        cases = (
            ("threshold_pass", [support.scored_pair(80, 90), support.scored_pair(80, 90)], "pass"),
            (
                "three_pair_pass",
                [
                    support.scored_pair(80, 90),
                    support.scored_pair(80, 90),
                    support.scored_pair(80, 90),
                ],
                "pass",
            ),
            (
                "candidate_below_threshold",
                [support.scored_pair(80, 89), support.scored_pair(80, 90)],
                "regression",
            ),
            (
                "critical_result",
                [support.scored_pair(80, 90, candidate_critical=True), support.scored_pair(80, 90)],
                "critical",
            ),
            (
                "negative_delta",
                [support.scored_pair(91, 90), support.scored_pair(80, 90)],
                "regression",
            ),
            ("fewer_than_two_pairs", [support.scored_pair(80, 90)], "regression"),
            (
                "mean_below_threshold",
                [support.scored_pair(81, 90), support.scored_pair(80, 90)],
                "regression",
            ),
            (
                "four_pairs",
                [
                    support.scored_pair(80, 90),
                    support.scored_pair(80, 90),
                    support.scored_pair(80, 90),
                    support.scored_pair(80, 90),
                ],
                "regression",
            ),
        )

        # when / then
        for name, pairs, expected_outcome in cases:
            with self.subTest(case=name):
                receipt, envelope = build_adapter_receipt(_CANDIDATE_DIGEST, pairs)
                self.assertEqual(receipt["outcome"], expected_outcome)
                self.assertEqual(envelope["outcome"], expected_outcome)


if __name__ == "__main__":
    unittest.main()
