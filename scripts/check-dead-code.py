#!/usr/bin/env python3
"""Fail on target dependencies and files that nothing in the repository uses.

Usage: python3 -I scripts/check-dead-code.py [--report]

Both checks are deterministic. Neither builds the package; the first evaluates only the manifest.
  - A Package.swift target dependency that no Swift file in that target imports. Untracked Swift
    files count, because SwiftPM compiles them too.
  - A tracked non-Swift file whose name, or stem of four or more characters, no other tracked
    file mentions. Stage a new file to include it.

Findings kept on purpose are listed in BuildTools/dead-code-allowlist.txt with a reason. The check
also fails on an entry that no longer matches a finding, so the list cannot go stale. --report
prints every finding, allowlisted ones included, and exits 0: the leads for an audit.

A product is matched by its name, or its module alias, against imported module names. A product
whose module has another name needs an allowlist entry. Unused declarations and imports need an
indexed build; .claude/skills/removing-dead-code covers them.
"""

import json
import os
import re
import subprocess
import sys

ALLOWLIST = "BuildTools/dead-code-allowlist.txt"
CHECKER = "scripts/check-dead-code.py"
IMPORT = re.compile(
    r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|package\s+|internal\s+|private\s+|fileprivate\s+)?"
    r"import\s+(?:struct\s+|class\s+|enum\s+|protocol\s+|func\s+|var\s+|let\s+|typealias\s+)?"
    r"(\w+)"
)
ENTRY = re.compile(r"^(file|dependency)\s+(.+?)\s+#\s*(\S.*)$")
# Tools find these by name or location, so no other file has to mention them.
CONVENTIONAL_PREFIXES = (".github/", ".agents/", ".claude/", "docs/research/")
CONVENTIONAL_NAMES = {
    ".editorconfig", ".gitattributes", ".gitignore", ".swift-format", ".swift-version",
    ".swiftlint.yml", "Package.resolved", "LICENSE", "README.md", "CODE_OF_CONDUCT.md",
    "CONTRIBUTING.md", "SECURITY.md", "AGENTS.md", "CLAUDE.md",
}
# Mentions here keep nothing alive: this script's own text, the allowlist, and dated research.
NOT_REFERENCES = (CHECKER, ALLOWLIST)
SOURCE_ROOTS = {
    "test": ("Tests", "Sources", "Source", "src", "srcs"),
    "plugin": ("Plugins",),
}
DEFAULT_SOURCE_ROOTS = ("Sources", "Source", "src", "srcs")


def git_files(*options):
    listing = subprocess.run(
        ["git", "ls-files", "-z", *options], check=True, capture_output=True, text=True
    ).stdout
    return sorted(path for path in listing.split("\0") if path and os.path.isfile(path))


def target_directory(target):
    if target.get("path"):
        return os.path.normpath(target["path"])
    for root in SOURCE_ROOTS.get(target["type"], DEFAULT_SOURCE_ROOTS):
        candidate = os.path.join(root, target["name"])
        if os.path.isdir(candidate):
            return candidate
    sys.exit(f"check-dead-code: cannot find the directory of target {target['name']}")


def imported_modules(path):
    """Top-level imports, ignoring lines inside block comments and multiline string literals."""
    modules = set()
    in_comment = in_string = False
    with open(path, encoding="utf-8") as source:
        for line in source:
            if not in_comment and not in_string:
                match = IMPORT.match(line)
                if match:
                    modules.add(match.group(1))
            stripped = line.strip()
            if in_comment:
                in_comment = "*/" not in line
            elif not in_string and stripped.startswith("/*"):
                in_comment = "*/" not in stripped[2:]
            elif line.count('"""') % 2 == 1:
                in_string = not in_string
    return modules


def accepted_names(dependency):
    """The import names that use this dependency: its own name and any module alias."""
    for kind in ("byName", "target"):
        if kind in dependency:
            return dependency[kind][0], {dependency[kind][0]}
    if "product" in dependency:
        name, _, aliases = dependency["product"][:3]
        return name, {name, *(aliases or {}).values()}
    return None, set()


def orphaned_dependencies(swift_files):
    manifest = subprocess.run(
        ["swift", "package", "dump-package"], check=True, capture_output=True, text=True
    ).stdout
    findings = set()
    for target in json.loads(manifest)["targets"]:
        directory = target_directory(target) + os.sep
        imported = set()
        for path in swift_files:
            if path.startswith(directory):
                imported |= imported_modules(path)
        for dependency in target.get("dependencies", []):
            name, names = accepted_names(dependency)
            if name and not names & imported:
                findings.add(f"{target['name']} {name}")
    return findings


def is_conventional(path):
    return path.startswith(CONVENTIONAL_PREFIXES) or os.path.basename(path) in CONVENTIONAL_NAMES


def unreferenced_files(tracked):
    texts = {}
    for path in tracked:
        if path in NOT_REFERENCES or path.startswith("docs/research/"):
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                texts[path] = handle.read()
        except UnicodeDecodeError:
            continue  # binary files mention nothing
    findings = set()
    for path in tracked:
        if path.endswith(".swift") or path in NOT_REFERENCES or is_conventional(path):
            continue
        name = os.path.basename(path)
        stem = name.split(".")[0]
        # A stem covers code that builds a resource name from parts; it is a prefix of the name.
        term = stem if len(stem) >= 4 else name
        if not any(term in text for other, text in texts.items() if other != path):
            findings.add(path)
    return findings


def read_allowlist(errors):
    entries = {}
    if not os.path.isfile(ALLOWLIST):
        return entries
    with open(ALLOWLIST, encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            match = ENTRY.match(text)
            if not match:
                errors.append(
                    f"{ALLOWLIST}:{number}:1: error: expected 'file <path>  # reason' or "
                    "'dependency <target> <module>  # reason'"
                )
                continue
            kind, subject = match.group(1), match.group(2)
            if kind == "dependency":
                subject = " ".join(subject.split())
            if (kind, subject) in entries:
                errors.append(f"{ALLOWLIST}:{number}:1: error: duplicate entry '{kind} {subject}'")
                continue
            entries[(kind, subject)] = number
    return entries


def main():
    report = sys.argv[1:] == ["--report"]
    if sys.argv[1:] and not report:
        sys.exit("usage: python3 -I scripts/check-dead-code.py [--report]")
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    errors = []
    allowed = read_allowlist(errors)
    swift_files = [p for p in git_files("--cached", "--others", "--exclude-standard") if p.endswith(".swift")]
    findings = {("dependency", subject) for subject in orphaned_dependencies(swift_files)}
    findings |= {("file", subject) for subject in unreferenced_files(git_files("--cached"))}

    if report:
        for kind, subject in sorted(findings):
            print(f"{kind} {subject}{'  (allowlisted)' if (kind, subject) in allowed else ''}")
        return 0

    for kind, subject in sorted(findings - set(allowed)):
        if kind == "dependency":
            target, module = subject.split(" ")
            errors.append(
                f"Package.swift:1:1: error: {target} declares {module}, but no file in the target "
                f"imports it; remove it or add 'dependency {subject}  # reason' to {ALLOWLIST}"
            )
        else:
            errors.append(
                f"{subject}:1:1: error: no other file mentions this file; delete it or add "
                f"'file {subject}  # reason' to {ALLOWLIST}"
            )
    for key in sorted(set(allowed) - findings):
        errors.append(
            f"{ALLOWLIST}:{allowed[key]}:1: error: '{key[0]} {key[1]}' no longer matches a "
            "finding; remove the entry"
        )

    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
