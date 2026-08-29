"""Full page receipts and generic-safe neutral envelopes."""

from __future__ import annotations

import unittest

from benchmark_core.canonical import canonical_sha256

from page_change_m3 import build_adapter_receipt

from . import support


class AdapterReceiptTests(unittest.TestCase):
    def test_envelope_is_neutral_and_binds_each_identity(self) -> None:
        # given
        candidate_lessons = ["  Treat volatile counters as noise.\r\n"]
        pairs = [support.scored_pair(80, 90), support.scored_pair(80, 90)]

        # when
        receipt, envelope = build_adapter_receipt(candidate_lessons, pairs)

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
        self.assertEqual(
            envelope["candidate_digest"],
            canonical_sha256(
                {"schema_version": 1, "lessons": ["Treat volatile counters as noise."]}
            ),
        )
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

    def test_candidate_digest_is_derived_from_the_frozen_replacement_lessons(self) -> None:
        # given
        pairs = [support.scored_pair(80, 90), support.scored_pair(80, 90)]
        candidate_record_digest = canonical_sha256({"candidate_record": "forged"})

        # when
        _, envelope = build_adapter_receipt(["  Preserve exact order.\r\n"], pairs)

        # then
        self.assertEqual(
            envelope["candidate_digest"],
            canonical_sha256({"schema_version": 1, "lessons": ["Preserve exact order."]}),
        )
        self.assertNotEqual(envelope["candidate_digest"], candidate_record_digest)

    def test_envelope_binds_each_changed_frozen_identity_independently(self) -> None:
        # given
        pairs = [support.scored_pair(80, 90), support.scored_pair(80, 90)]
        identities = {
            "adapter_id": "page-change-m3",
            "adapter_version": "1.0.0",
            "dataset_digest": "a" * 64,
            "oracle_digest": "b" * 64,
            "gates_digest": "c" * 64,
            "execution_surface_digest": "d" * 64,
        }
        changes: tuple[tuple[str, object], ...] = (
            ("adapter_id", "page-change-m3-alt"),
            ("adapter_version", "1.0.1"),
            ("dataset_digest", "e" * 64),
            ("oracle_digest", "e" * 64),
            ("gates_digest", "e" * 64),
            ("execution_surface_digest", "e" * 64),
            ("candidate_digest", ["A changed frozen lesson."]),
        )

        # when / then
        for field, changed_value in changes:
            with self.subTest(field=field):
                changed_identities = dict(identities)
                lessons = ["The frozen candidate lesson."]
                if field == "candidate_digest":
                    assert isinstance(changed_value, list)
                    lessons = changed_value
                else:
                    assert isinstance(changed_value, str)
                    changed_identities[field] = changed_value
                _, envelope = build_adapter_receipt(lessons, pairs, changed_identities)
                expected = (
                    canonical_sha256({"schema_version": 1, "lessons": lessons})
                    if field == "candidate_digest"
                    else changed_value
                )
                self.assertEqual(envelope[field], expected)

    def test_receipt_digest_hashes_the_full_receipt_not_the_neutral_envelope(self) -> None:
        # given
        pairs = [support.scored_pair(80, 90), support.scored_pair(80, 90)]
        identities = {
            "adapter_id": "page-change-m3",
            "adapter_version": "1.0.0",
            "dataset_digest": "a" * 64,
            "oracle_digest": "b" * 64,
            "gates_digest": "c" * 64,
            "execution_surface_digest": "d" * 64,
        }

        # when
        receipt, envelope = build_adapter_receipt(["A frozen candidate lesson."], pairs, identities)
        _, changed_identity = build_adapter_receipt(
            ["A frozen candidate lesson."],
            pairs,
            {**identities, "execution_surface_digest": "e" * 64},
        )

        # then
        self.assertEqual(envelope["receipt_digest"], canonical_sha256(receipt))
        self.assertEqual(envelope["receipt_digest"], changed_identity["receipt_digest"])


if __name__ == "__main__":
    unittest.main()
