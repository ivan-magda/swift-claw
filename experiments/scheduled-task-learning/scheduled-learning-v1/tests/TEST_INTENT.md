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

## Immutable event journal and replay controller (Task 2)

The semantic reducer cases (trigger kinds, admission, trials, promotion, rollback) live only in the
frozen 24-case corpus at `conformance/replay-cases.json`, scored by `scheduled_learning_v1.conformance`.
`score_case` calls `benchmark_learning.learning_replay.replay` directly, in-memory, on a `case["attempt"]`
dict — it never constructs an `EventJournal` or a `ReplayController` and never touches a filesystem path.
So for every mutant below, the "nearest conformance case" is nearest only in the sense that it happens to
exercise the same reducer transition; it structurally cannot observe a disk/journal/controller-layer bug
because conformance never runs through that layer at all.

| Risk | Production branch or seam | Nearest existing test | Unique reachable mutant | Primary test |
| --- | --- | --- | --- | --- |
| `append()` returns a path/digest that does not match what was actually written to disk | `EventJournal.append` (journal.py) | conformance case `c01-sequence-gap-rejected` (nearest event-shape case; scores in-memory only) | Return `CommittedEvent(path=..., sha256=...)` computed from the *input* payload instead of the canonicalized `event_json` bytes actually persisted (e.g. drop the `dumps`/`canonical_sha256` round-trip) | `test_event_journal::EventJournalTests::test_append_returns_the_exact_committed_path_and_canonical_sha256` |
| `append()` assigns sequence numbers out of call order, or a reopened journal recomputes the wrong next sequence | `EventJournal._next_sequence` / `_committed_paths` (journal.py) | conformance case `c03-evidence-window-cutoff-and-compatibility-exclusions` (nearest case with a long ordered event log, but its ordering is enforced by `canonical_event_log`, not by journal filename sort) | Sort `_committed_paths()` lexicographically by filename instead of numerically by the captured `int(match.group(1))` (breaks past sequence 999999→1000000, or on reopen after a gap) | `test_event_journal::EventJournalTests::test_append_orders_sequence_numbers_by_call_order` |
| `append()` silently overwrites an already-committed event file instead of rejecting the write | `EventJournal.append` → `_write_new_file` (journal.py) | conformance case `c01-sequence-gap-rejected` (nearest rejection case, but it rejects a *contract* violation in-memory, not a *filesystem* collision) | Replace the `O_EXCL` open flag with `O_TRUNC` (or drop the `target.exists()` guard), so a second writer with the same next-sequence assumption clobbers the first writer's committed bytes instead of raising `FileExistsError` | `test_event_journal::EventJournalTests::test_append_rejects_writing_to_an_already_committed_target` |
| `load()` returns cached/reconstructed event objects instead of the exact bytes currently on disk | `EventJournal.load` (journal.py) | conformance case `c02-controller-restart-interrupts-operation-and-owner-precedence-suppresses-trigger` (nearest single-event-shaped case, but conformance never persists events to disk at all) | Cache the `ReplayEvent` returned by `append()` in-memory and have `load()` return the cache instead of re-reading and re-parsing each file from disk | `test_event_journal::EventJournalTests::test_load_reflects_the_exact_bytes_currently_committed_to_disk` |
| `ReplayController.replay()` writes a `replay-receipt.json` that does not equal the receipt member of its own return value | `ReplayController.replay` (controller.py) | conformance case `c14-promotion-then-post-promotion-adapter-critical-rollback` (nearest case with a real, multi-decision receipt, but conformance never calls `write()` or reads a `replay-receipt.json` file) | Write `replay_receipt(...)` recomputed independently instead of `result["receipt"]`, or write the receipt before the final `decisions` mutation lands, so the published file and the returned dict silently diverge | `test_replay_controller::ReplayControllerTests::test_replay_persists_the_exact_core_receipt` |
| `ReplayController.replay()` writes `state.json`/`decision-receipts.json` that drop, reorder, or partially serialize the returned `state`/`decisions` members | `ReplayController.replay` (controller.py) | conformance case `c17-owner-triggered-rollback-then-no-relapse-from-later-evidence` (nearest case with several ordered decisions, but conformance asserts the in-memory dict only, never the published files) | Sort `result["decisions"]` before writing `decision-receipts.json` (e.g. by `decision` string), or write only the last decision, silently breaking the "no reordering" and "exact" guarantees while the in-memory `result` stays correct | `test_replay_controller::ReplayControllerTests::test_replay_persists_the_exact_state_and_ordered_decisions_without_reordering` |
| A freshly constructed `EventJournal`/`ReplayController` pointed at an existing root does not durably see what an earlier handle committed | `EventJournal.__init__` / `EventJournal.load` (journal.py) | conformance case `c02-controller-restart-interrupts-operation` (nearest single-event case, but conformance has no concept of "reopening" — it builds one in-memory event list per case) | Compute `_next_sequence` once from a module-level cache keyed by root instead of scanning `self._root.iterdir()` on every construction, so a second, independently constructed handle at the same root loses track of already-committed events | `test_replay_controller::ReplayControllerTests::test_reopened_journal_feeds_the_controller_the_same_committed_events` |

### Redundancy pass (`docs/TESTING.md` §9.1)

1. **Mutants killed:** the seven listed above — an incorrect committed path/digest, wrong sequence
   ordering on disk, a silent overwrite of a committed event, a load that trusts an in-memory cache
   instead of disk, a published receipt/state/decisions file that diverges from the returned dict, and
   a reopened handle that loses durable state.
2. **Production branch/seam:** `scheduled_learning_v1/replay_controller/journal.py` (filesystem-only
   append/load) and `scheduled_learning_v1/replay_controller/controller.py` (reducer delegation and
   canonical publication) — the seam this task adds between the pure, already-tested reducer and durable
   storage.
3. **Nearest existing test and why it misses each mutant:** in every row, the nearest conformance case
   scores `replay()` directly against an in-memory `attempt` dict (see `scheduled_learning_v1/conformance.py::score_case`)
   and never constructs an `EventJournal` or a `ReplayController`, so it cannot observe a bug confined to
   filename encoding, disk write atomicity, on-disk byte fidelity, or published-file/dict divergence —
   all seven mutants are invisible to any conformance case by construction, no matter how semantically
   close its event log is.
4. **Behavior-preserving refactor stays green:** yes — renaming internal helpers, changing the
   `_EVENT_FILENAME` regex's group count while preserving its semantics, or reformatting the written
   JSON's whitespace outside of `dumps`'s canonical form does not change any assertion's outcome.

No redundant test forms apply: each test targets a distinct journal/controller seam (path/digest
binding, sequence ordering, collision rejection, disk-truth loading, receipt publication, state/decision
publication, reopened durability) with no repeated baseline case or unconstructible scenario.
