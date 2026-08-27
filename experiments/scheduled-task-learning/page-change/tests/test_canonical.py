from __future__ import annotations

import os
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
