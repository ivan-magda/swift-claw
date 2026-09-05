from __future__ import annotations

import unittest
from collections.abc import Callable
from typing import Any

from dependency_benchmark.versioning import (
    AffectedInterval,
    Ecosystem,
    VersioningError,
    canonical_package_name,
    canonical_requirement,
    canonical_version,
    compare_versions,
    is_version_affected,
    normalize_ecosystem,
    parse_osv_intervals,
    satisfies_requirement,
    sort_versions,
)


class DependencyVersioningTests(unittest.TestCase):
    def test_supported_ecosystems_follow_the_frozen_version_contract(self) -> None:
        # Given
        normalization_cases = [
            (
                "npm",
                "@scope/package",
                "@scope/package",
                "1.2.3-alpha.1+build.7",
                "1.2.3-alpha.1+build.7",
            ),
            ("PyPI", "Django", "django", "0.12.01", "0.12.1"),
        ]
        satisfaction_cases: list[tuple[Ecosystem, str, str, bool]] = [
            ("npm", "1.5.0", "^1.2.3", True),
            ("npm", "2.0.0", "^1.2.3", False),
            ("npm", "1.2.3-alpha.1", ">=1.0.0 <2.0.0", False),
            ("npm", "1.2.3-alpha.1", ">=1.2.3-alpha.0 <2.0.0", True),
            ("pypi", "1.5a1", ">=1.0", False),
            ("pypi", "1.5a1", ">=1.0a1", True),
        ]

        # When / Then
        for raw_ecosystem, raw_name, name, raw_version, version in normalization_cases:
            with self.subTest(ecosystem=raw_ecosystem, version=raw_version):
                normalized_ecosystem = normalize_ecosystem(raw_ecosystem)
                self.assertEqual(canonical_package_name(normalized_ecosystem, raw_name), name)
                self.assertEqual(canonical_version(normalized_ecosystem, raw_version), version)
        for ecosystem, version, requirement, expected in satisfaction_cases:
            with self.subTest(ecosystem=ecosystem, version=version, requirement=requirement):
                self.assertEqual(satisfies_requirement(ecosystem, version, requirement), expected)
        self.assertEqual(canonical_requirement("npm", "^1.2.3"), ">=1.2.3 <2.0.0")
        self.assertEqual(canonical_requirement("pypi", ">=1.0, <2"), "<2,>=1.0")
        self.assertEqual(compare_versions("npm", "1.2.3+one", "1.2.3+two"), 0)
        self.assertEqual(
            sort_versions("npm", ["1.10.0", "1.2.10", "1.2.3+two", "1.2.3+one"]),
            ("1.2.3+one", "1.2.3+two", "1.2.10", "1.10.0"),
        )
        self.assertEqual(
            sort_versions("pypi", ["1.0.post1", "1.0", "1.0rc1"]),
            ("1.0rc1", "1.0", "1.0.post1"),
        )

    def test_versioning_rejects_unsupported_or_ambiguous_syntax(self) -> None:
        # Given
        invalid_calls: list[tuple[Callable[..., Any], tuple[Any, ...]]] = [
            (normalize_ecosystem, ("Maven",)),
            (canonical_package_name, ("npm", "MixedCase")),
            (canonical_package_name, ("pypi", "foo/bar")),
            (canonical_version, ("npm", "1.2")),
            (canonical_version, ("npm", "01.2.3")),
            (canonical_version, ("npm", "1.2.3-01")),
            (canonical_requirement, ("npm", "1.x")),
            (canonical_requirement, ("npm", "^1.2.3 || ^2.0.0")),
            (canonical_requirement, ("pypi", "===legacy")),
        ]

        # When / Then
        for function, arguments in invalid_calls:
            with (
                self.subTest(function=function.__name__, arguments=arguments),
                self.assertRaises(VersioningError),
            ):
                function(*arguments)

    def test_osv_events_preserve_branch_pairs_and_fixed_exclusivity(self) -> None:
        # Given
        descending_branch_events = [
            {"introduced": "4.0"},
            {"fixed": "4.0.4"},
            {"introduced": "3.2"},
            {"fixed": "3.2.13"},
            {"introduced": "2.2"},
            {"fixed": "2.2.28"},
            {"introduced": "2.2"},
            {"fixed": "2.2.28"},
        ]

        # When
        intervals = parse_osv_intervals("pypi", descending_branch_events)

        # Then
        self.assertEqual(
            intervals,
            (
                AffectedInterval("2.2", "2.2.28"),
                AffectedInterval("3.2", "3.2.13"),
                AffectedInterval("4.0", "4.0.4"),
            ),
        )
        self.assertTrue(is_version_affected("pypi", "3.2.12", intervals))
        self.assertFalse(is_version_affected("pypi", "3.2.13", intervals))
        self.assertTrue(is_version_affected("pypi", "3.1", intervals, ("3.1",)))
        for invalid_events in (
            [{"fixed": "1.0"}, {"introduced": "0"}],
            [{"introduced": "0"}],
            [{"introduced": "0"}, {"last_affected": "1.0"}],
            [
                {"introduced": "0"},
                {"fixed": "2.0"},
                {"introduced": "1.0"},
                {"fixed": "3.0"},
            ],
        ):
            with self.subTest(invalid_events=invalid_events), self.assertRaises(VersioningError):
                parse_osv_intervals("pypi", invalid_events)


if __name__ == "__main__":
    unittest.main()
