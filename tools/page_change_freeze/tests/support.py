"""Shared closed fake repository for freeze-tool contract tests."""

from __future__ import annotations

import copy
import os
from pathlib import Path
import struct
import subprocess
import tempfile
from typing import Any

from tools.page_change_freeze import artifacts, contract, manifest, run_order


class FreezeRepository:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        canonical_root = Path(contract.__file__).resolve().parents[2]
        self.write(contract.PROTOCOL_PATH, (canonical_root / contract.PROTOCOL_PATH).read_bytes())
        self.write("Package.swift", b"""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "fixture", targets: [
  .target(name: "Runtime"),
  .target(name: "ClawEvaluation", dependencies: ["Runtime"]),
  .executableTarget(name: "claw-eval", dependencies: ["ClawEvaluation"]),
])
""")
        self.write("Package.resolved", b'{"pins":[],"version":2}\n')
        self.write("Sources/Runtime/Runtime.swift", b"public let runtime = 1\n")
        self.write("Sources/ClawEvaluation/Evaluation.swift", b"public let evaluation = runtime\n")
        self.write("Sources/claw-eval/main.swift", b"print(evaluation)\n")
        macho = struct.pack("<IIIIIIII", artifacts.MACHO_MAGIC_64,
                            artifacts.MACHO_CPU_TYPE_ARM64, 0, 2, 0, 0, 0, 0)
        self.write(contract.EXECUTABLE_PATH, macho + b"frozen executable")
        (self.root / contract.EXECUTABLE_PATH).chmod(0o755)

        for path in contract.FREEZE_MODULE_PATHS:
            self.write(path, (canonical_root / path).read_bytes())
        for name in ("runtime.json", "canary.json", "canary-base-task.json",
                     "canary-clean-lessons.json", "canary-nonempty-lessons.json"):
            self.write(f"{contract.PAGE_ROOT}/config/{name}", b'{"schema_version":1}\n')
        for name in ("error-codes.json", "target-classes.json", "canonical-json-vector.json",
                     "lesson-lint-rules.json", "feedback-templates.json",
                     "conformance-coverage.json"):
            self.write(f"{contract.PAGE_ROOT}/contracts/{name}", b'{"schema_version":1}\n')
        self.write(contract.TASK_PROMPT_PATH, b"Read input.json once.\n")
        self.write(contract.SYNTHESIS_PROMPT_PATH, b"Synthesize bounded lessons.\n")
        for name in ("input.schema.json", "output.schema.json"):
            self.write(f"{contract.PAGE_ROOT}/schemas/{name}", b'{"type":"object"}\n')

        self.benchmark_sources = ["__init__.py", "canonical.py", "lessons.py", "scorer.py"]
        for name in self.benchmark_sources:
            body = b"def main():\n    return 0\n" if name == "scorer.py" else b"VALUE = 1\n"
            self.write(f"{contract.BENCHMARK_PACKAGE_ROOT}/{name}", body)
        wrapper_paths = (
            set(contract.LESSON_EXECUTABLE_PATHS)
            | set(contract.SCORER_EXECUTABLE_PATHS)
            | {
                contract.FEEDBACK_EXECUTABLE_PATH,
                contract.CONFORMANCE_EXECUTABLE_PATH,
                contract.BENCHMARK_BOOTSTRAP_PATH,
            }
        )
        for path in wrapper_paths:
            body = b"#!/bin/sh\nexit 0\n"
            if path == contract.CONFORMANCE_EXECUTABLE_PATH:
                body = b'#!/bin/sh\nprintf \'{"passed":24,"score":1.0,"total":24}\\n\'\n'
            elif path == contract.BENCHMARK_BOOTSTRAP_PATH:
                body = (canonical_root / path).read_bytes()
            self.write(path, body)
            (self.root / path).chmod(0o755)

        self.fixture_paths: list[str] = []
        self.gold_paths: list[str] = []
        split_entries: dict[str, list[dict[str, str]]] = {}
        for split, count in (("development", 6), ("regression", 3), ("sealed", 4)):
            split_entries[split] = []
            for index in range(1, count + 1):
                fixture = f"pc-{split}-{index:02d}"
                source = f"{contract.PAGE_ROOT}/sources/{split}/{fixture}.source.json"
                gold = f"{contract.PAGE_ROOT}/gold/{split}/{fixture}.gold.json"
                self.write(source, b'{"schema_version":1}\n')
                self.write(gold, b'{"schema_version":1}\n')
                self.fixture_paths.append(source)
                self.gold_paths.append(gold)
                split_entries[split].append({"fixture_id": fixture})
        splits = {"schema_version": 1, "splits": split_entries}
        self.write(contract.SPLITS_PATH, contract.canonical_json_bytes(splits) + b"\n")
        self.write(contract.CONFORMANCE_CASES_PATH, b'{"cases":[]}\n')

        self.package_description = {
            "targets": [
                {"name": "Runtime", "type": "library", "path": "Sources/Runtime",
                 "sources": ["Runtime.swift"], "resources": [], "target_dependencies": []},
                {"name": "ClawEvaluation", "type": "library", "path": "Sources/ClawEvaluation",
                 "sources": ["Evaluation.swift"], "resources": [],
                 "target_dependencies": ["Runtime"]},
                {"name": "claw-eval", "type": "executable", "path": "Sources/claw-eval",
                 "sources": ["main.swift"], "resources": [],
                 "target_dependencies": ["ClawEvaluation"]},
            ]
        }
        self.descriptor = self.make_descriptor()
        self.write(contract.MANIFEST_DESCRIPTOR_PATH,
                   contract.canonical_json_bytes(self.descriptor) + b"\n")

    def cleanup(self) -> None:
        self.temporary.cleanup()

    def make_descriptor(self) -> dict[str, Any]:
        values = {name: {} for name in contract.CATEGORY_NAMES}
        values.update({
            "configuration": {"runtime_contract_owner": "ClawEvaluation"},
            "budget": {"attempt_cap": 76},
            "model": {"provider_route": "openai-chatgpt/gpt-5.6-sol"},
            "retry": {"provider_retry": False},
            "output": {"max_utf8_bytes": 32768},
            "run_order": copy.deepcopy(run_order.RUN_ORDER_VALUES),
        })
        categories = {name: {"artifacts": [], "values": values[name]}
                      for name in contract.CATEGORY_NAMES}
        categories["runtime_sources"]["artifacts"] = [
            {"role": "source", "path": "Sources/Runtime/Runtime.swift"}]
        categories["harness_sources"]["artifacts"] = [
            {"role": "source", "path": "Sources/ClawEvaluation/Evaluation.swift"},
            {"role": "source", "path": "Sources/claw-eval/main.swift"},
        ]
        categories["dependencies"]["artifacts"] = [
            {"role": "package_manifest", "path": contract.PACKAGE_MANIFEST_PATH},
            {"role": "resolved_dependencies", "path": contract.PACKAGE_RESOLVED_PATH},
        ]
        categories["executable"]["artifacts"] = [
            {"role": "executable", "path": contract.EXECUTABLE_PATH}]
        configuration = [
            ("runtime", contract.RUNTIME_CONFIGURATION_PATH),
            ("canary", contract.CANARY_CONFIGURATION_PATH),
            ("canary_base_task", contract.CANARY_BASE_TASK_PATH),
            ("canary_clean_lessons", contract.CANARY_CLEAN_LESSONS_PATH),
            ("canary_nonempty_lessons", contract.CANARY_NONEMPTY_LESSONS_PATH),
            ("error_codes", f"{contract.PAGE_ROOT}/contracts/error-codes.json"),
            ("target_classes", f"{contract.PAGE_ROOT}/contracts/target-classes.json"),
            ("canonical_json_vector", contract.CANONICAL_JSON_VECTOR_PATH),
            *(("freeze_verifier_source", path) for path in sorted(contract.FREEZE_MODULE_PATHS)),
            ("manifest_descriptor", contract.MANIFEST_DESCRIPTOR_PATH),
        ]
        categories["configuration"]["artifacts"] = [
            {"role": role, "path": path} for role, path in configuration]
        categories["prompts"]["artifacts"] = [
            {"role": "task", "path": contract.TASK_PROMPT_PATH},
            {"role": "synthesis", "path": contract.SYNTHESIS_PROMPT_PATH},
        ]
        categories["schemas"]["artifacts"] = [
            {"role": "schema", "path": f"{contract.PAGE_ROOT}/schemas/{name}"}
            for name in ("input.schema.json", "output.schema.json")]
        categories["lesson_linter"]["artifacts"] = [
            {"role": "source", "path": f"{contract.BENCHMARK_PACKAGE_ROOT}/lessons.py"},
            {"role": "rules", "path": contract.LESSON_LINT_RULES_PATH},
            {"role": contract.BENCHMARK_BOOTSTRAP_ROLE,
             "path": contract.BENCHMARK_BOOTSTRAP_PATH},
            *({"role": "executable", "path": path}
              for path in sorted(contract.LESSON_EXECUTABLE_PATHS)),
        ]
        categories["feedback"]["artifacts"] = [
            {"role": "source", "path": f"{contract.BENCHMARK_PACKAGE_ROOT}/canonical.py"},
            {"role": contract.BENCHMARK_BOOTSTRAP_ROLE,
             "path": contract.BENCHMARK_BOOTSTRAP_PATH},
            {"role": "executable", "path": contract.FEEDBACK_EXECUTABLE_PATH},
            {"role": "templates", "path": contract.FEEDBACK_TEMPLATES_PATH},
        ]
        categories["scorer"]["artifacts"] = [
            {"role": "source", "path": f"{contract.BENCHMARK_PACKAGE_ROOT}/{name}"}
            for name in ("__init__.py", "scorer.py")]
        categories["scorer"]["artifacts"] += [
            {"role": "executable", "path": path}
            for path in sorted(contract.SCORER_EXECUTABLE_PATHS)]
        categories["scorer"]["artifacts"].append({
            "role": contract.BENCHMARK_BOOTSTRAP_ROLE,
            "path": contract.BENCHMARK_BOOTSTRAP_PATH,
        })
        categories["fixtures"]["artifacts"] = [
            {"role": "source", "path": path} for path in self.fixture_paths]
        categories["gold"]["artifacts"] = [
            {"role": "gold", "path": path} for path in self.gold_paths]
        categories["splits"]["artifacts"] = [
            {"role": "splits", "path": contract.SPLITS_PATH}]
        categories["conformance"]["artifacts"] = [
            {"role": "cases", "path": contract.CONFORMANCE_CASES_PATH},
            {"role": "coverage", "path": contract.CONFORMANCE_COVERAGE_PATH},
            {"role": contract.BENCHMARK_BOOTSTRAP_ROLE,
             "path": contract.BENCHMARK_BOOTSTRAP_PATH},
            {"role": "executable", "path": contract.CONFORMANCE_EXECUTABLE_PATH},
        ]
        return {
            "schema_version": contract.DESCRIPTOR_SCHEMA_VERSION,
            "decision": contract.DECISION, "experiment": contract.EXPERIMENT,
            "protocol": {"version": contract.PROTOCOL_VERSION, "path": contract.PROTOCOL_PATH,
                         "sha256": contract.PROTOCOL_SHA256},
            "swift_package": {"executable_target": contract.SWIFT_EXECUTABLE_TARGET},
            "categories": categories,
        }

    def make_manifest(self, descriptor: dict[str, Any] | None = None,
                      *, package_description: dict[str, Any] | None = None) -> dict[str, Any]:
        return manifest.build(self.root, descriptor or self.descriptor,
                              package_description=package_description or self.package_description)

    def manifest_raw(self, descriptor: dict[str, Any] | None = None) -> bytes:
        return contract.canonical_json_bytes(self.make_manifest(descriptor))

    def write(self, relative: str, data: bytes) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def init_git(self) -> None:
        self.git("init", "-q")
        self.git("config", "user.name", "Manifest Test")
        self.git("config", "user.email", "manifest@example.invalid")

    def git(self, *arguments: str) -> str:
        environment = os.environ.copy()
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        return subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "-C", str(self.root), *arguments],
            env=environment, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True,
        ).stdout

    def committed_manifest(self) -> tuple[dict[str, Any], bytes, str, str]:
        value = self.make_manifest()
        raw = contract.canonical_json_bytes(value)
        path = f"{contract.PAGE_ROOT}/freeze/page-manifest.json"
        self.write(path, raw)
        self.init_git()
        self.git("add", ".")
        self.git("commit", "-qm", "freeze")
        return value, raw, path, self.git("rev-parse", "HEAD").strip()
