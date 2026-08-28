from __future__ import annotations

import copy
import unittest

from tools.page_change_freeze import contract, recovery
from tools.page_change_freeze.tests.support import FreezeRepository


class RecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = FreezeRepository()

    def tearDown(self) -> None:
        self.repo.cleanup()

    def _replacement_pair(self) -> tuple[dict, dict]:
        candidate = self.repo.make_manifest()
        baseline = copy.deepcopy(candidate)
        historical, _ = contract.load_json(self.repo.root / contract.INVALIDATED_MANIFEST_PATH)
        baseline["protocol"] = historical["protocol"]

        def refresh_category(name: str) -> None:
            category = baseline["categories"][name]
            payload = {key: category[key] for key in ("artifacts", "values")}
            category["sha256"] = contract.sha256_hex(contract.canonical_json_bytes(payload))

        def replace_digests(name: str, paths: frozenset[str]) -> None:
            for item in baseline["categories"][name]["artifacts"]:
                if item["path"] in paths:
                    item["sha256"] = "0" * 64

        budget = baseline["categories"]["budget"]
        budget["artifacts"] = []
        budget["values"].pop("recovery_accounting_seed")
        for key, (old, _new) in recovery.RECOVERY_CAPS.items():
            budget["values"][key] = old
        refresh_category("budget")

        harness = baseline["categories"]["harness_sources"]
        harness["artifacts"] = [
            item
            for item in harness["artifacts"]
            if item["path"] not in contract.REPLACEMENT_ADDED_HARNESS_PATHS
        ]
        replace_digests("harness_sources", contract.REPLACEMENT_CHANGED_HARNESS_PATHS)
        refresh_category("harness_sources")

        configuration = baseline["categories"]["configuration"]
        configuration["artifacts"] = [
            item
            for item in configuration["artifacts"]
            if item["path"] not in contract.REPLACEMENT_ADDED_CONFIGURATION_PATHS
        ]
        replace_digests(
            "configuration", contract.REPLACEMENT_CHANGED_CONFIGURATION_PATHS
        )
        refresh_category("configuration")

        baseline["categories"]["executable"]["artifacts"][0]["sha256"] = "0" * 64
        refresh_category("executable")
        return baseline, candidate

    def test_recovery_only_delta_is_allowed(self) -> None:
        # given
        baseline, candidate = self._replacement_pair()

        # when
        delta = recovery.compare_replacement_manifests(
            baseline,
            candidate,
            baseline_sha256=contract.INVALIDATED_MANIFEST_SHA256,
            candidate_sha256="a" * 64,
        )

        # then
        self.assertEqual(delta["verdict"], "allowed")
        self.assertEqual(delta["violations"], [])
        self.assertEqual(
            [item["category"] for item in delta["changed_categories"]],
            ["budget", "configuration", "executable", "harness_sources"],
        )

    def test_decision_artifact_mutants_are_forbidden(self) -> None:
        # given
        baseline, candidate = self._replacement_pair()
        mutations = {
            "prompt": ("prompts", contract.TASK_PROMPT_PATH),
            "scorer": ("scorer", None),
            "fixture": ("fixtures", None),
            "gold_label": ("gold", None),
            "split": ("splits", contract.SPLITS_PATH),
        }

        for name, (category, path) in mutations.items():
            with self.subTest(name=name):
                changed = copy.deepcopy(candidate)
                artifacts = changed["categories"][category]["artifacts"]
                target = next(
                    item for item in artifacts if path is None or item["path"] == path
                )
                target["sha256"] = "f" * 64

                # when
                delta = recovery.compare_replacement_manifests(
                    baseline,
                    changed,
                    baseline_sha256=contract.INVALIDATED_MANIFEST_SHA256,
                    candidate_sha256="b" * 64,
                )

                # then
                self.assertEqual(delta["verdict"], "forbidden")
                self.assertIn(f"immutable category changed: {category}", delta["violations"])

    def test_ledger_total_or_source_digest_mismatch_blocks_admission(self) -> None:
        # given
        ledger_path = self.repo.root / contract.RECOVERY_LEDGER_PATH
        journal_path = self.repo.root / contract.INVALID_BATCH_JOURNAL_PATH
        ledger_raw = ledger_path.read_bytes()
        journal_raw = journal_path.read_bytes()

        ledger, _ = contract.load_json(ledger_path)
        ledger["total"]["attempts"] = 11
        ledger_path.write_bytes(contract.canonical_json_bytes(ledger))

        # when
        with self.assertRaisesRegex(contract.FreezeError, "stored recovery ledger differs"):
            recovery.verify_recovery_ledger(self.repo.root)

        # then
        ledger_path.write_bytes(ledger_raw)
        journal_path.write_bytes(journal_raw.replace(b"batch_started", b"batch_starteX", 1))
        with self.assertRaisesRegex(contract.FreezeError, "wrong SHA-256"):
            recovery.verify_recovery_ledger(self.repo.root)

        journal_path.write_bytes(journal_raw)
        ledger_target = ledger_path.with_name("recovery-ledger-target.json")
        ledger_path.rename(ledger_target)
        ledger_path.symlink_to(ledger_target)
        with self.assertRaisesRegex(contract.FreezeError, "symlinks are forbidden"):
            recovery.verify_recovery_ledger(self.repo.root)
        ledger_path.unlink()
        ledger_target.rename(ledger_path)

        candidate = self.repo.make_manifest()
        candidate_raw = contract.canonical_json_bytes(candidate)
        delta = recovery.build_replacement_delta(self.repo.root, candidate, candidate_raw)
        delta_path = self.repo.root / contract.REPLACEMENT_DELTA_PATH
        delta_target = delta_path.with_name("replacement-delta-target.json")
        delta_target.write_bytes(contract.canonical_json_bytes(delta))
        delta_path.unlink()
        delta_path.symlink_to(delta_target)
        with self.assertRaisesRegex(contract.FreezeError, "symlinks are forbidden"):
            recovery.verify_replacement_admission(
                self.repo.root,
                candidate,
                candidate_raw,
                replacement_delta_sha256=contract.sha256_hex(delta_target.read_bytes()),
                recovery_ledger_sha256=contract.sha256_hex(ledger_raw),
                invalidation_report_sha256=contract.INVALIDATION_REPORT_SHA256,
            )


if __name__ == "__main__":
    unittest.main()
