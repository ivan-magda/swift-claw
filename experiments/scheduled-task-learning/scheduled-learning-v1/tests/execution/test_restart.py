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

from benchmark_core.canonical import load_object, write
from scheduled_learning_v1.execution.lifecycle import _launch_restart, _write_failure
from scheduled_learning_v1.run import main

from .support import frozen_tree, run_fake_scored


class RestartTests(unittest.TestCase):
    def test_scored_and_active_cli_require_and_forward_the_exact_credential_root(self) -> None:
        # given
        with (
            tempfile.TemporaryDirectory() as temporary,
            tempfile.TemporaryDirectory() as credential_temporary,
        ):
            root = Path(temporary)
            credential_root = Path(credential_temporary).resolve()
            frozen_tree(root)
            promoted_digest = "a" * 64
            scored_dispatches: list[tuple[Path, Path]] = []
            active_dispatches: list[tuple[Path, int, Path]] = []

            def scored(path: Path, credential: Path) -> dict[str, object]:
                scored_dispatches.append((path, credential))
                return {"status": "complete"}

            def active(path: Path, generation: int, credential: Path) -> dict[str, object]:
                active_dispatches.append((path, generation, credential))
                return {"status": "complete"}

            # when / then
            output = io.StringIO()
            with (
                patch("scheduled_learning_v1.run.run_scored", scored),
                patch("scheduled_learning_v1.run.run_active", active),
                patch(
                    "scheduled_learning_v1.run._replayed_promoted_digest",
                    return_value=promoted_digest,
                ),
                redirect_stdout(output),
            ):
                with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
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
                with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    main(
                        [
                            "active",
                            "--root",
                            str(root),
                            "--generation",
                            "3",
                            "--promoted-digest",
                            promoted_digest,
                        ]
                    )
                main(
                    [
                        "scored",
                        "--root",
                        str(root),
                        "--manifest",
                        str(root / "freeze" / "manifest.json"),
                        "--approval",
                        str(root / "freeze" / "owner-budget-approval.json"),
                        "--credential-state-root",
                        str(credential_root),
                    ]
                )
                main(
                    [
                        "active",
                        "--root",
                        str(root),
                        "--generation",
                        "3",
                        "--promoted-digest",
                        promoted_digest,
                        "--credential-state-root",
                        str(credential_root),
                    ]
                )

            # then
            self.assertEqual(
                scored_dispatches,
                [(root.resolve(), credential_root.resolve())],
            )
            self.assertEqual(
                active_dispatches,
                [(root.resolve(), 3, credential_root.resolve())],
            )
            self.assertEqual(output.getvalue(), "status=complete\nstatus=complete\n")

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
                        "--credential-state-root",
                        str(root.parent.resolve()),
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
                        "--credential-state-root",
                        str(root.parent.resolve()),
                    ]
                )
            self.assertEqual(dispatched, [])

    def test_parent_passes_exact_promoted_digest_and_credential_root_in_fresh_python_argv(
        self,
    ) -> None:
        # given
        with (
            tempfile.TemporaryDirectory() as temporary,
            tempfile.TemporaryDirectory() as credential_temporary,
        ):
            root = Path(temporary)
            credential_root = Path(credential_temporary).resolve()
            expected = "a" * 64
            observed: list[str] = []

            def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
                observed.extend(command)
                return subprocess.CompletedProcess(command, 0, "", "")

            # when
            with patch("scheduled_learning_v1.execution.lifecycle.subprocess.run", run):
                _launch_restart(root, 3, expected, credential_root)

            # then
            self.assertEqual(observed[0], sys.executable)
            self.assertEqual(
                observed[-4:],
                [
                    "--promoted-digest",
                    expected,
                    "--credential-state-root",
                    str(credential_root),
                ],
            )

    def test_failed_active_child_redacts_credential_root_from_failure_evidence(self) -> None:
        # given
        with (
            tempfile.TemporaryDirectory() as temporary,
            tempfile.TemporaryDirectory() as credential_temporary,
        ):
            root = Path(temporary)
            credential_root = Path(credential_temporary).resolve()

            def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
                diagnostic = f"failed argv: {' '.join(command)}"
                return subprocess.CompletedProcess(command, 9, "active failed", diagnostic)

            # when
            with (
                patch("scheduled_learning_v1.execution.lifecycle.subprocess.run", run),
                self.assertRaises(RuntimeError) as captured,
            ):
                _launch_restart(root, 3, "a" * 64, credential_root)

            # then
            self.assertNotIn(str(credential_root), str(captured.exception))
            _write_failure(root, captured.exception, credential_root)
            failure_path = root / "results" / "failure.json"
            self.assertIn("[credential-state-root]", failure_path.read_text(encoding="utf-8"))
            self.assertNotIn(str(credential_root), failure_path.read_text(encoding="utf-8"))

    def test_fresh_process_reconstructs_promotion_and_reports_restart_score_failure(self) -> None:
        # given / when / then
        for name, restart_score, expected_status in (
            ("passing restart", 100, "complete"),
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
def active(path, generation, credential_state_root):
    marker.write_text('entered', encoding='utf-8')
    return {{'status': 'incomplete_failed'}}
with patch.object(run, 'run_active', active):
    run.main([
        'active', '--root', str(root), '--generation', '3',
        '--promoted-digest', {"f" * 64!r},
        '--credential-state-root', str(root.parent.resolve()),
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

    def test_failure_marked_tree_is_not_resumed_by_fresh_active_process(self) -> None:
        # given
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            promoted_digest = self._promoted_tree(root)
            event_names = sorted(path.name for path in (root / "results" / "events").glob("*.json"))
            write(
                root / "results" / "failure.json",
                {"schema_version": 1, "status": "incomplete_failed", "error": "parent failed"},
            )
            factory_marker = root / "restart-operations-built"
            task_marker = root / "restart-task-entered"
            scorer_marker = root / "restart-scorer-entered"
            script = f"""
from pathlib import Path
from unittest.mock import patch
from benchmark_core.canonical import load_object
from tests.execution.support import FIXED_TIME, FakeOperations, verified_receipt
import scheduled_learning_v1.execution.lifecycle as lifecycle
import scheduled_learning_v1.run as run
root = Path({str(root)!r})
factory_marker = Path({str(factory_marker)!r})
task_marker = Path({str(task_marker)!r})
scorer_marker = Path({str(scorer_marker)!r})
manifest = load_object(root / 'freeze' / 'manifest.json')
class MarkingOperations(FakeOperations):
    def run_task(self, row, lessons, promotion_receipt=None):
        task_marker.write_text('entered', encoding='utf-8')
        return super().run_task(row, lessons, promotion_receipt)
    def score_active(self, attempt, *, restart):
        scorer_marker.write_text('entered', encoding='utf-8')
        return super().score_active(attempt, restart=restart)
def factory(*args, **kwargs):
    factory_marker.write_text('built', encoding='utf-8')
    return MarkingOperations(args[3], generation=3)
with (
    patch.object(lifecycle, 'verify_pre_run', return_value=verified_receipt(manifest)),
    patch.object(lifecycle, '_make_operations', factory),
    patch.object(lifecycle, '_utc_now', return_value=FIXED_TIME),
):
    run.main([
        'active', '--root', str(root), '--generation', '3',
        '--promoted-digest', {promoted_digest!r},
        '--credential-state-root', str(root.parent.resolve()),
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
            self.assertEqual(child.returncode, 0, child.stderr)
            self.assertFalse(factory_marker.exists())
            self.assertFalse(task_marker.exists())
            self.assertFalse(scorer_marker.exists())
            self.assertEqual(
                sorted(path.name for path in (root / "results" / "events").glob("*.json")),
                event_names,
            )
            self.assertFalse((root / "results" / "restart-evidence.json").exists())
            report = load_object(root / "results" / "final-report.json")
            self.assertEqual(report["status"], "incomplete_failed")
            self.assertTrue(report["m4_blocked"])

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
    operations = FakeOperations(
        root, manifest, args[3], restart_score={restart_score!r}, generation=3
    )
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
        '--credential-state-root', str(root.parent.resolve()),
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
