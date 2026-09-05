"""The committed Swift admission fixture is exact production Python output."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tests.interop.emit_task_admission_fixture import emit_fixture


class TaskAdmissionFixtureTests(unittest.TestCase):
    def test_committed_fixture_matches_fresh_operations_output(self) -> None:
        # given
        repository = Path(__file__).resolve().parents[5]
        committed = Path(__file__).resolve().parent / "task-admission-fixture"

        # when
        with tempfile.TemporaryDirectory() as temporary:
            reproduced = Path(temporary) / "fixture"
            emit_fixture(repository, reproduced)
            committed_files = _files(committed)
            reproduced_files = _files(reproduced)

            # then
            self.assertEqual(reproduced_files, committed_files)
            for relative in committed_files:
                self.assertEqual(
                    (reproduced / relative).read_bytes(),
                    (committed / relative).read_bytes(),
                    relative,
                )


def _files(root: Path) -> list[Path]:
    return sorted(path.relative_to(root) for path in root.rglob("*") if path.is_file())


if __name__ == "__main__":
    unittest.main()
