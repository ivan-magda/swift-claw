"""Operator-facing contract for the preserved historical run."""

from __future__ import annotations

import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from scheduled_learning_v1.run import main


class ArchivalContractTests(unittest.TestCase):
    def test_readme_marks_head_archival_and_requires_a_fresh_freeze_and_authorization(self) -> None:
        # given
        root = Path(__file__).resolve().parents[1]

        # when
        readme = (root / "README.md").read_text(encoding="utf-8").lower()

        # then
        self.assertIn("archival head", readme)
        self.assertIn("fresh freeze", readme)
        self.assertIn("new explicit owner authorization", readme)
        self.assertNotIn("the live scored command is deliberately separate", readme)

    def test_cli_help_marks_archival_head_ineligible_for_scored_execution(self) -> None:
        # given
        root_output = io.StringIO()
        scored_output = io.StringIO()

        # when
        with redirect_stdout(root_output), self.assertRaises(SystemExit) as root_exit:
            main(["--help"])
        with redirect_stdout(scored_output), self.assertRaises(SystemExit) as scored_exit:
            main(["scored", "--help"])
        root_help = " ".join(root_output.getvalue().lower().split())
        scored_help = " ".join(scored_output.getvalue().lower().split())

        # then
        self.assertEqual(root_exit.exception.code, 0)
        self.assertEqual(scored_exit.exception.code, 0)
        self.assertIn("archival m3 evidence", root_help)
        self.assertIn("fresh freeze", root_help)
        self.assertIn("new explicit owner authorization", root_help)
        self.assertIn("archival head is ineligible", scored_help)
        self.assertIn("newly frozen", scored_help)
        self.assertIn("newly authorized", scored_help)

    def test_validation_protocol_records_the_post_run_archival_ruling(self) -> None:
        # given
        repository = Path(__file__).resolve().parents[4]

        # when
        protocol = (repository / "docs/research/172-validation-protocol.md").read_text(
            encoding="utf-8"
        )
        _, ruling = protocol.split("## Post-run archival ruling", maxsplit=1)
        ruling = " ".join(ruling.lower().split())

        # then
        self.assertIn("post-run hardening revision is archival", ruling)
        self.assertIn("do not verify or authorize the current source bytes", ruling)
        self.assertIn("fresh freeze", ruling)
        self.assertIn("new explicit owner authorization", ruling)


if __name__ == "__main__":
    unittest.main()
