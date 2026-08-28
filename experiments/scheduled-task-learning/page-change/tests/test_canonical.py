from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from page_benchmark.canonical import (
    StrictJSONError,
    canonical_sha256,
    dumps,
    load_object,
    loads_object,
    write,
)

from path_test_support import PAGE_ROOT as ROOT


class StrictJSONTests(unittest.TestCase):
    def test_canonical_serializer_matches_cross_language_vector(self) -> None:
        # Given
        vector = load_object(ROOT / "contracts/canonical-json-vector.json")

        # When
        rendered = dumps(vector["value"])

        # Then
        self.assertEqual(rendered, vector["canonical_json"])
        self.assertEqual(
            canonical_sha256(vector["value"]),
            vector["canonical_sha256"],
        )

    def test_writer_replaces_leaf_links_without_modifying_their_targets(self) -> None:
        for link_kind in ("symbolic", "hard"):
            with self.subTest(link_kind=link_kind), tempfile.TemporaryDirectory() as directory:
                # Given
                root = Path(directory)
                protected = root / "protected.txt"
                protected.write_bytes(b"keep me")
                output = root / "artifact.json"
                if link_kind == "symbolic":
                    output.symlink_to(protected)
                else:
                    os.link(protected, output)

                # When
                write(output, {"published": True})

                # Then
                self.assertEqual(protected.read_bytes(), b"keep me")
                self.assertEqual(output.read_text(encoding="utf-8"), '{"published":true}\n')

    def test_page_record_canonicalize_normalizes_problematic_fraction_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            # Given
            root = Path(directory)
            source = root / "swift-draft.json"
            source.write_text(
                '{"two_thirds":0.66666700000000001,"one_third":0.33333299999999999}\n',
                encoding="utf-8",
            )
            output = root / "canonical.json"

            # When
            completed = subprocess.run(  # noqa: S603 - fixed protected executable
                [
                    str(ROOT / "artifacts/page-record"),
                    "canonicalize",
                    "--input",
                    str(source),
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

            # Then
            self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
            self.assertEqual(completed.stdout, "")
            self.assertEqual(
                output.read_bytes(),
                b'{"one_third":0.333333,"two_thirds":0.666667}\n',
            )

    def test_page_record_canonicalize_fails_closed_for_invalid_json(self) -> None:
        mutants = {
            "malformed": '{"value":',
            "duplicate": '{"value":1,"value":2}',
            "nonfinite": '{"value":NaN}',
        }
        for name, raw in mutants.items():
            with self.subTest(mutant=name), tempfile.TemporaryDirectory() as directory:
                # Given
                root = Path(directory)
                source = root / "invalid.json"
                source.write_text(raw, encoding="utf-8")
                output = root / "canonical.json"

                # When
                completed = subprocess.run(  # noqa: S603 - fixed protected executable
                    [
                        str(ROOT / "artifacts/page-record"),
                        "canonicalize",
                        "--input",
                        str(source),
                        "--output",
                        str(output),
                    ],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )

                # Then
                self.assertEqual(completed.returncode, 2)
                self.assertEqual(
                    loads_object(completed.stdout),
                    {
                        "schema_version": 1,
                        "status": "invalid",
                        "error": "page_record.input_invalid",
                    },
                )
                self.assertFalse(output.exists())

    def test_page_record_bundle_preserves_integral_float_receipt_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            # Given
            root = Path(directory)
            first = root / "first.json"
            second = root / "second.json"
            write(first, {"attempt_id": "first", "score": 1.0})
            write(second, {"attempt_id": "second", "score": 0.5})
            output = root / "records.json"

            # When
            completed = subprocess.run(  # noqa: S603 - fixed protected executable
                [
                    str(ROOT / "artifacts/page-record"),
                    "bundle",
                    "--record",
                    str(first),
                    "--record",
                    str(second),
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

            # Then
            self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
            self.assertEqual(
                output.read_bytes(),
                b'{"records":[{"attempt_id":"first","score":1.0},'
                b'{"attempt_id":"second","score":0.5}],"schema_version":1}\n',
            )

    def test_rejects_duplicate_object_keys(self) -> None:
        # Given
        raw = '{"task_id":"a","task_id":"b"}'

        # When
        with self.assertRaises(StrictJSONError) as raised:
            loads_object(raw)

        # Then
        self.assertRegex(str(raised.exception), "duplicate object key")

    def test_rejects_content_after_root_object(self) -> None:
        # Given
        raw = '{"ok":true} trailing'

        # When
        with self.assertRaises(StrictJSONError) as raised:
            loads_object(raw)

        # Then
        self.assertRegex(
            str(raised.exception),
            "surrounding text or a second JSON value",
        )

    def test_rejects_python_non_json_numeric_constant(self) -> None:
        # Given
        raw = '{"value":NaN}'

        # When
        with self.assertRaises(StrictJSONError) as raised:
            loads_object(raw)

        # Then
        self.assertRegex(str(raised.exception), "non-JSON numeric constant")


if __name__ == "__main__":
    unittest.main()
