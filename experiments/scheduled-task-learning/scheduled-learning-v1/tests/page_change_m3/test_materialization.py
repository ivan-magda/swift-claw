"""Task-carrier materialization: clean/trial lesson sets and the reused validator boundary."""

from __future__ import annotations

import unittest

from page_change_m3.validation import ContractError

from page_change_m3 import materialize_task

from . import support


class TaskMaterializationTests(unittest.TestCase):
    def test_clean_condition_uses_the_canonical_empty_lesson_set(self) -> None:
        # given
        source = support.real_fresh_source("pc-development-07", "development")

        # when
        carrier = materialize_task(source, [])

        # then
        self.assertEqual(
            carrier,
            {
                "schema_version": 1,
                "task_id": source["task_id"],
                "task": source["task"],
                "active_lessons": {"schema_version": 1, "lessons": []},
            },
        )

    def test_trial_condition_carries_the_exact_effective_lesson_set(self) -> None:
        # given
        source = support.real_fresh_source("pc-regression-04", "regression")
        lessons = ["Ignore volatile counters.", "Treat timestamps as noise."]

        # when
        carrier = materialize_task(source, lessons)

        # then
        self.assertEqual(carrier["active_lessons"], {"schema_version": 1, "lessons": lessons})

    def test_materialize_task_preserves_the_exact_task_object_without_stringifying_it(
        self,
    ) -> None:
        # given
        source = support.real_fresh_source("pc-sealed-05", "sealed")

        # when
        carrier = materialize_task(source, [])

        # then
        self.assertIsInstance(carrier["task"], dict)
        self.assertEqual(carrier["task"], source["task"])
        self.assertEqual(set(carrier["task"]), {"before_html", "after_html", "region_ids"})

    def test_materialize_task_normalizes_lesson_text_before_carrying_it(self) -> None:
        # given
        source = support.real_fresh_source("pc-regression-05", "regression")

        # when
        carrier = materialize_task(source, ["Keep it short.\r\n  "])

        # then
        self.assertEqual(carrier["active_lessons"]["lessons"], ["Keep it short."])

    def test_page_invalid_source_fails_through_the_reused_page_validator(self) -> None:
        # given
        source = support.source_with_invalid_region_id()

        # when / then
        with self.assertRaises(ContractError) as raised:
            materialize_task(source, [])
        self.assertIn(
            "schema.bounded_values", {issue.requirement for issue in raised.exception.issues}
        )

    def test_materialize_task_rejects_a_source_outside_the_frozen_fresh_set(self) -> None:
        # given
        source = support.source_with_foreign_fixture_id()

        # when / then
        with self.assertRaises(ContractError) as raised:
            materialize_task(source, [])
        self.assertIn(
            "fixtures.frozen_split_membership",
            {issue.requirement for issue in raised.exception.issues},
        )


if __name__ == "__main__":
    unittest.main()
