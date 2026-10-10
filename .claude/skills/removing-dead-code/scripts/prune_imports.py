#!/usr/bin/env python3
"""Find imports the compiler proves removable, in a copy of the package.

Usage (from the package root):
  python3 -I prune_imports.py --work DIR [--check-only] [--modules A,B]
                              [--include-platform] (--base REF | --all | FILE ...)

Periphery reports unused imports only for modules it indexed, so imports of package
dependencies (GRDB, Logging, NIO...) and some project imports never show up. This script
removes top-level imports in a copy under DIR one module at a time, builds the package with
tests, and restores that module's import in every file the compiler rejects. Expect one to three
builds per module. It writes DIR/prune.patch for `git apply` and never touches the working tree.

--check-only builds with MemberImportVisibility and lists the files that compile only because
another file in their target imports a module. Run it before pruning and after any import
removal. Each target is built on its own with only that target strict: `swift build` stops at
the first failing target, so one pre-existing failure would otherwise hide the rest.

Pruning uses the default visibility rule, where a file can compile by borrowing a module that
another file in its target imports. So after pruning, each affected target is built once more
with MemberImportVisibility, and every removed import that the error output names as a missing
defining module is put back. Borrowing that existed before the run is reported by --check-only,
not changed.

--modules limits candidates to imports of the named modules. `--modules deps` means every
package-dependency product the targets declare plus Testing and Synchronization: the imports
Periphery never reports. A repository-wide pass uses `--all --modules deps`: without a filter,
every module's pass rebuilds most targets.

Runs take a machine-wide lock: a second run waits for the first. Parallel runs each rebuild the
whole package and finish later than the same runs in sequence.

Imports of Foundation and OS modules are skipped unless --include-platform is given: a macOS
build cannot prove that Linux still compiles without them. Lines inside #if are always skipped.
"""

import argparse
import difflib
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile

IMPORT = re.compile(r"^(?:@testable\s+|@preconcurrency\s+|@_spi\(\w+\)\s+)*import\s+(\w+)\s*$")
PLATFORM_MODULES = {
    "Foundation", "FoundationEssentials", "FoundationNetworking", "FoundationXML",
    "Darwin", "Glibc", "Musl", "Android", "WinSDK", "System", "SystemPackage", "Dispatch", "os",
    "CoreFoundation",
    # swift-crypto sits over CryptoKit on Apple platforms, so macOS cannot prove Linux needs none.
    "Crypto",
}
ANSI = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;;[^\x1b]*\x1b\\")
BORROWED = re.compile(r"missing import of defining module '(\w+)'")
ERROR = re.compile(r"^(/[^:]+\.swift):(\d+):\d+: error: (.*)$")
STRICT_SETTING = '.enableUpcomingFeature("MemberImportVisibility")'


def run(command, cwd):
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True)


def describe_package(root):
    return json.loads(run(["swift", "package", "describe", "--type", "json"], root).stdout)


def describe_targets(package):
    return {target["name"]: (target["path"], target["type"]) for target in package["targets"]}


def dependency_modules(package):
    modules = {"Testing", "Synchronization"}
    for target in package["targets"]:
        modules.update(target.get("product_dependencies", []))
    return modules


def owner(path, targets):
    for name, (directory, _) in targets.items():
        if path.startswith(directory.rstrip("/") + "/"):
            return name
    return None


def candidates_in(path, include_platform, modules=None):
    found = []
    depth = 0
    with open(path, encoding="utf-8") as handle:
        for number, text in enumerate(handle.read().splitlines(), start=1):
            stripped = text.strip()
            if stripped.startswith("#if"):
                depth += 1
            elif stripped.startswith("#endif"):
                depth -= 1
            match = IMPORT.match(text)
            if depth == 0 and match and (modules is None or match.group(1) in modules):
                if include_platform or match.group(1) not in PLATFORM_MODULES:
                    found.append((path, number, text.strip()))
    return found


class Workspace:
    """A copy of the package where imports are removed and the result is built."""

    def __init__(self, root, work, files):
        self.root = root
        self.copy = os.path.join(work, "copy")
        self.build_dir = os.path.join(work, "build")
        self.log = os.path.join(work, "build.log")
        self.pristine = {}
        for path in files:
            with open(os.path.join(root, path), encoding="utf-8") as handle:
                self.pristine[path] = handle.read().splitlines(keepends=True)
        listing = run(["git", "ls-files", "-z", "-co", "--exclude-standard"], root).stdout
        names = [p for p in listing.split("\0") if p and os.path.isfile(os.path.join(root, p))]
        os.makedirs(self.copy, exist_ok=True)
        subprocess.run(
            ["rsync", "-a", "--from0", "--files-from=-", root + "/", self.copy + "/"],
            input="\0".join(names) + "\0", text=True, check=True,
        )

    def set_strict(self, target_names):
        with open(os.path.join(self.root, "Package.swift"), encoding="utf-8") as handle:
            manifest = handle.read()
        if target_names:
            names = ", ".join(f'"{name}"' for name in sorted(target_names))
            manifest += (
                f"\nfor target in package.targets where [{names}].contains(target.name) {{\n"
                f"  target.swiftSettings = (target.swiftSettings ?? []) + [{STRICT_SETTING}]\n}}\n"
            )
        with open(os.path.join(self.copy, "Package.swift"), "w", encoding="utf-8") as handle:
            handle.write(manifest)

    def kept(self, path, removed):
        drop = {number for (file, number, _) in removed if file == path}
        return [text for number, text in enumerate(self.pristine[path], start=1) if number not in drop]

    def apply(self, removed):
        for path in self.pristine:
            with open(os.path.join(self.copy, path), "w", encoding="utf-8") as handle:
                handle.write("".join(self.kept(path, removed)))

    def build(self, target=None):
        """Returns (succeeded, {relative path: {error messages}}). Exits on unparseable failure.

        A target build uses the native build system with -continue-building-after-errors. The
        default backend cancels a target's remaining compile batches after the first failure, so
        which files report errors would depend on scheduling.
        """
        if target:
            command = ["swift", "build", "--build-system", "native", "--target", target,
                       "--scratch-path", self.build_dir + "-native",
                       "-Xswiftc", "-continue-building-after-errors"]
            self.log = os.path.join(os.path.dirname(self.build_dir), f"build-{target}.log")
        else:
            command = ["swift", "build", "--build-tests", "--scratch-path", self.build_dir]
        result = run(command, self.copy)
        output = ANSI.sub("", result.stdout + result.stderr)
        with open(self.log, "w", encoding="utf-8") as handle:
            handle.write(output)
        errors = {}
        prefix = os.path.realpath(self.copy) + "/"
        for line in output.splitlines():
            match = ERROR.match(line)
            if match:
                path = os.path.realpath(match.group(1))
                relative = path[len(prefix):] if path.startswith(prefix) else path
                errors.setdefault(relative, set()).add(match.group(3))
        if result.returncode != 0 and not errors:
            sys.exit(f"build failed without file-level errors; see {self.log}")
        return result.returncode == 0, errors

    def patch(self, removed):
        chunks = []
        for path, lines in sorted(self.pristine.items()):
            kept = self.kept(path, removed)
            if kept != lines:
                chunks.extend(difflib.unified_diff(lines, kept, f"a/{path}", f"b/{path}"))
        return "".join(chunks)


def check_only(workspace, owners, targets):
    relying = {}
    workspace.apply(set())
    for name in sorted(owners):
        print(f"check: strict build of {name}", file=sys.stderr)
        workspace.set_strict({name})
        _, errors = workspace.build(target=name)
        for path, messages in errors.items():
            if path in workspace.pristine:
                relying.setdefault(path, set()).update(messages)
        outside = sorted(path for path in errors if path not in workspace.pristine)
        if any(owner(path, targets) != name for path in outside):
            print(f"{name}: a dependency failed to build, so {name} was not checked. Log: {workspace.log}")
        elif outside:
            print(f"{name}: {len(outside)} files outside the list also borrow imports (not in scope).")
    for path, messages in sorted(relying.items()):
        print(f"{path}: needs imports it gets from other files")
        for message in sorted(messages):
            print(f"    {message}")
    if not relying:
        print("No listed file relies on another file's imports.")
    return 1 if relying else 0


def prune(workspace, candidates, targets):
    """Removes one module at a time, so every new error is caused by that module's removal."""
    by_module = {}
    for entry in candidates:
        by_module.setdefault(IMPORT.match(entry[2]).group(1), set()).add(entry)
    removed = set()
    for module in sorted(by_module):
        trial = set(by_module[module])
        while trial:
            workspace.apply(removed | trial)
            ok, errors = workspace.build()
            if ok:
                removed |= trial
                break
            for path in errors:
                needed = {entry for entry in trial if entry[0] == path}
                if not needed:
                    # The failing file borrowed this module from a file in its target, or the
                    # failure is in another target entirely: keep the module wherever it was.
                    target = owner(path, targets)
                    needed = {entry for entry in trial if owner(entry[0], targets) == target}
                trial -= needed or set(trial)
        kept = len(by_module[module]) - len(removed & by_module[module])
        print(f"prune: {module}: {len(by_module[module]) - kept} removable, {kept} needed", file=sys.stderr)
    workspace.apply(removed)
    return removed


def restore_borrowed(workspace, removed, targets):
    """Puts back removed imports that a file only seemed not to need because it borrowed them."""
    while True:
        workspace.apply(removed)
        restored = set()
        for name in sorted({owner(entry[0], targets) for entry in removed}):
            print(f"prune: strict check of {name}", file=sys.stderr)
            workspace.set_strict({name})
            _, errors = workspace.build(target=name)
            for path, messages in errors.items():
                borrowed = {m.group(1) for message in messages for m in [BORROWED.search(message)] if m}
                restored |= {
                    entry for entry in removed
                    if entry[0] == path and IMPORT.match(entry[2]).group(1) in borrowed
                }
        workspace.set_strict(set())
        if not restored:
            workspace.apply(removed)
            return removed
        for path, number, text in sorted(restored):
            print(f"prune: kept {path}:{number} ({text}): the file borrows it", file=sys.stderr)
        removed = removed - restored


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--work", required=True, help="scratch directory for the copy and build")
    parser.add_argument("--base", help="check Swift files changed since this git ref")
    parser.add_argument("--all", action="store_true", help="check every Swift file in a target")
    parser.add_argument("--check-only", action="store_true", help="list borrowed-import files")
    parser.add_argument("--modules", help="comma-separated module names to try")
    parser.add_argument("--include-platform", action="store_true")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args()

    root = os.getcwd()
    package = describe_package(root)
    targets = describe_targets(package)
    files = list(args.files)
    if args.base:
        changed = run(["git", "diff", "--name-only", "--diff-filter=AM", args.base], root).stdout
        files += changed.splitlines()
    if args.all:
        files += run(["git", "ls-files", "*.swift"], root).stdout.splitlines()
    # Package.swift is not in a target; restoring it would also erase the strict setting.
    files = sorted(
        {p for p in files if p.endswith(".swift") and os.path.isfile(p) and owner(p, targets)}
    )
    if not files:
        sys.exit("no Swift files inside a target to check")

    lock = open(os.path.join(tempfile.gettempdir(), "swift-claw-prune-imports.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("prune: another prune_imports.py run is building; waiting for it", file=sys.stderr)
        fcntl.flock(lock, fcntl.LOCK_EX)

    workspace = Workspace(root, os.path.abspath(args.work), files)
    owners = {owner(path, targets) for path in files}
    if args.check_only:
        return check_only(workspace, owners, targets)

    workspace.set_strict(set())
    print(f"prune: baseline build for {len(files)} files (the first build is slow)", file=sys.stderr)
    workspace.apply(set())
    ok, baseline = workspace.build()
    if not ok:
        # A target that fails hides its dependents, whose imports would then look removable.
        for path, messages in sorted(baseline.items()):
            print(f"{path}: {sorted(messages)[0]}")
        sys.exit(f"baseline build failed; fix the package build first. Log: {workspace.log}")

    modules = None
    if args.modules == "deps":
        modules = dependency_modules(package)
    elif args.modules:
        modules = set(args.modules.split(","))
    candidates = [
        entry for path in files for entry in candidates_in(path, args.include_platform, modules)
    ]
    removed = restore_borrowed(workspace, prune(workspace, candidates, targets), targets)
    patch_path = os.path.join(os.path.abspath(args.work), "prune.patch")
    with open(patch_path, "w", encoding="utf-8") as handle:
        handle.write(workspace.patch(removed))
    for path, number, text in sorted(removed):
        print(f"{path}:{number}: {text}")
    print(f"\n{len(removed)} of {len(candidates)} candidate imports are removable.")
    print(f"Patch: {patch_path} (apply with git apply)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
