#!/usr/bin/env python3
"""List SwiftPM target dependencies that no Swift file in the target imports.

Usage (from the package root): python3 -I orphan_deps.py

Reads `swift package describe --type json`, then scans every `import` line, including lines
inside `#if` blocks, of each target's Swift files. A dependency listed here is a candidate,
not a verdict: a product can also be needed for linking, a plugin, or a resource bundle.
Exit status is 1 when any candidate exists, so the script can gate a review step.
"""

import json
import os
import re
import subprocess
import sys

IMPORT = re.compile(
    r"\s*(?:@[\w()]+\s+)*(?:public\s+|package\s+|internal\s+|private\s+|fileprivate\s+)?"
    r"import\s+(?:struct\s+|class\s+|enum\s+|protocol\s+|func\s+|var\s+|let\s+|typealias\s+)?"
    r"(\w+)"
)


def imported_modules(path):
    modules = set()
    for root, _, files in os.walk(path):
        for name in files:
            if not name.endswith(".swift"):
                continue
            with open(os.path.join(root, name), encoding="utf-8") as source:
                for line in source:
                    match = IMPORT.match(line)
                    if match:
                        modules.add(match.group(1))
    return modules


def main():
    described = subprocess.run(
        ["swift", "package", "describe", "--type", "json"],
        check=True,
        capture_output=True,
        text=True,
    )
    package = json.loads(described.stdout)
    orphans = []
    for target in package["targets"]:
        declared = target.get("target_dependencies", []) + target.get("product_dependencies", [])
        imports = imported_modules(target["path"])
        for dependency in declared:
            if dependency not in imports:
                orphans.append((target["name"], dependency))
    for target, dependency in orphans:
        print(f"{target}: declares '{dependency}' but no file imports it")
    if not orphans:
        print("No orphaned target dependencies.")
    return 1 if orphans else 0


if __name__ == "__main__":
    sys.exit(main())
