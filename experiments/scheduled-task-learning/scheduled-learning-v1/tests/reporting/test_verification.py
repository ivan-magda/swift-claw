"""Offline verification rehashes every committed event."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from scheduled_learning_v1.reporting import verify_results

from .support import result_tree


class ResultVerificationTests(unittest.TestCase):
    def test_valid_tree_verifies_offline(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = result_tree(root)

            # when
            receipt = verify_results(root, manifest)

            # then
            self.assertEqual(receipt["status"], "verified")

    def test_changed_event_byte_is_rejected(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = result_tree(root)
            event_path = next((root / "results" / "events").glob("0*.json"))
            event_path.write_text(event_path.read_text(encoding="utf-8") + " ", encoding="utf-8")

            # when / then
            with self.assertRaises(ValueError):
                verify_results(root, manifest)


if __name__ == "__main__":
    unittest.main()
