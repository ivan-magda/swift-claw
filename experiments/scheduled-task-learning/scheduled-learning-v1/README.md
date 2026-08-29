# Scheduled-learning v1 harness (M3)

This directory hosts the experiment-only harness that replays the accepted `scheduled-learning/v1`
algorithm (Issue 170) through one page-change adapter, per the M3 spec
(`docs/superpowers/specs/2026-08-29-scheduled-learning-v1-evaluation-harness-design.md`) and its
frozen validation protocol (`docs/research/172-validation-protocol.md`). It does not call a model or
modify production Swift targets.

This package is a fresh, scenario-neutral experiment root. It reuses the completed replay-core
contracts from `benchmark_learning.learning_contract` / `benchmark_learning.learning_replay` and the
frozen `page_benchmark` validation/scoring/sealing functions, but its own corpus, gold data, split,
prompts, schemas, and gates are independent of Protocol 0.6 and M0.

## Layout

- `scheduled_learning_v1/` is the experiment controller: replay journal, worker bridge, freeze
  manifest, execution lifecycle, and reporting. Currently exposes only `ALGORITHM_ID`; later tasks
  add the replay controller, freeze verification, and orchestration.
- `page_change_m3/` is the fresh page-change adapter: materialization, scoring, and receipts.
  Reserved as an empty source root here; Task 3 adds its public carrier builders.
- `tests/` mirrors that layout by subsystem and keeps the pre-commit redundancy pass required by
  `docs/TESTING.md` §9.1 in `tests/TEST_INTENT.md`.

## Deterministic commands

Run all checks from this directory:

```sh
scripts/lint.sh
scripts/test.sh
```

`scripts/lint.sh` runs Ruff (format + lint) and Mypy strict over `scheduled_learning_v1`,
`page_change_m3`, and `tests`, plus the sibling `benchmark-core/benchmark_core` and
`benchmark-core/benchmark_learning` source roots. `scripts/test.sh` runs the package's `unittest`
suite. Both are offline: no network access, no model credentials, no live provider call.

This package depends on `swift-claw-benchmark-core` and `page-benchmark` through local `uv` path
sources (`../benchmark-core`, `../page-change`); `uv.lock` pins the resolved dependency graph.

Later tasks add `uv run python -B -m scheduled_learning_v1.conformance .` (the frozen replay
conformance corpus), freeze/preflight verification, and the scored-run CLI. See
`docs/superpowers/plans/2026-08-29-scheduled-learning-v1-page-harness.md` for the full task
sequence.
