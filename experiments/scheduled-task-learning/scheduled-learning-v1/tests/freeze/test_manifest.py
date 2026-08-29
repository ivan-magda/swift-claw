"""Observable freeze-manifest construction and verification behavior."""

from __future__ import annotations

import copy
import unittest

from scheduled_learning_v1.freeze import build_manifest, verify_manifest

from .support import (
    FreezeTestRepository,
    create_repository,
    rehash_binding,
    run_module,
)


class ManifestTests(unittest.TestCase):
    repository: FreezeTestRepository
    manifest: dict[str, object]

    def setUp(self) -> None:
        self.repository = create_repository()
        self.addCleanup(self.repository.cleanup)
        self.manifest = build_manifest(self.repository.experiment_root)

    def test_verifier_rejects_one_changed_declared_file_and_ignores_runtime_outputs(self) -> None:
        # given
        runtime_approval = self.repository.experiment_root / "freeze" / "owner-budget-approval.json"
        runtime_approval.write_text("{}\n", encoding="utf-8")
        runtime_result = self.repository.experiment_root / "results" / "events" / "event.json"
        runtime_result.parent.mkdir(parents=True)
        runtime_result.write_text("{}\n", encoding="utf-8")

        # when
        verify_manifest(self.repository.experiment_root, self.manifest)
        evaluator_prompt = self.repository.experiment_root / "prompts" / "evaluator.md"
        evaluator_prompt.write_bytes(evaluator_prompt.read_bytes() + b"changed\n")

        # then
        with self.assertRaisesRegex(ValueError, "input file changed"):
            verify_manifest(self.repository.experiment_root, self.manifest)

    def test_verifier_rejects_an_extra_harness_source(self) -> None:
        # given
        extra = self.repository.experiment_root / "scheduled_learning_v1" / "extra.py"
        extra.write_text("VALUE = 1\n", encoding="utf-8")

        # when / then
        with self.assertRaisesRegex(ValueError, "harness_sources closure membership changed"):
            verify_manifest(self.repository.experiment_root, self.manifest)

    def test_verifier_rejects_a_symlinked_declared_input(self) -> None:
        # given
        prompt = self.repository.experiment_root / "prompts" / "evaluator.md"
        target = self.repository.repository_root / "outside-prompt.md"
        target.write_bytes(prompt.read_bytes())
        prompt.unlink()
        prompt.symlink_to(target)

        # when / then
        with self.assertRaisesRegex(ValueError, "symlink"):
            verify_manifest(self.repository.experiment_root, self.manifest)

    def test_verifier_rejects_rehashed_route_and_output_cap_substitutions(self) -> None:
        # given
        route_changed = copy.deepcopy(self.manifest)
        route_execution = _object(route_changed, "swift_execution")
        _object(route_execution, "task_route")["provider_reference"] = "other/model"
        rehash_binding(route_changed, "swift_execution")

        output_changed = copy.deepcopy(self.manifest)
        output_execution = _object(output_changed, "swift_execution")
        _object(output_execution, "evaluator_route")["max_output_tokens"] = 513
        rehash_binding(output_changed, "swift_execution")

        # when / then
        with self.assertRaisesRegex(ValueError, "task route"):
            verify_manifest(self.repository.experiment_root, route_changed)
        with self.assertRaisesRegex(ValueError, "evaluator route"):
            verify_manifest(self.repository.experiment_root, output_changed)

    def test_verifier_rejects_json_type_coercions_in_exact_values(self) -> None:
        # given
        boolean_schema = copy.deepcopy(self.manifest)
        boolean_schema["schema_version"] = True

        float_budget = copy.deepcopy(self.manifest)
        _object(float_budget, "budgets")["reflector_calls"] = 1.0
        rehash_binding(float_budget, "budgets")

        integer_gate = copy.deepcopy(self.manifest)
        gates = _object(integer_gate, "gates")
        _object(gates, "adapter_pass_rule")["allow_critical_result"] = 0
        rehash_binding(integer_gate, "gates")

        # when / then
        for case, changed in (
            ("boolean schema", boolean_schema),
            ("float budget", float_budget),
            ("integer gate", integer_gate),
        ):
            with self.subTest(case=case), self.assertRaises(ValueError):
                verify_manifest(self.repository.experiment_root, changed)

    def test_verifier_rejects_a_rehashed_run_order_substitution(self) -> None:
        # given
        changed = copy.deepcopy(self.manifest)
        run_order = changed["run_order"]
        if not isinstance(run_order, list) or not isinstance(run_order[0], dict):
            self.fail("test manifest run order must contain objects")
        run_order[0]["fixture_id"] = "pc-development-08"
        rehash_binding(changed, "run_order")

        # when / then
        with self.assertRaisesRegex(ValueError, "run order"):
            verify_manifest(self.repository.experiment_root, changed)

    def test_verifier_rejects_a_rehashed_aggregate_budget_substitution(self) -> None:
        # given
        changed = copy.deepcopy(self.manifest)
        _object(changed, "budgets")["responses_sends"] = 39
        rehash_binding(changed, "budgets")

        # when / then
        with self.assertRaisesRegex(ValueError, "aggregate budgets"):
            verify_manifest(self.repository.experiment_root, changed)

    def test_verifier_rejects_a_rehashed_gate_substitution(self) -> None:
        # given
        changed = copy.deepcopy(self.manifest)
        gates = _object(changed, "gates")
        _object(gates, "active_and_restart_gates")["minimum_restart_active_score"] = 89
        rehash_binding(changed, "gates")

        # when / then
        with self.assertRaisesRegex(ValueError, "gates"):
            verify_manifest(self.repository.experiment_root, changed)

    def test_verifier_rejects_a_rehashed_executable_identity_substitution(self) -> None:
        # given
        changed = copy.deepcopy(self.manifest)
        _object(changed, "swift_execution")["executable_sha256"] = "0" * 64
        rehash_binding(changed, "swift_execution")

        # when / then
        with self.assertRaisesRegex(ValueError, "executable identity"):
            verify_manifest(self.repository.experiment_root, changed)


class FreezeCLITests(unittest.TestCase):
    def test_module_cli_builds_and_verifies_without_an_owner_checkpoint(self) -> None:
        # given
        repository = create_repository()
        self.addCleanup(repository.cleanup)

        # when
        built = run_module("build", str(repository.experiment_root))
        verified = run_module("verify", str(repository.experiment_root))

        # then
        self.assertEqual(built.returncode, 0, built.stderr)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertTrue((repository.experiment_root / "freeze" / "manifest-input.json").is_file())
        self.assertTrue((repository.experiment_root / "freeze" / "manifest.json").is_file())
        self.assertIn("owner_approval=absent", verified.stdout)

    def test_module_cli_verify_rejects_a_changed_bound_input(self) -> None:
        # given
        repository = create_repository()
        self.addCleanup(repository.cleanup)
        built = run_module("build", str(repository.experiment_root))
        prompt = repository.experiment_root / "prompts" / "task.md"
        prompt.write_bytes(prompt.read_bytes() + b"changed\n")

        # when
        verified = run_module("verify", str(repository.experiment_root))

        # then
        self.assertEqual(built.returncode, 0, built.stderr)
        self.assertNotEqual(verified.returncode, 0)
        self.assertIn("input file changed", verified.stderr)


def _object(value: dict[str, object], key: str) -> dict[str, object]:
    item = value[key]
    if not isinstance(item, dict):
        raise AssertionError(f"test manifest {key} must be an object")
    return item


if __name__ == "__main__":
    unittest.main()
