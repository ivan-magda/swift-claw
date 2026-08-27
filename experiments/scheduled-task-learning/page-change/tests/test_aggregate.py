from __future__ import annotations

import copy
import hashlib
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

from aggregate_test_support import (
    FREEZE_COMMIT,
    PAGE_ROOT,
    REPOSITORY_ROOT,
    _actual_fixtures,
    _bind_lifecycle_receipt,
    _bind_promotion,
    _bind_records_to_run_order,
    _classify,
    _condition,
    _development_bundle,
    _noise_atoms,
    _promotion_from_development,
    _records,
    _rescore,
)
from page_benchmark.aggregate import build_gate_receipt
from page_benchmark.canonical import canonical_sha256, dumps, load_object, loads_object, write
from page_benchmark.conformance import run as run_conformance
from page_benchmark.execution import stage_attempts, validate_record_order
from page_benchmark.manifest_artifacts import load_manifest, scorer_digest
from page_benchmark.records import SKELETON_KEYS, seal_score_receipts


class AggregateCliTests(unittest.TestCase):
    @staticmethod
    def _restore_python_globals(path: list[str], dont_write_bytecode: bool) -> None:
        sys.path[:] = path
        sys.dont_write_bytecode = dont_write_bytecode

    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory(prefix="page-change-aggregate-")
        cls.addClassCleanup(cls._temporary.cleanup)
        cls.temporary = Path(cls._temporary.name)
        original_path = list(sys.path)
        original_dont_write_bytecode = sys.dont_write_bytecode
        cls.addClassCleanup(
            cls._restore_python_globals,
            original_path,
            original_dont_write_bytecode,
        )
        repository_path = str(REPOSITORY_ROOT)
        if repository_path not in sys.path:
            sys.path.append(repository_path)
        sys.dont_write_bytecode = True
        from tools.page_change_freeze import artifacts as freeze_artifacts
        from tools.page_change_freeze import manifest as freeze_manifest
        from tools.page_change_freeze import run_order as freeze_run_order
        from tools.page_change_freeze.contract import (
            EXECUTABLE_PATH,
            PROTOCOL_PATH,
            canonical_json_bytes,
            load_json,
        )

        descriptor, _ = load_json(PAGE_ROOT / "freeze/page-manifest-descriptor.json")
        manifest_root = REPOSITORY_ROOT
        if not (PAGE_ROOT / "artifacts/claw-eval-macos-arm64").is_file():
            manifest_root = cls.temporary / "manifest-root"
            protected_paths = {PROTOCOL_PATH}
            protected_paths.update(
                item["path"]
                for category in descriptor["categories"].values()
                for item in category["artifacts"]
            )
            for relative_path in sorted(protected_paths - {EXECUTABLE_PATH}):
                destination = manifest_root / relative_path
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(REPOSITORY_ROOT / relative_path, destination)
            executable = manifest_root / EXECUTABLE_PATH
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_bytes(
                struct.pack(
                    "<II",
                    freeze_artifacts.MACHO_MAGIC_64,
                    freeze_artifacts.MACHO_CPU_TYPE_ARM64,
                )
            )
            executable.chmod(0o755)
        package_description = freeze_artifacts.run_swift_package_describe(
            REPOSITORY_ROOT
        )
        if manifest_root != REPOSITORY_ROOT:
            package_description["path"] = str(manifest_root)
            for target in package_description["targets"]:
                for resource in target.get("resources", []):
                    resource_path = Path(resource["path"])
                    if resource_path.is_absolute():
                        resource["path"] = str(
                            manifest_root
                            / resource_path.relative_to(REPOSITORY_ROOT)
                        )
        generated_manifest = freeze_manifest.build(
            manifest_root,
            descriptor,
            package_description=package_description,
        )
        manifest_bytes = canonical_json_bytes(generated_manifest)
        cls.manifest_path = cls.temporary / "manifest.json"
        cls.manifest_path.write_bytes(manifest_bytes)
        cls.manifest, cls.manifest_sha256 = load_manifest(cls.manifest_path)
        cls.scorer_digest = scorer_digest(cls.manifest)
        cls.run_order = freeze_run_order.derive(cls.manifest, cls.manifest_sha256)
        cls.run_order_path = cls.temporary / "run-order.json"
        write(cls.run_order_path, cls.run_order)
        cls.conformance_receipt = run_conformance(PAGE_ROOT)
        cls.conformance_path = cls.temporary / "conformance-receipt.json"
        write(cls.conformance_path, cls.conformance_receipt)

    def _write(self, name: str, value: dict) -> Path:
        path = self.temporary / name
        write(path, value)
        return path

    def _invoke(
        self,
        stage: str,
        records_path: Path,
        *extra: str,
        manifest_path: Path | None = None,
        approved_manifest_sha256: str | None = None,
        approved_freeze_commit: str | None = None,
        run_order_path: Path | None = None,
        conformance_path: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            str(PAGE_ROOT / "artifacts/page-aggregate"),
            stage,
            "--root",
            str(REPOSITORY_ROOT),
            "--manifest",
            str(manifest_path or self.manifest_path),
            "--approved-manifest-sha256",
            approved_manifest_sha256 or self.manifest_sha256,
            "--approved-freeze-commit",
            approved_freeze_commit or FREEZE_COMMIT,
            "--run-order",
            str(run_order_path or self.run_order_path),
            "--records",
            str(records_path),
            "--conformance-receipt",
            str(conformance_path or self.conformance_path),
            *extra,
        ]
        return subprocess.run(
            command,
            cwd=PAGE_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

    def _development(self) -> tuple[dict[str, dict], list[dict], Path, dict, Path]:
        fixtures = _actual_fixtures("development")
        records = _bind_records_to_run_order(
            _records(fixtures, ("clean",), scorer_digest=self.scorer_digest),
            fixtures,
            self.run_order,
            "development",
        )
        records_path = self._write(
            "development-records.json",
            {"schema_version": 1, "records": records},
        )
        completed = self._invoke("development", records_path)
        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        receipt = loads_object(completed.stdout)
        self.assertEqual(completed.stdout, dumps(receipt))
        self.assertEqual(receipt["result"]["outcome"], "development_ready")
        receipt_path = self._write("development-receipt.json", receipt)
        return fixtures, records, records_path, receipt, receipt_path

    def test_freeze_generated_manifest_and_development_trust_inputs(self) -> None:
        # Given — the real freeze-generated manifest, order, and conformance receipt from setUpClass

        # When
        _, records, records_path, receipt, _ = self._development()

        # Then
        self.assertEqual(receipt["manifest_sha256"], self.manifest_sha256)
        self.assertEqual(receipt["freeze_commit"], FREEZE_COMMIT)
        self.assertEqual(receipt["run_order_sha256"], canonical_sha256(self.run_order))
        self.assertEqual(receipt["conformance_receipt_sha256"], canonical_sha256(self.conformance_receipt))

        fake_manifest = copy.deepcopy(self.manifest)
        fake_manifest["categories"]["scorer"]["sha256"] = "0" * 64
        fake_path = self.temporary / "fake-manifest.json"
        fake_path.write_bytes(dumps(fake_manifest).encode("utf-8").removesuffix(b"\n"))
        stale_conformance = copy.deepcopy(self.conformance_receipt)
        stale_conformance["passed"] = 23
        stale_path = self._write("stale-conformance.json", stale_conformance)
        missing_restart = copy.deepcopy(self.run_order)
        del missing_restart["stages"][7]
        missing_restart_path = self._write(
            "missing-restart-run-order.json",
            missing_restart,
        )

        mutants = (
            (
                "fake_manifest",
                {"manifest_path": fake_path},
            ),
            (
                "stale_conformance",
                {"conformance_path": stale_path},
            ),
            (
                "missing_conformance",
                {"conformance_path": self.temporary / "absent.json"},
            ),
            (
                "missing_frozen_restart_barrier",
                {"run_order_path": missing_restart_path},
            ),
            (
                "malformed_freeze_commit",
                {"approved_freeze_commit": "f" * 39},
            ),
        )
        for name, overrides in mutants:
            with self.subTest(mutant=name):
                rejected = self._invoke("development", records_path, **overrides)
                self.assertEqual(rejected.returncode, 2)
                body = loads_object(rejected.stdout)
                self.assertEqual(body["outcome"], "invalid_batch")
                self.assertEqual(body["gate_failures"], ["aggregate.input_invalid"])

        reordered = copy.deepcopy(records)
        reordered[0], reordered[1] = reordered[1], reordered[0]
        reordered_path = self._write(
            "reordered-development-records.json",
            {"schema_version": 1, "records": reordered},
        )
        rejected = self._invoke("development", reordered_path)
        self.assertEqual(rejected.returncode, 2)
        self.assertIn(
            "frozen order identity",
            loads_object(rejected.stdout)["input_error"],
        )

    def test_real_run_order_preserves_stage_split_and_record_identity(self) -> None:
        # Given
        expected = {
            "development": ("development", {"clean"}),
            "regression": (
                "regression",
                {"clean", "lesson-conditioned"},
            ),
            "sealed": (
                "sealed",
                {
                    "clean",
                    "lesson-conditioned",
                    "post-restart lesson-conditioned",
                },
            ),
        }

        for aggregate_stage, (split, conditions) in expected.items():
            with self.subTest(stage=aggregate_stage):
                fixtures = _actual_fixtures(split)

                # When
                attempts = stage_attempts(self.run_order, aggregate_stage)
                records = _bind_records_to_run_order(
                    _records(
                        fixtures,
                        tuple(sorted(conditions)),
                        scorer_digest=self.scorer_digest,
                    ),
                    fixtures,
                    self.run_order,
                    aggregate_stage,
                )

                # Then
                self.assertEqual(
                    {attempt["fixture_id"] for attempt in attempts},
                    set(fixtures),
                )
                self.assertEqual(
                    {attempt["condition"] for attempt in attempts},
                    conditions,
                )
                validate_record_order(records, self.run_order, aggregate_stage)

                mismatched = copy.deepcopy(records)
                mismatched[0]["fixture_id"] = "pc-outside-01"
                with self.assertRaisesRegex(ValueError, "frozen order identity"):
                    validate_record_order(
                        mismatched,
                        self.run_order,
                        aggregate_stage,
                    )

    def test_page_record_seals_one_plaintext_attempt_and_fails_closed(self) -> None:
        # Given
        fixtures = _actual_fixtures("development")
        records = _bind_records_to_run_order(
            _records(fixtures, ("clean",), scorer_digest=self.scorer_digest),
            fixtures,
            self.run_order,
            "development",
        )
        expected = records[0]
        split_contract = load_object(PAGE_ROOT / "contracts/splits.json")
        entry = next(
            item
            for item in split_contract["splits"]["development"]
            if item["fixture_id"] == expected["fixture_id"]
        )
        page_prefix = Path("experiments/scheduled-task-learning/page-change")
        source = str(page_prefix / entry["source"])
        gold = str(page_prefix / entry["gold"])
        attempt_path = self._write("page-record-attempt.json", expected["attempt"])
        carrier_path = self._write(
            "page-record-carrier.json",
            expected["carrier_receipt"],
        )
        skeleton = {
            key: expected[key]
            for key in SKELETON_KEYS
        }
        skeleton_path = self._write("page-record-skeleton.json", skeleton)

        def invoke(
            *,
            attempt: Path = attempt_path,
            carrier: Path = carrier_path,
            record_skeleton: Path = skeleton_path,
            output: Path | None = None,
        ) -> subprocess.CompletedProcess[str]:
            command = [
                str(PAGE_ROOT / "artifacts/page-record"),
                "--root",
                str(REPOSITORY_ROOT),
                "--manifest",
                str(self.manifest_path),
                "--approved-manifest-sha256",
                self.manifest_sha256,
                "--source",
                source,
                "--gold",
                gold,
                "--attempt",
                str(attempt),
                "--carrier",
                str(carrier),
                "--skeleton",
                str(record_skeleton),
            ]
            if output is not None:
                command.extend(("--output", str(output)))
            return subprocess.run(
                command,
                cwd=PAGE_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

        # When
        completed = invoke()

        # Then
        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        self.assertEqual(completed.stdout, dumps(expected))
        output_path = self.temporary / "page-record-output.json"
        written = invoke(output=output_path)
        self.assertEqual(written.returncode, 0, written.stderr + written.stdout)
        self.assertEqual(written.stdout, "")
        self.assertEqual(output_path.read_text(encoding="utf-8"), dumps(expected))

        duplicate_attempt = self.temporary / "page-record-duplicate-attempt.json"
        duplicate_attempt.write_text(
            '{"raw_output":null,"runtime_outcome":"completed",'
            '"runtime_outcome":"completed","tool_events":[]}\n',
            encoding="utf-8",
        )
        wrong_carrier = copy.deepcopy(expected["carrier_receipt"])
        wrong_carrier["source_sha256"] = "0" * 64
        wrong_carrier_path = self._write(
            "page-record-wrong-carrier.json",
            wrong_carrier,
        )
        wrong_stage = copy.deepcopy(skeleton)
        wrong_stage["condition"] = "lesson-conditioned"
        wrong_stage_path = self._write(
            "page-record-wrong-stage.json",
            wrong_stage,
        )
        envelope = self._write(
            "page-record-sealed-envelope.json",
            {"envelope_sha256": "a" * 64},
        )
        extra_skeleton = {**skeleton, "operator_override": True}
        extra_skeleton_path = self._write(
            "page-record-extra-skeleton.json",
            extra_skeleton,
        )
        mutants = (
            ("duplicate_attempt_key", {"attempt": duplicate_attempt}),
            ("carrier_source_digest", {"carrier": wrong_carrier_path}),
            ("stage_condition", {"record_skeleton": wrong_stage_path}),
            ("sealed_envelope_before_unseal", {"attempt": envelope}),
            ("extra_skeleton_field", {"record_skeleton": extra_skeleton_path}),
        )
        for name, override in mutants:
            with self.subTest(mutant=name):
                rejected = invoke(**override)
                self.assertEqual(rejected.returncode, 2)
                self.assertEqual(
                    loads_object(rejected.stdout),
                    {
                        "schema_version": 1,
                        "status": "invalid",
                        "error": "page_record.input_invalid",
                    },
                )

    def test_record_skeleton_schema_matches_closed_runtime_contract(self) -> None:
        # Given
        schema = load_object(PAGE_ROOT / "schemas/record-skeleton.schema.json")

        # When
        required = set(schema["required"])
        properties = set(schema["properties"])

        # Then
        self.assertEqual(required, SKELETON_KEYS)
        self.assertEqual(properties, SKELETON_KEYS)
        self.assertFalse(schema["additionalProperties"])

    def test_full_gate_chain_recomputes_self_consistent_prior_receipt(self) -> None:
        # Given
        (
            development_fixtures,
            development_records,
            development_records_path,
            development_receipt,
            development_receipt_path,
        ) = self._development()
        development_bundle = _development_bundle(
            development_records,
            development_fixtures,
        )
        synthesis_input, transcript, lint_report, promotion = _promotion_from_development(
            development_bundle,
            feedback_generator_digest=self.manifest["categories"]["feedback"]["sha256"],
        )
        development_bundle_path = self._write(
            "development-bundle.json",
            development_bundle,
        )
        synthesis_input_path = self._write("synthesis-input.json", synthesis_input)
        transcript_path = self._write("synthesis-transcript.json", transcript)
        lint_report_path = self._write("lint-report.json", lint_report)
        promotion_receipt_path = self._write(
            "promotion-receipt.json",
            promotion["promotion_receipt"],
        )
        active_lesson_set_path = self._write(
            "active-lesson-set.json",
            promotion["active_lesson_set"],
        )
        promotion_arguments = (
            "--development-receipt",
            str(development_receipt_path),
            "--development-records",
            str(development_records_path),
            "--synthesis-input",
            str(synthesis_input_path),
            "--development-bundle",
            str(development_bundle_path),
            "--synthesis-transcript",
            str(transcript_path),
            "--lint-report",
            str(lint_report_path),
            "--promotion-receipt",
            str(promotion_receipt_path),
            "--active-lesson-set",
            str(active_lesson_set_path),
        )

        regression_fixtures = _actual_fixtures("regression")
        regression_records = _bind_records_to_run_order(
            _records(
                regression_fixtures,
                ("clean", "lesson-conditioned"),
                scorer_digest=self.scorer_digest,
            ),
            regression_fixtures,
            self.run_order,
            "regression",
        )
        _bind_promotion(
            regression_records,
            regression_fixtures,
            promotion,
            scorer_digest=self.scorer_digest,
        )
        regression_records_path = self._write(
            "regression-records.json",
            {"schema_version": 1, "records": regression_records},
        )
        # When
        regression_completed = self._invoke(
            "regression",
            regression_records_path,
            *promotion_arguments,
        )
        # Then
        self.assertEqual(
            regression_completed.returncode,
            0,
            regression_completed.stderr + regression_completed.stdout,
        )
        regression_receipt = loads_object(regression_completed.stdout)
        self.assertIn(
            regression_receipt["result"]["outcome"],
            {"regression_promoted", "regression_promoted_not_testable"},
        )
        regression_receipt_path = self._write(
            "regression-receipt.json",
            regression_receipt,
        )

        alternate_records = copy.deepcopy(development_records)
        alternate = alternate_records[0]
        alternate["parsed_output"]["evidence"].reverse()
        _rescore(
            alternate_records,
            development_fixtures,
            scorer_digest=self.scorer_digest,
        )
        alternate_bundle = _development_bundle(
            alternate_records,
            development_fixtures,
        )
        (
            alternate_synthesis_input,
            alternate_transcript,
            alternate_lint_report,
            alternate_promotion,
        ) = _promotion_from_development(
            alternate_bundle,
            feedback_generator_digest=self.manifest["categories"]["feedback"]["sha256"],
        )
        self.assertEqual(
            alternate_synthesis_input["selected_target_classes"],
            synthesis_input["selected_target_classes"],
        )
        alternate_bundle_path = self._write(
            "alternate-development-bundle.json",
            alternate_bundle,
        )
        alternate_synthesis_path = self._write(
            "alternate-synthesis-input.json",
            alternate_synthesis_input,
        )
        alternate_transcript_path = self._write(
            "alternate-synthesis-transcript.json",
            alternate_transcript,
        )
        alternate_lint_path = self._write(
            "alternate-lint-report.json",
            alternate_lint_report,
        )
        alternate_promotion_path = self._write(
            "alternate-promotion-receipt.json",
            alternate_promotion["promotion_receipt"],
        )
        alternate_active_path = self._write(
            "alternate-active-lesson-set.json",
            alternate_promotion["active_lesson_set"],
        )
        alternate_arguments = (
            "--development-receipt",
            str(development_receipt_path),
            "--development-records",
            str(development_records_path),
            "--synthesis-input",
            str(alternate_synthesis_path),
            "--development-bundle",
            str(alternate_bundle_path),
            "--synthesis-transcript",
            str(alternate_transcript_path),
            "--lint-report",
            str(alternate_lint_path),
            "--promotion-receipt",
            str(alternate_promotion_path),
            "--active-lesson-set",
            str(alternate_active_path),
        )
        alternate_rejected = self._invoke(
            "regression",
            regression_records_path,
            *alternate_arguments,
        )
        self.assertEqual(alternate_rejected.returncode, 2)
        alternate_rejection = loads_object(alternate_rejected.stdout)
        self.assertIn(
            "development bundle differs from accepted development records",
            alternate_rejection["input_error"],
        )

        sealed_fixtures = _actual_fixtures("sealed")
        sealed_records = _bind_records_to_run_order(
            _records(
                sealed_fixtures,
                (
                    "clean",
                    "lesson-conditioned",
                    "post-restart lesson-conditioned",
                ),
                scorer_digest=self.scorer_digest,
            ),
            sealed_fixtures,
            self.run_order,
            "sealed",
        )
        _bind_promotion(
            sealed_records,
            sealed_fixtures,
            promotion,
            scorer_digest=self.scorer_digest,
        )
        lifecycle_receipt, _ = _bind_lifecycle_receipt(sealed_records)
        seal_score_receipts(sealed_records, sealed_fixtures, self.scorer_digest)
        sealed_records_path = self._write(
            "sealed-records.json",
            {"schema_version": 1, "records": sealed_records},
        )
        lifecycle_path = self._write("lifecycle-receipt.json", lifecycle_receipt)
        sealed_arguments = (
            *promotion_arguments,
            "--regression-receipt",
            str(regression_receipt_path),
            "--regression-records",
            str(regression_records_path),
            "--lifecycle-receipt",
            str(lifecycle_path),
        )
        sealed_completed = self._invoke(
            "sealed",
            sealed_records_path,
            *sealed_arguments,
        )
        self.assertEqual(
            sealed_completed.returncode,
            0,
            sealed_completed.stderr + sealed_completed.stdout,
        )
        sealed_receipt = loads_object(sealed_completed.stdout)
        self.assertEqual(sealed_receipt["result"]["outcome"], "page_validated")

        failed_regression_records = copy.deepcopy(regression_records)
        for record in _condition(failed_regression_records, "lesson-conditioned"):
            fixture = regression_fixtures[record["fixture_id"]]
            noise = _noise_atoms(fixture)
            _classify(record, fixture, selected_noise=noise)
        _rescore(
            failed_regression_records,
            regression_fixtures,
            scorer_digest=self.scorer_digest,
        )
        failed_payload = {
            "schema_version": 1,
            "records": failed_regression_records,
        }
        failed_records_path = self._write(
            "failed-regression-records.json",
            failed_payload,
        )
        forged_regression_receipt = build_gate_receipt(
            "regression",
            self.manifest_sha256,
            FREEZE_COMMIT,
            canonical_sha256(self.run_order),
            canonical_sha256(failed_payload),
            regression_fixtures,
            self.scorer_digest,
            canonical_sha256(self.conformance_receipt),
            regression_receipt["result"],
        )
        forged_receipt_path = self._write(
            "forged-regression-receipt.json",
            forged_regression_receipt,
        )
        forged_arguments = (
            *promotion_arguments,
            "--regression-receipt",
            str(forged_receipt_path),
            "--regression-records",
            str(failed_records_path),
            "--lifecycle-receipt",
            str(lifecycle_path),
        )
        rejected = self._invoke(
            "sealed",
            sealed_records_path,
            *forged_arguments,
        )
        self.assertEqual(rejected.returncode, 2)
        rejection = loads_object(rejected.stdout)
        self.assertEqual(rejection["gate_failures"], ["aggregate.input_invalid"])
        self.assertIn(
            "regression gate receipt differs from raw-record recomputation",
            rejection["input_error"],
        )


if __name__ == "__main__":
    unittest.main()
