# Issue 170: Minimal generic scheduled-task learning algorithm

| | |
|---|---|
| **Status** | Proposed M2 ADR, algorithm v1 |
| **Date** | 29 August 2026 |
| **Parent** | Issue 115 |
| **Scope issue** | Issue 170 |
| **Depends on** | Accepted M1 RFC in Issue 167 / PR 168 |
| **Algorithm ID** | `scheduled-learning/v1` |
| **Benchmark baseline** | Issue 118 Protocol 0.6 remains frozen |

`docs/ARCHITECTURE.md` remains the normative production specification. The accepted M1 RFC remains
authoritative for run identity, trust, persistence, evaluator blindness, feedback binding, trial
isolation, compare-and-swap decisions and restart behavior. This ADR selects only the smallest
versioned learning policy needed by M3 and M4. It changes no production behavior.

## 1. Decision

Swift Claw will use one fixed generic policy, `scheduled-learning/v1`, for every learning-enabled
scheduled job:

```text
last five compatible stable-run evaluations from the last 30 days
  -> two distinct negative runs with the same exact issue code
     OR one explicit owner correction
  -> one tool-free reflection call
  -> zero or one complete replacement lesson set
  -> at most three trial assignments
  -> promote after two distinct positive settled trial runs
     with no negative run or hard veto
  -> otherwise fall back to the untouched stable set
  -> roll back a promoted set only for an exact hard post-promotion trigger
```

The model evaluates one run and may propose one replacement lesson set. Deterministic code selects
the evidence window, resolves owner signals, decides whether reflection is permitted, validates and
admits the candidate, assigns trial exposure and performs promotion, fallback or rollback.

Version 1 deliberately has:

- one global policy rather than per-job tuning;
- exact compatibility rather than semantic matching;
- one candidate rather than a candidate pool;
- sequential bounded exposure rather than an online bandit or concurrent A/B test;
- whole-set replacement rather than lesson patches or append-only growth;
- categorical precedence rather than model confidence or calibrated probability.

## 2. Versioned parameters

Every value and formula below is bound by `scheduled-learning/v1`. Candidates, trials and decision
receipts carry this identifier. Changing any value, compatibility field, signal rule or decision
formula requires a new algorithm ID. Existing candidates and trials finish under the version they
were created with; they are never silently reinterpreted by a newer policy.

Evaluator prompt, evaluator schema, rubric, reflector prompt, evidence schema and adapter versions
remain separate identifiers. They are included in compatibility and provenance but do not create
per-job policy variants.

| Area | Parameter | `scheduled-learning/v1` |
|---|---|---:|
| Evidence | maximum compatible stable evaluations | 5 |
| Evidence | maximum evidence age at reflection cutoff | 30 days |
| Evidence | automatic reflection support | 2 distinct negative runs with the same exact issue code |
| Candidate | maximum lesson count | 3 |
| Candidate | maximum UTF-8 bytes per lesson | 512 |
| Candidate | maximum UTF-8 bytes for all lesson texts | 1536 |
| Candidate | reflector calls per frozen trigger | 1 |
| Candidate | candidates returned per trigger | 0 or 1 |
| Trial | maximum created-run assignments | 3 |
| Trial | positive runs required for promotion | 2 distinct runs |
| Trial | tolerated negative runs | 0 |
| Trial | assignment deadline | 30 days after admission |
| Trial | decision deadline | 7 days after the assignment deadline |
| Operations | evaluator maximum output | 512 tokens |
| Operations | reflector maximum output | 768 tokens |
| Retention | unreferenced evidence and feedback payload | 30 days |
| Retention | compact decision and provenance receipts | 90 days |

The existing global and proactive USD/token breakers remain authoritative. A breaker denial closes
the exact operation as `failed_no_call(budget_denied)` and never delays task-result persistence or
owner delivery. Version 1 does not requeue that logical operation after a budget denial.

Version 1 exposes no owner-facing or per-job overrides for these values.

## 3. Compatible evidence window

Reflection uses only evaluations of runs that used the current stable lesson set. Trial runs never
enter a new candidate's stable evidence window, and no reflection starts while a trial is open.

Trusted code derives one `compatibility_digest` from exact equality of:

- job ID and learning epoch;
- job-definition digest;
- current stable lesson-set digest;
- evidence schema and eligibility-classifier versions;
- evaluator prompt, output-schema and rubric versions;
- context schema, tool-catalog, policy and skill-set versions;
- configured primary route and actual terminal provider/model route;
- evaluator provider/model route;
- optional adapter ID/version and task-input schema version, or the canonical `none` value.

The compatibility projection excludes run IDs, timestamps, task input, final output, model-visible
carrier bytes and evidence digests. Those values belong to provenance, not compatibility.

Version 1 has no compatibility matrix. A mismatch creates another window. It does not downgrade,
merge or ask a model whether two executions were "close enough."

At one immutable reflection cutoff, the window contains the newest five completed compatible
evaluations whose logical occurrences are no more than 30 days old. Ordering is by logical
occurrence and then `run_id`, not by delayed evaluator completion time. Every selected evaluation and
owner-feedback edge is frozen by digest and feedback revision in the trigger and candidate source
manifest.

A stable lesson change, job-definition change, route change or relevant version change naturally
starts a new window.

## 4. Effective owner and evaluator signals

For each run, trusted code resolves exactly one effective outcome:

```text
positive | negative(issue_codes) | neutral
```

These categories are decision inputs. They are not confidence scores, probabilities or evidence
strength claims.

### 4.1 Base evaluator outcome

| Evaluator result | Effective outcome | Meaning |
|---|---|---|
| `no_issue` | `positive` | heuristic support for the output |
| `reusable_issue` | `negative(issue_codes)` | heuristic evidence of a reusable problem with bounded exact issue codes |
| `transient_issue` | `neutral` | not behavioral evidence |
| `uncertain` | `neutral` | not positive or negative evidence |

### 4.2 Owner precedence

For one exact run/evaluation subject, trusted code computes one effective outcome in this order:

1. An effective hard veto is recorded separately and stops dependent admission or promotion.
2. The latest unsuperseded owner result signal wins. `result useful` is `positive`; `result not
   useful` is `negative`; `result correction` is `negative` and carries its bounded correction
   payload as a direct one-run reflection trigger.
3. Otherwise, `evaluation confirm` keeps the evaluator outcome and records the separate
   `owner_confirmed` evidence-strength claim.
4. Otherwise, trusted code uses the evaluator outcome.

An `evaluation dispute` removes that evaluator outcome from dependent decisions and is a hard veto for
any candidate, trial or promotion whose source manifest requires it. A separate effective owner
outcome signal may still describe the run, but the disputed evaluation itself remains unusable.

Candidate-level controls do not become quality outcomes:

- `candidate approve` creates one immutable successor candidate record with the same replacement
  lesson-set digest, a predecessor edge, the exact approval event and the newly frozen feedback
  revision. The predecessor becomes superseded for admission;
- `candidate reject` hard-vetoes the exact candidate or trial;
- `candidate edit` hard-vetoes the old candidate and creates a new immutable candidate with a new
  digest that must pass every gate again.

At most one effective outcome exists per run. Multiple feedback events do not multiply support; the
append-only log and supersession links determine the one effective owner signal at the frozen cutoff.

A negative evaluator run uses its exact evaluator issue codes. An owner correction is its own direct
trigger. An owner `not useful` signal without an evaluator issue code uses the fixed synthetic code
`owner_not_useful`; version 1 performs no semantic clustering of free text.

### 4.3 Hard vetoes

The following outrank every positive outcome:

- authenticated evaluation dispute or candidate rejection bound to an exact dependency;
- exact frozen-adapter `critical` or `regression` receipt for the candidate and execution surface;
- security-policy, secret-leakage, corruption or invariant-violation receipt;
- job cancellation, purge barrier, stale learning epoch or stale base/candidate compare-and-swap.

A deterministic `pass` receipt is strong scoped evidence, but it does not reduce the requirement for
two distinct positive trial runs.

## 5. Reflection trigger

### 5.1 Automatic trigger

Automatic reflection is permitted when the compatible stable window contains at least two distinct
runs with:

- a negative effective outcome; and
- the same exact issue code.

One run counts at most once for one issue code. Positive and neutral runs do not erase a recurring
issue on other inputs. If several issue codes independently reach the threshold at the same cutoff,
one reflection call receives all qualifying codes and the same bounded evidence window.

### 5.2 Owner-directed trigger

One explicit owner correction may trigger reflection after one eligible run. It does not need a
second matching occurrence because it is an authenticated statement of desired behavior, not an
attempt to infer recurrence from one model evaluation.

An owner candidate edit bypasses reflection and directly creates a new immutable replacement
candidate. Candidate approval may admit only the immutable successor record described in section
4.2 after one eligible source run. It cannot create a candidate from nothing and never bypasses
validation or trial outcomes. The successor remains eligible only while its predecessor, base and
learning epoch still match, the predecessor remains unadmitted and the newly frozen feedback
revision remains current. It does not regenerate lesson bytes or count as a second trial.

A plain `not useful` signal remains one negative run. Without a correction payload it needs another
matching negative run for automatic reflection.

### 5.3 Idempotency and retry boundary

The trigger identity covers:

```text
job + learning epoch + algorithm ID + stable digest
+ ordered evidence digests + effective feedback revision
+ ordered qualifying issue codes
```

Exactly one logical reflector operation may run for that trigger. It returns one complete candidate
or `no_candidate`. Invalid, duplicate, no-op, failed or interrupted reflection does not start a
self-critique or repair loop. Another automatic attempt requires a changed trigger identity from new
evidence, new effective owner feedback, a new stable base or a new algorithm version.

Existing M1 provider retry and `interrupted_unknown` rules still apply to the one logical operation.

Reflection is not permitted while a trial is open, while the job is cancelled or one-shot, while a
hard veto is unresolved, or while the learning budget is unavailable.

## 6. Candidate consolidation and admission

The reflector receives the current complete stable lesson set, the frozen compatible evidence
window, qualifying issue codes and bounded effective owner payloads through the M1 closed carrier. It
returns either `no_candidate` or one complete ordered replacement set.

The replacement set contains zero to three lesson strings. Zero is valid when the evidence says the
current lessons should be removed. Candidate bytes are canonicalized with Unicode normalization,
line-ending normalization and surrounding-whitespace removal before digesting. Admission rejects:

- an empty individual lesson;
- duplicate normalized lesson text;
- more than three lessons;
- a lesson over 512 UTF-8 bytes;
- total lesson text over 1536 UTF-8 bytes;
- a replacement digest identical to the current stable digest;
- a replacement lesson-set digest already closed against the same base and algorithm version, unless
  this record is the single approval successor of that exact current unadmitted predecessor;
- any M1 schema, Unicode, secret-leakage, job, epoch, base or source-binding violation.

The reflector is instructed to preserve still-useful incumbent rules, merge overlapping rules and
remove contradicted or obsolete rules, but code does not pretend to verify semantic quality. Safety
comes from the bounded data-only schema and existing runtime policy, not from lexical approval of the
prose.

Version 1 has no patches, per-lesson confidence, ranking, embeddings, semantic deduplication,
iterative refinement or candidate tournament. The immutable source manifest remains candidate-level;
per-lesson provenance is deferred until a concrete consumer needs it.

Admission additionally requires:

- a repeatable, non-cancelled job;
- the exact current stable base and learning epoch;
- no open trial;
- no effective hard veto;
- available learning budget;
- automatic trigger support, or an effective owner correction/edit/approval path.

Passing admission opens an experiment; it does not activate the candidate.

## 7. Bounded trial

One trial may be open per job. The stable pointer remains unchanged.

The next created scheduled or owner-requested run-now executions may receive the candidate until one
of these assignment boundaries closes the trial cohort:

- three run assignments have been consumed;
- 30 days have passed since admission;
- a hard veto or negative trial outcome closes the trial;
- two positive settled trial runs exist and no already-assigned run remains unsettled.

The M1 fire transaction remains authoritative: an assignment is consumed only when a run is created,
and a created run consumes exposure even if it later fails technically.

Each exact trial run resolves to:

- **positive:** eligible, settled, evaluated, effective outcome `positive`;
- **negative:** eligible, settled, evaluated, effective outcome `negative`;
- **neutral:** technical/infrastructure failure, ineligible evidence, missing evaluation,
  `transient_issue`, `uncertain` or effective outcome `neutral`.

A neutral run consumes exposure but supplies no promotion support. One negative run closes the trial
immediately to fallback. Hard vetoes close it immediately. Two positive distinct runs close further
assignment early, but promotion still waits for every already-assigned run to settle.

At admission, the trial pins two immutable absolute timestamps:

```text
assignmentDeadline = admittedAt + 30 days
decisionDeadline = admittedAt + 37 days
```

These deadlines are maximum bounds, not minimum waiting periods. Early assignment closure changes
neither timestamp. Code decides immediately once assignment is closed and every assigned run has
settled. If any assigned run remains unsettled at the decision deadline, the cohort is incomplete and
falls back. Version 1 never promotes while an assigned run could later contradict the decision.

All reflection, fallback, promotion and rollback decisions are event-driven and occur as soon as
their count-based conditions are satisfied. Time windows are maximum freshness and expiry bounds;
they never impose a minimum waiting period.

There is no concurrent stable control arm in production v1. The frozen pre-trial stable evidence
window is the heuristic baseline. Controlled clean-vs-candidate comparison belongs to the M3 harness,
not to ordinary scheduled delivery.

## 8. Promotion and fallback

### 8.1 Promotion

A candidate promotes only when all of the following are true in the M1 decision transaction:

- assignment is closed and every assigned run is settled;
- at least two distinct trial runs are positive;
- no trial run is negative;
- no deterministic adapter was frozen, or the exact frozen adapter has a `pass` receipt for the
  candidate lesson-set digest and execution surface;
- no owner, deterministic, security or consistency veto is effective;
- job, epoch, algorithm, candidate, replacement, base and feedback revisions still match;
- the stable pointer and revision still identify the recorded base;
- all source, compatibility, budget and versioned gate receipts remain valid.

The transaction writes the immutable decision receipt, compare-and-swaps the stable pointer and
closes the exact trial. Candidate approval by itself is never promotion evidence.

The promotion receipt binds the complete settled cohort and every positive trial run in it. Rollback
recomputes remaining support from that fixed set; it never selects a different subset later.

Promotion based only on evaluator outcomes remains a heuristic activation. Owner signals and a
deterministic adapter may strengthen the separately recorded evidence claim, but activation state
and evidence strength remain different axes.

### 8.2 Fallback

Fallback closes the exact trial and leaves the stable pointer untouched. It occurs on:

- any negative trial outcome;
- any hard veto;
- fewer than two positive runs after assignment is closed and every assigned run has settled;
- a frozen deterministic adapter has no exact `pass` receipt when the trial closes;
- an incomplete cohort at the decision deadline;
- job cancellation;
- stale epoch/base/feedback/version predicates;
- decision-time corruption or compare-and-swap loss.

Purge closes the trial through the M1 epoch barrier and resets derived state. It is not fallback and
does not preserve the stable pointer.

A closed replacement lesson-set digest is not automatically retried against the same base under the
same algorithm version. The single approval successor is not a retry because its exact predecessor
was never admitted to a trial and is atomically superseded by the same approval transaction.
Otherwise, new evidence must produce different lesson bytes, an owner edit must change the
replacement digest, or a newer algorithm version must make a new decision. This prevents trial loops
hidden behind a new candidate-record manifest.

## 9. Rollback

Rollback restores only the direct retained base of the currently active promotion. It is a separate
exact compare-and-swap transaction and is eligible only when the current stable digest and revision
still identify that promotion.

Version 1 rollback triggers are deliberately narrow:

- authenticated owner rejection or explicit rollback of the exact active candidate;
- owner `not useful`, correction or evaluation dispute that invalidates one of the exact positive
  trial runs used by the promotion and leaves fewer than two valid positive support runs;
- `critical` or `regression` receipt from the adapter frozen by the exact active promotion and bound
  to its candidate and execution surface;
- security, secret-leakage, corruption or invariant-violation receipt bound to that promotion.

An ordinary later heuristic `reusable_issue` on a new active run does not immediately roll back the
stable pointer. It enters the normal new stable evidence window and may produce a replacement
candidate. This avoids oscillation from one uncalibrated evaluator result.

The direct predecessor base, promotion receipt and exact support dependencies remain retained while
that promotion is the current stable revision. A stale trigger or stable-pointer compare-and-swap
miss records a stale rollback decision and changes nothing. A rolled-back replacement lesson-set
digest cannot be re-admitted against the same base under `scheduled-learning/v1`.

## 10. Route, budget and retention policy

Evaluation and reflection use the existing configured provider route used by scheduled jobs. Version
1 adds no separate learning router, model committee or self-review model. Existing retry and fallback
behavior may select an actual terminal route; that exact route is recorded, and evidence from another
route falls into another compatibility window.

Each eligible run permits at most one logical evaluator operation. Each frozen trigger permits at
most one logical reflector operation. Both use the existing global and proactive breakers. Each
logical operation makes one structured model call with the output caps in the parameter table. No
second model call repairs malformed semantic content; a schema-invalid result fails the operation.
Existing provider-level retry rules remain unchanged.

Full unreferenced evidence, evaluation excerpts and feedback payloads may be removed after 30 days.
Compact digests, versions, decision receipts and provenance edges remain for 90 days. Anything
referenced by an open trial, current stable promotion, rollback base, live candidate or purge barrier
is retained regardless of those windows. Explicit owner purge and the M1 epoch barrier remain
stronger than ordinary retention.

## 11. Deterministic adapters and page-change benchmark

The generic algorithm understands only a versioned deterministic receipt bound to exact subject and
execution-surface digests. It does not know how an adapter computes the receipt. At admission, a
trial freezes either no deterministic adapter or one exact adapter ID and version. When an adapter is
frozen, the gate also pins the existing M1 dataset, oracle, gate and execution-surface versions that
its receipt must match.

- When no adapter is frozen, promotion requires no deterministic receipt.
- When an adapter is frozen, promotion also requires an exact `pass` receipt for the candidate
  lesson-set digest and execution surface.
- An exact frozen-adapter `critical` or `regression` receipt is an immediate hard veto.
- A missing or inconclusive receipt prevents promotion and causes fallback when the trial closes.
- An exact frozen-adapter `pass` may upgrade the scoped evidence claim, but it never bypasses two
  positive trial runs, owner/security vetoes or compare-and-swap predicates.

Page-change monitoring is the first M3 adapter and benchmark only. Its corpus, split, scorer, oracle,
critical-failure definitions and numeric regression gates must be frozen in a fresh M3 validation
artifact before outputs are observed. None of those page-specific concepts or thresholds enter
`scheduled-learning/v1`.

The M0 synthesized lesson artifact was derived from gold-informed feedback and is permanently
ineligible as an M3 stable set, reflection input, candidate seed, candidate, example or trial
artifact.

M3 candidate synthesis may use only M1-compliant blind evaluations and authenticated owner signals.
Deterministic oracle data may be used only after candidate freeze to produce a scoped verification
receipt.

Issue 118 Protocol 0.6 and its M0 evidence remain historical scenario-selection artifacts. They are
not rewritten and cannot provide a new production verification receipt.

## 12. Deterministic flow

```text
on compatible stable evaluation or owner feedback:
  if open trial: record signal only; do not reflect
  freeze latest 5 compatible stable evaluations within 30 days
  resolve one effective outcome per run

  if owner correction:
    trigger = direct-owner trigger
  else:
    trigger = any exact issue code in negative outcomes from >= 2 distinct runs

  if no trigger or trigger already attempted: stop
  run one reflection operation
  validate one complete replacement candidate
  if invalid, no-op, duplicate or vetoed: close trigger without retry
  freeze the optional deterministic adapter and its exact gate identity
  admit one trial only if exact job/base/epoch/budget predicates still match

on settled trial run:
  resolve effective outcome
  if hard veto or outcome is negative: fallback immediately
  if two positive runs and no assigned run is unsettled: close assignment
  else continue until three assignments or assignment deadline

on closed assignment:
  wait for all assigned runs until decision deadline
  if >= 2 positive and 0 negative and the frozen adapter requirement is satisfied
     and every exact predicate holds: promote by CAS
  else: fallback, stable remains unchanged

on exact post-promotion hard trigger:
  if current stable still equals that promotion and trigger remains valid:
    rollback by CAS to the retained direct base
  else:
    record stale rollback; change nothing
```

## 13. Rejected alternatives

- **Reflect after every run.** Too noisy and expensive; it converts transient mistakes into lessons.
- **Append every new lesson.** Unbounded memory accumulates contradictions and stale rules.
- **Semantic issue clustering or embeddings.** No concrete v1 need justifies another model/index and
  a hidden compatibility policy.
- **Per-job thresholds.** They create an unvalidated configuration matrix before one generic policy
  has evidence.
- **Several candidates, online bandits or concurrent A/B tests.** More exposure, attribution and
  state complexity than the sprint needs.
- **Model-reported confidence or numeric self-score.** Not calibrated and not an authorization or
  promotion signal.
- **Automatic rollback on one later heuristic failure.** It would allow an uncalibrated evaluator to
  oscillate the stable pointer.
- **Page-specific promotion formulas.** They would make the first benchmark the production boundary.

## 14. Consequences and limits

The policy is intentionally conservative and small enough to implement and test end to end. Two
repeated failures can create a candidate, at most three future runs are exposed, two clean outcomes
are required and one negative outcome stops the experiment.

The thresholds are engineering defaults, not statistical significance claims. Exact compatibility
may split evidence aggressively, and low-frequency jobs may need owner correction or run-now
executions to finish a trial inside the fixed deadlines. Those are accepted v1 trade-offs. M3 may
show that a value is impractical, but changing it requires `scheduled-learning/v2` and fresh frozen
validation rather than editing v1 after seeing held-out results.

No P0 generic algorithm choice remains for M3. M3 still owns the fresh generic harness and the first
page-change adapter's benchmark-specific data and gates. Production Swift, migrations and tests
remain M4 work.
