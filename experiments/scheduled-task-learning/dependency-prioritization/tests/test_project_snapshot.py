from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from benchmark_core.canonical import dumps
from dependency_benchmark.project_snapshot import (
    ProjectSnapshotError,
    dependency_paths,
    incoming_requirements,
    load_project_snapshot,
    parse_project_snapshot,
)

from support import project_snapshot_value


class DependencyProjectSnapshotTests(unittest.TestCase):
    def test_graph_derives_bounded_paths_first_edge_scope_and_all_constraints(self) -> None:
        # Given
        value = project_snapshot_value()

        # When
        snapshot = parse_project_snapshot(value)
        django_paths = dependency_paths(snapshot)["django"]
        requirements = incoming_requirements(snapshot, "django")

        # Then
        self.assertEqual(snapshot.root.package_name, "fixture-app")
        self.assertEqual(
            [
                (
                    path.node_keys,
                    path.package_chain,
                    path.relationship,
                    path.runtime_scope,
                )
                for path in django_paths
            ],
            [
                (
                    ("root", "django"),
                    ("pypi:fixture-app@1.0.0", "pypi:django@3.2.12"),
                    "direct",
                    "production",
                ),
                (
                    ("root", "helper", "django"),
                    (
                        "pypi:fixture-app@1.0.0",
                        "pypi:fixture-helper@1.5.0",
                        "pypi:django@3.2.12",
                    ),
                    "transitive",
                    "development_only",
                ),
            ],
        )
        self.assertEqual(requirements, ("<3.3,>=3.2", "<4,>=3.2"))

        reordered = copy.deepcopy(value)
        reordered["dependencies"].reverse()
        reordered["root_dependencies"].reverse()
        reordered["release_inventories"][0]["releases"].reverse()
        changed = copy.deepcopy(value)
        changed["finding_facts"][0]["manifest_evidence"] = ["Different evidence."]
        self.assertEqual(
            parse_project_snapshot(reordered).semantic_sha256, snapshot.semantic_sha256
        )
        self.assertNotEqual(
            parse_project_snapshot(changed).semantic_sha256, snapshot.semantic_sha256
        )

        unknown_property = copy.deepcopy(value)
        unknown_property["root"]["unexpected"] = True
        incompatible_install = copy.deepcopy(value)
        incompatible_install["dependency_edges"][0]["requirement"] = ">=3.3,<4"
        cycle = copy.deepcopy(value)
        cycle["dependency_edges"].append(
            {
                "parent_node_key": "django",
                "child_node_key": "helper",
                "requirement": ">=1,<2",
            }
        )
        for invalid in (unknown_property, incompatible_install, cycle):
            with self.subTest(invalid=invalid), self.assertRaises(ProjectSnapshotError):
                parse_project_snapshot(invalid)

    def test_equivalent_releases_and_non_finding_path_fan_in_are_deterministic(self) -> None:
        # Given
        equivalent_release = project_snapshot_value()
        equivalent_release["release_inventories"][0]["releases"].append(
            {"version": "3.2.13.0", "availability": "available"}
        )
        equivalent_snapshot = parse_project_snapshot(equivalent_release)
        reversed_equivalent_release = copy.deepcopy(equivalent_release)
        reversed_equivalent_release["release_inventories"][0]["releases"].reverse()
        self.assertEqual(
            parse_project_snapshot(reversed_equivalent_release).semantic_sha256,
            equivalent_snapshot.semantic_sha256,
        )
        duplicate_release = copy.deepcopy(equivalent_release)
        duplicate_release["release_inventories"][0]["releases"].append(
            {"version": "3.2.13", "availability": "unavailable"}
        )
        with self.assertRaises(ProjectSnapshotError):
            parse_project_snapshot(duplicate_release)

        many_non_finding_paths = project_snapshot_value()
        many_non_finding_paths["dependencies"].append(
            {
                "node_key": "fan-in",
                "package_name": "fixture-fan-in",
                "installed_version": "1.0.0",
            }
        )
        for index in range(9):
            node_key = f"bridge-{index}"
            many_non_finding_paths["dependencies"].append(
                {
                    "node_key": node_key,
                    "package_name": f"fixture-bridge-{index}",
                    "installed_version": "1.0.0",
                }
            )
            many_non_finding_paths["root_dependencies"].append(
                {
                    "child_node_key": node_key,
                    "requirement": ">=1,<2",
                    "runtime_scope": "production",
                }
            )
            many_non_finding_paths["dependency_edges"].append(
                {
                    "parent_node_key": node_key,
                    "child_node_key": "fan-in",
                    "requirement": ">=1,<2",
                }
            )
        parse_project_snapshot(many_non_finding_paths)

    def test_loader_rejects_non_regular_symlinked_and_escaping_paths(self) -> None:
        # Given
        value = project_snapshot_value()
        snapshot = parse_project_snapshot(value)

        # When / Then
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            actual = root / "actual"
            actual.mkdir()
            snapshot_path = actual / "snapshot.json"
            snapshot_path.write_text(dumps(value), encoding="utf-8")
            linked = root / "linked"
            linked.symlink_to(actual, target_is_directory=True)
            child = actual / "child"
            child.mkdir()
            outside = root / "outside.json"
            outside.write_text(dumps(value), encoding="utf-8")
            self.assertEqual(load_project_snapshot(snapshot_path), snapshot)
            for invalid_path in (linked / "snapshot.json", actual):
                with (
                    self.subTest(invalid_path=invalid_path),
                    self.assertRaises(ProjectSnapshotError),
                ):
                    load_project_snapshot(invalid_path)
            with self.assertRaises(ProjectSnapshotError):
                load_project_snapshot(
                    child / ".." / ".." / "outside.json",
                    snapshot_root=actual,
                )


if __name__ == "__main__":
    unittest.main()
