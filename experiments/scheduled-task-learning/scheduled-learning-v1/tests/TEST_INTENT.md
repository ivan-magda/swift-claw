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

## Fresh M3 page-change data and closed carriers (Task 3)

`page_benchmark`'s own suite (`experiments/scheduled-task-learning/page-change/tests/test_validation.py`,
`tests/test_fixtures.py`) exercises `validate_source`/`validate_gold` and Protocol 0.6's fixture
tooling directly against Protocol 0.6's 13-fixture corpus; it never imports `page_change_m3`, never
constructs an evaluator/reflector carrier, and has no concept of a second, disjoint fresh corpus. So
for every mutant below, "nearest existing page test" is nearest only in the sense that it happens to
call the same reused validator function — it structurally cannot observe a bug confined to the M3
carrier-construction or fresh-fixture-independence boundary this task adds.

| Risk | Production branch or seam | Nearest existing test | Unique reachable mutant | Primary test |
| --- | --- | --- | --- | --- |
| The evaluator or reflector carrier silently leaks a scoring/candidate/oracle field (directly or nested inside its own "closed" sub-object) to the model | `page_change_m3/materialize.py::build_evaluator_carrier` / `build_reflector_carrier` | `page-change/tests/test_validation.py` (nearest reused-validator case, but it only checks `page_benchmark`'s own attempt/gold/lesson-candidate schemas, never an M3 carrier) | Add `"active_lessons": task["active_lessons"]` (or any of `candidate_digest`/`trial`/`score`/`gold`/`oracle`) to the evaluator carrier, or leave an evaluation's `oracle`/`score` key un-stripped in `build_reflector_carrier`'s blind summary | `test_carrier_visibility::EvaluatorCarrierVisibilityTests::test_evaluator_carrier_excludes_lessons_and_scoring_context` and `::ReflectorCarrierVisibilityTests::test_reflector_carrier_strips_an_oracle_field_from_an_evaluation_summary` |
| `materialize_task` substitutes the clean/trial lesson set (returns a non-empty set for clean, or drops/mutates the effective set for trial) | `page_change_m3/materialize.py::materialize_task` | none in `page-change` (its own `materialize.py` builds page-change's own `target_class`-object lesson schema, a different shape, for a different, frozen corpus) | Return `active_lessons.lessons` as a copy of some default/stale list instead of the exact `[normalize_lesson_text(text) for text in lessons]` result, so clean silently carries a non-empty set or trial silently drops entries | `test_materialization::TaskMaterializationTests::test_clean_condition_uses_the_canonical_empty_lesson_set` and `::test_trial_condition_carries_the_exact_effective_lesson_set` |
| A fresh M3 fixture reuses Protocol 0.6/M0 fixture content (same before/after HTML and region IDs under a new fixture ID), or the committed fresh split drifts from exactly 2/3/2 | `page_change_m3/fixtures.py::verify_fixture_independence` | `page-change/tests/test_fixtures.py::FixtureContractTests::test_all_fixtures_and_split_quotas_are_valid` (nearest: `page_benchmark.fixtures.validate_repository` checks Protocol 0.6's own split counts and cross-fixture literal/mechanism uniqueness *within* its one corpus, but has no concept of a second, sibling corpus to be disjoint from) | Copy an existing Protocol 0.6 fixture's `task` object into a fresh source under a new frozen fixture ID, or delete/duplicate one of the seven frozen fresh source/gold files | `test_fixture_boundary::FixtureBoundaryTests::test_a_fresh_source_reusing_protocol_06_task_content_is_rejected` and `::test_an_incomplete_fresh_corpus_fails_the_exact_split_count_check` |
| `materialize_task` accepts a page-valid source whose `fixture_id` is not one of the seven frozen fresh M3 IDs (e.g. a Protocol 0.6/M0 ID slipping in through this path) | `page_change_m3/materialize.py::materialize_task` (membership check against `fixtures.ALL_FRESH_FIXTURE_IDS`) | `page-change/tests/test_validation.py` (nearest, but `validate_source` alone accepts any pattern-matching fixture ID from any split; it has no concept of "fresh M3" membership) | Remove or bypass the `source["fixture_id"] not in ALL_FRESH_FIXTURE_IDS` check, letting a Protocol 0.6-shaped `fixture_id` (e.g. `pc-development-01`) materialize through the M3 path | `test_materialization::TaskMaterializationTests::test_materialize_task_rejects_a_source_outside_the_frozen_fresh_set` |
| A superficially well-shaped fresh source (all required keys present) with a page-invalid nested value (e.g. a malformed `region_id`) is accepted instead of failing through the reused `page_benchmark.validation.validate_source` boundary | `page_change_m3/materialize.py::materialize_task` → `page_change_m3/validation.py::require_valid_source` | `page-change/tests/test_validation.py` (validates the same function directly, but never through the M3 `materialize_task` call boundary) | Skip or swallow the `require_valid_source(source)` call (or catch and discard its `ContractError`) before constructing the carrier | `test_materialization::TaskMaterializationTests::test_page_invalid_source_fails_through_the_reused_page_validator` |
| An attacker-controlled stable lesson or owner payload closes its own untrusted marker and injects model-visible markup | `page_change_m3/materialize.py::_fence_untrusted` | `test_reflector_carrier_fences_stable_lessons_and_owner_payloads_as_untrusted` (nearest, but it uses harmless text and cannot detect a delimiter escape) | Interpolate `</untrusted>` from a lesson or owner payload without escaping `<`/`>` so it terminates the outer fence | `test_carrier_visibility::ReflectorCarrierVisibilityTests::test_reflector_fences_cannot_be_closed_by_lesson_or_owner_payload_content` |
| An undeclared source or gold fixture expands a split beyond the frozen 2/3/2 inventory | `page_change_m3/fixtures.py::verify_fixture_independence` directory inventory | `test_an_incomplete_fresh_corpus_fails_the_exact_split_count_check` (nearest, but it only exercises missing expected files) | Iterate only the expected filenames, allowing `pc-development-99.source.json` or an extra gold file to evade the frozen boundary | `test_fixture_boundary::FixtureBoundaryTests::test_an_extra_fresh_fixture_fails_the_exact_split_inventory_check` |
| Evaluator run identity changes across identical calls, or fails to bind either the task ID or raw output | `page_change_m3/materialize.py::_run_identity` | `test_evaluator_carrier_has_the_exact_top_level_and_run_key_sets` (nearest, but it observes shape only) | Use time/randomness, a constant, task ID alone, or raw output alone for `run_id` | `test_carrier_visibility::EvaluatorCarrierVisibilityTests::test_evaluator_run_identity_is_deterministic_and_binds_task_and_raw_output` |

### Redundancy pass (`docs/TESTING.md` §9.1)

1. **Mutants killed:** the eight listed above — evaluator/reflector visibility leakage (including a
   nested oracle field inside a blind evaluation summary), clean/trial lesson-set substitution,
   Protocol 0.6/M0 fixture-content or split-count drift, a non-fresh fixture ID slipping through
   `materialize_task`, a skipped reused-validator call, an attacker-closing untrusted fence, an
   extra source/gold fixture outside the frozen inventory, and a time/random or partial-input
   evaluator run identity.
2. **Production branch/seam:** `page_change_m3/materialize.py` (carrier construction and lesson-set
   handling), `page_change_m3/validation.py` (closed carrier shapes), and `page_change_m3/fixtures.py`
   (fresh fixture discovery and Protocol 0.6/M0 independence) — the fresh-data boundary this task adds
   between the reused page validator and the generic reducer's evaluator/reflector operations.
3. **Nearest existing test and why it misses each mutant:** `page-change`'s own suite calls
   `validate_source`/`validate_gold`/`validate_lesson_candidate` directly against Protocol 0.6's
   13-fixture corpus and page-change's own lesson-candidate schema; it never imports `page_change_m3`,
   never constructs an evaluator/reflector carrier, and has no concept of a second, disjoint fresh
   corpus or a fresh-fixture membership gate — every mutant above is invisible to it by construction,
   no matter how similar the reused validator call looks.
4. **Behavior-preserving refactor stays green:** yes — renaming internal helpers (e.g. `_fence_untrusted`,
   `_blind_evaluation_summary`), reordering the seven fixtures' construction, or reformatting the
   committed JSON's whitespace outside canonical `dumps` form does not change any assertion's outcome.

No redundant test forms apply: each test targets a distinct carrier-construction, lesson-set, or
fixture-independence seam with no repeated baseline case, DM/group/topic variant, or unconstructible
scenario. `test_materialize_task_preserves_the_exact_task_object_without_stringifying_it` and
`test_materialize_task_normalizes_lesson_text_before_carrying_it` are additional, narrower assertions
kept in `test_materialization.py` because they name their own distinct mutants (task-object
stringification/loss, and a normalization no-op) not covered by the five rows above; they are not
duplicated here since neither is the nearest-test citation for a Protocol 0.6 comparison.

## Trusted M3 page adapter scoring and receipt boundary (Task 4)

`page_benchmark`'s scorer suite proves page-level scoring from a source, gold record, and raw attempt.
It does not construct M3 pairs, aggregate deltas, apply the frozen 2--3 pair policy, or expose a
generic-safe envelope. The new tests therefore own only that post-freeze adapter boundary.

| Risk | Production branch or seam | Nearest existing test | Unique reachable mutant | Primary test |
| --- | --- | --- | --- | --- |
| A model-supplied score claim changes a pair result instead of the reused scorer and sealer deciding it from the raw attempt | `page_change_m3.oracle.sealed_score` scorer/sealer boundary | `page-change/tests/test_scorer_semantics.py::test_evidence_is_order_independent_and_accepts_nonempty_exact_substrings` scores one raw attempt but has no M3 outer attempt or score-claim field | Read `attempt["score"]` instead of the sealed `score_result["score"]` | `test_pair_scoring::PairScoringTests::test_pair_receipt_is_sealed_from_raw_attempts_not_embedded_score_claims` |
| A candidate score exactly at 90 or a mean delta exactly at 10 is rejected, or three otherwise-valid pairs are rejected | `page_change_m3.adapter.outcome_for_pairs` threshold/count pass branch | The page scorer's success threshold test has no paired mean or M3 maximum-pair branch | **threshold comparator changed** from inclusive to exclusive, or reject the allowed third pair | `test_adapter_gates::AdapterGateTests::test_adapter_reports_each_distinct_gate_outcome` |
| A clean/candidate delta is calculated in the opposite direction, or a critical scorer result is folded into ordinary regression | `page_change_m3.adapter.outcome_for_pairs` delta and critical branches | `test_pair_scoring` proves score provenance only; it has equal clean/candidate scores and cannot distinguish direction or outcome taxonomy | **pair direction reversed**; **critical result treated as ordinary regression** | `test_adapter_gates::AdapterGateTests::test_adapter_reports_each_distinct_gate_outcome` |
| The generic reducer receives page metrics, or the envelope digest hashes itself/envelope bytes rather than the complete page receipt | `page_change_m3.receipt.build_adapter_receipt` receipt-to-envelope boundary | `benchmark-core/tests/test_learning_contract.py::test_adapter_envelope_rejects_invalid_digest_unknown_key_and_unknown_outcome` validates generic shape but never builds a page receipt | **envelope hash computed over wrong bytes** or include `pairs` in the envelope | `test_adapter_receipt::AdapterReceiptTests::test_envelope_is_neutral_and_binds_each_identity` and `::test_receipt_digest_hashes_the_full_receipt_not_the_neutral_envelope` |

### Redundancy pass (`docs/TESTING.md` §9.1)

1. **Mutants killed:** the four named mutants above: threshold comparator changed, pair direction
   reversed, critical result treated as ordinary regression, and envelope hash computed over wrong
   bytes. The pair-provenance case additionally kills use of an untrusted embedded score claim.
2. **Production branch/seam:** `oracle.py` is the only scorer/sealer bridge; `adapter.py` owns the
   paired threshold, direction, count, and critical branches; `receipt.py` owns the boundary that
   strips full page evidence before generic replay.
3. **Nearest existing test and why it misses each mutant:** page-change scorer tests never call M3
   pair aggregation or receipt construction, while generic contract tests accept an already-neutral
   envelope and never see a page score or full receipt. Neither layer can observe an aggregation,
   direction, outcome-taxonomy, or receipt-byte-binding defect here.
4. **Behavior-preserving refactor stays green:** yes — the tests assert sealed scores, public
   outcomes, exact neutral key shape, and receipt hashes, not private helpers or call order.

No redundant test forms apply: the gate table contains only distinct observable categories; the two
receipt tests separately protect visibility/identity binding and the distinct full-receipt hash
boundary.

### Fix round 1

| Risk | Production branch or seam | Nearest existing test | Unique reachable mutant | Primary test |
| --- | --- | --- | --- | --- |
| A caller-provided candidate-record digest or unnormalized lesson text is forwarded as the replacement lesson-set identity | `page_change_m3.receipt.build_adapter_receipt` candidate provenance boundary | The original neutral-envelope test only checked a supplied digest was forwarded | Replace the canonical normalized lesson-set hash with the caller argument or hash raw CRLF/whitespace lesson text | `test_adapter_receipt::AdapterReceiptTests::test_candidate_digest_is_derived_from_the_frozen_replacement_lessons` |
| One frozen adapter/dataset/oracle/gates/execution-surface binding, or the candidate replacement digest, is omitted, swapped, or held stale when its exact frozen input changes | `page_change_m3.receipt.build_adapter_receipt` envelope binding projection | The candidate-provenance test does not vary frozen adapter identities, and the receipt-hash test intentionally proves receipt stability across an envelope-only change | Project every envelope identity from one fixed value, swap two digest fields, or retain the old candidate digest | `test_adapter_receipt::AdapterReceiptTests::test_envelope_binds_each_changed_frozen_identity_independently` |

The two fix-round tests are non-redundant: one proves the candidate is derived from normalized frozen
lesson data rather than a caller digest; the table proves each separate envelope projection reacts to
its own changed identity. The existing full-receipt hash test remains the only check that an
envelope-only identity change does not alter receipt bytes.

## One-shot Swift worker bridge (Task 5)

| Risk | Production branch or seam | Nearest existing test | Unique reachable mutant | Primary test |
| --- | --- | --- | --- | --- |
| A bridge launches a second subprocess or swaps either canonical subcommand/flag pair | `worker_bridge/bridge.py::WorkerBridge._run` subprocess boundary | `Tests/ClawEvaluationTests/Learning/Call/EvaluationLearningCallTests` runs Swift worker internals, never Python subprocess argv or durability | Invoke `subprocess.run` twice, replace `learning-call --request` with `worker --invocation`, or route a task through the learning command | `test_process_launch::ProcessLaunchTests::test_launches_one_exact_learning_command_and_bounds_stdout_diagnostics` and `::test_launches_one_exact_task_command` |
| The final closed request lacks the committed start-event authorization, or uses an independently-derived event identity | `worker_bridge/requests.py::bind_authorization` and `bridge.py` use of `CommittedEvent` | `Tests/ClawEvaluationTests/Learning/Call/EvaluationLearningCallContractTests` verifies Swift admission against a prebuilt event but cannot observe Python's journal append-return binding | Omit `authorization`, use an event filename guessed from sequence, or rehash a different event object | `test_authorization::AuthorizationTests::test_writes_only_the_committed_start_event_path_and_sha_as_authorization` |
| A successful terminal event hashes Python diagnostics/classification instead of the exact durable Swift result | `worker_bridge/bridge.py::WorkerBridge._run` result publication binding | The returned-event assertions in the same test prove start authorization only; Swift result tests never inspect the Python finish event | Compute `result_digest` from the augmented terminal dictionary rather than the canonical result object loaded from `result_path` | `test_authorization::AuthorizationTests::test_writes_only_the_committed_start_event_path_and_sha_as_authorization` |
| A task result from another carrier is accepted | `worker_bridge/task_results.py::validate_task_result` | `Tests/ClawEvaluationTests/Learning/EvaluationLearningWorkerTests` checks Swift task materialization but never Python result-to-call binding | Compare only job ID and accept a substituted `learning_carrier_sha256` | `test_task_result::TaskResultTests::test_rejects_malformed_and_substituted_carrier_results` |
| A malformed/cross-operation evaluator or reflector result is accepted, or an output cap is ignored | `worker_bridge/learning_results.py::validate_learning_result` | `Tests/ClawEvaluationTests/Learning/Call/EvaluationLearningCallContractTests` owns Swift result construction, not Python terminal classification | Ignore `kind`/`operation_id`, or change `>` to `>=` at 513/769 completion tokens | `test_learning_result::LearningResultTests::test_rejects_wrong_kind_and_cross_operation_and_enforces_exact_completion_caps` and `::test_reflector_accepts_768_and_rejects_769_completion_tokens` |
| Python double-subtracts reported usage, counts a failed-no-call send, or ignores the retry cap | `worker_bridge/accounting.py::validate_usage` | `Tests/ClawEvaluationTests/Learning/Call/EvaluationLearningCallRunnerTests` verifies the worker formula but cannot observe this Python revalidation | Subtract the terminal row twice, permit four sends, or permit nonzero failed-no-call sends | `test_accounting::AccountingTests::test_recomputes_reported_and_missing_usage_without_a_second_subtraction` and `::test_failed_no_call_is_zero_sends_and_handed_off_usage_is_bounded` |
| A reflector launch emits a Python-only trigger key or uses an unrelated opaque operation ID | `worker_bridge/bridge.py::_start_payload` and `requests.py` reflector core admission | The generic contract test checks shape but cannot observe the bridge's selected operation identity or its durable start append | Add `trigger_digest` to the start payload or stop requiring the reflector operation ID to be the frozen trigger digest | `test_authorization::AuthorizationTests::test_reflector_start_uses_trigger_as_operation_id_and_exact_shared_payload` |
| Learning provenance binds the authorization-free core, a substituted freeze/executable, or unhashed/oversized output | `worker_bridge/learning_results.py::validate_learning_result` final request and result validator | The completion-cap matrix changes usage only; it never changes authorization, provenance, output SHA, byte count, grapheme count, or exact result keys | Compare `request_sha256` to `core_digest(core)`, omit freeze/executable comparisons, use canonical-JSON hashing for output text, or skip one local output bound | `test_learning_result::LearningResultTests::test_binds_final_request_provenance_output_and_outcome_shape` and `::test_enforces_output_byte_and_grapheme_limits_and_exact_result_keys` |
| A canonical task result can be replaced by an invented operation-shaped record, another configuration/provenance, or inconsistent process/output/carrier/accounting evidence | `worker_bridge/task_results.py::validate_task_result` exact Swift result/configuration/carrier projection and shared accounting dependency | The substituted-carrier test changes only one digest; Swift worker tests cannot observe Python accepting invented result fields or skipping its independent accounting check | Accept `job_id`/`operation_id` as task-result identity, ignore process/lock UUID or exact configuration approval, accept a completed result with a critical code, eligible replacement, or exceeded output counter, trust changed top-level lesson IDs, trust `accounted_tokens`, or trust a false carrier-verification/taint result | `test_task_result::TaskResultTests::test_binds_canonical_result_identity_route_provenance_and_accounting`, `::test_rejects_broken_carrier_protocol_and_configuration_provenance`, and `test_accounting::AccountingTests::test_task_rows_use_the_shared_proxy_formula` |
| A task or learning launch can admit an invented top-level core field, a task budget snapshot, or a task route that strict Swift admission rejects | `worker_bridge/requests.py::_validate_core` and `bound_contract` exact TaskInvocationCore/CallRequestCore plus selected Swift route projection before journaling | The exact successful argv tests use canonical cores and cannot distinguish Python accepting a wider schema or a drifted global budget/route constant | Permit an unknown task or learning core key, accept a global Responses cap other than Swift's frozen 454, or self-authorize a task retry budget of 3 instead of 1, and launch the process anyway | `test_process_launch::ProcessLaunchTests::test_rejects_noncanonical_task_and_learning_cores_before_launch` |
| Coordinated edits replace Swift's scheduled-learning receipt constants while preserving every internal digest/equality | `worker_bridge/task_results.py::_require_carrier_bindings` scheduled receipt identity boundary | `test_rejects_malformed_and_substituted_carrier_results` changes only one top-level lesson list, so cross-record equality already rejects it | Change top-level, workspace, and receipt `lesson_set_id`/`lesson_ids` together and recompute both receipt digests | `test_task_result::TaskResultTests::test_rejects_coordinated_scheduled_receipt_identity_substitution` |
| A usage row from another run/session/model is counted as this task's frozen-route usage | `worker_bridge/task_results.py::_require_accounting` per-row identity binding | `test_task_rows_use_the_shared_proxy_formula` uses reduced accounting-only rows and cannot observe result or route identity | Accept a row after independently substituting its `run_id`, `session_id`, or `model` while leaving the first provider-call ID and token total intact | `test_task_result::TaskResultTests::test_binds_every_usage_row_to_result_and_frozen_route_identity` |
| A completed-shaped task record or invalid outcome-specific critical/replacement combination is accepted after relabeling it as any failure | `worker_bridge/task_results.py::validate_task_result` terminal outcome projection | The completed-shape mutations change critical code/disposition/counts but leave `outcome == completed`; no prior test presents any failure outcome | Return `failed` for any known failure outcome without checking its raw output/critical/replacement shape | `test_task_result::TaskResultTests::test_rejects_outcome_specific_failure_shape_mutations` |
| A canonical Swift task failure is rejected because its optional `outputCounts` encoded as nil is absent | `worker_bridge/task_results.py::_require_result_schema` and `_require_route_and_output` optional output-count branch | Every prior task fixture is completed and therefore correctly requires output counts | Call `_object(result, "output_counts")` unconditionally or remove it from the optional result keys | `test_task_result::TaskResultTests::test_accepts_canonical_failure_with_missing_output_counts` |
| A canonical `.failed` learning result with zero observed Responses sends is rejected, or loosening accounting also permits a zero-send successful response | `worker_bridge/learning_results.py::_classify_outcome` outcome-specific use of shared accounting | `test_failed_no_call_is_zero_sends_and_handed_off_usage_is_bounded` exercises only the separate no-usage accounting shortcut, not a full canonical failed usage record or response outcome | Unconditionally reject `responses_sends == 0`, or unconditionally accept it for both `.failed` and `.response` | `test_learning_result::LearningResultTests::test_failed_result_accepts_zero_sends_but_response_still_requires_a_send` |
| A task result substitutes an invented nonempty tool-contract critical code for Swift's closed violation enum | `worker_bridge/task_results.py::_valid_ineligible_failure` tool-contract branch | `test_rejects_outcome_specific_failure_shape_mutations` rejects a missing critical code but never supplies an unknown nonempty code | Accept any nonempty string instead of the five `EvaluationToolViolation` raw values | `test_task_result::TaskResultTests::test_rejects_unknown_nonempty_tool_contract_critical_code` |
| A zero-accountable-send learning failure falsely claims a terminal reported usage row | `worker_bridge/accounting.py::validate_usage` reported-row admission guard | `test_failed_result_accepts_zero_sends_but_response_still_requires_a_send` uses the canonical all-null usage row and cannot distinguish a fabricated reported row | Omit Swift's `reportedRow == nil || responsesSends - provenNotStartedResponsesSends > 0` guard | `test_learning_result::LearningResultTests::test_rejects_zero_send_failed_usage_with_reported_terminal_row` |
| A completed task result omits or nulls the output counter that Swift's completed runtime projection supplies | `worker_bridge/task_results.py::_require_route_and_output` completed output-count branch | `test_accepts_canonical_failure_with_missing_output_counts` intentionally exercises the opposite failure branch; the completed identity test mutates only a present counter | Return early for every null/missing `output_counts` value instead of rejecting completed results | `test_task_result::TaskResultTests::test_completed_result_requires_non_null_output_counts` |

### Redundancy pass (`docs/TESTING.md` §9.1)

The retained groups protect separate seams: both subprocess command lines, returned-event
authorization, the shared reflector start identity, canonical task/configuration/carrier/budget binding,
final learning-request/result invariants, completion caps, and the two result shapes' shared
accounting arithmetic. The
nearest Swift worker tests cannot observe Python's event durability or subprocess command line; they
remain the authority for Swift tool freedom and network policy. Each test asserts public output or a
durable input/result record, so behavior-preserving helper extraction or formatting leaves it green.

The round-3 additions are non-redundant: coordinated receipt substitution evades the prior one-field
comparison, usage identity changes preserve accounting arithmetic, failure relabeling leaves the prior
completed branch entirely, and zero-send `.failed` uses a full usage object that the no-call shortcut
never accepts. Their paired/table assertions vary one canonical contract dimension at a time and kill
the named reachable mutants without binding private helper structure.

The round-4 additions protect three separate branches. The tool-code case closes an enum domain while
preserving the rest of a canonical failure. The reported-row case changes only terminal usage presence,
leaving the accepted all-null zero-send failure intact. The completed-count case exercises the completed
branch that the existing optional failure-count test deliberately does not reach. Each remains green
under helper extraction because it asserts only the public validator result.

## Freeze manifest and pre-run approval (Task 6)

| Risk | Production branch or seam | Nearest existing test | Unique reachable mutant | Primary test |
| --- | --- | --- | --- | --- |
| A bound prompt, corpus member, scorer source, or executable changes after freeze, or runtime-only `results/` and owner-approval outputs are accidentally treated as manifest inputs | `freeze.verify_manifest` shared file-record verifier and excluded runtime locations | `tools/page_change_freeze/tests/test_manifest_core.py::ManifestCoreTests::test_manifest_rejects_changed_bytes` protects Protocol 0.6's descriptor and categories, never this M3 closure | Trust the stored `{path, sha256, bytes}` record without reading the current file, or recursively include `results/` / `freeze/owner-budget-approval.json` | `test_manifest::ManifestTests::test_verifier_rejects_one_changed_declared_file_and_ignores_runtime_outputs` |
| A new harness source silently expands the frozen code closure, or a symlink substitutes bytes outside the declared repository tree | `freeze.verify_manifest` closure-membership discovery and symlink-safe path traversal | The page-freeze closure test operates on `tools/page_change_freeze`; it never discovers `scheduled_learning_v1` / `page_change_m3` | Compare only listed records and ignore a newly added `.py`, or follow a symlink while hashing | `test_manifest::ManifestTests::test_verifier_rejects_an_extra_harness_source` and `::test_verifier_rejects_a_symlinked_declared_input` |
| A rehashed manifest changes the configured model route or one operation's output cap | `freeze.verify_manifest` frozen `swift_execution` semantic checks | Worker-bridge tests validate a supplied manifest against Swift admission but do not construct or freeze its route facts | Accept any nonempty route/model or any positive output cap after the binding digest is recomputed | `test_manifest::ManifestTests::test_verifier_rejects_rehashed_route_and_output_cap_substitutions` |
| JSON numeric/boolean coercion weakens a frozen manifest fact while its affected binding is valid | `freeze.verify_manifest` type-exact JSON semantic comparisons | Route and gate value-substitution cases use different values of the expected type; worker validators do not call the freeze verifier | Use Python `==`, allowing `True` for schema `1`, `1.0` for an integer budget, or `0` for a `false` gate | `test_manifest::ManifestTests::test_verifier_rejects_json_type_coercions_in_exact_values` |
| A rehashed manifest changes task attempt order while retaining the same fixtures and count | `freeze.verify_manifest` exact ordered `run_order` check | Replay conformance orders semantic events in-memory; it has no M3 task-attempt schedule | Sort by fixture ID or accept any ten entries | `test_manifest::ManifestTests::test_verifier_rejects_a_rehashed_run_order_substitution` |
| A rehashed manifest widens one owner-review aggregate budget | `freeze.verify_manifest` exact `budgets` check | Worker accounting tests enforce per-result arithmetic, not the cross-run 10/5/1/38/120000 ceiling | Accept any positive budget or compare only key shape | `test_manifest::ManifestTests::test_verifier_rejects_a_rehashed_aggregate_budget_substitution` |
| A rehashed manifest weakens an adapter, active, or restart threshold that later reporting must source from the manifest | `freeze.verify_manifest` exact committed `gates` check | Adapter tests exercise the current contract file directly but cannot detect a substituted manifest threshold | Accept the gate file digest without carrying and checking its exact threshold object | `test_manifest::ManifestTests::test_verifier_rejects_a_rehashed_gate_substitution` |
| A rehashed manifest names executable bytes other than the discovered `claw-eval` artifact | `freeze.verify_manifest` executable file-record/hash binding | Python process-launch tests execute a configured fake but never bind it into an M3 freeze | Trust `swift_execution.executable_sha256` without matching the protected executable record | `test_manifest::ManifestTests::test_verifier_rejects_a_rehashed_executable_identity_substitution` |
| The required `python -m scheduled_learning_v1.freeze build|verify` surface diverges from the public builder/verifier or requires an owner checkpoint during offline freeze construction | `freeze.main` CLI adapter | Package smoke and conformance tests never invoke this module CLI | Dispatch `verify` to a different loader, omit canonical outputs, or require the not-yet-created owner approval | `test_manifest::FreezeCLITests::test_module_cli_builds_and_verifies_without_an_owner_checkpoint` |
| CLI `verify` regenerates or trusts stored data instead of invoking the public verifier | `freeze.main` verify dispatch | The CLI happy path remains green if verification is bypassed | Mutate a bound prompt after CLI build and still exit zero | `test_manifest::FreezeCLITests::test_module_cli_verify_rejects_a_changed_bound_input` |
| A fully valid manifest and approval fail to return the closed verified receipt | `preflight.verify_pre_run` accepted return path | Rejection tests cannot detect an unconditional failure or a receipt assembled from stale values | Reject every approval, or return a receipt without the current freeze commit and exact budgets | `test_preflight::PreflightTests::test_unchanged_freeze_and_owner_checkpoint_are_verified` |
| A missing or value-substituted owner budget is accepted | `preflight.verify_pre_run` closed approval and exact budget comparison | Manifest budget verification protects the stored manifest, not the separately authorized budget object | Default a missing approval or accept 39 sends | `test_preflight::PreflightTests::test_missing_or_changed_owner_budget_is_rejected` |
| JSON numeric/boolean coercion weakens the approval schema or integer budget | `preflight.verify_pre_run` type-exact approval comparisons | The ordinary wrong-value tests do not distinguish Python-equal JSON types | Use Python `==`, allowing `True` or `1.0` for schema `1`, or `1.0` for an integer budget | `test_preflight::PreflightTests::test_approval_schema_and_budget_types_are_exact` |
| The closed approval accepts a wrong schema value, another valid manifest hash, an extra top-level key, or an extra budget key | `preflight.verify_pre_run` exact approval identity and key sets | The valid receipt case and budget-value case keep the approved shape and manifest digest intact | Skip one closed-object, manifest-digest, or nested-budget-key check | `test_preflight::PreflightTests::test_closed_approval_rejects_wrong_values_and_extra_keys` |
| Approval remains valid after `HEAD` moves | `preflight.verify_pre_run` current-commit comparison | Existing page-freeze approval binds GitHub comment evidence and cannot observe this local closed object | Omit `git rev-parse HEAD` or compare to a stale cached commit | `test_preflight::PreflightTests::test_changed_commit_is_rejected` |
| A non-RFC-3339 timestamp or an impossible calendar date with valid lexical shape is accepted | `preflight.verify_pre_run` timestamp lexical and calendar validation branches | Current-commit validation never parses approval time | Accept arbitrary text, or stop after the timestamp regex without parsing the date | `test_preflight::PreflightTests::test_noncanonical_or_impossible_approval_timestamp_is_rejected` |

### Redundancy pass (`docs/TESTING.md` §9.1)

1. **Mutants killed:** the rows above cover current-byte substitution, dynamic closure growth,
   symlink traversal, route/output-cap substitution, JSON type coercion, task-order substitution,
   aggregate-budget widening, gate-threshold weakening, executable substitution, CLI verification
   bypass, and accepted/rejected/stale owner-authorization branches.
2. **Production branch/seam:** `freeze.py` owns manifest build/verify/CLI orchestration,
   `freeze_inputs.py` owns closure and file-record verification, `frozen_contract.py` owns shared
   runtime facts and type-exact JSON comparison, `page_change_m3/identities.py` owns page identity
   derivation, and `preflight.py` adds the closed owner object and current-commit gate. None launches
   a worker; Task 7 owns verification immediately before each real model call and score.
3. **Nearest existing test and why it misses each mutant:** Protocol 0.6's page-freeze suite binds a
   different descriptor, corpus, verifier package, executable, and approval protocol. The M3 worker
   tests start after a manifest is supplied and therefore cannot observe this package's source
   closure, aggregate budget, CLI, or current-Git-commit checks. Prompt, corpus, scorer, and
   executable byte changes intentionally share one representative file-record case; repeating that
   same verifier path for each file kind would add no mutant.
4. **Behavior-preserving refactor stays green:** yes — tests call the public builder/verifier or the
   module CLI and assert accepted/rejected outcomes. Helper extraction, record iteration order, and
   error wording outside the named semantic field leave them green.
