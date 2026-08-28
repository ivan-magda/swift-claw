from __future__ import annotations

import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from tools.page_change_freeze import cli, contract
from tools.page_change_freeze.tests.support import FreezeRepository


class CLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = FreezeRepository()

    def tearDown(self) -> None:
        self.repo.cleanup()

    def _generate(self, output: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "/usr/bin/python3", "-I",
                str(self.repo.root / contract.FREEZE_VERIFIER_PATH),
                "generate",
                "--repo-root", str(self.repo.root),
                "--descriptor", str(self.repo.root / contract.MANIFEST_DESCRIPTOR_PATH),
                "--output", str(output),
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_cli_names_offline_live_and_local_runtime_checks_honestly(self) -> None:
        # given
        expected_commands = (
            "generate-recovery-ledger", "generate-replacement-delta",
            "verify-record-consistency", "verify-live-freeze", "verify-runtime-binding",
        )

        # when
        help_text = cli.parser().format_help()

        # then
        for command in expected_commands:
            self.assertIn(command, help_text)
        self.assertNotIn("verify-approved", help_text)

    def test_cli_generate_runs_through_isolated_entry_point(self) -> None:
        # given
        output = self.repo.root / f"{contract.PAGE_ROOT}/freeze/generated-manifest.json"

        # when
        result = self._generate(output)

        # then
        self.assertEqual(result.returncode, 0, result.stderr)
        value, raw = contract.load_json(output)
        self.assertEqual(raw, contract.canonical_json_bytes(value))
        self.assertEqual(value["manifest_kind"], contract.MANIFEST_KIND)
        self.assertIn(f"manifest_sha256={contract.sha256_hex(raw)}", result.stdout)

    def test_cli_generate_rejects_outside_and_symlink_outputs(self) -> None:
        cases: list[tuple[str, Path, bytes | None]] = []
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        cases.append(("outside", Path(outside.name) / "manifest.json", None))
        target = self.repo.root / f"{contract.PAGE_ROOT}/freeze/existing.json"
        target.write_bytes(b"preserve me")
        symlink = target.with_name("manifest-link.json")
        symlink.symlink_to(target)
        cases.append(("symlink", symlink, target.read_bytes()))

        for name, output, target_before in cases:
            with self.subTest(name=name):
                # given
                expected_error = "outside the repository" if name == "outside" else "may not be a symlink"

                # when
                result = self._generate(output)

                # then
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected_error, result.stderr)
                if name == "outside":
                    self.assertFalse(output.exists())
                else:
                    self.assertEqual(target.read_bytes(), target_before)

    def test_isolated_bootstrap_uses_unique_package_and_stdlib(self) -> None:
        # given
        self.repo.write(f"{contract.FREEZE_PACKAGE_ROOT}/hashlib.py",
                        b"raise RuntimeError('shadowed hashlib')\n")
        bootstrap = self.repo.root / contract.FREEZE_VERIFIER_PATH

        # when
        result = subprocess.run(
            ["/usr/bin/python3", "-I", str(bootstrap), "--help"],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

        # then
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("verify-live-freeze", result.stdout)

        ambient = self.repo.root / "ambient"
        self.repo.write("ambient/tools/__init__.py", b"")
        self.repo.write("ambient/tools/page_change_freeze/__init__.py", b"")
        self.repo.write("ambient/tools/page_change_freeze/cli.py",
                        b"raise RuntimeError('ambient tools package won')\n")
        launcher = (
            "import runpy,sys;"
            f"sys.path.append({str(ambient)!r});"
            f"sys.argv=[{str(bootstrap)!r},'--help'];"
            f"runpy.run_path({str(bootstrap)!r},run_name='__main__')"
        )
        isolated = subprocess.run(
            ["/usr/bin/python3", "-I", "-c", launcher], check=False,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.assertEqual(isolated.returncode, 0, isolated.stderr)
        self.assertIn("verify-live-freeze", isolated.stdout)

        for relative in ("__pycache__/cli.cpython-311.pyc", "cli.so"):
            with self.subTest(relative=relative):
                # given
                import_artifact = f"{contract.FREEZE_PACKAGE_ROOT}/{relative}"
                self.repo.write(import_artifact, b"untrusted import bytes")

                # when
                rejected = subprocess.run(
                    ["/usr/bin/python3", "-I", str(bootstrap), "--help"],
                    check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )

                # then
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("forbidden import artifact", rejected.stderr)
                artifact_path = self.repo.root / import_artifact
                artifact_path.unlink()
                if artifact_path.parent.name == "__pycache__":
                    artifact_path.parent.rmdir()

    def test_isolated_bootstrap_rejects_symlinked_source_before_import(self) -> None:
        # given
        bootstrap = self.repo.root / contract.FREEZE_VERIFIER_PATH
        cli_path = self.repo.root / contract.FREEZE_PACKAGE_ROOT / "cli.py"
        real_cli = cli_path.with_name("real-cli.py")
        cli_path.rename(real_cli)
        cli_path.symlink_to(real_cli)

        # when
        rejected = subprocess.run(
            ["/usr/bin/python3", "-I", str(bootstrap), "--help"],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

        # then
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("forbidden import artifact", rejected.stderr)

    def test_isolated_bootstrap_rechecks_closure_when_import_fails(self) -> None:
        # given
        bootstrap = self.repo.root / contract.FREEZE_VERIFIER_PATH
        cli_path = self.repo.root / contract.FREEZE_PACKAGE_ROOT / "cli.py"
        created = self.repo.root / contract.FREEZE_PACKAGE_ROOT / "created.pyc"
        cli_path.write_text(
            "from pathlib import Path\n"
            f"Path({str(created)!r}).write_bytes(b'unprotected')\n"
            "raise RuntimeError('import failed')\n"
        )

        # when
        rejected = subprocess.run(
            ["/usr/bin/python3", "-I", str(bootstrap), "--help"],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

        # then
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("forbidden import artifact", rejected.stderr)

    def test_receipt_file_and_stdout_share_one_canonical_lf(self) -> None:
        # given
        receipt = {"schema_version": 1, "status": "verified"}
        output = self.repo.root / "receipts/stage.json"
        output.parent.mkdir()
        stream = io.BytesIO()

        # when
        raw = cli.emit_receipt(receipt, output_path=output, stream=stream)

        # then
        self.assertEqual(output.read_bytes(), raw)
        self.assertEqual(stream.getvalue(), raw)
        self.assertTrue(raw.endswith(b"\n"))
        self.assertFalse(raw.endswith(b"\n\n"))
        self.assertEqual(json.loads(raw), receipt)


if __name__ == "__main__":
    unittest.main()
