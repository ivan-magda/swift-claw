#!/usr/bin/env python3
"""Fail on target dependencies and files that nothing in the repository uses.

Usage: python3 -I scripts/check-dead-code.py [--report]

Both checks are deterministic. Neither builds the package; the first evaluates only the
manifest.
  - A Package.swift target dependency that no Swift file in that target imports.
    Untracked Swift files count, because SwiftPM compiles them too.
  - A tracked non-Swift file whose name, or stem of four or more characters, no other
    tracked file mentions. Stage a new file to include it.

Findings kept on purpose are listed in BuildTools/dead-code-allowlist.txt with a reason.
The check also fails on an entry that no longer matches a finding, so the list cannot go
stale. --report prints every finding, allowlisted ones included, and exits 0: the leads
for an audit.

A product is matched by its name, or its module alias, against imported module names. A
product whose module has another name needs an allowlist entry. Unused declarations and
imports need an indexed build; .claude/skills/removing-dead-code covers them.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any, NamedTuple

ALLOWLIST = "BuildTools/dead-code-allowlist.txt"
CHECKER = "scripts/check-dead-code.py"
RESEARCH = "docs/research/"

# Mentions in these files keep nothing alive: this script's own text and the allowlist.
# Dated research under RESEARCH does not count either.
NOT_REFERENCES = (CHECKER, ALLOWLIST)

# Tools find these by name or location, so no other file has to mention them.
CONVENTIONAL_PREFIXES = (".github/", ".agents/", ".claude/", RESEARCH)
CONVENTIONAL_NAMES = frozenset(
    {
        ".editorconfig",
        ".gitattributes",
        ".gitignore",
        ".ruff.toml",
        ".swift-format",
        ".swift-version",
        ".swiftlint.yml",
        "AGENTS.md",
        "CLAUDE.md",
        "CODE_OF_CONDUCT.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "Package.resolved",
        "README.md",
        "SECURITY.md",
    }
)

# A shorter stem would match unrelated text, so the whole file name is searched instead.
MINIMUM_STEM_LENGTH = 4

# Where SwiftPM looks for a target that has no explicit path, by target type.
SOURCE_ROOTS = {
    "test": ("Tests", "Sources", "Source", "src", "srcs"),
    "plugin": ("Plugins",),
}
DEFAULT_SOURCE_ROOTS = ("Sources", "Source", "src", "srcs")

IMPORT = re.compile(
    r"""
    \s*
    (?:@\w+(?:\([^)]*\))?\s+)*                              # @testable, @_spi(Name)
    (?:(?:public|package|internal|private|fileprivate)\s+)?
    import\s+
    (?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?   # scoped import
    (?P<module>\w+)
    """,
    re.VERBOSE,
)
ENTRY_FORMAT = "'file <path>  # reason' or 'dependency <target> <module>  # reason'"
ALLOWLIST_ENTRY = re.compile(
    r"^(?P<kind>file|dependency)\s+(?P<subject>.+?)\s+#\s*\S.*$"
)


class Finding(NamedTuple):
    """A file nothing mentions, or a target dependency nothing imports."""

    kind: str  # "file" or "dependency"
    subject: str  # the file path, or "<target> <module>"

    def __str__(self) -> str:
        """Return the finding as an allowlist entry spells it, without the reason."""
        return f"{self.kind} {self.subject}"


def run(*command: str) -> str:
    """Run a command and return its standard output; exit with its error if it fails."""
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        # Show the tool's own diagnostic, such as SwiftPM's manifest error.
        failed = " ".join(command)
        sys.exit(f"check-dead-code: `{failed}` failed\n{result.stderr.rstrip()}")
    output: str = result.stdout
    return output


def git_files(*options: str) -> list[str]:
    """Return the existing files that `git ls-files` lists with these options."""
    listing = run("git", "ls-files", "-z", *options)
    return sorted(path for path in listing.split("\0") if path and Path(path).is_file())


def target_directory(target: dict[str, Any]) -> str:
    """Return the directory that holds a manifest target's sources."""
    if target.get("path"):
        return os.path.normpath(str(target["path"]))
    for root in SOURCE_ROOTS.get(target["type"], DEFAULT_SOURCE_ROOTS):
        candidate = f"{root}/{target['name']}"
        if Path(candidate).is_dir():
            return candidate
    sys.exit(f"check-dead-code: cannot find the directory of target {target['name']}")


def imported_modules(path: str) -> set[str]:
    """Return the modules a Swift file imports.

    Lines inside block comments and multiline string literals are not imports.
    """
    modules: set[str] = set()
    in_comment = in_string = False
    with Path(path).open(encoding="utf-8") as source:
        for line in source:
            if not in_comment and not in_string and (match := IMPORT.match(line)):
                modules.add(match["module"])

            # Decide whether the next line starts inside a comment or a string.
            stripped = line.strip()
            if in_comment:
                in_comment = "*/" not in line
            elif not in_string and stripped.startswith("/*"):
                in_comment = "*/" not in stripped[2:]
            elif line.count('"""') % 2 == 1:
                in_string = not in_string
    return modules


def import_names(dependency: dict[str, Any]) -> tuple[str, set[str]] | None:
    """Return a dependency's name and the module names an import of it can use.

    The manifest spells a dependency as {"byName": [name, ...]}, {"target": [name, ...]}
    or {"product": [name, package, module aliases, ...]}.
    """
    for kind in ("byName", "target"):
        if kind in dependency:
            name = dependency[kind][0]
            return name, {name}
    if "product" in dependency:
        name, _package, module_aliases = dependency["product"][:3]
        return name, {name, *(module_aliases or {}).values()}
    return None


def orphaned_dependencies(swift_files: list[str]) -> set[Finding]:
    """Return the target dependencies that no Swift file in the target imports."""
    manifest = json.loads(run("swift", "package", "dump-package"))
    findings: set[Finding] = set()
    for target in manifest["targets"]:
        directory = target_directory(target) + "/"
        imported: set[str] = set()
        for path in swift_files:
            if path.startswith(directory):
                imported |= imported_modules(path)
        for dependency in target.get("dependencies", []):
            names = import_names(dependency)
            if names is None:
                continue
            name, accepted = names
            if not accepted & imported:
                findings.add(Finding("dependency", f"{target['name']} {name}"))
    return findings


def is_conventional(path: str) -> bool:
    """Return whether tools find this file by its name or location."""
    name = PurePosixPath(path).name
    return path.startswith(CONVENTIONAL_PREFIXES) or name in CONVENTIONAL_NAMES


def counts_as_mention(path: str) -> bool:
    """Return whether naming another file in this file keeps that file alive."""
    return path not in NOT_REFERENCES and not path.startswith(RESEARCH)


def search_term(path: str) -> str:
    """Return the text that, mentioned anywhere, keeps the file alive.

    That is the stem, so code that builds a resource name from parts still counts.
    """
    name = PurePosixPath(path).name
    stem = name.split(".")[0]
    return stem if len(stem) >= MINIMUM_STEM_LENGTH else name


def read_text(path: str) -> str | None:
    """Return a file's text, or None for a binary file, which mentions nothing."""
    try:
        return Path(path).read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None


def unreferenced_files(tracked: list[str]) -> set[Finding]:
    """Return the tracked non-Swift files whose name no other tracked file mentions."""
    texts: dict[str, str] = {}
    for path in tracked:
        if counts_as_mention(path) and (text := read_text(path)) is not None:
            texts[path] = text

    findings: set[Finding] = set()
    for path in tracked:
        if path.endswith(".swift") or path in NOT_REFERENCES or is_conventional(path):
            continue
        term = search_term(path)
        if not any(term in text for other, text in texts.items() if other != path):
            findings.add(Finding("file", path))
    return findings


def find_dead_code() -> set[Finding]:
    """Return the findings of both checks."""
    # SwiftPM compiles untracked Swift files too, so their imports count.
    sources = git_files("--cached", "--others", "--exclude-standard")
    swift_files = [path for path in sources if path.endswith(".swift")]
    tracked = git_files("--cached")
    return orphaned_dependencies(swift_files) | unreferenced_files(tracked)


def parse_entry(text: str) -> Finding | None:
    """Return the finding an allowlist entry keeps, or None if it is malformed."""
    match = ALLOWLIST_ENTRY.match(text)
    if not match:
        return None
    kind, subject = match["kind"], match["subject"]
    if kind == "dependency":
        subject = " ".join(subject.split())  # any spacing between target and module
    return Finding(kind, subject)


def read_allowlist() -> tuple[dict[Finding, int], list[str]]:
    """Return the allowlisted findings with their line numbers, and the entry errors."""
    entries: dict[Finding, int] = {}
    errors: list[str] = []
    allowlist = Path(ALLOWLIST)
    lines = (
        allowlist.read_text(encoding="utf-8").splitlines()
        if allowlist.is_file()
        else []
    )
    for number, line in enumerate(lines, start=1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        finding = parse_entry(text)
        if finding is None:
            errors.append(f"{ALLOWLIST}:{number}:1: error: expected {ENTRY_FORMAT}")
        elif finding in entries:
            errors.append(f"{ALLOWLIST}:{number}:1: error: duplicate entry '{finding}'")
        else:
            entries[finding] = number
    return entries, errors


def finding_error(finding: Finding) -> str:
    """Return the error for a finding that the allowlist does not keep."""
    keep_it = f"add '{finding}  # reason' to {ALLOWLIST}"
    if finding.kind == "dependency":
        target, module = finding.subject.split(" ")
        return (
            f"Package.swift:1:1: error: {target} declares {module}, but no file in the "
            f"target imports it; remove it or {keep_it}"
        )
    return (
        f"{finding.subject}:1:1: error: no other file mentions this file; "
        f"delete it or {keep_it}"
    )


def parse_arguments() -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--report",
        action="store_true",
        help="print every finding, allowlisted ones included, and exit 0",
    )
    return parser.parse_args()


def main() -> int:
    """Run both checks and return the exit status."""
    arguments = parse_arguments()
    os.chdir(Path(__file__).resolve().parents[1])
    allowed, errors = read_allowlist()
    findings = find_dead_code()

    if arguments.report:
        for finding in sorted(findings):
            note = "  (allowlisted)" if finding in allowed else ""
            print(f"{finding}{note}")
        return 0

    errors += [finding_error(finding) for finding in sorted(findings - allowed.keys())]
    errors += [
        f"{ALLOWLIST}:{line}:1: error: '{entry}' no longer matches a finding; "
        "remove the entry"
        for entry, line in sorted(allowed.items())
        if entry not in findings
    ]
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
