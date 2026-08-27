from __future__ import annotations

import copy
import unittest

from tools.page_change_freeze import contract, run_order
from tools.page_change_freeze.tests.support import FreezeRepository


class RunOrderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = FreezeRepository()

    def tearDown(self) -> None:
        self.repo.cleanup()

    def test_derives_exact_counterbalanced_attempts_and_barriers(self) -> None:
        # given
        value = self.repo.make_manifest()
        digest = contract.sha256_hex(contract.canonical_json_bytes(value))

        # when
        first = run_order.derive(value, digest)

        # then
        self.assertEqual(first, run_order.derive(value, digest))
        self.assertEqual([stage["name"] for stage in first["stages"]],
                         run_order.RUN_ORDER_VALUES["stage_sequence"])
        self.assertEqual(first["planned_attempts"], {
            "canary": 4, "page_task": 72, "page_synthesis": 1,
            "page_task_or_synthesis": 73,
        })
        stages = {stage["name"]: stage for stage in first["stages"]}
        self.assertEqual([len(stages[name]["attempts"]) for name in
                          ("development", "regression", "sealed-pre-restart",
                           "sealed-post-restart")], [18, 18, 24, 12])
        self.assertEqual(stages["synthesis"]["kind"], "synthesis-attempt")
        barrier_names = [name for name in run_order.RUN_ORDER_VALUES["stage_sequence"]
                         if name.endswith("-barrier")]
        barriers = [stages[name] for name in barrier_names]
        self.assertTrue(all(set(barrier) == {"name", "kind", "barrier", "order_key"}
                            for barrier in barriers))
        self.assertTrue(all(barrier["kind"] == "barrier" and barrier["barrier"]
                            for barrier in barriers))
        self.assertEqual(len({barrier["order_key"] for barrier in barriers}), len(barriers))

        canary = stages["canary"]["events"]
        self.assertEqual([event["kind"] for event in canary],
                         ["attempt", "attempt", "barrier", "attempt", "attempt"])
        attempts = [event for event in canary if event["kind"] == "attempt"]
        self.assertEqual([(item["process"], item["condition"], item["lesson_source"])
                          for item in attempts], [
            ("A", "clean", "clean"), ("A", "nonempty", "artifact"),
            ("B", "clean", "clean"), ("B", "nonempty", "durable_active"),
        ])
        self.assertEqual(attempts[0]["worker_process_key"], attempts[1]["worker_process_key"])
        self.assertNotEqual(attempts[1]["worker_process_key"], attempts[2]["worker_process_key"])

        for stage_name, maximum_imbalance in (("regression", 1), ("sealed-pre-restart", 0)):
            items = stages[stage_name]["attempts"]
            first_conditions = [items[index]["condition"] for index in range(0, len(items), 2)]
            self.assertLessEqual(abs(first_conditions.count("clean") -
                                     first_conditions.count("lesson-conditioned")),
                                 maximum_imbalance)
            self.assertTrue(all(left != right for left, right in
                                zip(first_conditions, first_conditions[1:])))
            clean = [(item["fixture_id"], item["replicate_index"])
                     for item in items if item["condition"] == "clean"]
            lesson = [(item["fixture_id"], item["replicate_index"])
                      for item in items if item["condition"] == "lesson-conditioned"]
            self.assertEqual(clean, lesson)
        sealed = [(item["fixture_id"], item["replicate_index"])
                  for item in stages["sealed-pre-restart"]["attempts"]
                  if item["condition"] == "clean"]
        restarted = [(item["fixture_id"], item["replicate_index"])
                     for item in stages["sealed-post-restart"]["attempts"]]
        self.assertEqual(sealed, restarted)

    def test_order_is_sensitive_to_external_final_manifest_digest(self) -> None:
        # given
        first_manifest = self.repo.make_manifest()
        first_digest = contract.sha256_hex(contract.canonical_json_bytes(first_manifest))
        self.repo.write(contract.TASK_PROMPT_PATH, b"changed prompt\n")
        second_manifest = self.repo.make_manifest()
        second_digest = contract.sha256_hex(contract.canonical_json_bytes(second_manifest))

        # when
        first = run_order.derive(first_manifest, first_digest)
        second = run_order.derive(second_manifest, second_digest)

        # then
        self.assertNotEqual(first_digest, second_digest)
        self.assertNotEqual(
            [item["block_order_key"] for item in first["stages"][1]["attempts"]],
            [item["block_order_key"] for item in second["stages"][1]["attempts"]],
        )
        with self.assertRaises(contract.FreezeError) as raised:
            run_order.derive(first_manifest, "f" * 64)
        self.assertRegex(str(raised.exception), "does not match")

    def test_split_contract_identity_and_count_mutants_fail_closed(self) -> None:
        # given
        path = self.repo.root / contract.SPLITS_PATH
        baseline, _ = contract.load_json(path)
        mutations = []
        missing = copy.deepcopy(baseline)
        missing["splits"]["regression"].pop()
        mutations.append((missing, "fixture count"))
        wrong_split = copy.deepcopy(baseline)
        wrong_split["splits"]["regression"][0]["fixture_id"] = "pc-development-99"
        mutations.append((wrong_split, "fixture identity"))
        duplicate = copy.deepcopy(baseline)
        duplicate["splits"]["regression"][1] = copy.deepcopy(
            duplicate["splits"]["regression"][0]
        )
        mutations.append((duplicate, "fixture identity"))

        for value, message in mutations:
            with self.subTest(message=message):
                path.write_bytes(contract.canonical_json_bytes(value) + b"\n")

                # when
                with self.assertRaises(contract.FreezeError) as raised:
                    self.repo.make_manifest()

                # then
                self.assertRegex(str(raised.exception), message)


if __name__ == "__main__":
    unittest.main()
