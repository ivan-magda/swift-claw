"""Trusted pair scoring must ignore model-supplied score claims."""

from __future__ import annotations

import copy
import unittest

from page_change_m3 import score_pair

from . import support


class PairScoringTests(unittest.TestCase):
    def test_pair_receipt_is_sealed_from_raw_attempts_not_embedded_score_claims(self) -> None:
        # given
        source = support.real_fresh_source("pc-regression-04", "regression")
        gold = support.real_fresh_gold("pc-regression-04", "regression")
        clean = {
            "source": source,
            "gold": gold,
            "attempt": support.complete_attempt(gold),
            "score": 0,
        }
        candidate = copy.deepcopy(clean)
        candidate["score"] = 1000

        # when
        pair = score_pair(clean, candidate)
        clean_result = pair["clean"]
        candidate_result = pair["candidate"]

        # then
        self.assertIsInstance(clean_result, dict)
        self.assertIsInstance(candidate_result, dict)
        assert isinstance(clean_result, dict)
        assert isinstance(candidate_result, dict)
        self.assertEqual(clean_result["score"], 100.0)
        self.assertEqual(candidate_result["score"], 100.0)
        self.assertEqual(pair["delta"], 0.0)
        self.assertNotEqual(candidate_result["score"], candidate["score"])
        self.assertIn("score_receipt_digest", candidate_result)


if __name__ == "__main__":
    unittest.main()
