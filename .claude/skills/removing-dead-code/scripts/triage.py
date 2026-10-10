#!/usr/bin/env python3
"""Turn two Periphery CSV scans into a triage report with false-positive hints.

Usage (from the package root): python3 -I triage.py ALL_CSV PROD_CSV > report.md

ALL_CSV is a scan with tests included; PROD_CSV ignores tests, so its extra rows are production
declarations that only tests reach. The notes are hints from simple source reading. They point
at the check to make; they never prove that a declaration is dead or alive.
"""

import collections
import csv
import re
import sys

TYPE_DECL = re.compile(r"^(\s*)(?:[\w@()]+\s+)*(struct|class|enum|actor|protocol|extension)\s+(\w+)([^{]*)")


def read_rows(path):
    with open(path, newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


class Source:
    """Caches file lines so each finding can look at its neighborhood."""

    def __init__(self):
        self.cache = {}

    def lines(self, path):
        if path not in self.cache:
            try:
                with open(path, encoding="utf-8") as handle:
                    self.cache[path] = handle.read().split("\n")
            except OSError:
                self.cache[path] = []
        return self.cache[path]


def split_location(location):
    path, line, _ = location.rsplit(":", 2)
    return path, int(line)


def attributes_above(lines, index):
    """Returns the attribute and doc-comment block directly above a declaration line."""
    block = []
    cursor = index - 1
    while cursor >= 0 and len(block) < 400:
        text = lines[cursor].strip()
        if not text or text == "}" or re.match(r"(?:\w+\s+)*(func|let|var|case)\s", text):
            break
        block.append(text)
        cursor -= 1
    return "\n".join(reversed(block))


def enclosing_type(lines, index):
    indentation = len(lines[index]) - len(lines[index].lstrip())
    for cursor in range(index - 1, -1, -1):
        match = TYPE_DECL.match(lines[cursor])
        if match and len(match.group(1)) < indentation:
            return match.group(2), match.group(3), match.group(4)
    return None


def parameterized_signatures(lines):
    """Signatures (with their attributes) of @Test functions that take arguments."""
    signatures = []
    for index, text in enumerate(lines):
        if re.match(r"\s*(?:\w+\s+)*func\s", text):
            above = attributes_above(lines, index)
            if "@Test" in above and "arguments" in above:
                signature = [text]
                cursor = index
                while "{" not in lines[cursor] and cursor + 1 < len(lines):
                    cursor += 1
                    signature.append(lines[cursor])
                signatures.append((index, cursor, above + "\n" + "\n".join(signature)))
    return signatures


def conforms(lines, type_name, inheritance, protocols):
    pattern = "|".join(protocols)
    if re.search(rf"\b({pattern})\b", inheritance or ""):
        return True
    extension = re.compile(rf"extension\s+{type_name}\s*:[^{{]*\b({pattern})\b")
    return any(extension.search(text) for text in lines)


def enclosing_function(lines, index):
    indentation = len(lines[index]) - len(lines[index].lstrip())
    for cursor in range(index - 1, -1, -1):
        match = re.match(r"^(\s*)(?:[\w@()]+\s+)*func\s+(\w+)", lines[cursor])
        if match and len(match.group(1)) < indentation:
            return match.group(2)
    return None


def notes_for(row, source, flagged_functions=frozenset()):
    path, line = split_location(row["Location"])
    lines = source.lines(path)
    if not lines or line > len(lines):
        return ["source not found at this location; rescan"]
    index = line - 1
    kind = row["Kind"]
    name = row["Name"]
    notes = []
    above = attributes_above(lines, index)
    signatures = parameterized_signatures(lines) if path.startswith("Tests/") else []

    if kind.startswith("function") and "@Test" in above and "arguments" in above:
        notes.append("parameterized @Test: Swift Testing runs it")
    if kind == "enum" and any(re.search(rf"\b{name}\b", text) for _, _, text in signatures):
        notes.append("argument type of a parameterized @Test")
    if kind == "var.parameter" and any(start <= index <= end for start, end, _ in signatures):
        notes.append("argument of a parameterized @Test")

    enclosing = enclosing_type(lines, index)
    if enclosing:
        type_kind, type_name, inheritance = enclosing
        if kind == "enumelement" and conforms(lines, type_name, inheritance, ["CaseIterable"]):
            notes.append(f"{type_name} is CaseIterable: reachable through allCases")
        if kind.startswith("var.instance"):
            if conforms(lines, type_name, inheritance, ["Encodable", "Codable"]):
                notes.append(f"{type_name} is Encodable: the field is serialized")
            elif conforms(lines, type_name, inheritance, ["Equatable", "Hashable"]):
                notes.append(f"{type_name} is Equatable/Hashable: the field takes part in ==")
        if type_kind == "protocol":
            notes.append("protocol requirement: check calls on conforming types and documented contracts")

    if enclosing and kind.startswith("function") and enclosing[2].strip(" :"):
        notes.append(f"may witness a requirement of: {enclosing[2].strip(' :')}")
    if kind == "var.parameter" and not notes:
        notes.append("check the signature it must match: protocol, override, closure or function type")
    if path.startswith("Sources/") and (
        re.search(r"For(Testing|Tests)\b", name) or re.search(r"\b(tests?|seam)\b", above, re.I)
    ):
        notes.append("named or documented as a test seam")

    bare = name.split("(")[0]
    if kind != "var.parameter" and re.fullmatch(r"\w+", bare):
        callers = {
            enclosing_function(lines, other)
            for other, text in enumerate(lines)
            if other != index and re.search(rf"\b{bare}\b", text)
        } - {None}
        if callers and callers <= flagged_functions:
            notes.append(f"used only by flagged {', '.join(sorted(callers))}: settle that first")
    return notes


def table(rows, source, flagged_functions=frozenset(), extra_note=None):
    output = ["| Location | Kind | Name | Notes |", "| --- | --- | --- | --- |"]
    for row in rows:
        notes = notes_for(row, source, flagged_functions)
        if extra_note:
            notes.append(extra_note)
        output.append(
            f"| {row['Location']} | {row['Kind']} | `{row['Name']}` | {'; '.join(notes) or '-'} |"
        )
    return "\n".join(output)


def main():
    all_rows = read_rows(sys.argv[1])
    prod_rows = read_rows(sys.argv[2])
    source = Source()
    seen = {row["IDs"] for row in all_rows}

    imports = [row for row in all_rows if row["Kind"] == "module"]
    assign_only = [row for row in all_rows if row["Hints"] == "assignOnlyProperty"]
    redundant = [row for row in all_rows if row["Hints"] == "redundantPublicAccessibility"]
    unused = [
        row
        for row in all_rows
        if row not in imports and row not in assign_only and row not in redundant
    ]
    test_only = [
        row
        for row in prod_rows
        if row["IDs"] not in seen and row["Kind"] != "module" and row["Hints"] == "unused"
    ]

    print("# Periphery triage\n")
    print(
        f"Unused declarations: {len(unused)}. Test-only production declarations: "
        f"{len(test_only)}. Unused imports: {len(imports)}. Assign-only properties: "
        f"{len(assign_only)}. Redundant public (access level, not dead code): {len(redundant)}.\n"
    )
    print("Notes are hints for the check to make. A row without notes still needs every check.\n")

    flagged_functions = frozenset(
        row["Name"].split("(")[0] for row in unused if row["Kind"].startswith("function")
    )
    print("## Unused declarations, tests included\n")
    print(table(unused, source, flagged_functions) + "\n")

    print("## Production declarations that only tests reach\n")
    print("Seams, test conveniences and contracts live here. A removed production caller")
    print("(`git log -S'<name>' -- Sources`) is what makes one a leftover.\n")
    print(table(test_only, source) + "\n")

    print("## Unused imports reported by Periphery\n")
    print("This list covers only modules Periphery indexed. Imports of package dependencies")
    print("(GRDB, Logging, NIO...) are never reported, and some project imports are missed.\n")
    by_file = collections.defaultdict(list)
    for row in imports:
        path, line = split_location(row["Location"])
        by_file[path].append(f"{row['Name']} (line {line})")
    for path in sorted(by_file):
        print(f"- {path}: {', '.join(by_file[path])}")
    print()

    print("## Assign-only properties\n")
    explained = collections.Counter()
    unexplained = []
    for row in assign_only:
        notes = notes_for(row, source)
        if notes:
            explained[notes[0]] += 1
        else:
            unexplained.append(row)
    for note, count in explained.most_common():
        print(f"- {count} × {note}")
    print(f"\n{len(unexplained)} without a structural explanation:\n")
    print(table(unexplained, source))


if __name__ == "__main__":
    main()
