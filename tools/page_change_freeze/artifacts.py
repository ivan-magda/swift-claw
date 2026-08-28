"""Protected file, SwiftPM, executable, conformance, and Git snapshot checks."""

from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import stat
import struct
import subprocess
import tempfile
from typing import Any, Optional

from .contract import (
    BENCHMARK_CORE_ROOT,
    BENCHMARK_CORE_CATEGORY_SOURCES,
    BENCHMARK_PACKAGE_ROOT,
    BENCHMARK_BOOTSTRAP_ROLE,
    CONFORMANCE_EXECUTABLE_PATH,
    EXECUTABLE_PATH,
    FREEZE_MODULE_PATHS,
    FREEZE_PACKAGE_ROOT,
    PAGE_ROOT,
    PROTOCOL_PATH,
    PROTOCOL_SHA256,
    SWIFT_EXECUTABLE_TARGET,
    SWIFT_HARNESS_LIBRARY_TARGET,
    SWIFT_HARNESS_TARGETS,
    canonical_json_bytes,
    fail,
    load_json_bytes,
    normalized_path,
    require_object,
    sha256_hex,
)


MACHO_MAGIC_64 = 0xFEEDFACF
MACHO_CPU_TYPE_ARM64 = 0x0100000C


def rooted_regular_file(repo_root: Path, relative_path: str) -> Path:
    candidate = repo_root.joinpath(*PurePosixPath(relative_path).parts)
    current = repo_root
    for part in PurePosixPath(relative_path).parts:
        current /= part
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            fail(f"cannot stat protected path {relative_path}: {error}")
        if stat.S_ISLNK(mode):
            fail(f"symlinks are forbidden in protected paths: {relative_path}")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve protected path {relative_path}: {error}")
    if resolved != repo_root and repo_root not in resolved.parents:
        fail(f"protected path escapes repository root: {relative_path}")
    if not resolved.is_file():
        fail(f"protected path is not a regular file: {relative_path}")
    return resolved


def repository_relative_path(repo_root: Path, path: Path, *, location: str) -> str:
    try:
        relative = path.resolve(strict=True).relative_to(repo_root.resolve(strict=True)).as_posix()
    except (OSError, ValueError):
        fail(f"{location} is outside the repository root")
    return normalized_path(relative, location=location)


def artifact(repo_root: Path, relative_path: str) -> dict[str, Any]:
    path = rooted_regular_file(repo_root, relative_path)
    try:
        data = path.read_bytes()
    except OSError as error:
        fail(f"cannot read protected file {relative_path}: {error}")
    return {"path": relative_path, "bytes": len(data), "sha256": sha256_hex(data)}


def validate_protocol(repo_root: Path) -> None:
    raw = rooted_regular_file(repo_root, PROTOCOL_PATH).read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        fail("the frozen protocol must be UTF-8 without a byte-order mark")
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"the frozen protocol is not UTF-8: {error}")
    observed = sha256_hex(raw)
    if observed != PROTOCOL_SHA256:
        fail(f"the frozen protocol has the wrong SHA-256: {observed}")


def repository_files(repo_root: Path, directory: str, *, suffix: Optional[str] = None,
                     python_source_only: bool = False) -> set[str]:
    root = repo_root.joinpath(*PurePosixPath(directory).parts)
    try:
        mode = root.lstat().st_mode
    except OSError as error:
        fail(f"cannot inspect required directory {directory}: {error}")
    if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
        fail(f"required directory must be a real directory: {directory}")
    found: set[str] = set()
    for current_text, directory_names, file_names in os.walk(root, followlinks=False):
        current = Path(current_text)
        for name in list(directory_names):
            child = current / name
            if child.is_symlink():
                fail(f"symlinked directories are forbidden in protected closure: {child}")
            if name == "__pycache__":
                if python_source_only:
                    fail(f"bytecode caches are forbidden in protected Python closure: {child}")
                directory_names.remove(name)
        for name in file_names:
            child = current / name
            forbidden_import = child.suffix in {".pyc", ".pyo", ".so", ".dylib", ".pyd"}
            if python_source_only and forbidden_import:
                fail(
                    "non-source import artifact is forbidden in protected Python closure: "
                    f"{child}"
                )
            if suffix is not None and child.suffix != suffix:
                continue
            relative = child.relative_to(repo_root).as_posix()
            rooted_regular_file(repo_root, relative)
            found.add(relative)
    return found


def category_paths(categories: dict[str, dict[str, Any]], name: str,
                   *, roles: Optional[set[str]] = None) -> set[str]:
    return {
        item["path"] for item in categories[name]["artifacts"]
        if roles is None or item["role"] in roles
    }


def _require_membership(location: str, observed: set[str], expected: set[str]) -> None:
    if observed != expected:
        fail(
            f"{location} does not cover its full file closure; "
            f"missing={sorted(expected-observed)}, extra={sorted(observed-expected)}"
        )


def validate_repository_membership(repo_root: Path,
                                   categories: dict[str, dict[str, Any]]) -> None:
    page = repo_root.joinpath(*PurePosixPath(PAGE_ROOT).parts)
    try:
        shadows = sorted(
            item.relative_to(repo_root).as_posix()
            for item in page.iterdir() if item.is_file() and item.suffix == ".py"
        )
    except OSError as error:
        fail(f"cannot inspect page experiment root: {error}")
    if shadows:
        fail(f"top-level page Python files could shadow frozen wrapper imports: {shadows}")
    for name, directory, suffix in (
        ("schemas category", f"{PAGE_ROOT}/schemas", ".json"),
        ("fixtures category", f"{PAGE_ROOT}/sources", ".json"),
        ("gold category", f"{PAGE_ROOT}/gold", ".json"),
        ("prompts category", f"{PAGE_ROOT}/prompts", ".md"),
    ):
        category = name.split()[0]
        _require_membership(name, category_paths(categories, category),
                            repository_files(repo_root, directory, suffix=suffix))
    _require_membership(
        "conformance corpus category",
        category_paths(categories, "conformance", roles={"cases"}),
        repository_files(repo_root, f"{PAGE_ROOT}/conformance", suffix=".json"),
    )
    benchmark_sources = set().union(*(
        category_paths(categories, name, roles={"source"})
        for name in ("lesson_linter", "feedback", "scorer")
    ))
    for category, source_names in BENCHMARK_CORE_CATEGORY_SOURCES.items():
        expected = {f"{BENCHMARK_CORE_ROOT}/{name}" for name in source_names}
        observed = {
            path
            for path in category_paths(categories, category, roles={"source"})
            if path.startswith(f"{BENCHMARK_CORE_ROOT}/")
        }
        _require_membership(f"{category} benchmark-core sources", observed, expected)
    _require_membership(
        "benchmark source categories", benchmark_sources,
        repository_files(repo_root, BENCHMARK_PACKAGE_ROOT, suffix=".py", python_source_only=True)
        | repository_files(repo_root, BENCHMARK_CORE_ROOT, suffix=".py", python_source_only=True),
    )
    contract_paths = {
        item["path"] for category in categories.values() for item in category["artifacts"]
        if item["path"].startswith(f"{PAGE_ROOT}/contracts/")
    }
    _require_membership(
        "contract categories", contract_paths,
        repository_files(repo_root, f"{PAGE_ROOT}/contracts", suffix=".json"),
    )
    _require_membership(
        "configuration category",
        {path for path in category_paths(categories, "configuration")
         if path.startswith(f"{PAGE_ROOT}/config/")},
        repository_files(repo_root, f"{PAGE_ROOT}/config", suffix=".json"),
    )
    _require_membership(
        "freeze verifier source closure",
        category_paths(categories, "configuration", roles={"freeze_verifier_source"}),
        set(FREEZE_MODULE_PATHS),
    )
    executable_paths = {
        item["path"] for category in categories.values() for item in category["artifacts"]
        if item["role"] in {"executable", BENCHMARK_BOOTSTRAP_ROLE}
        and item["path"].startswith(f"{PAGE_ROOT}/artifacts/page-")
    }
    _require_membership(
        "benchmark executable wrappers", executable_paths,
        {path for path in repository_files(repo_root, f"{PAGE_ROOT}/artifacts")
         if PurePosixPath(path).name.startswith("page-")},
    )
    _require_membership(
        "freeze package directory", set(FREEZE_MODULE_PATHS),
        {path for path in repository_files(repo_root, FREEZE_PACKAGE_ROOT, suffix=".py",
                                           python_source_only=True)
         if not path.startswith(f"{FREEZE_PACKAGE_ROOT}/tests/")},
    )


def run_swift_package_describe(repo_root: Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="page-change-swiftpm-") as cache_text:
        environment = os.environ.copy()
        environment["CLANG_MODULE_CACHE_PATH"] = f"{cache_text}/clang"
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = f"{cache_text}/swiftpm"
        try:
            result = subprocess.run(
                ["swift", "package", "--disable-sandbox", "describe", "--type", "json"],
                cwd=repo_root, env=environment, check=False,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
        except OSError as error:
            fail(f"cannot execute SwiftPM package description: {error}")
    if result.returncode:
        fail(f"SwiftPM package description failed: {result.stderr.decode(errors='replace').strip()}")
    return require_object(load_json_bytes(result.stdout, location="SwiftPM description"),
                          location="SwiftPM description")


def _relative(repo_root: Path, raw: Any, *, location: str) -> str:
    if not isinstance(raw, str) or not raw:
        fail(f"{location} must be a non-empty path")
    candidate = Path(raw)
    if candidate.is_absolute():
        try:
            raw = candidate.resolve(strict=True).relative_to(repo_root).as_posix()
        except (OSError, ValueError):
            fail(f"{location} is outside the repository: {candidate}")
    return normalized_path(raw, location=location)


def swift_package_closure(repo_root: Path, description: dict[str, Any]) -> tuple[dict[str, str], dict[str, str], list[str]]:
    raw_targets = description.get("targets")
    if not isinstance(raw_targets, list):
        fail("SwiftPM package description lacks targets")
    targets: dict[str, dict[str, Any]] = {}
    for index, raw in enumerate(raw_targets):
        target = require_object(raw, location=f"SwiftPM targets[{index}]")
        name = target.get("name")
        if not isinstance(name, str) or not name or name in targets:
            fail("SwiftPM package description has an invalid or duplicate target name")
        targets[name] = target
    if SWIFT_EXECUTABLE_TARGET not in targets or targets[SWIFT_EXECUTABLE_TARGET].get("type") != "executable":
        fail(f"SwiftPM target {SWIFT_EXECUTABLE_TARGET} must exist and be executable")
    closure: set[str] = set()
    visiting: set[str] = set()

    def visit(name: str) -> None:
        if name in closure:
            return
        if name in visiting:
            fail(f"SwiftPM local target dependency cycle includes {name}")
        visiting.add(name)
        dependencies = targets[name].get("target_dependencies", [])
        if not isinstance(dependencies, list) or any(
            not isinstance(item, str) or item not in targets for item in dependencies
        ):
            fail(f"SwiftPM target {name} has invalid target_dependencies")
        for dependency in dependencies:
            visit(dependency)
        visiting.remove(name)
        closure.add(name)

    visit(SWIFT_EXECUTABLE_TARGET)
    if SWIFT_HARNESS_LIBRARY_TARGET not in closure:
        fail(f"{SWIFT_EXECUTABLE_TARGET} must depend on {SWIFT_HARNESS_LIBRARY_TARGET}")
    runtime: dict[str, str] = {}
    harness: dict[str, str] = {}
    for name in sorted(closure):
        target = targets[name]
        target_path = _relative(repo_root, target.get("path"), location=f"target {name}.path")
        destination = harness if name in SWIFT_HARNESS_TARGETS else runtime
        sources = target.get("sources", [])
        if not isinstance(sources, list) or any(not isinstance(item, str) for item in sources):
            fail(f"SwiftPM target {name} has invalid sources")
        for source in sources:
            path = normalized_path((PurePosixPath(target_path) / source).as_posix(),
                                   location=f"target {name} source")
            if path in destination:
                fail(f"SwiftPM target closure repeats {path}")
            destination[path] = "source"
        resources = target.get("resources", [])
        if not isinstance(resources, list):
            fail(f"SwiftPM target {name} has invalid resources")
        for index, raw_resource in enumerate(resources):
            resource = require_object(raw_resource, location=f"target {name}.resources[{index}]")
            path = _relative(repo_root, resource.get("path"), location=f"target {name} resource")
            candidate = repo_root.joinpath(*PurePosixPath(path).parts)
            paths = repository_files(repo_root, path) if candidate.is_dir() else {path}
            for resource_path in paths:
                rooted_regular_file(repo_root, resource_path)
                if resource_path in destination:
                    fail(f"SwiftPM target closure repeats {resource_path}")
                destination[resource_path] = "resource"
    return runtime, harness, sorted(closure)


def validate_package_closure(repo_root: Path, categories: dict[str, dict[str, Any]],
                             description: dict[str, Any]) -> list[str]:
    runtime, harness, targets = swift_package_closure(repo_root, description)
    for name, expected in (("runtime_sources", runtime), ("harness_sources", harness)):
        observed = {item["path"]: item["role"] for item in categories[name]["artifacts"]}
        if observed != expected:
            fail(f"{name} must equal the SwiftPM transitive target source/resource closure")
    return targets


def validate_executables(repo_root: Path, categories: dict[str, dict[str, Any]]) -> None:
    for category in categories.values():
        for item in category["artifacts"]:
            if item["role"] in {"executable", BENCHMARK_BOOTSTRAP_ROLE} \
                    and not rooted_regular_file(repo_root, item["path"]).stat().st_mode & stat.S_IXUSR:
                fail(f"executable artifact lacks owner-execute mode: {item['path']}")
    header = rooted_regular_file(repo_root, EXECUTABLE_PATH).read_bytes()[:8]
    if len(header) != 8 or header[:4] not in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}:
        fail(f"executable is not a 64-bit Mach-O arm64 file: {EXECUTABLE_PATH}")
    endian = "<" if header[:4] == b"\xcf\xfa\xed\xfe" else ">"
    magic, cpu = struct.unpack(f"{endian}II", header)
    if magic != MACHO_MAGIC_64 or cpu != MACHO_CPU_TYPE_ARM64:
        fail(f"executable is not a 64-bit Mach-O arm64 file: {EXECUTABLE_PATH}")


def run_conformance(repo_root: Path) -> dict[str, Any]:
    executable = rooted_regular_file(repo_root, CONFORMANCE_EXECUTABLE_PATH)
    try:
        result = subprocess.run([str(executable), str(repo_root / PAGE_ROOT)],
                                cwd=repo_root, check=False, timeout=60,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except subprocess.TimeoutExpired:
        fail("protected conformance runner exceeded 60 seconds")
    except OSError as error:
        fail(f"cannot execute protected conformance runner: {error}")
    if result.returncode:
        fail(f"protected conformance runner failed: {result.stderr.decode(errors='replace').strip()}")
    if len(result.stdout) > 4 * 1024 * 1024:
        fail("protected conformance receipt exceeds 4 MiB")
    receipt = require_object(load_json_bytes(result.stdout, location="conformance receipt",
                                             allow_floats=True),
                             location="conformance receipt")
    if receipt.get("passed") != 24 or receipt.get("total") != 24:
        fail("protected conformance receipt must report exactly 24/24")
    if canonical_json_bytes(receipt, allow_floats=True) + b"\n" != result.stdout:
        fail("protected conformance receipt must be canonical JSON with one LF")
    return receipt


def run_git(repo_root: Path, arguments: list[str]) -> bytes:
    environment = os.environ.copy()
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    try:
        result = subprocess.run(["git", "--no-replace-objects", "-C", str(repo_root), *arguments],
                                env=environment, check=False,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as error:
        fail(f"cannot execute Git: {error}")
    if result.returncode:
        fail(f"Git command failed ({' '.join(arguments)}): {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def verify_commit_snapshot(repo_root: Path, *, freeze_commit: str, manifest_path: str,
                           manifest_raw: bytes, manifest: dict[str, Any]) -> None:
    root = repo_root.resolve(strict=True)
    top = Path(run_git(root, ["rev-parse", "--show-toplevel"]).decode().strip()).resolve()
    if top != root:
        fail(f"repository root does not match Git top level: {top}")
    resolved = run_git(root, ["rev-parse", "--verify", f"{freeze_commit}^{{commit}}"]).decode().strip()
    if resolved != freeze_commit:
        fail(f"approval commit did not resolve to itself: {resolved}")
    executables = {
        item["path"] for category in manifest["categories"].values()
        for item in category["artifacts"]
        if item["role"] in {"executable", BENCHMARK_BOOTSTRAP_ROLE}
    }
    by_path = {item["path"]: item for item in manifest["protected_artifacts"]}
    expected = [(manifest_path, manifest_raw), *((path, None) for path in by_path)]
    for path, exact in expected:
        output = run_git(root, ["ls-tree", "-z", "--full-tree", freeze_commit, "--", path])
        entries = [entry for entry in output.split(b"\x00") if entry]
        if len(entries) != 1:
            fail(f"approved commit must contain one exact tree entry: {path}")
        try:
            metadata, raw_path = entries[0].split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split(" ")
            observed_path = raw_path.decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            fail(f"cannot parse Git tree entry for {path}")
        wanted_mode = "100755" if path in executables else "100644"
        if observed_path != path or mode != wanted_mode or kind != "blob":
            fail(f"approved commit has wrong mode/type for {path}: expected {wanted_mode} blob, observed {mode} {kind}")
        if run_git(root, ["cat-file", "-t", object_id]).decode().strip() != "blob":
            fail(f"Git object is not a blob: {object_id}")
        committed = run_git(root, ["cat-file", "blob", object_id])
        if exact is not None and committed != exact:
            fail("approved commit does not contain the exact canonical manifest bytes")
        if exact is None and (len(committed) != by_path[path]["bytes"] or sha256_hex(committed) != by_path[path]["sha256"]):
            fail(f"approved commit has different protected bytes: {path}")
