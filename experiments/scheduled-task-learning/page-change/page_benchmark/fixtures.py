"""Cross-file validation for page sources, hidden gold, and split quotas."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

from .canonical import dumps, load_object
from .validation import (
    MODEL_SPLIT_MARKER,
    TARGET_CLASSES,
    ContractError,
    ValidationIssue,
    require_valid,
    validate_gold,
    validate_source,
)


class _RegionParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.open_regions: list[str | None] = []
        self.parts: dict[str, list[str]] = defaultdict(list)
        self.counts: Counter[str] = Counter()
        self.tags: list[str] = []
        self.selector_values: list[str] = []
        self.visible_text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.tags.append(tag)
        attributes = dict(attrs)
        region_id = attributes.get("data-region-id")
        self.open_regions.append(region_id)
        if region_id is not None:
            self.counts[region_id] += 1
        for name, value in attrs:
            if name != "data-region-id" and value is not None:
                self.selector_values.append(f"{name}={value}")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        if self.open_regions:
            self.open_regions.pop()

    def handle_data(self, data: str) -> None:
        text = " ".join(data.split())
        if text:
            self.visible_text.append(text)
        for region_id in reversed(self.open_regions):
            if region_id is not None:
                if text:
                    self.parts[region_id].append(text)
                break

    def values(self) -> dict[str, str]:
        return {region_id: " ".join(parts) for region_id, parts in self.parts.items()}


def _parse_html(raw: str) -> _RegionParser:
    parser = _RegionParser()
    parser.feed(raw)
    parser.close()
    return parser


def model_visible_html_terms(raw: str) -> tuple[list[str], list[str]]:
    """Return normalized visible text and selector values from one task document."""

    parser = _parse_html(raw)
    return parser.visible_text, parser.selector_values


def _fail(message: str) -> None:
    raise ContractError((ValidationIssue("fixture.contract", message),))


def validate_fixture(source: dict[str, Any], gold: dict[str, Any]) -> dict[str, Any]:
    require_valid(source, validate_source)
    require_valid(gold, validate_gold)
    if source["fixture_id"] != gold["fixture_id"]:
        _fail("source and gold fixture_id differ")
    if source["task_id"] != gold["task_id"]:
        _fail("source and gold task_id differ")
    if not source["fixture_id"].startswith(f"pc-{source['split']}-"):
        _fail("fixture ID does not encode its split")

    before = _parse_html(source["task"]["before_html"])
    after = _parse_html(source["task"]["after_html"])
    listed = source["task"]["region_ids"]
    for region_id in listed:
        if before.counts[region_id] != 1 or after.counts[region_id] != 1:
            _fail(f"region {region_id} must occur exactly once in each document")
    extra_before = set(before.counts) - set(listed)
    extra_after = set(after.counts) - set(listed)
    if extra_before or extra_after:
        _fail("every data-region-id must be listed in task.region_ids")

    before_values = before.values()
    after_values = after.values()
    changed = {
        region_id
        for region_id in listed
        if before_values.get(region_id, "") != after_values.get(region_id, "")
    }
    atoms = gold["atoms"]
    atom_regions = {atom["region_id"] for atom in atoms}
    if changed != atom_regions:
        _fail(
            "gold atoms are not exhaustive for changed regions: "
            f"changed={sorted(changed)}, gold={sorted(atom_regions)}"
        )
    for atom in atoms:
        region_id = atom["region_id"]
        if before_values[region_id] != atom["before"] or after_values[region_id] != atom["after"]:
            _fail(f"gold evidence does not equal parsed region text for {region_id}")

    material_count = sum(atom["kind"] == "material" for atom in atoms)
    expected_verdict = "material" if material_count else ("cosmetic" if atoms else "none")
    if gold["expected_verdict"] != expected_verdict:
        _fail("expected verdict is inconsistent with gold atoms")

    marker_text = source["task"]["before_html"] + "\n" + source["task"]["after_html"]
    for marker_type in ("task_ids", "region_ids", "phrases"):
        for marker in gold["injection_markers"][marker_type]:
            if marker not in marker_text:
                _fail(f"injection {marker_type} marker is absent from source HTML: {marker}")
    return {
        "before": before_values,
        "after": after_values,
        "changed": sorted(changed),
        "tag_signature": "/".join(before.tags) + "=>" + "/".join(after.tags),
        "selectors": sorted(set(before.selector_values + after.selector_values)),
    }


def validate_repository(root: str | Path) -> dict[str, Any]:
    root = Path(root)
    split_contract = load_object(root / "contracts/splits.json")
    expected_counts = split_contract["fixture_counts"]
    seen_fixture_ids: set[str] = set()
    seen_families: dict[str, str] = {}
    mechanisms: dict[str, str] = {}
    template_signatures: dict[str, str] = {}
    literal_values: dict[str, str] = {}
    class_atoms: dict[str, Counter[str]] = defaultdict(Counter)
    class_families: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    injection_splits: set[str] = set()
    verdict_counts: Counter[str] = Counter()
    material_atoms = 0
    noise_atoms = 0

    for split, entries in split_contract["splits"].items():
        if len(entries) != expected_counts[split]:
            _fail(f"{split} fixture count is not {expected_counts[split]}")
        for entry in entries:
            source_path = root / entry["source"]
            gold_path = root / entry["gold"]
            if not source_path.is_file() or not gold_path.is_file():
                _fail(f"missing fixture path for {entry['fixture_id']}")
            source = load_object(source_path)
            gold = load_object(gold_path)
            derived = validate_fixture(source, gold)
            model_facing_source = dumps(
                {"schema_version": 1, "task_id": source["task_id"], "task": source["task"]}
            )
            if MODEL_SPLIT_MARKER.search(model_facing_source):
                _fail(f"model-facing source leaks a split marker: {entry['fixture_id']}")
            fixture_id = entry["fixture_id"]
            if fixture_id in seen_fixture_ids:
                _fail(f"duplicate fixture ID {fixture_id}")
            seen_fixture_ids.add(fixture_id)
            if (
                source["fixture_id"] != fixture_id
                or source["family_id"] != entry["family_id"]
                or source["split"] != split
            ):
                _fail(f"split entry metadata mismatch for {fixture_id}")
            family = source["family_id"]
            if family in seen_families:
                _fail(f"family {family} crosses or repeats splits")
            seen_families[family] = split

            signature = derived["tag_signature"]
            if signature in template_signatures and template_signatures[signature] != split:
                _fail(f"DOM template signature crosses splits: {fixture_id}")
            template_signatures[signature] = split
            for selector in derived["selectors"]:
                if selector in ("class=",):
                    continue
                previous = literal_values.get(f"selector:{selector}")
                if previous is not None and previous != split:
                    _fail(f"selector value crosses splits: {selector}")
                literal_values[f"selector:{selector}"] = split

            if gold["injection_markers"]["phrases"]:
                injection_splits.add(split)
            verdict_counts[gold["expected_verdict"]] += 1
            for atom in gold["atoms"]:
                mechanism = atom["mechanism_id"]
                if mechanism in mechanisms:
                    _fail(f"concrete mechanism repeats: {mechanism}")
                mechanisms[mechanism] = split
                for literal in (atom["before"], atom["after"]):
                    previous = literal_values.get(f"literal:{literal}")
                    if previous is not None and previous != split:
                        _fail(f"changed literal value crosses splits: {literal}")
                    literal_values[f"literal:{literal}"] = split
                if atom["kind"] == "material":
                    material_atoms += split == "sealed"
                else:
                    noise_atoms += split == "sealed"
                    target_class = atom["target_class"]
                    class_atoms[split][target_class] += 1
                    class_families[split][target_class].add(family)

    minimum_atoms = split_contract["minimum_target_atoms_per_class_per_split"]
    minimum_families = split_contract["minimum_unrelated_families_per_class_per_split"]
    for split in split_contract["splits"]:
        for target_class in TARGET_CLASSES:
            if class_atoms[split][target_class] < minimum_atoms:
                _fail(f"{split}/{target_class} has fewer than {minimum_atoms} target atoms")
            if len(class_families[split][target_class]) < minimum_families:
                _fail(
                    f"{split}/{target_class} has fewer than {minimum_families} unrelated families"
                )
    if not set(split_contract["required_injection_splits"]).issubset(injection_splits):
        _fail("required regression/sealed injection fixtures are absent")

    sealed_contract = split_contract["sealed_contract"]
    sealed_verdicts: Counter[str] = Counter()
    for entry in split_contract["splits"]["sealed"]:
        sealed_verdicts[load_object(root / entry["gold"])["expected_verdict"]] += 1
    if (
        material_atoms != sealed_contract["material_atoms"]
        or noise_atoms != sealed_contract["noise_atoms"]
    ):
        _fail("sealed atom counts differ from the frozen contract")
    if dict(sealed_verdicts) != sealed_contract["verdict_counts"]:
        _fail("sealed verdict counts differ from the frozen contract")

    return {
        "schema_version": 1,
        "fixture_count": len(seen_fixture_ids),
        "family_count": len(seen_families),
        "split_class_atoms": {
            split: dict(sorted(counts.items())) for split, counts in sorted(class_atoms.items())
        },
        "status": "valid",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    arguments = parser.parse_args()
    print(dumps(validate_repository(arguments.root)), end="")


if __name__ == "__main__":
    main()
