from __future__ import annotations

import copy
from pathlib import Path
import unittest
from unittest import mock

from tools.page_change_freeze import contract, manifest, recovery
from tools.page_change_freeze.tests.support import FreezeRepository


class RecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = FreezeRepository()

    def tearDown(self) -> None:
        self.repo.cleanup()

    def _replacement_pair(self) -> tuple[dict, dict]:
        repository_root = Path(contract.__file__).resolve().parents[2]
        baseline, _ = contract.load_json(
            self.repo.root / contract.INVALIDATED_MANIFEST_PATH
        )
        candidate, _ = contract.load_json(
            repository_root / f"{contract.PAGE_ROOT}/freeze/page-manifest.json"
        )
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
            ["budget", "configuration", "executable", "harness_sources", "scorer"],
        )

        repository_root = Path(contract.__file__).resolve().parents[2]
        approved_candidate, approved_candidate_raw = contract.load_json(
            repository_root / f"{contract.PAGE_ROOT}/freeze/page-manifest.json"
        )
        approved_delta = recovery.build_replacement_delta(
            self.repo.root,
            approved_candidate,
            approved_candidate_raw,
        )
        approved_delta_raw = contract.canonical_json_bytes(approved_delta)
        (self.repo.root / contract.REPLACEMENT_DELTA_PATH).write_bytes(approved_delta_raw)
        ledger_raw = (self.repo.root / contract.RECOVERY_LEDGER_PATH).read_bytes()

        admission = recovery.verify_replacement_admission(
            self.repo.root,
            approved_candidate,
            approved_candidate_raw,
            replacement_delta_sha256=contract.sha256_hex(approved_delta_raw),
            recovery_ledger_sha256=contract.sha256_hex(ledger_raw),
            invalidation_report_sha256=contract.INVALIDATION_REPORT_SHA256,
        )
        self.assertEqual(
            admission["replacement_delta_sha256"],
            contract.sha256_hex(approved_delta_raw),
        )

    def test_recovery_seed_and_budget_caps_match_protocol_literals(self) -> None:
        ledger, _ = recovery.verify_recovery_ledger(self.repo.root)
        self.assertEqual(
            ledger["fresh"]["total"],
            {
                "accounted_tokens": 57_798,
                "attempts": 22,
                "file_reads": 22,
                "responses_sends": 44,
            },
        )
        seed = recovery.recovery_seed(ledger)
        self.assertEqual(
            seed["total"],
            {
                "accounted_tokens": 85_957,
                "attempts": 34,
                "file_reads": 33,
                "responses_sends": 66,
            },
        )

        _baseline, candidate = self._replacement_pair()
        budget = candidate["categories"]["budget"]["values"]
        self.assertEqual(
            (
                (
                    budget["canary_attempt_cap"],
                    budget["canary_responses_send_cap"],
                    seed["canary"]["file_reads"] + 4,
                ),
                (
                    budget["page_attempt_cap"],
                    budget["page_responses_send_cap"],
                    seed["page_clean_development"]["file_reads"]
                    + budget["page_planned_attempts"]
                    + budget["page_replacement_pool"],
                ),
                (
                    budget["global_attempt_cap"],
                    budget["global_responses_send_cap"],
                    budget["global_file_read_cap"],
                ),
            ),
            ((12, 24, 12), (102, 202, 101), (228, 454, 227)),
        )

    def test_decision_artifact_mutants_are_forbidden(self) -> None:
        # given
        baseline, candidate = self._replacement_pair()
        baseline_delta = recovery.compare_replacement_manifests(
            baseline,
            candidate,
            baseline_sha256=contract.INVALIDATED_MANIFEST_SHA256,
            candidate_sha256="b" * 64,
        )
        replacement_categories = {
            item["category"] for item in baseline_delta["changed_categories"]
        }
        mutations = [
            (
                category,
                category,
                None,
                f"immutable category changed: {category}",
            )
            for category in sorted(set(candidate["categories"]) - replacement_categories)
        ]
        target_taxonomy_path = f"{contract.PAGE_ROOT}/contracts/target-classes.json"
        mutations.append(
            (
                "target_taxonomy",
                "configuration",
                target_taxonomy_path,
                f"configuration changed forbidden path {target_taxonomy_path}",
            )
        )

        for name, category, path, expected_violation in mutations:
            with self.subTest(name=name):
                changed = copy.deepcopy(candidate)
                changed_category = changed["categories"][category]
                if changed_category["artifacts"]:
                    target = next(
                        item
                        for item in changed_category["artifacts"]
                        if path is None or item["path"] == path
                    )
                    target["sha256"] = "f" * 64
                else:
                    changed_category["values"]["recovery_test_mutant"] = True

                # when
                delta = recovery.compare_replacement_manifests(
                    baseline,
                    changed,
                    baseline_sha256=contract.INVALIDATED_MANIFEST_SHA256,
                    candidate_sha256="b" * 64,
                )

                # then
                self.assertEqual(delta["verdict"], "forbidden")
                self.assertIn(expected_violation, delta["violations"])

    def test_ledger_total_or_source_digest_mismatch_blocks_admission(self) -> None:
        # given
        ledger_path = self.repo.root / contract.RECOVERY_LEDGER_PATH
        journal_path = self.repo.root / contract.INVALID_BATCH_JOURNAL_PATH
        ledger_raw = ledger_path.read_bytes()
        journal_raw = journal_path.read_bytes()

        ledger, _ = contract.load_json(ledger_path)
        ledger["cumulative"]["total"]["attempts"] = 33
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
        prior_path = self.repo.root / contract.PRIOR_RECOVERY_LEDGER_PATH
        prior_raw = prior_path.read_bytes()
        prior_path.write_bytes(prior_raw.replace(b'"attempts":12', b'"attempts":13', 1))
        with self.assertRaisesRegex(
            contract.FreezeError, "stored prior recovery ledger differs"
        ):
            recovery.verify_recovery_ledger(self.repo.root)
        prior_path.write_bytes(prior_raw)

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

    def test_self_consistent_canonical_composite_substitution_is_rejected(self) -> None:
        role, path, _digest, _byte_count, canonical_digest, canonical_byte_count = (
            recovery.INVALID_BATCH_COMPOSITES[0]
        )
        composite_path = self.repo.root / path
        value = contract.load_json_bytes(
            composite_path.read_bytes(), location=path, allow_floats=True
        )
        canonical = contract.canonical_json_line_bytes(value, allow_floats=True)
        self.assertEqual((len(canonical), contract.sha256_hex(canonical)), (
            canonical_byte_count,
            canonical_digest,
        ))
        composite_path.write_bytes(canonical)
        substituted = (
            (
                role,
                path,
                canonical_digest,
                canonical_byte_count,
                canonical_digest,
                canonical_byte_count,
            ),
            *recovery.INVALID_BATCH_COMPOSITES[1:],
        )

        with mock.patch.object(recovery, "INVALID_BATCH_COMPOSITES", substituted):
            with self.assertRaisesRegex(
                contract.FreezeError,
                "invalid-batch composite does not reproduce its frozen mismatch",
            ):
                recovery.build_recovery_ledger(self.repo.root)

    def test_report_claim_mutants_are_rejected_after_digest_binding(self) -> None:
        report_path = self.repo.root / contract.INVALIDATION_REPORT_PATH
        original = report_path.read_bytes()
        mutations = (
            (
                "canonicalization",
                lambda value: value["canonicalization_evidence"][0].__setitem__(
                    "first_difference_offset", 0
                ),
                "canonicalization evidence differs",
            ),
            (
                "extra_digest",
                lambda value: value["artifact_digests"].__setitem__(
                    "unverified_sha256", "f" * 64
                ),
                "does not bind the preserved canonicalization evidence",
            ),
            (
                "fresh_double_count",
                lambda value: value["fresh_accounting"]["total"].__setitem__(
                    "attempts", 34
                ),
                "fresh accounting differs",
            ),
            (
                "wrong_experiment",
                lambda value: value.__setitem__("experiment", "not-page-change"),
                "wrong identity or classification",
            ),
            (
                "exposure",
                lambda value: value["outputs_exposed_before_discovery"]["cumulative"].__setitem__(
                    "task_outputs", 34
                ),
                "output exposure differs",
            ),
            (
                "closure",
                lambda value: value["protected_closure_evidence"].__setitem__(
                    "sealed_reservations", 1
                ),
                "protected-closure evidence differs",
            ),
        )
        for name, mutate, message in mutations:
            with self.subTest(name=name):
                value, _ = contract.load_json(report_path)
                mutate(value)
                raw = contract.canonical_json_line_bytes(value)
                report_path.write_bytes(raw)
                with mock.patch.object(
                    recovery,
                    "INVALIDATION_REPORT_SHA256",
                    contract.sha256_hex(raw),
                ):
                    with self.assertRaisesRegex(contract.FreezeError, message):
                        recovery.build_recovery_ledger(self.repo.root)
                report_path.write_bytes(original)

    def test_replacement_evidence_manifest_record_binds_verified_file(self) -> None:
        _baseline, candidate = self._replacement_pair()
        changed = copy.deepcopy(candidate)
        path = contract.INVALID_BATCH_EVIDENCE[0][1]
        budget = changed["categories"]["budget"]
        item = next(record for record in budget["artifacts"] if record["path"] == path)
        item["bytes"] = 1
        item["sha256"] = "f" * 64
        payload = {key: budget[key] for key in ("artifacts", "values")}
        budget["sha256"] = contract.sha256_hex(contract.canonical_json_bytes(payload))
        protected = next(
            record for record in changed["protected_artifacts"] if record["path"] == path
        )
        protected["bytes"] = 1
        protected["sha256"] = "f" * 64
        changed_raw = contract.canonical_json_bytes(changed)
        manifest.verify_structure(changed, changed_raw)

        with self.assertRaisesRegex(
            contract.FreezeError,
            "candidate manifest does not bind exact replacement evidence bytes",
        ):
            recovery.build_replacement_delta(self.repo.root, changed, changed_raw)

    def test_only_record_source_may_change_in_scorer_category(self) -> None:
        baseline, candidate = self._replacement_pair()
        scorer = candidate["categories"]["scorer"]
        bootstrap = next(
            item
            for item in scorer["artifacts"]
            if item["path"] == contract.BENCHMARK_BOOTSTRAP_PATH
        )
        bootstrap["sha256"] = "f" * 64
        payload = {key: scorer[key] for key in ("artifacts", "values")}
        scorer["sha256"] = contract.sha256_hex(contract.canonical_json_bytes(payload))

        delta = recovery.compare_replacement_manifests(
            baseline,
            candidate,
            baseline_sha256=contract.INVALIDATED_MANIFEST_SHA256,
            candidate_sha256="c" * 64,
        )

        self.assertEqual(delta["verdict"], "forbidden")
        self.assertIn(
            f"scorer changed forbidden path {contract.BENCHMARK_BOOTSTRAP_PATH}",
            delta["violations"],
        )

    def test_exact_candidate_source_and_binary_digests_are_pinned(self) -> None:
        expected = (
            (
                "executable",
                contract.EXECUTABLE_PATH,
                "executable",
                16_722_880,
                "ad471ed38847b1eba7233051e16bda3028c31bd1812d49d72c7e837464dd3b46",
            ),
            (
                "harness_sources",
                "Sources/ClawEvaluation/Page/EvaluationContract.swift",
                "source",
                8_842,
                "96e3a816dbb19543fea5dc4714605286769b4d57554e705f33012c8f7fd57cba",
            ),
            (
                "harness_sources",
                "Sources/ClawEvaluation/Page/EvaluationPageRecords.swift",
                "source",
                12_335,
                "f9a65b10d9bb7365c9a7af188aefda0531b494ec7e0970200c9bd75baf67283b",
            ),
            (
                "harness_sources",
                "Sources/ClawEvaluation/Page/Experiment/EvaluationPageExperiment.swift",
                "source",
                21_608,
                "0f0ea2fa14804459b5aa335c177ac221685e41c6d45ef2ef7f41cef112f03181",
            ),
            (
                "harness_sources",
                "Sources/ClawEvaluation/Runtime/EvaluationExperimentProfile.swift",
                "source",
                3_207,
                "7ddfe2a4f39ad0fb704ba65c4dbec6ca60519ba0e2d2d289141219429a4b1bb3",
            ),
            (
                "scorer",
                f"{contract.BENCHMARK_PACKAGE_ROOT}/record.py",
                "source",
                5_278,
                "d93cfd0bed7e0fff6cc86c55131717cc246da9a01f494c66989fe62e17780b64",
            ),
        )
        self.assertEqual(contract.REPLACEMENT_EXACT_CANDIDATE_ARTIFACTS, expected)
        self.assertEqual(
            contract.REPLACEMENT_CHANGED_HARNESS_PATHS,
            frozenset(path for category, path, *_rest in expected if category == "harness_sources"),
        )
        self.assertEqual(
            contract.REPLACEMENT_CHANGED_SCORER_PATHS,
            frozenset(path for category, path, *_rest in expected if category == "scorer"),
        )
        baseline, candidate = self._replacement_pair()

        for category, path, _role, _byte_count, _digest in expected:
            with self.subTest(path=path):
                changed = copy.deepcopy(candidate)
                item = next(
                    artifact
                    for artifact in changed["categories"][category]["artifacts"]
                    if artifact["path"] == path
                )
                item["sha256"] = "f" * 64
                delta = recovery.compare_replacement_manifests(
                    baseline,
                    changed,
                    baseline_sha256=contract.INVALIDATED_MANIFEST_SHA256,
                    candidate_sha256="d" * 64,
                )
                self.assertEqual(delta["verdict"], "forbidden")
                self.assertIn(
                    f"{category} candidate artifact differs from frozen version 0.6 bytes: {path}",
                    delta["violations"],
                )


if __name__ == "__main__":
    unittest.main()
