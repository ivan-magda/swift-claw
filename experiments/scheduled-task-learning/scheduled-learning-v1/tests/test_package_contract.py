import unittest

from scheduled_learning_v1 import ALGORITHM_ID


class PackageContractTests(unittest.TestCase):
    def test_package_exposes_the_frozen_algorithm_id(self) -> None:
        # Given
        expected = "scheduled-learning/v1"

        # When
        actual = ALGORITHM_ID

        # Then
        self.assertEqual(actual, expected)
