"""Fresh-process promoted-digest handoff and restart fail-closed behavior."""

from __future__ import annotations

import io
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import cast
from unittest.mock import patch

from benchmark_core.canonical import load_object
from scheduled_learning_v1.execution.lifecycle import _launch_restart
from scheduled_learning_v1.run import main

from .support import frozen_tree, run_fake_scored


class RestartTests(unittest.TestCase):
    def test_scored_cli_accepts_exact_canonical_paths(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frozen_tree(root)
            dispatched: list[Path] = []

            def scored(path: Path) -> dict[str, object]:
                dispatched.append(path)
                return {"status": "complete"}

            # when
            output = io.StringIO()
            with patch("scheduled_learning_v1.run.run_scored", scored), redirect_stdout(output):
                main(
                    [
                        "scored",
                        "--root",
                        str(root),
                        "--manifest",
                        str(root / "freeze" / "manifest.json"),
                        "--approval",
                        str(root / "freeze" / "owner-budget-approval.json"),
                    ]
                )

            # then
            self.assertEqual(dispatched, [root.resolve()])
            self.assertEqual(output.getvalue(), "status=complete\n")

    def test_scored_cli_rejects_noncanonical_frozen_paths_before_dispatch(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frozen_tree(root)

            # when / then
            with (
                patch("scheduled_learning_v1.run.run_scored") as run_scored,
                self.assertRaises(ValueError),
            ):
                main(
                    [
                        "scored",
                        "--root",
                        str(root),
                        "--manifest",
                        str(root / "freeze" / "owner-budget-approval.json"),
                        "--approval",
                        str(root / "freeze" / "manifest.json"),
                    ]
                )
            run_scored.assert_not_called()

    def test_scored_cli_rejects_threshold_override_before_dispatch(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frozen_tree(root)
            dispatched: list[Path] = []

            def scored(path: Path) -> dict[str, object]:
                dispatched.append(path)
                return {"status": "complete"}

            # when / then
            with (
                patch("scheduled_learning_v1.run.run_scored", scored),
                redirect_stderr(io.StringIO()),
                redirect_stdout(io.StringIO()),
                self.assertRaises(SystemExit),
            ):
                main(
                    [
                        "scored",
                        "--root",
                        str(root),
                        "--manifest",
                        str(root / "freeze" / "manifest.json"),
                        "--approval",
                        str(root / "freeze" / "owner-budget-approval.json"),
                        "--minimum-active-score",
                        "0",
                    ]
                )
            self.assertEqual(dispatched, [])

    def test_parent_passes_exact_promoted_digest_in_fresh_python_argv(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            expected = "a" * 64
            observed: list[str] = []

            def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
                observed.extend(command)
                return subprocess.CompletedProcess(command, 0, "", "")

            # when
            with patch("scheduled_learning_v1.execution.lifecycle.subprocess.run", run):
                _launch_restart(root, 3, expected)

            # then
            self.assertEqual(observed[0], sys.executable)
            self.assertEqual(observed[-2:], ["--promoted-digest", expected])

    def test_fresh_process_reconstructs_promotion_and_reports_restart_score_failure(self) -> None:
        # given / when / then
        for name, restart_score, expected_status in (
            ("passing restart", 96, "complete"),
            ("below restart gate", 89, "incomplete_failed"),
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                promoted_digest = self._promoted_tree(root)
                child = self._fresh_active(root, promoted_digest, restart_score)
                self.assertEqual(child.returncode, 0, child.stderr)
                report = load_object(root / "results" / "final-report.json")
                self.assertEqual(report["status"], expected_status)
                self.assertEqual(report["restart_evidence"]["promoted_digest_matched"], True)
                restart_task = load_object(root / "results" / "restart-task-input.json")
                self.assertEqual(restart_task["condition"], "post_restart_active")
                self.assertEqual(
                    restart_task["lessons"],
                    ["Ignore   volatile deployment counters."],
                )

    def test_fresh_process_rejects_promoted_digest_mismatch_before_restart(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._promoted_tree(root)

            # when
            marker = root / "run-active-entered"
            script = f"""
from pathlib import Path
from unittest.mock import patch
import scheduled_learning_v1.run as run
root = Path({str(root)!r})
marker = Path({str(marker)!r})
def active(path, generation):
    marker.write_text('entered', encoding='utf-8')
    return {{'status': 'incomplete_failed'}}
with patch.object(run, 'run_active', active):
    run.main([
        'active', '--root', str(root), '--generation', '3',
        '--promoted-digest', {"f" * 64!r},
    ])
"""

            # when
            child = subprocess.run(  # noqa: S603 -- fresh interpreter executes fixed wrapper
                [sys.executable, "-B", "-c", script],
                check=False,
                capture_output=True,
                text=True,
            )

            # then
            self.assertNotEqual(child.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertFalse((root / "results" / "restart-evidence.json").exists())

    def _promoted_tree(self, root: Path) -> str:
        report, _, _ = run_fake_scored(
            root,
            restart_boundary=False,
            lessons=["  Ignore   volatile deployment counters.  "],
        )
        promoted_digest = report["promoted_digest"]
        self.assertIsInstance(promoted_digest, str)
        return cast(str, promoted_digest)

    def _fresh_active(
        self, root: Path, promoted_digest: str, restart_score: float
    ) -> subprocess.CompletedProcess[str]:
        script = f"""
from pathlib import Path
from unittest.mock import patch
from benchmark_core.canonical import load_object, write
from tests.execution.support import FIXED_TIME, FakeOperations, verified_receipt
import scheduled_learning_v1.execution.lifecycle as lifecycle
import scheduled_learning_v1.run as run
root = Path({str(root)!r})
manifest = load_object(root / 'freeze' / 'manifest.json')
def factory(*args, **kwargs):
    operations = FakeOperations(args[3], restart_score={restart_score!r}, generation=3)
    captured['operations'] = operations
    return operations
captured = {{}}
with (
    patch.object(lifecycle, 'verify_pre_run', return_value=verified_receipt(manifest)),
    patch.object(lifecycle, '_make_operations', factory),
    patch.object(lifecycle, '_utc_now', return_value=FIXED_TIME),
):
    run.main([
        'active', '--root', str(root), '--generation', '3',
        '--promoted-digest', {promoted_digest!r},
    ])
write(root / 'results' / 'restart-task-input.json', captured['operations'].task_inputs[0])
"""
        return subprocess.run(  # noqa: S603 -- fresh interpreter executes isolated test support
            [sys.executable, "-B", "-c", script],
            check=False,
            capture_output=True,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
