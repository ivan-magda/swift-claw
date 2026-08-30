"""Current-tree contract for a fresh unapproved scheduled-learning run."""

from __future__ import annotations

import unittest
from pathlib import Path


class FreshRunReadinessContractTests(unittest.TestCase):
    def test_current_tree_excludes_historical_owner_approval_and_results(self) -> None:
        # given
        root = Path(__file__).resolve().parents[1]
        historical_outputs = {
            "owner approval": root / "freeze" / "owner-budget-approval.json",
            "results": root / "results",
        }

        # when
        observed = {name: path.exists() for name, path in historical_outputs.items()}

        # then
        for name, exists in observed.items():
            with self.subTest(name=name):
                self.assertFalse(exists)


if __name__ == "__main__":
    unittest.main()
