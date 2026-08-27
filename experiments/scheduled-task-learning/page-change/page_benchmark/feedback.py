"""Generate normalized feedback using only frozen code templates."""

from __future__ import annotations

import argparse
from typing import Any

from .canonical import SHA256_HEX, canonical_sha256, dumps, load_object, write

FEEDBACK_GENERATOR_VERSION = "page-feedback-v1"


def feedback_generator_identity(
    templates_contract: dict[str, Any],
    category_sha256: str,
) -> dict[str, str]:
    if (
        not isinstance(templates_contract, dict)
        or set(templates_contract) != {"schema_version", "templates"}
        or templates_contract.get("schema_version") != 1
        or isinstance(templates_contract.get("schema_version"), bool)
        or not isinstance(templates_contract.get("templates"), dict)
    ):
        raise ValueError("feedback templates contract is malformed")
    if not isinstance(category_sha256, str) or SHA256_HEX.fullmatch(category_sha256) is None:
        raise ValueError("feedback generator category digest is malformed")
    return {
        "version": FEEDBACK_GENERATOR_VERSION,
        "sha256": category_sha256,
        "templates_sha256": canonical_sha256(templates_contract),
    }


def normalize_feedback(
    runs: list[dict[str, Any]],
    templates_contract: dict[str, Any],
) -> list[dict[str, Any]]:
    templates = templates_contract["templates"]
    normalized: list[dict[str, Any]] = []
    for run in sorted(runs, key=lambda item: item["run_id"]):
        run_id = run["run_id"]
        for index, entry in enumerate(run["score_result"]["error_ledger"]):
            code = entry["code"]
            if code not in templates:
                raise ValueError(f"no frozen feedback template for error code {code}")
            template = templates[code]
            item: dict[str, Any] = {
                "run_id": run_id,
                "ledger_index": index,
                "code": code,
                "critical": entry["critical"],
                "summary": template["summary"],
                "guidance": template["guidance"],
            }
            if "target_class" in entry:
                item["target_class"] = entry["target_class"]
            normalized.append(item)
    return normalized


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", required=True, help="object with a runs array")
    parser.add_argument("--templates", required=True)
    parser.add_argument("--output")
    arguments = parser.parse_args()
    payload = load_object(arguments.runs)
    if set(payload) != {"runs"} or not isinstance(payload["runs"], list):
        raise ValueError("runs input must contain only a runs array")
    result = {
        "schema_version": 1,
        "feedback": normalize_feedback(payload["runs"], load_object(arguments.templates)),
    }
    if arguments.output:
        write(arguments.output, result)
    else:
        print(dumps(result), end="")


if __name__ == "__main__":
    main()
