"""Full page receipts and generic-safe neutral envelopes."""

from __future__ import annotations

import unittest

from benchmark_core.canonical import canonical_sha256

from page_change_m3 import build_adapter_receipt

from . import support


class AdapterReceiptTests(unittest.TestCase):
    def test_envelope_is_neutral_and_binds_each_identity(self) -> None:
        # given
        candidate_digest = "b" * 64
        pairs = [support.scored_pair(80, 90), support.scored_pair(80, 90)]

        # when
        receipt, envelope = build_adapter_receipt(candidate_digest, pairs)

        # then
        self.assertEqual(
            set(envelope),
            {
                "adapter_id",
                "adapter_version",
                "candidate_digest",
                "dataset_digest",
                "oracle_digest",
                "gates_digest",
                "execution_surface_digest",
                "outcome",
                "receipt_digest",
            },
        )
        self.assertEqual(envelope["candidate_digest"], candidate_digest)
        self.assertEqual(envelope["receipt_digest"], canonical_sha256(receipt))
        self.assertNotIn("pairs", envelope)
        self.assertEqual(envelope["adapter_id"], "page-change-m3")
        self.assertEqual(envelope["adapter_version"], "1.0.0")
        for field in (
            "dataset_digest",
            "oracle_digest",
            "gates_digest",
            "execution_surface_digest",
        ):
            value = envelope[field]
            self.assertIsInstance(value, str)
            assert isinstance(value, str)
            self.assertRegex(value, r"^[0-9a-f]{64}$")

    def test_receipt_digest_hashes_the_full_receipt_not_the_neutral_envelope(self) -> None:
        # given
        pairs = [support.scored_pair(80, 90), support.scored_pair(80, 90)]

        # when
        receipt, envelope = build_adapter_receipt("c" * 64, pairs)
        _, changed_candidate = build_adapter_receipt("d" * 64, pairs)

        # then
        self.assertEqual(envelope["receipt_digest"], canonical_sha256(receipt))
        self.assertEqual(envelope["receipt_digest"], changed_candidate["receipt_digest"])


if __name__ == "__main__":
    unittest.main()
