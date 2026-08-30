# Scheduled-learning v1 harness (M3)

This directory hosts the experiment-only harness that replays the accepted `scheduled-learning/v1`
algorithm (Issue 170) through one page-change adapter, per the M3 spec
(`docs/superpowers/specs/2026-08-29-scheduled-learning-v1-evaluation-harness-design.md`) and its
frozen validation protocol (`docs/research/172-validation-protocol.md`). Its offline checks never call
a model, and it does not modify production Swift targets.

## Archival status

This checked-out revision is an **archival HEAD** containing post-run hardening. The preserved
`freeze/owner-budget-approval.json` and `results/` are historical evidence from the authorized run;
their bytes remain unchanged. That old freeze and approval do not verify or authorize the current
source tree, and `freeze verify` must not be presented as verification of this HEAD.

Do not run `scored` from this archival HEAD. Any future live run requires a fresh freeze over the
then-current source followed by new explicit owner authorization for that exact freeze. The
historical approval is not reusable.

This package is a fresh, scenario-neutral experiment root. It reuses the completed replay-core
contracts from `benchmark_learning.learning_contract` / `benchmark_learning.learning_replay` and the
frozen `page_benchmark` validation/scoring/sealing functions, but its own corpus, gold data, split,
prompts, schemas, and gates are independent of Protocol 0.6 and M0.

## Layout

- `scheduled_learning_v1/` is the experiment controller: replay journal, worker bridge, freeze
  manifest, execution lifecycle, and offline reporting verification.
- `page_change_m3/` is the fresh page-change adapter: materialization, scoring, and receipts.
- `tests/` mirrors that layout by subsystem and keeps the pre-commit redundancy pass required by
  `docs/TESTING.md` §9.1 in `tests/TEST_INTENT.md`.

## Deterministic commands

Run all checks from this directory:

```sh
scripts/lint.sh
scripts/test.sh
uv run python -B -m scheduled_learning_v1.conformance .
uv run python -B -m scheduled_learning_v1.run verify-results --root .
```

`scripts/lint.sh` runs Ruff (format + lint) and Mypy strict over `scheduled_learning_v1`,
`page_change_m3`, and `tests`, plus the sibling `benchmark-core/benchmark_core` and
`benchmark-core/benchmark_learning` source roots. `scripts/test.sh` runs the package's `unittest`
suite. Both are offline: no network access, no model credentials, no live provider call.

The dedicated `python-scheduled-learning-v1.yml` workflow runs only `scripts/lint.sh`,
`scripts/test.sh`, and the replay conformance command above. Its jobs have no environment or secret
inputs, and the workflow never invokes the scored command.

This package depends on `swift-claw-benchmark-core` and `page-benchmark` through local `uv` path
sources (`../benchmark-core`, `../page-change`); `uv.lock` pins the resolved dependency graph.

Verify the preserved committed results offline with:

```sh
uv run python -B -m scheduled_learning_v1.run verify-results --root .
```
