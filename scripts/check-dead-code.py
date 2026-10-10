#!/usr/bin/env python3
"""Fail on target dependencies and files that nothing in the repository uses.

Usage: python3 -I scripts/check-dead-code.py

Both checks are deterministic and need no build:
  - a Package.swift target dependency that no Swift file in that target imports;
  - a tracked non-Swift file whose name or stem no other file mentions.

Findings kept on purpose are listed in BuildTools/dead-code-allowlist.txt with a reason. The check
also fails on an entry that no longer matches a finding, so the list cannot go stale. Unused
declarations and imports need an indexed build; .claude/skills/removing-dead-code covers them.
"""

import json
import os
import re
import subprocess
import sys

ALLOWLIST = "BuildTools/dead-code-allowlist.txt"
IMPORT = re.compile(
    r"\s*(?:@[\w()]+\s+)*(?:public\s+|package\s+|internal\s+|private\s+|fileprivate\s+)?"
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


def git(*arguments):
    return subprocess.run(["git", *arguments], check=True, capture_output=True, text=True).stdout


def repository_files():
    listing = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
    return sorted(path for path in listing.split("\0") if path and os.path.isfile(path))


def target_directory(target):
    if target.get("path"):
        return target["path"].rstrip("/")
    return ("Tests/" if target["type"] == "test" else "Sources/") + target["name"]


def dependency_name(dependency):
    for kind in ("byName", "target", "product"):
        if kind in dependency:
            return dependency[kind][0]
    return None


def orphaned_dependencies(files):
    manifest = subprocess.run(
        ["swift", "package", "dump-package"], check=True, capture_output=True, text=True
    ).stdout
    findings = set()
    for target in json.loads(manifest)["targets"]:
        directory = target_directory(target) + "/"
        imported = set()
        for path in files:
            if path.startswith(directory) and path.endswith(".swift"):
                with open(path, encoding="utf-8") as source:
                    imported.update(m.group(1) for m in map(IMPORT.match, source) if m)
        for dependency in target.get("dependencies", []):
            name = dependency_name(dependency)
            if name and name not in imported:
                findings.add(f"{target['name']} {name}")
    return findings


def is_conventional(path):
    return path.startswith(CONVENTIONAL_PREFIXES) or os.path.basename(path) in CONVENTIONAL_NAMES


def mentioned(term, path):
    # The allowlist names the files it keeps, so it never counts as a reference.
    found = subprocess.run(
        ["git", "grep", "--untracked", "-l", "-F", "-e", term, "--", ".",
         f":(exclude){path}", f":(exclude){ALLOWLIST}"],
        capture_output=True, text=True,
    )
    return bool(found.stdout.strip())


def unreferenced_files(files):
    findings = set()
    for path in files:
        if path.endswith(".swift") or path == ALLOWLIST or is_conventional(path):
            continue
        name = os.path.basename(path)
        stem = name.split(".")[0]
        # Code often builds a resource name from parts, such as "voice-note" plus "oga".
        if not mentioned(name, path) and not (len(stem) >= 4 and mentioned(stem, path)):
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
            subject = " ".join(match.group(2).split())
            entries[(match.group(1), subject)] = number
    return entries


def main():
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    files = repository_files()
    errors = []
    allowed = read_allowlist(errors)
    findings = {("dependency", subject) for subject in orphaned_dependencies(files)}
    findings |= {("file", subject) for subject in unreferenced_files(files)}

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
