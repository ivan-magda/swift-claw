"""Content-addressed manifest construction and verification."""

from __future__ import annotations

import copy
from pathlib import Path
import re
from typing import Any, Optional

from . import artifacts, run_order
from .contract import (
    CATEGORY_NAMES,
    CATEGORY_ROLE_RULES,
    DECISION,
    DESCRIPTOR_SCHEMA_VERSION,
    EXPERIMENT,
    FIXED_ROLE_PATHS,
    HEX_SHA256,
    MANIFEST_DESCRIPTOR_PATH,
    MANIFEST_KIND,
    MANIFEST_SCHEMA_VERSION,
    PROTOCOL_PATH,
    PROTOCOL_SHA256,
    PROTOCOL_VERSION,
    SWIFT_EXECUTABLE_TARGET,
    canonical_json_bytes,
    canonical_json_line_bytes,
    exactly_equal,
    fail,
    load_json,
    normalized_path,
    reject_reserved_keys,
    require_keys,
    require_object,
    sha256_hex,
)


def _descriptor_artifact(raw: Any, *, location: str) -> dict[str, str]:
    item = require_object(raw, location=location)
    require_keys(item, {"role", "path"}, location=location)
    role = item["role"]
    if not isinstance(role, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", role):
        fail(f"{location}.role is invalid")
    return {"role": role, "path": normalized_path(item["path"], location=f"{location}.path")}


def _validate_category(name: str, items: list[dict[str, Any]]) -> None:
    rules = CATEGORY_ROLE_RULES[name]
    roles = [item["role"] for item in items]
    unknown = sorted(set(roles) - set(rules))
    if unknown:
        fail(f"category {name} has unsupported artifact roles: {unknown}")
    paths = [item["path"] for item in items]
    if len(paths) != len(set(paths)):
        fail(f"category {name} contains a duplicate artifact path")
    for role, (minimum, maximum) in rules.items():
        count = roles.count(role)
        if count < minimum or maximum is not None and count > maximum:
            fail(f"category {name} requires role {role} count in [{minimum}, {maximum}]; observed={count}")
    fixed = FIXED_ROLE_PATHS.get(name)
    if fixed is not None:
        observed = {(item["role"], item["path"]) for item in items
                    if name not in {"lesson_linter", "feedback", "scorer"}
                    or item["role"] != "source"}
        if observed != fixed:
            fail(f"category {name} must contain the exact frozen role/path membership")


def parse_descriptor(value: Any) -> dict[str, dict[str, Any]]:
    root = require_object(value, location="descriptor")
    reject_reserved_keys(root, location="the manifest descriptor")
    require_keys(root, {"schema_version", "decision", "experiment", "protocol",
                        "swift_package", "categories"}, location="descriptor")
    if type(root["schema_version"]) is not int or root["schema_version"] != DESCRIPTOR_SCHEMA_VERSION:
        fail(f"descriptor.schema_version must be {DESCRIPTOR_SCHEMA_VERSION}")
    if root["decision"] != DECISION or root["experiment"] != EXPERIMENT:
        fail("descriptor must describe D6 for the page-change experiment")
    protocol = require_object(root["protocol"], location="descriptor.protocol")
    require_keys(protocol, {"version", "path", "sha256"}, location="descriptor.protocol")
    if protocol != {"version": PROTOCOL_VERSION, "path": PROTOCOL_PATH, "sha256": PROTOCOL_SHA256}:
        fail("descriptor.protocol must name the exact approved protocol 0.2 path and SHA-256")
    package = require_object(root["swift_package"], location="descriptor.swift_package")
    require_keys(package, {"executable_target"}, location="descriptor.swift_package")
    if package["executable_target"] != SWIFT_EXECUTABLE_TARGET:
        fail(f"descriptor.swift_package.executable_target must be {SWIFT_EXECUTABLE_TARGET}")
    categories = require_object(root["categories"], location="descriptor.categories")
    require_keys(categories, set(CATEGORY_NAMES), location="descriptor.categories")
    parsed: dict[str, dict[str, Any]] = {}
    for name in CATEGORY_NAMES:
        category = require_object(categories[name], location=f"descriptor.categories.{name}")
        require_keys(category, {"artifacts", "values"}, location=f"descriptor.categories.{name}")
        raw_items = category["artifacts"]
        if not isinstance(raw_items, list):
            fail(f"descriptor.categories.{name}.artifacts must be an array")
        items = sorted(
            (_descriptor_artifact(item, location=f"descriptor.categories.{name}.artifacts[{index}]")
             for index, item in enumerate(raw_items)),
            key=lambda item: (item["role"], item["path"]),
        )
        _validate_category(name, items)
        reject_reserved_keys(category["values"], location=f"descriptor.categories.{name}.values")
        if name == "run_order" and not exactly_equal(category["values"], run_order.RUN_ORDER_VALUES):
            fail("descriptor.categories.run_order.values must equal the frozen derivation contract")
        parsed[name] = {"artifacts": items, "values": copy.deepcopy(category["values"])}
    return parsed


def build(repo_root: Path, descriptor: Any,
          *, package_description: Optional[dict[str, Any]] = None,
          check_conformance: bool = True) -> dict[str, Any]:
    root = repo_root.resolve(strict=True)
    categories = parse_descriptor(descriptor)
    artifacts.validate_protocol(root)
    artifacts.validate_repository_membership(root, categories)
    description = package_description or artifacts.run_swift_package_describe(root)
    target_closure = artifacts.validate_package_closure(root, categories, description)
    artifacts.validate_executables(root, categories)
    if check_conformance:
        artifacts.run_conformance(root)

    paths = {PROTOCOL_PATH}
    for category in categories.values():
        paths.update(item["path"] for item in category["artifacts"])
    by_path = {path: artifacts.artifact(root, path) for path in sorted(paths)}
    memberships: dict[str, list[str]] = {path: [] for path in by_path}
    manifest_categories: dict[str, Any] = {}
    for name in CATEGORY_NAMES:
        records = []
        for item in categories[name]["artifacts"]:
            records.append({"role": item["role"], **by_path[item["path"]]})
            memberships[item["path"]].append(f"{name}:{item['role']}")
        values = run_order.manifest_values(root) if name == "run_order" else copy.deepcopy(categories[name]["values"])
        payload = {"artifacts": records, "values": values}
        manifest_categories[name] = {**payload, "sha256": sha256_hex(canonical_json_bytes(payload))}
    protected = [
        {**by_path[path], "memberships": sorted(memberships[path])}
        for path in sorted(by_path)
    ]
    return {
        "schema_version": MANIFEST_SCHEMA_VERSION, "manifest_kind": MANIFEST_KIND,
        "decision": DECISION, "experiment": EXPERIMENT,
        "protocol": {"version": PROTOCOL_VERSION, **by_path[PROTOCOL_PATH]},
        "swift_package": {"executable_target": SWIFT_EXECUTABLE_TARGET,
                          "target_closure": target_closure},
        "categories": manifest_categories, "protected_artifacts": protected,
    }


def _record(raw: Any, *, location: str) -> dict[str, Any]:
    item = require_object(raw, location=location)
    require_keys(item, {"path", "bytes", "sha256"}, location=location)
    path = normalized_path(item["path"], location=f"{location}.path")
    if type(item["bytes"]) is not int or item["bytes"] < 0:
        fail(f"{location}.bytes must be a non-negative integer")
    if not isinstance(item["sha256"], str) or not HEX_SHA256.fullmatch(item["sha256"]):
        fail(f"{location}.sha256 must be a lowercase SHA-256 digest")
    return {"path": path, "bytes": item["bytes"], "sha256": item["sha256"]}


def verify_structure(value: Any, raw: bytes) -> dict[str, Any]:
    root = require_object(value, location="manifest")
    reject_reserved_keys(root, location="the manifest")
    require_keys(root, {"schema_version", "manifest_kind", "decision", "experiment",
                        "protocol", "swift_package", "categories", "protected_artifacts"},
                 location="manifest")
    if type(root["schema_version"]) is not int \
            or root["schema_version"] != MANIFEST_SCHEMA_VERSION \
            or root["manifest_kind"] != MANIFEST_KIND:
        fail("manifest schema or kind is invalid")
    if root["decision"] != DECISION or root["experiment"] != EXPERIMENT:
        fail("manifest must describe D6 for the page-change experiment")
    if canonical_json_bytes(root) != raw:
        fail("manifest bytes are not the canonical JSON encoding")
    raw_protected = root["protected_artifacts"]
    if not isinstance(raw_protected, list) or not raw_protected:
        fail("manifest.protected_artifacts must be a non-empty array")
    by_path: dict[str, dict[str, Any]] = {}
    memberships: dict[str, list[str]] = {}
    for index, raw_item in enumerate(raw_protected):
        item = require_object(raw_item, location=f"protected_artifacts[{index}]")
        require_keys(item, {"path", "bytes", "sha256", "memberships"},
                     location=f"protected_artifacts[{index}]")
        record = _record({key: item[key] for key in ("path", "bytes", "sha256")},
                         location=f"protected_artifacts[{index}]")
        names = item["memberships"]
        if record["path"] in by_path or not isinstance(names, list) \
                or any(not isinstance(name, str) for name in names) \
                or names != sorted(set(names)):
            fail("protected artifacts must have unique paths and sorted memberships")
        by_path[record["path"]] = record
        memberships[record["path"]] = names
    if list(by_path) != sorted(by_path):
        fail("manifest.protected_artifacts must be sorted by path")
    protocol = require_object(root["protocol"], location="manifest.protocol")
    require_keys(protocol, {"version", "path", "bytes", "sha256"}, location="manifest.protocol")
    protocol_record = _record({key: protocol[key] for key in ("path", "bytes", "sha256")},
                              location="manifest.protocol")
    if protocol["version"] != PROTOCOL_VERSION or protocol_record["path"] != PROTOCOL_PATH \
            or protocol_record["sha256"] != PROTOCOL_SHA256 or by_path.get(PROTOCOL_PATH) != protocol_record:
        fail("manifest.protocol must bind the exact approved protocol")
    package = require_object(root["swift_package"], location="manifest.swift_package")
    require_keys(package, {"executable_target", "target_closure"}, location="manifest.swift_package")
    closure = package["target_closure"]
    if package["executable_target"] != SWIFT_EXECUTABLE_TARGET or not isinstance(closure, list) \
            or any(not isinstance(item, str) or not item for item in closure) \
            or closure != sorted(set(closure)) or SWIFT_EXECUTABLE_TARGET not in closure:
        fail("manifest.swift_package target closure is invalid")
    categories = require_object(root["categories"], location="manifest.categories")
    require_keys(categories, set(CATEGORY_NAMES), location="manifest.categories")
    expected_memberships: dict[str, list[str]] = {path: [] for path in by_path}
    for name in CATEGORY_NAMES:
        category = require_object(categories[name], location=f"manifest.categories.{name}")
        require_keys(category, {"artifacts", "values", "sha256"}, location=f"manifest.categories.{name}")
        raw_items = category["artifacts"]
        if not isinstance(raw_items, list):
            fail(f"manifest.categories.{name}.artifacts must be an array")
        records = []
        for index, raw_item in enumerate(raw_items):
            item = require_object(raw_item, location=f"manifest.categories.{name}.artifacts[{index}]")
            require_keys(item, {"role", "path", "bytes", "sha256"},
                         location=f"manifest.categories.{name}.artifacts[{index}]")
            if not isinstance(item["role"], str) or not re.fullmatch(r"[a-z][a-z0-9_]*", item["role"]):
                fail(f"manifest category {name} has invalid artifact role")
            records.append({"role": item["role"], **_record(
                {key: item[key] for key in ("path", "bytes", "sha256")},
                location=f"manifest.categories.{name}.artifacts[{index}]")})
        if records != sorted(records, key=lambda item: (item["role"], item["path"])):
            fail(f"manifest.categories.{name}.artifacts must be sorted")
        _validate_category(name, records)
        reject_reserved_keys(category["values"], location=f"manifest.categories.{name}.values")
        if name == "run_order":
            run_order.validate_manifest_values(category["values"])
        for record in records:
            protected = {key: record[key] for key in ("path", "bytes", "sha256")}
            if by_path.get(record["path"]) != protected:
                fail(f"category {name} has a stale artifact record: {record['path']}")
            expected_memberships[record["path"]].append(f"{name}:{record['role']}")
        payload = {"artifacts": records, "values": category["values"]}
        if category["sha256"] != sha256_hex(canonical_json_bytes(payload)):
            fail(f"category digest mismatch: {name}")
    for path, expected in expected_memberships.items():
        if memberships[path] != sorted(expected):
            fail(f"category membership mismatch: {path}")
    if {path for path, names in memberships.items() if not names and path != PROTOCOL_PATH}:
        fail("protected artifacts must belong to a category")
    return root


def verify_files(repo_root: Path, value: dict[str, Any],
                 *, package_description: Optional[dict[str, Any]] = None,
                 check_conformance: bool = True) -> None:
    root = repo_root.resolve(strict=True)
    for expected in value["protected_artifacts"]:
        observed = artifacts.artifact(root, expected["path"])
        if observed != {key: expected[key] for key in ("path", "bytes", "sha256")}:
            fail(f"protected artifact mismatch: {expected['path']}")
    descriptor, descriptor_raw = load_json(root / MANIFEST_DESCRIPTOR_PATH)
    if canonical_json_line_bytes(descriptor) != descriptor_raw:
        fail("descriptor must use canonical JSON bytes with exactly one trailing LF")
    rebuilt = build(root, descriptor, package_description=package_description,
                    check_conformance=check_conformance)
    if not exactly_equal(value, rebuilt):
        fail("manifest differs from its protected descriptor or current closure")


def verify_path(repo_root: Path, manifest_path: Path,
                *, package_description: Optional[dict[str, Any]] = None,
                check_conformance: bool = True) -> tuple[dict[str, Any], bytes]:
    value, raw = load_json(manifest_path)
    verified = verify_structure(value, raw)
    relative = artifacts.repository_relative_path(repo_root, manifest_path,
                                                  location="manifest path")
    if any(item["path"] == relative for item in verified["protected_artifacts"]):
        fail("the manifest cannot list itself as a protected artifact")
    verify_files(repo_root, verified, package_description=package_description,
                 check_conformance=check_conformance)
    return verified, raw
