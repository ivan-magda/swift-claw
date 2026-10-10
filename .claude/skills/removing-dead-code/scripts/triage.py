#!/usr/bin/env python3
"""Turn two Periphery CSV scans into a triage report with false-positive hints.

Usage (from the package root): python3 -I triage.py ALL_CSV PROD_CSV > report.md

ALL_CSV is a scan with tests included; PROD_CSV ignores tests, so its extra rows are
production declarations that only tests reach. The notes are hints from simple source
reading. They point at the check to make; they never prove that a declaration is dead or
alive.
"""

from __future__ import annotations

import argparse
import collections
import csv
import functools
import re
import sys
from collections.abc import Iterable, Sequence
from pathlib import Path
from typing import NamedTuple

# How far above a declaration to look for its attributes and doc comment.
MAX_ATTRIBUTE_LINES = 400

TYPE_DECLARATION = re.compile(
    r"^(?P<indent>\s*)(?:[\w@()]+\s+)*"
    r"(?P<kind>struct|class|enum|actor|protocol|extension)\s+(?P<name>\w+)"
    r"(?P<inheritance>[^{]*)"
)
FUNCTION_DECLARATION = re.compile(
    r"^(?P<indent>\s*)(?:[\w@()]+\s+)*func\s+(?P<name>\w+)"
)
FUNCTION_START = re.compile(r"\s*(?:\w+\s+)*func\s")
# The previous member's first line ends the attribute block above a declaration.
MEMBER_START = re.compile(r"(?:\w+\s+)*(?:func|let|var|case)\s")
TEST_SEAM_NAME = re.compile(r"For(?:Testing|Tests)\b")
TEST_SEAM_COMMENT = re.compile(r"\b(?:tests?|seam)\b", re.IGNORECASE)

# The default for tables without a "used only by flagged" note.
NO_FUNCTIONS: frozenset[str] = frozenset()

# Periphery hints that are not plain "unused".
ASSIGN_ONLY = "assignOnlyProperty"
REDUNDANT_PUBLIC = "redundantPublicAccessibility"

NOTES_CAVEAT = """\
Notes are hints for the check to make. A row without notes still needs every check.
"""
TEST_ONLY_CAVEAT = """\
Seams, test conveniences and contracts live here. A removed production caller
(`git log -S'<name>' -- Sources`) is what makes one a leftover.
"""
IMPORTS_CAVEAT = """\
This list covers only modules Periphery indexed. Imports of package dependencies
(GRDB, Logging, NIO...) are never reported, and some project imports are missed.
"""
PARAMETER_HINT = (
    "check the signature it must match: protocol, override, closure or function type"
)


class Finding(NamedTuple):
    """One row of a Periphery CSV scan."""

    kind: str
    name: str
    location: str  # path:line:column
    ids: str
    hints: str

    @classmethod
    def from_row(cls, row: dict[str, str]) -> Finding:
        """Make a finding from a CSV row."""
        return cls(row["Kind"], row["Name"], row["Location"], row["IDs"], row["Hints"])

    @property
    def path(self) -> str:
        """The file that declares it."""
        return self.location.rsplit(":", 2)[0]

    @property
    def line(self) -> int:
        """The 1-based line of the declaration."""
        return int(self.location.rsplit(":", 2)[1])


class TypeDeclaration(NamedTuple):
    """A type or extension declaration line."""

    kind: str  # struct, class, enum, actor, protocol or extension
    name: str
    inheritance: str  # the rest of the line up to the opening brace


class ParameterizedTest(NamedTuple):
    """A @Test function that takes arguments; Swift Testing runs it with each one."""

    first_line: int  # 0-based index of the func line
    last_line: int  # 0-based index of the line with the opening brace
    text: str  # its attributes and signature


def read_findings(path: str) -> list[Finding]:
    """Read a Periphery CSV scan."""
    with Path(path).open(newline="", encoding="utf-8") as scan:
        return [Finding.from_row(row) for row in csv.DictReader(scan)]


@functools.cache
def source_lines(path: str) -> tuple[str, ...]:
    """Return a file's lines, or none if it is gone. Each file is read once."""
    try:
        return tuple(Path(path).read_text(encoding="utf-8").split("\n"))
    except OSError:
        return ()


def indentation(text: str) -> int:
    """Return the width of a line's leading whitespace."""
    return len(text) - len(text.lstrip())


def attributes_above(lines: Sequence[str], index: int) -> str:
    """Return the attribute and doc-comment block directly above a declaration line."""
    block: list[str] = []
    for line in reversed(lines[max(0, index - MAX_ATTRIBUTE_LINES) : index]):
        text = line.strip()
        if not text or text == "}" or MEMBER_START.match(text):
            break
        block.append(text)
    return "\n".join(reversed(block))


def is_parameterized_test(attributes: str) -> bool:
    """Return whether these attributes mark a @Test that takes arguments."""
    return "@Test" in attributes and "arguments" in attributes


def enclosing_type(lines: Sequence[str], index: int) -> TypeDeclaration | None:
    """Return the closest type declaration above that is indented less than the line."""
    depth = indentation(lines[index])
    for text in reversed(lines[:index]):
        match = TYPE_DECLARATION.match(text)
        if match and len(match["indent"]) < depth:
            return TypeDeclaration(match["kind"], match["name"], match["inheritance"])
    return None


def enclosing_function(lines: Sequence[str], index: int) -> str | None:
    """Return the name of the closest less-indented function above the line."""
    depth = indentation(lines[index])
    for text in reversed(lines[:index]):
        match = FUNCTION_DECLARATION.match(text)
        if match and len(match["indent"]) < depth:
            return match["name"]
    return None


@functools.cache
def parameterized_tests(path: str) -> tuple[ParameterizedTest, ...]:
    """Return the parameterized @Test functions in a file."""
    lines = source_lines(path)
    tests: list[ParameterizedTest] = []
    for index, text in enumerate(lines):
        if not FUNCTION_START.match(text):
            continue
        attributes = attributes_above(lines, index)
        if not is_parameterized_test(attributes):
            continue
        last = index
        while "{" not in lines[last] and last + 1 < len(lines):
            last += 1
        signature = "\n".join(lines[index : last + 1])
        tests.append(ParameterizedTest(index, last, f"{attributes}\n{signature}"))
    return tuple(tests)


def conforms_to(
    lines: Sequence[str], declaration: TypeDeclaration, protocols: Iterable[str]
) -> bool:
    """Return whether the type adopts one of the protocols, here or in this file."""
    pattern = "|".join(protocols)
    if re.search(rf"\b({pattern})\b", declaration.inheritance):
        return True
    extension = re.compile(rf"extension\s+{declaration.name}\s*:[^{{]*\b({pattern})\b")
    return any(extension.search(text) for text in lines)


def parameterized_test_notes(
    finding: Finding, index: int, attributes: str
) -> list[str]:
    """Return hints that Swift Testing reaches the declaration at runtime."""
    notes: list[str] = []
    in_tests = finding.path.startswith("Tests/")
    tests = parameterized_tests(finding.path) if in_tests else ()
    if finding.kind.startswith("function") and is_parameterized_test(attributes):
        notes.append("parameterized @Test: Swift Testing runs it")
    if finding.kind == "enum":
        name = re.compile(rf"\b{finding.name}\b")
        if any(name.search(test.text) for test in tests):
            notes.append("argument type of a parameterized @Test")
    if finding.kind == "var.parameter" and any(
        test.first_line <= index <= test.last_line for test in tests
    ):
        notes.append("argument of a parameterized @Test")
    return notes


def enclosing_type_notes(
    finding: Finding, lines: Sequence[str], declaration: TypeDeclaration
) -> list[str]:
    """Return hints from the type that declares the finding."""
    notes: list[str] = []
    type_name = declaration.name
    if finding.kind == "enumelement" and conforms_to(
        lines, declaration, ["CaseIterable"]
    ):
        notes.append(f"{type_name} is CaseIterable: reachable through allCases")
    if finding.kind.startswith("var.instance"):
        if conforms_to(lines, declaration, ["Encodable", "Codable"]):
            notes.append(f"{type_name} is Encodable: the field is serialized")
        elif conforms_to(lines, declaration, ["Equatable", "Hashable"]):
            notes.append(
                f"{type_name} is Equatable/Hashable: the field takes part in =="
            )
    if declaration.kind == "protocol":
        notes.append(
            "protocol requirement: check calls on conforming types "
            "and documented contracts"
        )
    conformances = declaration.inheritance.strip(" :")
    if finding.kind.startswith("function") and conformances:
        notes.append(f"may witness a requirement of: {conformances}")
    return notes


def is_test_seam(name: str, attributes: str) -> bool:
    """Return whether a declaration's name or doc comment says tests use it."""
    return bool(TEST_SEAM_NAME.search(name) or TEST_SEAM_COMMENT.search(attributes))


def callers(finding: Finding, lines: Sequence[str], index: int) -> set[str]:
    """Return the functions in the same file whose bodies mention the declaration."""
    bare_name = finding.name.split("(")[0]
    if finding.kind == "var.parameter" or not re.fullmatch(r"\w+", bare_name):
        return set()
    mention = re.compile(rf"\b{bare_name}\b")
    names: set[str] = set()
    for other, text in enumerate(lines):
        if other != index and mention.search(text):
            caller = enclosing_function(lines, other)
            if caller:
                names.add(caller)
    return names


def notes_for(
    finding: Finding, flagged_functions: frozenset[str] = NO_FUNCTIONS
) -> list[str]:
    """Return hints about why Periphery may be wrong about this declaration."""
    lines = source_lines(finding.path)
    if not lines or finding.line > len(lines):
        return ["source not found at this location; rescan"]

    index = finding.line - 1
    attributes = attributes_above(lines, index)
    notes = parameterized_test_notes(finding, index, attributes)
    declaration = enclosing_type(lines, index)
    if declaration:
        notes += enclosing_type_notes(finding, lines, declaration)
    if finding.kind == "var.parameter" and not notes:
        notes.append(PARAMETER_HINT)
    if finding.path.startswith("Sources/") and is_test_seam(finding.name, attributes):
        notes.append("named or documented as a test seam")
    if flagged_functions:
        users = callers(finding, lines, index)
        if users and users <= flagged_functions:
            notes.append(
                f"used only by flagged {', '.join(sorted(users))}: settle that first"
            )
    return notes


def markdown_table(
    findings: Iterable[Finding], flagged_functions: frozenset[str] = NO_FUNCTIONS
) -> str:
    """Return the findings as a Markdown table with their notes."""
    rows = ["| Location | Kind | Name | Notes |", "| --- | --- | --- | --- |"]
    for finding in findings:
        notes = "; ".join(notes_for(finding, flagged_functions)) or "-"
        rows.append(
            f"| {finding.location} | {finding.kind} | `{finding.name}` | {notes} |"
        )
    return "\n".join(rows)


def print_unused_imports(imports: Iterable[Finding]) -> None:
    """Print the unused imports grouped by file."""
    print("## Unused imports reported by Periphery\n")
    print(IMPORTS_CAVEAT)
    by_file: collections.defaultdict[str, list[str]] = collections.defaultdict(list)
    for finding in imports:
        by_file[finding.path].append(f"{finding.name} (line {finding.line})")
    for path in sorted(by_file):
        print(f"- {path}: {', '.join(by_file[path])}")
    print()


def print_assign_only(properties: Iterable[Finding]) -> None:
    """Print assign-only properties: counted when explained, listed when not."""
    print("## Assign-only properties\n")
    explained: collections.Counter[str] = collections.Counter()
    unexplained: list[Finding] = []
    for finding in properties:
        notes = notes_for(finding)
        if notes:
            explained[notes[0]] += 1
        else:
            unexplained.append(finding)
    for note, count in explained.most_common():
        print(f"- {count} × {note}")  # noqa: RUF001 (a multiplication sign)
    print(f"\n{len(unexplained)} without a structural explanation:\n")
    print(markdown_table(unexplained))


def parse_arguments() -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("all_csv", help="Periphery scan with tests included")
    parser.add_argument("prod_csv", help="Periphery scan of production code only")
    return parser.parse_args()


def main() -> int:
    """Print the triage report."""
    arguments = parse_arguments()
    findings = read_findings(arguments.all_csv)
    production_findings = read_findings(arguments.prod_csv)

    imports = [f for f in findings if f.kind == "module"]
    assign_only = [f for f in findings if f.hints == ASSIGN_ONLY]
    redundant_public = [f for f in findings if f.hints == REDUNDANT_PUBLIC]
    unused = [
        f
        for f in findings
        if f.kind != "module" and f.hints not in {ASSIGN_ONLY, REDUNDANT_PUBLIC}
    ]
    # A declaration flagged without tests but not with them is one only tests reach.
    flagged_with_tests = {f.ids for f in findings}
    test_only = [
        f
        for f in production_findings
        if f.ids not in flagged_with_tests
        and f.kind != "module"
        and f.hints == "unused"
    ]

    print("# Periphery triage\n")
    print(
        f"Unused declarations: {len(unused)}. Test-only production declarations: "
        f"{len(test_only)}. Unused imports: {len(imports)}. Assign-only properties: "
        f"{len(assign_only)}. Redundant public (access level, not dead code): "
        f"{len(redundant_public)}.\n"
    )
    print(NOTES_CAVEAT)

    flagged_functions = frozenset(
        f.name.split("(")[0] for f in unused if f.kind.startswith("function")
    )
    print("## Unused declarations, tests included\n")
    print(markdown_table(unused, flagged_functions) + "\n")

    print("## Production declarations that only tests reach\n")
    print(TEST_ONLY_CAVEAT)
    print(markdown_table(test_only) + "\n")

    print_unused_imports(imports)
    print_assign_only(assign_only)
    return 0


if __name__ == "__main__":
    sys.exit(main())
