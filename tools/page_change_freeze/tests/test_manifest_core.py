from __future__ import annotations

import copy
import json
from pathlib import Path
import struct
import unittest

from tools.page_change_freeze import artifacts, contract, manifest
from tools.page_change_freeze.tests.support import FreezeRepository


class ManifestCoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = FreezeRepository()

    def tearDown(self) -> None:
        self.repo.cleanup()

    def test_generation_is_canonical_and_input_order_independent(self) -> None:
        # given
        reversed_descriptor = copy.deepcopy(self.repo.descriptor)
        reversed_descriptor["categories"] = dict(
            reversed(list(reversed_descriptor["categories"].items()))
        )
        for category in reversed_descriptor["categories"].values():
            category["artifacts"].reverse()

        # when
        first = self.repo.manifest_raw()
        second = self.repo.manifest_raw(reversed_descriptor)

        # then
        self.assertEqual(first, second)
        self.assertFalse(first.endswith(b"\n"))
        self.assertEqual(set(json.loads(first)["categories"]), set(contract.CATEGORY_NAMES))
        self.assertNotIn(b"freeze_commit", first)
        manifest.verify_structure(json.loads(first), first)

    def test_descriptor_requires_exact_categories_protocol_and_dependency_roles(self) -> None:
        # given
        mutations = []
        missing_category = copy.deepcopy(self.repo.descriptor)
        del missing_category["categories"]["scorer"]
        mutations.append((missing_category, "wrong keys"))
        protocol = copy.deepcopy(self.repo.descriptor)
        protocol["protocol"]["sha256"] = "0" * 64
        mutations.append((protocol, "exact approved protocol"))
        dependency = copy.deepcopy(self.repo.descriptor)
        dependency["categories"]["dependencies"]["artifacts"].pop()
        mutations.append((dependency, "requires role"))
        for category in ("feedback", "lesson_linter"):
            wrong_core_provenance = copy.deepcopy(self.repo.descriptor)
            wrong_core_provenance["categories"][category]["artifacts"] = [
                item
                for item in wrong_core_provenance["categories"][category]["artifacts"]
                if item["path"] != f"{contract.BENCHMARK_CORE_ROOT}/canonical.py"
            ]
            mutations.append(
                (wrong_core_provenance, f"{category} benchmark-core sources")
            )
        for candidate, message in mutations:
            with self.subTest(message=message):
                # when
                with self.assertRaises(contract.FreezeError) as raised:
                    self.repo.make_manifest(candidate)

                # then
                self.assertRegex(str(raised.exception), message)

    def test_descriptor_values_are_content_bound_without_duplicating_runtime_semantics(self) -> None:
        # given
        baseline = self.repo.make_manifest()
        changed_descriptor = copy.deepcopy(self.repo.descriptor)
        changed_descriptor["categories"]["budget"]["values"]["attempt_cap"] = 77

        # when
        changed = self.repo.make_manifest(changed_descriptor)

        # then
        self.assertNotEqual(
            contract.canonical_json_bytes(baseline),
            contract.canonical_json_bytes(changed),
        )

        # given
        forged = copy.deepcopy(baseline)
        forged["categories"]["budget"]["values"]["attempt_cap"] = 77
        payload = {key: forged["categories"]["budget"][key] for key in ("artifacts", "values")}
        forged["categories"]["budget"]["sha256"] = contract.sha256_hex(
            contract.canonical_json_bytes(payload)
        )
        # when
        with self.assertRaises(contract.FreezeError) as raised:
            manifest.verify_files(self.repo.root, forged,
                                  package_description=self.repo.package_description)

        # then
        self.assertRegex(str(raised.exception), "protected descriptor")

    def test_protocol_rejects_bom_and_invalid_utf8_before_hashing(self) -> None:
        # given
        path = self.repo.root / contract.PROTOCOL_PATH
        original = path.read_bytes()
        for raw, message in ((b"\xef\xbb\xbf" + original, "byte-order mark"),
                             (b"\xff", "not UTF-8")):
            with self.subTest(message=message):
                path.write_bytes(raw)

                # when
                with self.assertRaises(contract.FreezeError) as raised:
                    self.repo.make_manifest()

                # then
                self.assertRegex(str(raised.exception), message)
                path.write_bytes(original)

    def test_full_artifact_and_verifier_module_closures_are_exact(self) -> None:
        # given
        for mutation, expected in (("schema", "full file closure"),
                                   ("verifier", "freeze_verifier_source count"),
                                   ("core", "benchmark source categories"),
                                   ("shadow", "shadow")):
            with self.subTest(mutation=mutation):
                descriptor = copy.deepcopy(self.repo.descriptor)
                if mutation == "schema":
                    descriptor["categories"]["schemas"]["artifacts"].pop()
                elif mutation == "verifier":
                    descriptor["categories"]["configuration"]["artifacts"] = [
                        item for item in descriptor["categories"]["configuration"]["artifacts"]
                        if item["path"] != f"{contract.FREEZE_PACKAGE_ROOT}/approval.py"]
                elif mutation == "core":
                    self.repo.write(
                        f"{contract.BENCHMARK_CORE_ROOT}/unlisted.py",
                        b"VALUE = 2\n",
                    )
                else:
                    self.repo.write(f"{contract.PAGE_ROOT}/hashlib.py", b"raise RuntimeError\n")

                # when
                with self.assertRaises(contract.FreezeError) as raised:
                    self.repo.make_manifest(descriptor)

                # then
                self.assertRegex(str(raised.exception), expected)
                if mutation == "core":
                    (self.repo.root / contract.BENCHMARK_CORE_ROOT / "unlisted.py").unlink()

    def test_python_closures_reject_unprotected_import_artifacts(self) -> None:
        for suffix in (".pyc", ".so"):
            with self.subTest(suffix=suffix):
                # given
                candidate = self.repo.root / contract.BENCHMARK_PACKAGE_ROOT / f"unlisted{suffix}"
                candidate.write_bytes(b"unprotected import bytes")

                # when
                with self.assertRaises(contract.FreezeError) as raised:
                    self.repo.make_manifest()

                # then
                self.assertRegex(str(raised.exception), "non-source import artifact")
                candidate.unlink()

    def test_swiftpm_transitive_source_and_resource_closure_is_exact(self) -> None:
        # given
        description = copy.deepcopy(self.repo.package_description)
        description["targets"][0]["resources"] = [
            {"path": str(self.repo.root / "Sources/Runtime/data.json")}
        ]
        self.repo.write("Sources/Runtime/data.json", b"{}\n")

        # when
        with self.assertRaises(contract.FreezeError) as raised:
            self.repo.make_manifest(package_description=description)

        # then
        self.assertRegex(str(raised.exception), "transitive target source/resource")

    def test_executable_rejects_mode_symlink_and_wrong_architecture(self) -> None:
        # given
        path = self.repo.root / contract.EXECUTABLE_PATH
        baseline = path.read_bytes()
        for mutation, message in (("mode", "owner-execute"), ("symlink", "symlinks are forbidden"),
                                  ("arch", "Mach-O arm64")):
            with self.subTest(mutation=mutation):
                if mutation == "mode":
                    path.chmod(0o644)
                elif mutation == "symlink":
                    target = path.with_name("target")
                    path.rename(target)
                    path.symlink_to(target)
                else:
                    path.write_bytes(struct.pack("<II", artifacts.MACHO_MAGIC_64, 7))

                # when
                with self.assertRaises(contract.FreezeError) as raised:
                    self.repo.make_manifest()

                # then
                self.assertRegex(str(raised.exception), message)
                if path.is_symlink():
                    path.unlink()
                    path.with_name("target").rename(path)
                path.write_bytes(baseline)
                path.chmod(0o755)

    def test_file_verification_detects_changed_bytes_and_descriptor_drift(self) -> None:
        # given
        value = self.repo.make_manifest()
        self.repo.write(contract.TASK_PROMPT_PATH, b"changed\n")

        # when
        with self.assertRaises(contract.FreezeError) as raised:
            manifest.verify_files(self.repo.root, value,
                                  package_description=self.repo.package_description)

        # then
        self.assertRegex(str(raised.exception), "protected artifact mismatch")

    def test_structure_rejects_category_deletion_and_digest_mutation(self) -> None:
        # given
        value = self.repo.make_manifest()
        missing = copy.deepcopy(value)
        del missing["categories"]["gold"]
        changed = copy.deepcopy(value)
        changed["categories"]["budget"]["sha256"] = "0" * 64
        for candidate, message in ((missing, "wrong keys"), (changed, "digest mismatch")):
            with self.subTest(message=message):
                # when
                with self.assertRaises(contract.FreezeError) as raised:
                    manifest.verify_structure(candidate, contract.canonical_json_bytes(candidate))

                # then
                self.assertRegex(str(raised.exception), message)

    def test_protected_conformance_runner_must_emit_canonical_24_of_24(self) -> None:
        # given
        runner = self.repo.root / contract.CONFORMANCE_EXECUTABLE_PATH
        mutations = (
            (b"#!/bin/sh\nprintf 'failed\\n' >&2\nexit 7\n", "runner failed"),
            (b"#!/bin/sh\nprintf '{\"passed\":23,\"total\":24}\\n'\n", "24/24"),
            (b"#!/bin/sh\nprintf '{\"passed\":24,\"total\":25}\\n'\n", "24/24"),
            (b"#!/bin/sh\nprintf '{\"passed\":24, \"total\":24}\\n'\n", "canonical JSON"),
        )

        for script, message in mutations:
            with self.subTest(message=message):
                runner.write_bytes(script)
                runner.chmod(0o755)

                # when
                with self.assertRaises(contract.FreezeError) as raised:
                    self.repo.make_manifest()

                # then
                self.assertRegex(str(raised.exception), message)

    def test_real_swiftpm_description_matches_injected_shape(self) -> None:
        # given
        expected_targets = ["ClawEvaluation", "Runtime", "claw-eval"]

        # when
        description = artifacts.run_swift_package_describe(self.repo.root)
        value = self.repo.make_manifest(package_description=description)

        # then
        self.assertEqual(value["swift_package"]["target_closure"],
                         expected_targets)


if __name__ == "__main__":
    unittest.main()
