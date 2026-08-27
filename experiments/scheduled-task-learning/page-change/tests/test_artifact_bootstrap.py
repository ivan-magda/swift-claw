from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from path_test_support import PAGE_ROOT


class ArtifactBootstrapTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.page_root = Path(self.temporary.name) / "page-change"
        artifacts = self.page_root / "artifacts"
        artifacts.mkdir(parents=True)
        self.bootstrap = artifacts / "page-bootstrap"
        shutil.copy2(PAGE_ROOT / "artifacts/page-bootstrap", self.bootstrap)
        self.bootstrap.chmod(0o755)
        shutil.copytree(
            PAGE_ROOT / "page_benchmark",
            self.page_root / "page_benchmark",
            ignore=shutil.ignore_patterns(
                "__pycache__",
                "*.pyc",
                "*.pyo",
                "*.so",
                "*.dylib",
                "*.pyd",
            ),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _run_scorer(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/usr/bin/python3", "-I", str(self.bootstrap), "scorer", "--help"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_role_bootstrap_disables_bytecode_writes(self) -> None:
        # given
        package_root = self.page_root / "page_benchmark"

        # when
        result = self._run_scorer()

        # then
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(package_root.rglob("*.pyc")))
        self.assertFalse(any(path.name == "__pycache__" for path in package_root.rglob("*")))

    def test_role_wrapper_isolates_standard_library_imports(self) -> None:
        # given
        artifacts = self.page_root / "artifacts"
        wrapper = artifacts / "page-feedback"
        shutil.copy2(PAGE_ROOT / "artifacts/page-feedback", wrapper)
        wrapper.chmod(0o755)
        (artifacts / "hashlib.py").write_text(
            'raise RuntimeError("artifact hashlib shadow was imported")\n',
            encoding="utf-8",
        )

        # when
        isolated = subprocess.run(
            [str(wrapper), "--help"],
            cwd=self.page_root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        mutant = artifacts / "page-feedback-without-isolation"
        mutant.write_text(
            wrapper.read_text(encoding="utf-8").replace("python3 -I", "python3"),
            encoding="utf-8",
        )
        mutant.chmod(0o755)
        unisolated = subprocess.run(
            [str(mutant), "--help"],
            cwd=self.page_root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # then
        self.assertEqual(isolated.returncode, 0, isolated.stderr)
        self.assertNotEqual(unisolated.returncode, 0)
        self.assertIn("artifact hashlib shadow was imported", unisolated.stderr)

    def test_every_role_wrapper_is_executable_and_dispatches(self) -> None:
        # given — these are the complete protected benchmark roles, not interchangeable samples.
        wrappers = {
            "page-synthesis": "--feedback-generator-sha256",
            "page-lesson-lint": "--candidate",
            "page-promotion": "--artifact-output",
            "page-aggregate": "{development,regression,sealed}",
            "page-record": "--skeleton",
            "page-conformance": "[root]",
            "page-scorer": "--source",
            "page-feedback": "--templates",
        }

        # when
        observations = [
            (
                wrapper,
                distinctive_help,
                subprocess.run(
                    [str(PAGE_ROOT / "artifacts" / wrapper), "--help"],
                    cwd=PAGE_ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                ),
            )
            for wrapper, distinctive_help in wrappers.items()
        ]

        # then
        for wrapper, distinctive_help, result in observations:
            with self.subTest(wrapper=wrapper):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(distinctive_help, result.stdout)

    def test_role_bootstrap_rejects_preexisting_import_artifacts(self) -> None:
        package_root = self.page_root / "page_benchmark"
        cases = (
            ("__pycache__/rogue.pyc", "bytecode caches"),
            ("rogue.so", "non-source import artifact"),
        )
        for relative, expected_error in cases:
            with self.subTest(relative=relative):
                # given
                candidate = package_root / relative
                candidate.parent.mkdir(exist_ok=True)
                candidate.write_bytes(b"unprotected import bytes")

                try:
                    # when
                    result = self._run_scorer()

                    # then
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected_error, result.stderr)
                finally:
                    candidate.unlink(missing_ok=True)
                    if candidate.parent.name == "__pycache__":
                        candidate.parent.rmdir()

    def test_role_bootstrap_rechecks_closure_when_import_fails(self) -> None:
        # given
        package_root = self.page_root / "page_benchmark"
        created = package_root / "created.pyc"
        (package_root / "scorer.py").write_text(
            "from pathlib import Path\n"
            f"Path({str(created)!r}).write_bytes(b'unprotected')\n"
            "raise RuntimeError('import failed')\n"
        )

        # when
        result = self._run_scorer()

        # then
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-source import artifact", result.stderr)


if __name__ == "__main__":
    unittest.main()
