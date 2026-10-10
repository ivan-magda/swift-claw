#!/usr/bin/env python3
"""Find imports the compiler proves removable, in a copy of the package.

Usage (from the package root):
  python3 -I prune_imports.py --work DIR [--check-only] [--modules A,B]
                              [--include-platform] (--base REF | --all | FILE ...)

Periphery reports unused imports only for modules it indexed, so imports of package
dependencies (GRDB, Logging, NIO...) and some project imports never show up. This script
removes top-level imports in a copy under DIR one module at a time, builds the package
with tests, and restores that module's import in every file the compiler rejects. Expect
one to three builds per module. It writes DIR/prune.patch for `git apply` and never
touches the working tree.

--check-only builds with MemberImportVisibility and lists the files that compile only
because another file in their target imports a module. Run it before pruning and after
any import removal. Each target is built on its own with only that target strict: `swift
build` stops at the first failing target, so one pre-existing failure would otherwise
hide the rest.

Pruning uses the default visibility rule, where a file can compile by borrowing a module
that another file in its target imports. So after pruning, each affected target is built
once more with MemberImportVisibility, and every removed import that the error output
names as a missing defining module is put back. Borrowing that existed before the run is
reported by --check-only, not changed.

--modules limits candidates to imports of the named modules. `--modules deps` means
every package-dependency product the targets declare plus Testing and Synchronization:
the imports Periphery never reports. A repository-wide pass uses `--all --modules deps`:
without a filter, every module's pass rebuilds most targets.

Runs take a machine-wide lock: a second run waits for the first. Parallel runs each
rebuild the whole package and finish later than the same runs in sequence.

Imports of Foundation and OS modules are skipped unless --include-platform is given: a
macOS build cannot prove that Linux still compiles without them. Lines inside #if are
always skipped.
"""

from __future__ import annotations

import argparse
import contextlib
import difflib
import fcntl
import json
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from collections.abc import Collection, Generator, Iterable, Sequence
from pathlib import Path
from typing import Any, NamedTuple

IMPORT = re.compile(
    r"^(?:@testable\s+|@preconcurrency\s+|@_spi\(\w+\)\s+)*import\s+(?P<module>\w+)\s*$"
)
PLATFORM_MODULES = frozenset(
    {
        "Android",
        "CoreFoundation",
        "Darwin",
        "Dispatch",
        "Foundation",
        "FoundationEssentials",
        "FoundationNetworking",
        "FoundationXML",
        "Glibc",
        "Musl",
        "System",
        "SystemPackage",
        "WinSDK",
        "os",
        # swift-crypto sits over CryptoKit on Apple platforms, so macOS cannot prove
        # that Linux needs none.
        "Crypto",
    }
)
# `--modules deps` tries these toolchain modules besides the declared products.
TOOLCHAIN_MODULES = ("Testing", "Synchronization")

ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;;[^\x1b]*\x1b\\")
COMPILER_ERROR = re.compile(
    r"^(?P<path>/[^:]+\.swift):(?P<line>\d+):\d+: error: (?P<message>.*)$"
)
BORROWED = re.compile(r"missing import of defining module '(?P<module>\w+)'")
# Appended to the copy's manifest to build some targets with MemberImportVisibility.
STRICT_MANIFEST_SUFFIX = """
for target in package.targets where [{names}].contains(target.name) {{
  target.swiftSettings =
    (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}}
"""
LOCK_FILE = "swift-claw-prune-imports.lock"


class ImportLine(NamedTuple):
    """A top-level import line that the run may remove."""

    path: str  # relative to the package root
    number: int  # 1-based line number
    text: str  # the line without surrounding whitespace
    module: str


def run(
    command: list[str], cwd: Path, *, check: bool = False
) -> subprocess.CompletedProcess[str]:
    """Run a command and capture its output; with check, fail if the command fails."""
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=check)


def describe_package(root: Path) -> dict[str, Any]:
    """Return SwiftPM's JSON description of the package."""
    command = ["swift", "package", "describe", "--type", "json"]
    package: dict[str, Any] = json.loads(run(command, root, check=True).stdout)
    return package


def target_directories(package: dict[str, Any]) -> dict[str, str]:
    """Return each target's source directory, by target name."""
    return {target["name"]: target["path"] for target in package["targets"]}


def dependency_modules(package: dict[str, Any]) -> set[str]:
    """Return the modules `--modules deps` stands for."""
    modules: set[str] = set(TOOLCHAIN_MODULES)
    for target in package["targets"]:
        modules.update(target.get("product_dependencies", []))
    return modules


def owning_target(path: str, targets: dict[str, str]) -> str | None:
    """Return the target whose directory holds the file, if any."""
    for name, directory in targets.items():
        if path.startswith(directory.rstrip("/") + "/"):
            return name
    return None


def import_candidates(
    path: str, modules: Collection[str] | None, *, include_platform: bool
) -> list[ImportLine]:
    """Return the file's top-level imports that the run may try to remove.

    Imports inside #if are never candidates, and platform modules only with
    include_platform. With modules set, only imports of those modules are.
    """
    candidates: list[ImportLine] = []
    depth = 0
    text = Path(path).read_text(encoding="utf-8")
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("#if"):
            depth += 1
        elif stripped.startswith("#endif"):
            depth -= 1
        match = IMPORT.match(line)
        if depth != 0 or not match:
            continue
        module = match["module"]
        if modules is not None and module not in modules:
            continue
        if module in PLATFORM_MODULES and not include_platform:
            continue
        candidates.append(ImportLine(path, number, stripped, module))
    return candidates


def borrowed_modules(messages: Iterable[str]) -> set[str]:
    """Return the modules that strict-build errors name as missing defining modules."""
    return {
        match["module"] for message in messages if (match := BORROWED.search(message))
    }


class Workspace:
    """A copy of the package where imports are removed and the result is built."""

    root: Path
    work: Path
    copy: Path
    log: Path  # the latest build's output
    original_lines: dict[str, list[str]]  # by path, with line endings

    def __init__(self, root: Path, work: Path, files: Iterable[str]) -> None:
        """Copy the package into WORK/copy and remember the original files."""
        self.root = root
        self.work = work
        self.copy = work / "copy"
        self.log = work / "build.log"
        self.original_lines = {
            path: (root / path).read_text(encoding="utf-8").splitlines(keepends=True)
            for path in files
        }
        self._copy_package()

    def _copy_package(self) -> None:
        """Copy every tracked file and every untracked one git does not ignore."""
        listing = run(["git", "ls-files", "-z", "-co", "--exclude-standard"], self.root)
        names = [
            name
            for name in listing.stdout.split("\0")
            if name and (self.root / name).is_file()
        ]
        self.copy.mkdir(parents=True, exist_ok=True)
        # The trailing slashes make rsync copy the files into the copy, not beside it.
        rsync = [
            "rsync",
            "-a",
            "--from0",
            "--files-from=-",
            f"{self.root}/",
            f"{self.copy}/",
        ]
        subprocess.run(rsync, input="\0".join(names) + "\0", text=True, check=True)

    def write_manifest(self, strict_targets: Iterable[str] = ()) -> None:
        """Write the copy's manifest, with MemberImportVisibility for these targets."""
        manifest = (self.root / "Package.swift").read_text(encoding="utf-8")
        names = ", ".join(f'"{name}"' for name in sorted(strict_targets))
        if names:
            manifest += STRICT_MANIFEST_SUFFIX.format(names=names)
        (self.copy / "Package.swift").write_text(manifest, encoding="utf-8")

    def write_sources(self, removed: Collection[ImportLine]) -> None:
        """Write every checked file into the copy without the removed import lines."""
        for path in self.original_lines:
            text = "".join(self._lines_without(path, removed))
            (self.copy / path).write_text(text, encoding="utf-8")

    def build(self, target: str | None = None) -> tuple[bool, dict[str, set[str]]]:
        """Build the copy; return whether it succeeded and the errors by file.

        Without a target, the whole package builds with tests. A target build uses the
        native build system with -continue-building-after-errors: the default backend
        cancels a target's remaining compile batches after the first failure, so which
        files report errors would depend on scheduling.

        Exits when the build fails without an error in any file.
        """
        if target:
            command = ["swift", "build", "--build-system", "native", "--target", target]
            command += ["--scratch-path", str(self.work / "build-native")]
            command += ["-Xswiftc", "-continue-building-after-errors"]
            self.log = self.work / f"build-{target}.log"
        else:
            command = ["swift", "build", "--build-tests"]
            command += ["--scratch-path", str(self.work / "build")]
            self.log = self.work / "build.log"
        result = run(command, self.copy)
        output = ANSI_ESCAPE.sub("", result.stdout + result.stderr)
        self.log.write_text(output, encoding="utf-8")
        errors = self._errors_by_file(output)
        if result.returncode != 0 and not errors:
            sys.exit(f"build failed without file-level errors; see {self.log}")
        return result.returncode == 0, errors

    def patch(self, removed: Collection[ImportLine]) -> str:
        """Return a unified diff that removes the import lines from the package."""
        chunks: list[str] = []
        for path, lines in sorted(self.original_lines.items()):
            kept = self._lines_without(path, removed)
            if kept != lines:
                chunks.extend(
                    difflib.unified_diff(lines, kept, f"a/{path}", f"b/{path}")
                )
        return "".join(chunks)

    def _lines_without(self, path: str, removed: Collection[ImportLine]) -> list[str]:
        """Return a file's original lines without the removed imports."""
        dropped = {line.number for line in removed if line.path == path}
        lines = enumerate(self.original_lines[path], start=1)
        return [text for number, text in lines if number not in dropped]

    def _errors_by_file(self, output: str) -> dict[str, set[str]]:
        """Return the compiler errors in the output, by path relative to the copy."""
        prefix = f"{self.copy.resolve()}/"
        errors: dict[str, set[str]] = defaultdict(set)
        for line in output.splitlines():
            match = COMPILER_ERROR.match(line)
            if match:
                path = str(Path(match["path"]).resolve()).removeprefix(prefix)
                errors[path].add(match["message"])
        return dict(errors)


def check_only(
    workspace: Workspace, owners: Iterable[str], targets: dict[str, str]
) -> int:
    """Print the checked files that compile only by borrowing another file's import.

    Returns 1 if there are any, else 0.
    """
    borrowing: dict[str, set[str]] = defaultdict(set)
    workspace.write_sources(set())
    for name in sorted(owners):
        print(f"check: strict build of {name}", file=sys.stderr)
        workspace.write_manifest({name})
        _, errors = workspace.build(target=name)
        for path, messages in errors.items():
            if path in workspace.original_lines:
                borrowing[path] |= messages
        outside = [path for path in errors if path not in workspace.original_lines]
        if any(owning_target(path, targets) != name for path in outside):
            print(
                f"{name}: a dependency failed to build, so {name} was not checked. "
                f"Log: {workspace.log}"
            )
        elif outside:
            print(
                f"{name}: {len(outside)} files outside the list also borrow imports "
                "(not in scope)."
            )

    for path, messages in sorted(borrowing.items()):
        print(f"{path}: needs imports it gets from other files")
        for message in sorted(messages):
            print(f"    {message}")
    if not borrowing:
        print("No listed file relies on another file's imports.")
    return 1 if borrowing else 0


def imports_to_keep(
    failing_path: str, trial: set[ImportLine], targets: dict[str, str]
) -> set[ImportLine]:
    """Return the trial imports that a build error in this file shows to be needed.

    Those are the file's own trial imports. A file without any borrowed the module from
    a file in its target, or the failure is in another target entirely: then the module
    stays across that target, or everywhere if the target has no trial import either.
    """
    in_file = {line for line in trial if line.path == failing_path}
    if in_file:
        return in_file
    target = owning_target(failing_path, targets)
    in_target = {line for line in trial if owning_target(line.path, targets) == target}
    return in_target or set(trial)


def prune(
    workspace: Workspace, candidates: Iterable[ImportLine], targets: dict[str, str]
) -> set[ImportLine]:
    """Remove imports one module at a time, so each new error comes from that module."""
    by_module: dict[str, set[ImportLine]] = defaultdict(set)
    for candidate in candidates:
        by_module[candidate.module].add(candidate)

    removed: set[ImportLine] = set()
    for module, imports in sorted(by_module.items()):
        trial = set(imports)
        while trial:
            workspace.write_sources(removed | trial)
            succeeded, errors = workspace.build()
            if succeeded:
                removed |= trial
                break
            for path in errors:
                trial -= imports_to_keep(path, trial, targets)
        removable = len(removed & imports)
        needed = len(imports) - removable
        print(
            f"prune: {module}: {removable} removable, {needed} needed", file=sys.stderr
        )
    workspace.write_sources(removed)
    return removed


def restore_borrowed(
    workspace: Workspace, removed: set[ImportLine], targets: dict[str, str]
) -> set[ImportLine]:
    """Put back removed imports that a file only seemed not to need.

    Such a file compiled by borrowing the module from another file in its target. Each
    affected target builds with MemberImportVisibility until no error names a removed
    import's module as missing.
    """
    removed = set(removed)  # the caller's set stays as it was
    while True:
        workspace.write_sources(removed)
        restored: set[ImportLine] = set()
        affected = {
            target for line in removed if (target := owning_target(line.path, targets))
        }
        for name in sorted(affected):
            print(f"prune: strict check of {name}", file=sys.stderr)
            workspace.write_manifest({name})
            _, errors = workspace.build(target=name)
            for path, messages in errors.items():
                modules = borrowed_modules(messages)
                restored |= {
                    line
                    for line in removed
                    if line.path == path and line.module in modules
                }
        workspace.write_manifest()
        if not restored:
            return removed
        for line in sorted(restored):
            location = f"{line.path}:{line.number}"
            print(
                f"prune: kept {location} ({line.text}): the file borrows it",
                file=sys.stderr,
            )
        removed -= restored


def prune_files(
    workspace: Workspace,
    files: Sequence[str],
    modules: Collection[str] | None,
    targets: dict[str, str],
    *,
    include_platform: bool,
) -> int:
    """Prune the files' imports, write the patch and print what it removes."""
    workspace.write_manifest()
    print(
        f"prune: baseline build for {len(files)} files (the first build is slow)",
        file=sys.stderr,
    )
    workspace.write_sources(set())
    succeeded, baseline_errors = workspace.build()
    if not succeeded:
        # A target that fails hides its dependents, whose imports would then look
        # removable.
        for path, messages in sorted(baseline_errors.items()):
            print(f"{path}: {min(messages)}")
        sys.exit(
            f"baseline build failed; fix the package build first. Log: {workspace.log}"
        )

    candidates = [
        line
        for path in files
        for line in import_candidates(path, modules, include_platform=include_platform)
    ]
    removed = restore_borrowed(
        workspace, prune(workspace, candidates, targets), targets
    )
    patch_path = workspace.work / "prune.patch"
    patch_path.write_text(workspace.patch(removed), encoding="utf-8")
    for line in sorted(removed):
        print(f"{line.path}:{line.number}: {line.text}")
    print(f"\n{len(removed)} of {len(candidates)} candidate imports are removable.")
    print(f"Patch: {patch_path} (apply with git apply)")
    return 0


def files_to_check(
    arguments: argparse.Namespace, root: Path, targets: dict[str, str]
) -> list[str]:
    """Return the Swift files inside a target that the command line selects."""
    files = list(arguments.files)
    if arguments.base:
        changed = ["git", "diff", "--name-only", "--diff-filter=AM", arguments.base]
        files += run(changed, root).stdout.splitlines()
    if arguments.all:
        files += run(["git", "ls-files", "*.swift"], root).stdout.splitlines()
    # Package.swift is in no target; restoring it would also erase the strict setting.
    return sorted(
        {
            path
            for path in files
            if path.endswith(".swift")
            and Path(path).is_file()
            and owning_target(path, targets)
        }
    )


def candidate_modules(
    argument: str | None, package: dict[str, Any]
) -> Collection[str] | None:
    """Return the modules whose imports the run may remove; None means every module."""
    if argument == "deps":
        return dependency_modules(package)
    if argument:
        return set(argument.split(","))
    return None


@contextlib.contextmanager
def machine_wide_lock() -> Generator[None, None, None]:
    """Hold a lock that makes a second run on this machine wait for the first."""
    with Path(tempfile.gettempdir(), LOCK_FILE).open("w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(
                "prune: another prune_imports.py run is building; waiting for it",
                file=sys.stderr,
            )
            fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def parse_arguments() -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--work", required=True, help="scratch directory for the copy and build"
    )
    parser.add_argument("--base", help="check Swift files changed since this git ref")
    parser.add_argument(
        "--all", action="store_true", help="check every Swift file in a target"
    )
    parser.add_argument(
        "--check-only", action="store_true", help="list borrowed-import files"
    )
    parser.add_argument(
        "--modules", help="comma-separated module names to try, or deps"
    )
    parser.add_argument(
        "--include-platform",
        action="store_true",
        help="also try Foundation, OS modules and Crypto",
    )
    parser.add_argument("files", nargs="*", help="Swift files to check")
    return parser.parse_args()


def main() -> int:
    """Run the check or the prune and return the exit status."""
    arguments = parse_arguments()
    root = Path.cwd()
    package = describe_package(root)
    targets = target_directories(package)
    files = files_to_check(arguments, root, targets)
    if not files:
        sys.exit("no Swift files inside a target to check")

    with machine_wide_lock():
        workspace = Workspace(root, Path(arguments.work).resolve(), files)
        if arguments.check_only:
            owners = {
                owner for path in files if (owner := owning_target(path, targets))
            }
            return check_only(workspace, owners, targets)
        modules = candidate_modules(arguments.modules, package)
        return prune_files(
            workspace,
            files,
            modules,
            targets,
            include_platform=arguments.include_platform,
        )


if __name__ == "__main__":
    sys.exit(main())
