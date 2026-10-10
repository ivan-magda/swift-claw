#!/usr/bin/env python3
"""List tracked non-Swift files whose name nothing else in the repository mentions.

Usage (from the repository root): python3 -I unreferenced_files.py

A file counts as referenced when another tracked file contains its basename or its stem
(`voice-note` for `voice-note.oga`), because code often builds a resource name from parts.
Files that tools discover by convention (CI workflows, lint and editor configs, issue
templates) are reported separately and are never candidates. A listed file is a lead: links
from outside the repository, such as a README image on another site, stay invisible here.
"""

import os
import subprocess
import sys

DISCOVERED_BY_CONVENTION = (
    ".github/",
    ".agents/",
    ".claude/",
    ".editorconfig",
    ".gitattributes",
    ".gitignore",
    ".swift-format",
    ".swift-version",
    ".swiftlint.yml",
    "Package.resolved",
    "LICENSE",
    "README.md",
    "CODE_OF_CONDUCT.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "AGENTS.md",
    "CLAUDE.md",
)
SKIPPED_PREFIXES = ("docs/research/",)


def tracked_files():
    listing = subprocess.run(
        ["git", "ls-files", "-z"], check=True, capture_output=True, text=True
    ).stdout
    return [path for path in listing.split("\0") if path]


def referencing_files(term, exclude):
    found = subprocess.run(
        ["git", "grep", "-l", "-F", "-e", term, "--", ".", f":(exclude){exclude}"],
        capture_output=True,
        text=True,
    ).stdout
    return [path for path in found.splitlines() if path]


def is_convention(path):
    name = os.path.basename(path)
    return any(
        path.startswith(prefix) or name == prefix or path.endswith("/" + prefix)
        for prefix in DISCOVERED_BY_CONVENTION
    )


def main():
    candidates = []
    for path in tracked_files():
        if path.endswith(".swift") or path.startswith(SKIPPED_PREFIXES) or is_convention(path):
            continue
        name = os.path.basename(path)
        stem = name.split(".")[0] or name
        if referencing_files(name, path):
            continue
        if len(stem) >= 4 and referencing_files(stem, path):
            continue
        candidates.append(path)
    for path in candidates:
        print(path)
    if not candidates:
        print("No unreferenced non-Swift files.")
    return 1 if candidates else 0


if __name__ == "__main__":
    sys.exit(main())
