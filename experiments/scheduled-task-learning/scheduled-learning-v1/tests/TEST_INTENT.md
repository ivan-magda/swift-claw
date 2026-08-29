# Scheduled-learning v1 harness test-intent map

This is the pre-commit redundancy pass required by `docs/TESTING.md` §9.1. Every retained test names
one primary observable risk, a distinct reachable mutant, and a nearest existing test that would not
catch it.

## Package scaffold (Task 1)

| Risk | Production branch or seam | Nearest existing test | Unique reachable mutant | Primary test |
| --- | --- | --- | --- | --- |
| A wrong or drifted algorithm identifier silently enters the freeze manifest and every decision receipt it binds | `scheduled_learning_v1.ALGORITHM_ID` package boundary | none; new package boundary | Change `ALGORITHM_ID` to any value other than the exact frozen string `"scheduled-learning/v1"` (typo, wrong version suffix, or a value copied from Protocol 0.6/M0) | `test_package_contract::PackageContractTests::test_package_exposes_the_frozen_algorithm_id` |

### Redundancy pass (`docs/TESTING.md` §9.1)

1. **Mutant killed:** `ALGORITHM_ID` silently changes to any string other than
   `"scheduled-learning/v1"` (a typo, a stray whitespace character, or accidental reuse of a
   Protocol 0.6/M0 identifier).
2. **Production branch/seam:** the top-level `scheduled_learning_v1` package boundary — this is the
   sole export that every later manifest, receipt, and adapter-envelope binding in this plan reads
   the algorithm identity from.
3. **Nearest existing test and why it misses this mutant:** none exists. `benchmark-core`'s
   `tests/test_learning_contract.py` and `page-change`'s suite both predate this package and never
   import `scheduled_learning_v1`; no test in the repository can observe this constant.
4. **Behavior-preserving refactor stays green:** yes — renaming the module, moving the constant
   within `__init__.py`, or changing unrelated docstrings does not change the imported value, so the
   test keeps passing.

No redundant test forms apply (no DM/group/topic variants, no repeated baseline case, no derived
value, no absent-log assertion, no raw storage round-trip, no unconstructible integration scenario):
this is the first and only test in a brand-new package boundary.
