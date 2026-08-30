"""Owner checkpoint and current-commit preflight behavior."""

from __future__ import annotations

import copy
import unittest

from scheduled_learning_v1.freeze import build_manifest
from scheduled_learning_v1.preflight import verify_pre_run

from .support import (
    FreezeTestRepository,
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
        self.assertEqual(
            actual["budgets"],
            {
                "task_attempts": 10,
                "evaluator_calls": 5,
                "reflector_calls": 1,
                "responses_sends": 38,
                "accounted_tokens": 5_045_184,
            },
        )

    def test_missing_or_changed_owner_budget_is_rejected(self) -> None:
        # given
        missing: dict[str, object] = {}
        changed = dict(self.approval)
        budgets = dict(_object(changed, "budgets"))
        budgets["responses_sends"] = 39
        changed["budgets"] = budgets

        # when / then
        for approval in (missing, changed):
            with self.subTest(approval=approval), self.assertRaises(ValueError):
                verify_pre_run(self.repository.experiment_root, approval)

    def test_approval_schema_and_budget_types_are_exact(self) -> None:
        # given
        boolean_schema = copy.deepcopy(self.approval)
        boolean_schema["schema_version"] = True
        float_schema = copy.deepcopy(self.approval)
        float_schema["schema_version"] = 1.0
        float_budget = copy.deepcopy(self.approval)
        _object(float_budget, "budgets")["reflector_calls"] = 1.0

        # when / then
        for case, approval in (
            ("boolean schema", boolean_schema),
            ("float schema", float_schema),
            ("float budget", float_budget),
        ):
            with self.subTest(case=case), self.assertRaises(ValueError):
                verify_pre_run(self.repository.experiment_root, approval)

    def test_closed_approval_rejects_wrong_values_and_extra_keys(self) -> None:
        # given
        wrong_schema = copy.deepcopy(self.approval)
        wrong_schema["schema_version"] = 2
        wrong_manifest = copy.deepcopy(self.approval)
        wrong_manifest["manifest_sha256"] = "0" * 64
        extra_approval_key = copy.deepcopy(self.approval)
        extra_approval_key["note"] = "not-authorized"
        extra_budget_key = copy.deepcopy(self.approval)
        _object(extra_budget_key, "budgets")["unapproved_calls"] = 1

        # when / then
        for case, approval in (
            ("wrong schema", wrong_schema),
            ("wrong manifest", wrong_manifest),
            ("extra approval key", extra_approval_key),
            ("extra budget key", extra_budget_key),
        ):
            with self.subTest(case=case), self.assertRaises(ValueError):
                verify_pre_run(self.repository.experiment_root, approval)

    def test_changed_commit_is_rejected(self) -> None:
        # given
        changed = self.repository.repository_root / "after-approval.txt"
        changed.write_text("new commit\n", encoding="utf-8")
        self.repository.commit("test: move head after approval")

        # when / then
        with self.assertRaisesRegex(ValueError, "freeze commit"):
            verify_pre_run(self.repository.experiment_root, self.approval)

    def test_noncanonical_or_impossible_approval_timestamp_is_rejected(self) -> None:
        # given
        noncanonical = copy.deepcopy(self.approval)
        noncanonical["approved_at"] = "2026-08-30"
        impossible = copy.deepcopy(self.approval)
        impossible["approved_at"] = "2026-02-30T00:00:00Z"

        # when / then
        for case, approval in (("noncanonical", noncanonical), ("impossible", impossible)):
            with self.subTest(case=case), self.assertRaisesRegex(ValueError, "approved_at"):
                verify_pre_run(self.repository.experiment_root, approval)


def _object(value: dict[str, object], key: str) -> dict[str, object]:
    item = value[key]
    if not isinstance(item, dict):
        raise AssertionError(f"test approval {key} must be an object")
    return item


if __name__ == "__main__":
    unittest.main()
