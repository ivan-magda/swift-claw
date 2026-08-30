# Issue #172: M3 scheduled-learning validation protocol

- Status: Proposed; owner approval required before scored calls
- Protocol version: 1.0
- Date: 2026-08-29
- Decision issue: [#172](https://github.com/ivan-magda/swift-claw/issues/172)
- Depends on: accepted M1 RFC (Issue 167), accepted `scheduled-learning/v1` algorithm (Issue 170)
- Spec: `docs/superpowers/specs/2026-08-29-scheduled-learning-v1-evaluation-harness-design.md`

## Purpose

M3 replays the accepted `scheduled-learning/v1` algorithm through one page-change adapter to answer
one question: does the generic reducer's own trigger, candidate, trial, promotion, and rollback
machinery — not the page-change task itself — behave correctly end to end against a real model
route, including across a fresh-process restart. M3 is a harness validation, not a second scenario
efficacy study.

No scored model call may run until the owner approves the frozen manifest digest and the exact
freeze commit it derives from.

## Independence from Protocol 0.6, M0, and recovery

M3 uses a fresh corpus, gold set, split, prompts, schemas, gates, and adapter identity. It does not
reuse, mutate, or generalize any Protocol 0.6 artifact:

- no fixture, gold record, or path is shared with Protocol 0.6's page-change corpus or its M0
  lesson set;
- M3 does not read, extend, or replay Protocol 0.6's recovery controller, invalid-batch ledger, or
  any of its scored outputs, candidate, or decision evidence;
- M3 reuses only frozen `page_benchmark` *functions* (`validate_source`, `score`,
  `seal_score_receipts`) as library calls, never their data or state.

M3's algorithm identity is `scheduled-learning/v1`; Protocol 0.6 has no algorithm identity because
it predates the generic reducer.

## Fixed fixture split

The frozen M3 page proposal is exactly seven fresh fixtures: 2 development, 3 regression, 2 sealed.

| Split | Fixture IDs | Purpose |
| --- | --- | --- |
| development | `pc-development-07`, `pc-development-08` | Two independent noise-heavy changes that can produce the same blind reusable-issue code and qualify the frozen trigger. |
| regression | `pc-regression-04`, `pc-regression-05`, `pc-regression-06` | Three mixed substantive-plus-noise comparisons used for paired clean controls and candidate trial assignments. |
| sealed | `pc-sealed-05`, `pc-sealed-06` | Unseen active and post-restart active checks, one per condition. |

Every fixture ID and its `.source.json`/`.gold.json` path is disjoint from Protocol 0.6 and M0 by
both path and digest. The split is fixed before the first scored call and is not revised after
inspecting any result.

## Fixed call, send, and token budgets

| Budget | Value |
| --- | --- |
| Task attempts | 10 |
| Evaluator calls | 5 |
| Reflector calls | 1 |
| Responses sends | 38 |
| Accounted tokens | 120,000 |

The ten task attempts are two development clean runs, three paired regression clean controls, three
candidate trial runs, one active run, and one post-restart active run. The five evaluator calls
cover only the two development runs and the three candidate trial runs; the paired regression clean
controls and the active/restart runs are never blindly evaluated by the generic evaluator. Task
attempts keep the frozen two-send worker ceiling (one `file_read` round trip, one final-answer round
trip). Evaluator and reflector calls keep the existing provider retry budget of three sends each. The
hard Responses-send ceiling is therefore `10 * 2 + (5 + 1) * 3 = 38`. Each budget is an aggregate
pre-dispatch guard: the runner checks remaining headroom before starting the next attempt or call,
never after.

## Adapter pass rule

The page adapter reports `pass` only when all of the following hold over one candidate's valid
clean/candidate pairs:

- 2 or 3 valid pairs are present (a missing/incomplete pair is `inconclusive`, not scored zero);
- every candidate score in the valid pairs is at least 90;
- no pair has a critical scorer result;
- no pair has a negative delta (`candidate_score - clean_score < 0`);
- the mean candidate-minus-clean delta across valid pairs is at least 10.

Any other named violation (score below 90, a negative delta, fewer than two valid pairs) is
`regression`; a critical scorer result is always reported `critical`, never folded into `regression`.
`pass` can satisfy the adapter gate but cannot itself supply either of the two positive generic
trial outcomes the reducer requires for promotion — the reducer still requires two positive
assignment-level outcomes independently of the adapter envelope.

## Active and restart gates

Only a promotion admits one active attempt. Active and post-restart active scores are excluded from
the adapter pass rule above; they are evaluated only by the final report, after promotion, against
one frozen threshold each:

- the active run's page score is at least 90;
- the post-restart active run's page score is at least 90, using the exact same promoted lesson-set
  digest reloaded by a fresh Python and Swift process.

A restart attempt that scores below 90, or that cannot bind the exact promoted digest it was handed
before the fresh process started, fails the M4-blocking gate even if the pre-restart active run
passed.

## Closed-carrier exclusions

Evaluator and reflector carriers are closed and tool-free; each excludes fields by construction, not
by convention, and is validated against a closed JSON Schema (`additionalProperties: false`).

The evaluator carrier excludes: lesson text and identity, trial condition, candidate identity, prior
score, promotion state, gold data, oracle data, and expected direction. It carries only task
identity, task input, the raw model output under evaluation, and run identity.

The reflector carrier carries only: the current complete stable lesson set, compatible blind
evaluations, qualifying issue codes, and bounded effective owner payloads. Every lesson, evidence
item, and owner-provided body inside it is separately fenced as untrusted data — the reflector
receives no gold, oracle, candidate, or promotion state either.

Both carriers reject unknown fields and require `schema_version: 1`. Schema-invalid model output
fails the corresponding operation with a terminal result; there is no schema-repair model call.

## Manifest-before-call rule

Before the first scored model call, the pre-run gate creates and validates the freeze manifest,
binding: the protocol and algorithm identity; evaluator and reflector prompts and schemas; the fresh
corpus, gold data, and split; adapter, dataset, oracle, gate, and execution-surface identities; model
routes, output caps, and provider retry budgets; the aggregate budgets above; run order; and the
deterministic conformance corpus. Every bound input is recorded as `{path, sha256, bytes}`.

The manifest itself never records a Git commit identity — recording one would make the manifest
self-referential, since committing it changes `HEAD`. The runner instead accepts the manifest digest
and the exact freeze commit separately (through the owner-approval object below), then re-verifies
every bound path against both before *every* model call and every score operation, not only at
startup. A manifest, conformance, digest, schema, or budget failure stops the run before the next
external call; it never repairs or retries around the mismatch.

## Owner budget checkpoint

A scored run additionally requires one owner-authorized approval object, created only after the
freeze commit exists, with exact keys `schema_version`, `manifest_sha256`, `expected_freeze_commit`,
`budgets`, `owner_identity`, and `approved_at` (an RFC 3339 UTC timestamp). Its `budgets` object has
exact keys `task_attempts`, `evaluator_calls`, `reflector_calls`, `responses_sends`, and
`accounted_tokens`, matching the values in the table above (10/5/1/38/120000).

The runner requires `approval["expected_freeze_commit"] == git rev-parse HEAD` at verification time.
Authorization is never inferred from issue approval, CI success, or a prior run: the owner
explicitly authorizes the exact frozen manifest digest, the resulting freeze commit, and the budget
before the run begins. A stopped scored run produces an incomplete failed report and does not resume
without a fresh owner authorization.

## Live execution is outside CI

The dedicated `python-scheduled-learning-v1.yml` workflow runs only the package lint script, unit
tests, and the replay conformance corpus. Its two jobs receive no environment or secret inputs, and
a static package test enforces its complete action/command allowlist. Those harness commands make no
model/provider call, and the workflow never invokes the scored command.

Before the live run, freeze verification checks the exact committed manifest bytes. The owner runs
the scored command from Task 9 of the implementation plan by hand after passing the budget
checkpoint. CI never runs that command.

## Post-run archival ruling

The checked-out post-run hardening revision is archival. The preserved owner approval and result
tree remain evidence for their original freeze commit only; they do not verify or authorize the
current source bytes. No re-freeze or replacement approval is part of this hardening wave. A future
live execution requires a fresh freeze of the then-current closure and new explicit owner
authorization for that exact manifest before any provider dispatch.
