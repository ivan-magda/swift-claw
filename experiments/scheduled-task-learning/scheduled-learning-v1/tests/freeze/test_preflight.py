"""Owner checkpoint and current-commit preflight behavior."""

from __future__ import annotations

import unittest

from scheduled_learning_v1.freeze import build_manifest
from scheduled_learning_v1.preflight import verify_pre_run

from .support import (
    FreezeTestRepository,
    RecordingBridge,
    approval_for,
    create_repository,
    publish_manifest,
)


class PreflightTests(unittest.TestCase):
    repository: FreezeTestRepository
    manifest: dict[str, object]
    approval: dict[str, object]

    def setUp(self) -> None:
        self.repository = create_repository()
        self.addCleanup(self.repository.cleanup)
        self.manifest = build_manifest(self.repository.experiment_root)
        publish_manifest(self.repository, self.manifest)
        self.approval = approval_for(self.repository, self.manifest)

    def test_unchanged_freeze_and_owner_checkpoint_are_verified(self) -> None:
        # given
        expected_commit = self.repository.git("rev-parse", "HEAD")

        # when
        actual = verify_pre_run(self.repository.experiment_root, self.approval)

        # then
        self.assertEqual(actual["status"], "verified")
        self.assertEqual(actual["freeze_commit"], expected_commit)
        self.assertEqual(actual["budgets"], self.manifest["budgets"])

    def test_missing_or_changed_owner_budget_stops_before_bridge_dispatch(self) -> None:
        # given
        missing: dict[str, object] = {}
        changed = dict(self.approval)
        budgets = dict(_object(changed, "budgets"))
        budgets["responses_sends"] = 39
        changed["budgets"] = budgets

        # when / then
        for approval in (missing, changed):
            with self.subTest(approval=approval):
                bridge = RecordingBridge()
                with self.assertRaises(ValueError):
                    _verify_then_dispatch(self.repository, approval, bridge)
                self.assertEqual(bridge.calls, [])

    def test_changed_commit_stops_before_bridge_dispatch(self) -> None:
        # given
        changed = self.repository.repository_root / "after-approval.txt"
        changed.write_text("new commit\n", encoding="utf-8")
        self.repository.commit("test: move head after approval")
        bridge = RecordingBridge()

        # when / then
        with self.assertRaisesRegex(ValueError, "freeze commit"):
            _verify_then_dispatch(self.repository, self.approval, bridge)
        self.assertEqual(bridge.calls, [])

    def test_noncanonical_approval_timestamp_is_rejected(self) -> None:
        # given
        changed = dict(self.approval)
        changed["approved_at"] = "2026-08-30"

        # when / then
        with self.assertRaisesRegex(ValueError, "approved_at"):
            verify_pre_run(self.repository.experiment_root, changed)


def _verify_then_dispatch(
    repository: FreezeTestRepository,
    approval: dict[str, object],
    bridge: RecordingBridge,
) -> None:
    verify_pre_run(repository.experiment_root, approval)
    bridge.run_task()
    bridge.run_learning()


def _object(value: dict[str, object], key: str) -> dict[str, object]:
    item = value[key]
    if not isinstance(item, dict):
        raise AssertionError(f"test approval {key} must be an object")
    return item


if __name__ == "__main__":
    unittest.main()
