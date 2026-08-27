"""Dynamic one-shot lesson candidate linter."""

from __future__ import annotations

import argparse
import re
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any

from .canonical import StrictJSONError, dumps, load_object, loads_object
from .fixtures import model_visible_html_terms
from .validation import TARGET_CLASSES, validate_lesson_candidate

_DEFAULT_IGNORABLE_RANGES = (
    (0x00AD, 0x00AD),
    (0x034F, 0x034F),
    (0x061C, 0x061C),
    (0x115F, 0x1160),
    (0x17B4, 0x17B5),
    (0x180B, 0x180F),
    (0x200B, 0x200F),
    (0x202A, 0x202E),
    (0x2060, 0x206F),
    (0x3164, 0x3164),
    (0xFE00, 0xFE0F),
    (0xFEFF, 0xFEFF),
    (0xFFA0, 0xFFA0),
    (0x1BCA0, 0x1BCA3),
    (0x1D173, 0x1D17A),
    (0xE0000, 0xE0FFF),
)


def _contains_default_ignorable(character: str) -> bool:
    scalar = ord(character)
    return any(lower <= scalar <= upper for lower, upper in _DEFAULT_IGNORABLE_RANGES)


def _contains_bounded_term(text: str, term: str) -> bool:
    normalized_text = unicodedata.normalize("NFKC", text).casefold()
    normalized_term = unicodedata.normalize("NFKC", term).casefold()
    if not normalized_term:
        return False
    prefix = r"(?<!\w)" if normalized_term[0].isalnum() or normalized_term[0] == "_" else ""
    suffix = r"(?!\w)" if normalized_term[-1].isalnum() or normalized_term[-1] == "_" else ""
    return re.search(prefix + re.escape(normalized_term) + suffix, normalized_text) is not None


_MINIMUM_REPLICATES_FOR_QUALIFYING_FIXTURE = 2
_MINIMUM_QUALIFYING_FIXTURES = 2
_MINIMUM_QUALIFYING_FAMILIES = 2


def support_by_class(
    runs: list[dict[str, Any]],
    sources: list[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    source_by_fixture = {source["fixture_id"]: source for source in sources}
    replicates: dict[str, dict[str, set[int]]] = defaultdict(lambda: defaultdict(set))
    for run in runs:
        fixture_id = run["fixture_id"]
        if fixture_id not in source_by_fixture:
            raise ValueError(f"run references unknown development fixture {fixture_id}")
        for entry in run["score_result"]["error_ledger"]:
            code = entry["code"]
            if code in TARGET_CLASSES:
                replicates[code][fixture_id].add(run["replicate"])
    result: dict[str, dict[str, Any]] = {}
    for target_class in TARGET_CLASSES:
        qualifying = sorted(
            fixture_id
            for fixture_id, indexes in replicates[target_class].items()
            if len(indexes) >= _MINIMUM_REPLICATES_FOR_QUALIFYING_FIXTURE
        )
        families = sorted({source_by_fixture[fixture_id]["family_id"] for fixture_id in qualifying})
        result[target_class] = {
            "qualifying_fixture_ids": qualifying,
            "qualifying_family_ids": families,
            "supported": len(qualifying) >= _MINIMUM_QUALIFYING_FIXTURES
            and len(families) >= _MINIMUM_QUALIFYING_FAMILIES,
        }
    return result


_DYNAMIC_TERM_CATEGORIES = (
    "fixture_task_region_atom_mechanism_and_family_ids",
    "urls_and_html_selector_values",
    "before_after_literals_and_derived_proper_phrases",
)
_WORD = re.compile(r"[^\W\d_]+(?:['’\-][^\W\d_]+)*", flags=re.UNICODE)  # noqa: RUF001
_MINIMUM_PROPER_TERM_LENGTH = 2
_MINIMUM_PROPER_PHRASE_RUN_LENGTH = 2


def _proper_terms(literal: str) -> set[str]:
    tokens = _WORD.findall(literal)
    terms = {
        token
        for token in tokens
        if len(token) >= _MINIMUM_PROPER_TERM_LENGTH
        and (token.isupper() or any(character.isupper() for character in token[1:]))
    }
    run: list[str] = []
    for token in [*tokens, ""]:
        if token and token[0].isupper():
            run.append(token)
            continue
        if len(run) >= _MINIMUM_PROPER_PHRASE_RUN_LENGTH:
            terms.update(run)
            for width in range(2, len(run) + 1):
                for start in range(len(run) - width + 1):
                    terms.add(" ".join(run[start : start + width]))
        run = []
    return terms


def _string_values(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [item for nested in value for item in _string_values(nested)]
    if isinstance(value, dict):
        return [item for nested in value.values() for item in _string_values(nested)]
    return []


_MINIMUM_CAPITALIZED_TOKEN_LENGTH = 3


def _dynamic_forbidden_terms(
    runs: list[dict[str, Any]],
    sources: list[dict[str, Any]],
    golds: list[dict[str, Any]],
) -> dict[str, list[str]]:
    terms: dict[str, set[str]] = {category: set() for category in _DYNAMIC_TERM_CATEGORIES}

    def add_literal(literal: str) -> None:
        literal_terms = terms[_DYNAMIC_TERM_CATEGORIES[2]]
        literal_terms.add(literal)
        literal_terms.update(_proper_terms(literal))
        tokens = re.findall(r"[A-Za-z][A-Za-z'-]*", literal)
        for width in range(2, min(4, len(tokens)) + 1):
            for start in range(0, len(tokens) - width + 1):
                phrase = " ".join(tokens[start : start + width])
                if any(character.isupper() for character in phrase):
                    literal_terms.add(phrase)
        literal_terms.update(
            token
            for token in tokens
            if len(token) >= _MINIMUM_CAPITALIZED_TOKEN_LENGTH
            and any(character.isupper() for character in token)
        )

    identifier_terms = terms[_DYNAMIC_TERM_CATEGORIES[0]]
    selector_terms = terms[_DYNAMIC_TERM_CATEGORIES[1]]
    for source in sources:
        identifier_terms.update((source["fixture_id"], source["task_id"], source["family_id"]))
        identifier_terms.update(source["task"]["region_ids"])
        html = source["task"]["before_html"] + "\n" + source["task"]["after_html"]
        selector_terms.update(re.findall(r"https?://[^\s\"'<>]+", html, flags=re.IGNORECASE))
        for document in (source["task"]["before_html"], source["task"]["after_html"]):
            visible, selectors = model_visible_html_terms(document)
            selector_terms.update(selectors)
            selector_terms.update(
                selector.split("=", 1)[1] for selector in selectors if "=" in selector
            )
            for literal in visible:
                add_literal(literal)
    for gold in golds:
        identifier_terms.update((gold["fixture_id"], gold["task_id"]))
        for atom in gold["atoms"]:
            identifier_terms.update((atom["atom_id"], atom["region_id"], atom["mechanism_id"]))
            add_literal(atom["before"])
            add_literal(atom["after"])
    for run in runs:
        identifier_terms.update((run["run_id"], run["fixture_id"]))
        raw_output = run.get("attempt", {}).get("raw_output")
        if isinstance(raw_output, str):
            terms[_DYNAMIC_TERM_CATEGORIES[2]].update(_proper_terms(raw_output))
        output = run["parsed_output"]
        if isinstance(output, dict):
            for field in ("task_id", "material_region_ids", "ignored_region_ids"):
                identifier_terms.update(_string_values(output.get(field)))
            evidence = output.get("evidence")
            if isinstance(evidence, list):
                for item in evidence:
                    if not isinstance(item, dict):
                        continue
                    identifier_terms.update(_string_values(item.get("region_id")))
                    for field in ("before", "after"):
                        for literal in _string_values(item.get(field)):
                            add_literal(literal)
        for entry in run["score_result"]["error_ledger"]:
            for field in ("atom_id", "region_id"):
                identifier_terms.update(_string_values(entry.get(field)))
    return {category: sorted(term for term in values if term) for category, values in terms.items()}


_EXPECTED_MAXIMUM_LESSONS = 3
_EXPECTED_MAXIMUM_SCALARS_PER_LESSON = 400
_EXPECTED_MAXIMUM_TOTAL_SCALARS = 1000


def _validated_rule_grammar(rules: dict[str, Any]) -> dict[str, Any]:
    expected_rule_keys = {
        "schema_version",
        "maximum_lessons",
        "maximum_scalars_per_lesson",
        "maximum_total_scalars",
        "rule_grammar",
        "forbidden_patterns",
        "forbidden_terms",
        "dynamic_forbidden_term_categories",
        "required_rule_terms",
        "class_concept_terms",
    }
    if (
        not isinstance(rules, dict)
        or set(rules) != expected_rule_keys
        or rules.get("schema_version") != 1
    ):
        raise ValueError("lesson lint rules have unknown, missing, or invalid top-level fields")
    grammar = rules["rule_grammar"]
    grammar_keys = {
        "style",
        "allowed_initial_verbs",
        "minimum_body_scalars",
        "maximum_body_scalars",
        "terminal",
        "forbidden_body_characters",
        "case_sensitive_initial",
    }
    if not isinstance(grammar, dict) or set(grammar) != grammar_keys:
        raise ValueError("lesson lint rules must declare the complete rule grammar")
    verbs = grammar["allowed_initial_verbs"]
    forbidden = grammar["forbidden_body_characters"]
    expected_dynamic_categories = list(_DYNAMIC_TERM_CATEGORIES)
    class_terms = rules.get("class_concept_terms")
    if (
        rules["maximum_lessons"] != _EXPECTED_MAXIMUM_LESSONS
        or rules["maximum_scalars_per_lesson"] != _EXPECTED_MAXIMUM_SCALARS_PER_LESSON
        or rules["maximum_total_scalars"] != _EXPECTED_MAXIMUM_TOTAL_SCALARS
        or grammar["style"] != "single_imperative_sentence"
        or not isinstance(verbs, list)
        or not verbs
        or any(not isinstance(value, str) or not value.isalpha() for value in verbs)
        or len(set(verbs)) != len(verbs)
        or [value.casefold() for value in verbs] != rules["required_rule_terms"]
        or not isinstance(grammar["minimum_body_scalars"], int)
        or isinstance(grammar["minimum_body_scalars"], bool)
        or not isinstance(grammar["maximum_body_scalars"], int)
        or isinstance(grammar["maximum_body_scalars"], bool)
        or grammar["minimum_body_scalars"] < 1
        or grammar["maximum_body_scalars"] < grammar["minimum_body_scalars"]
        or grammar["maximum_body_scalars"] + 2 > rules["maximum_scalars_per_lesson"]
        or grammar["terminal"] != "."
        or not isinstance(forbidden, list)
        or forbidden != ["\r", "\n", ".", "!", "?"]
        or grammar["case_sensitive_initial"] is not True
        or rules["dynamic_forbidden_term_categories"] != expected_dynamic_categories
        or not isinstance(rules["forbidden_patterns"], list)
        or any(not isinstance(value, str) or not value for value in rules["forbidden_patterns"])
        or not isinstance(rules["forbidden_terms"], list)
        or any(not isinstance(value, str) or not value for value in rules["forbidden_terms"])
        or not isinstance(class_terms, dict)
        or set(class_terms) != set(TARGET_CLASSES)
        or any(
            not isinstance(values, list)
            or not values
            or any(not isinstance(value, str) or not value for value in values)
            for values in class_terms.values()
        )
    ):
        raise ValueError("lesson lint rule grammar is internally inconsistent")
    return grammar


def _matches_rule_grammar(text: str, grammar: dict[str, Any]) -> bool:
    terminal = grammar["terminal"]
    if not text.endswith(terminal):
        return False
    stem = text[: -len(terminal)]
    matched_verb = next(
        (verb for verb in grammar["allowed_initial_verbs"] if stem.startswith(verb + " ")),
        None,
    )
    if matched_verb is None:
        return False
    body = stem[len(matched_verb) + 1 :]
    return grammar["minimum_body_scalars"] <= len(body) <= grammar[
        "maximum_body_scalars"
    ] and not any(character in body for character in grammar["forbidden_body_characters"])


_DEVELOPMENT_SOURCE_COUNT = 6
_DEVELOPMENT_GOLD_COUNT = 6


def lint_candidate(
    candidate: dict[str, Any],
    selected_target_classes: list[str],
    runs: list[dict[str, Any]],
    sources: list[dict[str, Any]],
    golds: list[dict[str, Any]],
    rules: dict[str, Any],
) -> dict[str, Any]:
    errors: list[dict[str, Any]] = []
    grammar = _validated_rule_grammar(rules)
    if len(sources) != _DEVELOPMENT_SOURCE_COUNT or any(
        source.get("split") != "development" for source in sources
    ):
        raise ValueError("lesson linter may inspect only the six development sources")
    expected_task_ids = {source["task_id"] for source in sources}
    if (
        len(golds) != _DEVELOPMENT_GOLD_COUNT
        or {gold.get("task_id") for gold in golds} != expected_task_ids
    ):
        raise ValueError("lesson linter may inspect only the six development gold records")
    for issue in validate_lesson_candidate(candidate):
        errors.append({"code": "lesson.schema", "message": issue.message})

    lessons = candidate.get("lessons", []) if isinstance(candidate, dict) else []
    actual_classes = [lesson.get("target_class") for lesson in lessons if isinstance(lesson, dict)]
    if actual_classes != selected_target_classes:
        errors.append(
            {
                "code": "lesson.class_set",
                "message": "lessons must match selected_target_classes exactly and in order",
            }
        )

    support = support_by_class(runs, sources)
    for target_class in selected_target_classes:
        if target_class not in support or not support[target_class]["supported"]:
            errors.append(
                {
                    "code": "lesson.unsupported_class",
                    "target_class": target_class,
                    "message": (
                        "target class lacks errors in two replicates of two unrelated "
                        "development fixtures"
                    ),
                }
            )

    total_scalars = sum(
        len(lesson.get("text", "")) for lesson in lessons if isinstance(lesson, dict)
    )
    if total_scalars > rules["maximum_total_scalars"]:
        errors.append(
            {"code": "lesson.total_length", "message": "lesson set exceeds the total scalar limit"}
        )

    compiled_patterns = [
        re.compile(pattern, flags=re.IGNORECASE) for pattern in rules["forbidden_patterns"]
    ]
    static_terms = [term.casefold() for term in rules["forbidden_terms"]]
    dynamic_terms = _dynamic_forbidden_terms(runs, sources, golds)
    for index, lesson in enumerate(lessons):
        if not isinstance(lesson, dict) or not isinstance(lesson.get("text"), str):
            continue
        text = lesson["text"]
        normalized_text = unicodedata.normalize("NFKC", text)
        lesson_target_class = lesson.get("target_class")
        if normalized_text != text:
            errors.append(
                {
                    "code": "lesson.non_nfkc",
                    "lesson_index": index,
                    "message": "lesson text must already be Unicode NFKC",
                }
            )
        if any(
            unicodedata.category(character).startswith("C")
            or _contains_default_ignorable(character)
            for character in text
        ):
            errors.append(
                {
                    "code": "lesson.invisible_or_control",
                    "lesson_index": index,
                    "message": (
                        "lesson text contains a control, format, or default-ignorable scalar"
                    ),
                }
            )
        if not _matches_rule_grammar(normalized_text, grammar):
            errors.append(
                {
                    "code": "lesson.rule_grammar",
                    "lesson_index": index,
                    "message": "lesson must be one bounded imperative rule sentence",
                }
            )
        for pattern in compiled_patterns:
            if pattern.search(text):
                errors.append(
                    {
                        "code": "lesson.forbidden_pattern",
                        "lesson_index": index,
                        "pattern": pattern.pattern,
                        "message": "lesson contains a frozen forbidden pattern",
                    }
                )
        leakage_category = next(
            (
                category
                for category in rules["dynamic_forbidden_term_categories"]
                if any(
                    _contains_bounded_term(normalized_text, term)
                    for term in dynamic_terms[category]
                )
            ),
            None,
        )
        if any(_contains_bounded_term(normalized_text, term) for term in static_terms):
            leakage_category = "static_forbidden_terms"
        if leakage_category is not None:
            errors.append(
                {
                    "code": "lesson.example_leakage",
                    "lesson_index": index,
                    "category": leakage_category,
                    "message": (
                        "lesson contains an identifier, proper name, selector, or literal "
                        "development value"
                    ),
                }
            )
        if not any(
            _contains_bounded_term(normalized_text, term) for term in rules["required_rule_terms"]
        ):
            errors.append(
                {
                    "code": "lesson.not_rule",
                    "lesson_index": index,
                    "message": "lesson does not state a general decision rule",
                }
            )
        concept_terms = rules["class_concept_terms"].get(lesson_target_class, [])
        if not any(_contains_bounded_term(normalized_text, term) for term in concept_terms):
            errors.append(
                {
                    "code": "lesson.class_concept",
                    "lesson_index": index,
                    "message": "lesson does not express its selected target-class concept",
                }
            )

    # Stable de-duplication matters because one text can match both static and
    # dynamic versions of the same prohibition.
    unique_errors: list[dict[str, Any]] = []
    seen: set[str] = set()
    for error in errors:
        key = dumps(error)
        if key not in seen:
            seen.add(key)
            unique_errors.append(error)
    return {
        "schema_version": 1,
        "accepted": not unique_errors,
        "selected_target_classes": selected_target_classes,
        "support": support,
        "errors": unique_errors,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--synthesis-input", required=True)
    parser.add_argument("--development-bundle", required=True)
    arguments = parser.parse_args()
    try:
        candidate = loads_object(Path(arguments.candidate).read_text(encoding="utf-8"))
    except StrictJSONError as error:
        print(
            dumps(
                {
                    "schema_version": 1,
                    "accepted": False,
                    "errors": [{"code": "lesson.parse", "message": str(error)}],
                }
            ),
            end="",
        )
        return
    synthesis_input = load_object(arguments.synthesis_input)
    bundle = load_object(arguments.development_bundle)
    report = lint_candidate(
        candidate,
        synthesis_input["selected_target_classes"],
        bundle["runs"],
        bundle["sources"],
        bundle["golds"],
        synthesis_input["lint_rules"],
    )
    print(dumps(report), end="")


if __name__ == "__main__":
    main()
