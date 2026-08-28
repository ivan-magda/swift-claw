from __future__ import annotations

import unittest

from tools.page_change_freeze import contract


class ContractTests(unittest.TestCase):
    def test_json_loader_rejects_duplicate_object_keys(self) -> None:
        # given
        raw = b'{"decision":"D6","decision":"other"}'

        # when
        with self.assertRaises(contract.FreezeError) as raised:
            contract.load_json_bytes(raw, location="duplicate fixture")

        # then
        self.assertRegex(str(raised.exception), "duplicate JSON key")

    def test_normalized_path_rejects_parent_traversal(self) -> None:
        # given
        candidate = "experiments/scheduled-task-learning/../escape.json"

        # when
        with self.assertRaises(contract.FreezeError) as raised:
            contract.normalized_path(candidate, location="fixture path")

        # then
        self.assertRegex(str(raised.exception), "repository-relative path")


if __name__ == "__main__":
    unittest.main()
