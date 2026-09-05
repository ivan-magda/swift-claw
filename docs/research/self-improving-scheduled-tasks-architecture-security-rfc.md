# Issue 167: Generic scheduled-task learning architecture

| | |
|---|---|
| **Status** | Accepted M1 RFC/ADR, compact v3.1 |
| **Date** | 29 August 2026 |
| **Parent** | Issue 115 |
| **Scope issue** | Issue 167 |
| **Baseline** | Issue 118 frozen Protocol 0.6 |

`docs/ARCHITECTURE.md` remains the normative technical specification. A production increment must
amend it before changing the scheduler, run, context, policy or persistence contracts defined there.

This RFC fixes only the boundaries required for the current capability and realistic next
increments. Exact algorithms, thresholds and physical storage shape are deferred until their
implementation milestone.

## 1. Decision and guarantees

Swift Claw will add one durable, job-scoped learning control plane for scheduled tasks. A scheduled
job keeps its ordinary prompt, runtime, tools, policy, approvals, budgets and delivery path. The
learning control plane records task evidence, evaluates quality, accepts owner feedback, proposes a
bounded lesson set and tests it through a finite trial before promotion.

Existing `run_id` remains the only task-attempt identity. The successful fire transaction binds the
run to the exact logical occurrence, fire kind, job-definition digest, learning epoch, stable lesson
base and effective lesson-set digest. Execution continues through the ordinary proactive
`TurnRunner` / `AgentRuntime` path. Context assembly and provider execution record the actual ordered
execution-surface segments; the sealer derives their aggregate digest after settlement.

```text
scheduled fire
  -> pin the effective job-scoped lesson set to run_id
  -> execute the ordinary proactive agent run
  -> commit terminal state and terminal receipt
  -> record that no more primary-run facts can arrive
  -> seal bounded evidence or a technical exclusion
  -> classify learning eligibility in code
  -> run a blind, tool-free evaluator when eligible
  -> combine saved evaluation with durable owner feedback
  -> run separate tool-free reflection when policy permits
  -> validate one immutable replacement candidate
  -> assign a finite trial override
  -> promote with compare-and-swap or fall back to stable lessons
```

**Capability guarantee.** Every executable scheduled task can use the same capture, evaluation,
feedback and lesson lifecycle. A repeatable job can trial and reuse lessons across restarts. A
one-shot job can retain evidence, evaluation and feedback, but cannot exercise a trial until another
occurrence exists.

**Evidence guarantee.** Natural runs and LLM evaluation provide heuristic evidence. Authenticated
owner feedback establishes owner intent for an exact subject. Only a deterministic adapter over a
named, versioned dataset and oracle may issue scoped `deterministically_verified` evidence. The
system does not claim objective improvement for arbitrary subjective tasks.

## 2. Goals and non-goals

M1 defines the smallest architecture that can:

- preserve `run_id` as the sole attempt identity;
- isolate durable lessons by scheduled job;
- separate task quality from `RunState`;
- apply lessons only through a bounded, attributable trial;
- make owner feedback durable and exact-subject-bound;
- survive restart without claiming exactly-once LLM inference;
- keep lessons outside scheduling, policy and authority control planes;
- account learning calls against global and proactive budgets;
- support page-change as an optional deterministic adapter, not a product boundary;
- export, retain and purge derived learning data with its provenance.

M1 does not define or implement:

- global or cross-job lessons;
- a second task runtime or a page-specific production coordinator;
- exact support thresholds, evidence windows, trial sizes or acceptance formulas;
- automatic changes to prompts, schedules, tools, model routes, recipients or budgets;
- a generic memory/evaluation platform;
- a live page importer or benchmark corpus;
- Swift production code, migrations or tests;
- changes to the frozen Protocol 0.6 artifact.

## 3. Core invariants and trust boundary

- `run_id` is canonical. The learning subsystem adds a one-to-one binding, not another attempt row.
- The generic domain contains no page, HTML, selector, region or snapshot types.
- Scheduled execution remains an ordinary proactive agent run.
- Each job has one stable lesson-set pointer and at most one nonterminal trial override. Trials never
  stack, and the stable pointer remains unchanged until promotion.
- A lesson set is immutable, bounded and replaced as a whole. An edit creates a new digest.
- Lessons are advisory **untrusted data**, never authority. They cannot modify the job prompt,
  schedule, budgets, model route, tool catalog, risk tier, approvals, recipients, paths, commands,
  destinations or policy.
- Lesson bytes are rendered inside a trusted harness wrapper and never enter global/workspace
  memory, conversation history or FTS.
- Non-empty lessons add initial taint before sensitive-memory selection, the first provider call and
  the first tool-policy decision. They never replace persisted session taint or untrusted tool-metadata
  taint.
- Evaluation and reflection use fresh contexts with no tools, workspace memory, session history,
  approvals or provider replay state.
- The evaluator is blind to lesson text and IDs, stable/candidate digests, trial assignment, prior
  scores, promotion state and expected improvement.
- Deterministic adapter gold data, oracle results, holdouts and regression gates never enter a
  model-visible evaluator, reflector or candidate-synthesis carrier. Trusted code may attach only a
  scoped deterministic receipt after candidate freeze.
- Deterministic eligibility runs before any learning LLM spend.
- Feedback is evidence and control input, never direct activation or authority expansion.
- Promotion requires positive eligible evidence. Silence, evaluator failure and ineligible runs are
  not positive evidence.
- Database effects are idempotent. External provider inference is not exactly-once.
- Candidate text checks are defense in depth. Existing runtime policy, canonicalization, approval,
  egress and budget gates remain the security boundary.

## 4. Existing seams and ownership

The design extends current seams instead of introducing a second runtime.

**Scheduler/fire.** Extend the existing fused fire transaction after its occurrence and overlap
checks. The transaction selects stable or trial lessons, creates `run_id`, writes the learning
binding and consumes a trial assignment only when a run is created. Misfires, overlap
skips and compare-and-swap losers consume none.

**Run persistence.** `RunStore` already owns completion, degradation, cancellation, supersession,
approval suspension/resume and boot reconciliation. Every legal terminal transition for a bound run
must write one terminal receipt from a typed terminal-cause carrier in the same transaction as the
winning state. An approval resolution stores its typed cause as a primary immutable fact in the same
compare-and-swap that resolves the approval; the later terminal receipt references that fact.

**Context and runtime.** `TurnRunner` loads the lesson set pinned to `run_id` and passes it to
`ContextBuilder` before memory selection. The store verifies
`binding.job_id == run.job_id == lesson_set.job_id` and the canonical digest. The complete set becomes
one required, untrusted-labeled, non-truncatable context component before residual-budget fitting. If
it cannot fit, the run fails before provider dispatch; a bound run never substitutes current, empty or
partially truncated lessons.

Lesson taint augments the existing inputs. Memory fetch and rank use
`snapshot.isTainted || hasPinnedLessons`. Initial provider and tool dispatch use
`untrustedToolMetadata || hasPinnedLessons`, while persisted session taint remains an independent
input. These values apply before memory selection and before the first policy decision.

**Policy.** Existing tool policy, canonical-argument, approval, SSRF, exfiltration and proactive
budget checks remain authoritative. Lessons are never parsed as configuration or policy operands.

**Usage.** Evaluation and reflection are durable learning operations, not fake agent runs. Their
usage counts toward global and proactive learning totals without contaminating primary-run totals.

**Owner feedback.** M1 uses a separate `fb:` callback domain following the existing fail-closed
pattern: transport deduplication, numeric owner allowlist, private-DM binding, random one-time nonce,
exact subject digest, compare-and-swap consumption and redacted audit. It does not reuse tool-approval
rows, approval suspension or `AWAITING_APPROVAL`.

```text
SchedulerService
  -> fire transaction: bind run and effective lessons
  -> ordinary TurnRunner / AgentRuntime / tools / policy / outbox
  -> terminal and settlement records

ScheduledLearningService (asynchronous; never blocks owner delivery)
  -> evidence sealing -> eligibility -> evaluation -> reflection
  -> candidate admission -> trial -> promotion | fallback | rollback

Optional LearningEvaluatorAdapter
  -> page-change frozen scorer and fixtures first
```

## 5. Minimal logical model

The following are logical records, not a requirement for one Swift type or SQLite table per item.
The first implementation should expose one cohesive scheduled-learning store and split it only when
concrete callers need separate responsibilities.

- **Job learning state:** job ID, learning epoch, stable lesson-set digest and revision, and nullable
  open trial identity. The stable pointer is the only production activation pointer.
- **Lesson set:** immutable canonical bounded bytes, job ID, schema version, digest, creation source
  and time. The canonical empty set is valid.
- **Run learning binding:** one per created scheduled `run_id`; exact occurrence, fire kind,
  job-definition digest, learning epoch, stable and effective lesson-set digests, and optional trial
  identity/generation.
- **Terminal receipt:** one per terminal run; winning state, typed cause and terminal time.
- **Settlement receipt or marker:** durable proof that no further primary-run facts may arrive for
  the run. It may share storage with another record, but it is a distinct correctness boundary.
- **Execution-segment receipt:** immutable ordered record of the pinned lesson digest, context,
  policy, tool and skill versions, configured route, outbound model, terminal model and model-visible
  carrier digest for one context/provider segment.
- **Learning evidence:** one sealed, bounded projection or typed technical exclusion. It contains the
  run binding, terminal/settlement facts, complete bounded canonical final output, source message ID
  and digest, bounded ordered tool facts, ordered execution-segment receipts, usage references,
  relevant versions, a derived aggregate execution-surface digest and optional adapter facts. It
  excludes raw tool arguments, secrets, private raw observations, replay state and audit projections.
- **Eligibility receipt:** immutable classification keyed by sealed evidence or exclusion digest and
  classifier version.
- **Learning operation:** durable evaluator or reflector operation with source digest, learning
  epoch, model-visible carrier digest, route, schema/prompt versions, unique provider-call identity,
  attempt generation, optional superseded-operation link, usage references and state
  `pending | claimed | started | succeeded | failed_no_call | failed | interrupted_unknown`.
- **Evaluation:** exact evidence binding, frozen rubric and adapter versions, structured result and
  bounded findings.
- **Feedback target, input challenge and event:** authenticated owner, random nonce, exact run/output,
  evaluation or candidate digest, job, learning epoch, allowed action and expiry; append-only typed
  events with actor, transport identity, event time and optional supersession link.
- **Candidate:** immutable record digest distinct from its complete replacement lesson-set digest,
  bound to job, learning epoch, exact base digest/revision, frozen source and feedback revision,
  closed origin and an exact source manifest covering evidence, evaluations, feedback, base set and
  predecessor candidate.
- **Trial lease:** exact base and candidate digests, generation, assignment deadline, decision
  deadline, maximum and consumed assignments, frozen cohort cutoff, state and close reason.
- **Decision receipt:** immutable admission, promotion, fallback, rejection or rollback inputs and
  result.
- **Deterministic adapter receipt:** adapter, dataset, oracle and execution-surface versions plus the
  exact subject digests covered by the result.

Activation and evidence strength remain separate:

```text
activation: candidate | trial | active | rolled_back | superseded
evidence:   heuristic | owner_supported | owner_confirmed | deterministically_verified
```

An active lesson may remain heuristic. LLM evaluation can never produce deterministic verification.

## 6. Run capture, settlement and evidence

### 6.1 Fire binding

The existing fire transaction performs this order atomically:

1. resolve the current learning epoch and trial assignment eligibility;
2. pass the existing occurrence, misfire and overlap guards;
3. create the trigger and `run_id`;
4. pin job-definition, stable and effective lesson-set digests;
5. consume one trial assignment when the trial was selected.

A created run consumes its assignment even if it later fails technically. Scheduled and run-now
fires use the same selection rule; run-now consumes an assignment when it creates a run. A run
already bound to a lesson set keeps that exact digest through restart and approval resume. Retention
cannot collect lesson bytes referenced by a live bound run.

An upgrade may find pending, running or approval-suspended scheduled runs created before learning
bindings exist. They continue through the ordinary lifecycle as `legacy_unbound`, load no lessons and
produce only a technical learning exclusion. Code does not invent occurrence, job-definition or
lesson provenance, and a missing binding cannot roll back a legal terminal transition.

When the trial assignment deadline or assignment limit is reached, new fires use stable lessons and
the trial enters **draining**. Already assigned trial runs may finish until the decision deadline.
This separates bounded exposure from the time needed to evaluate assigned work.

Pausing a job stops ticker-created occurrences only. It does not extend trial deadlines or revoke
assignments already bound to runs. A run-now fire uses the same assignment and expiry rules as a
scheduled fire.

### 6.2 Terminal and settlement boundaries

Every legal `DONE`, `FAILED`, `CANCELLED` or `SUPERSEDED` transition writes a terminal receipt in the
same transaction. `RunState` alone is insufficient because it does not distinguish task failure from
provider, storage, budget, policy, approval or owner-interruption causes. An ordinary `DONE` commit
may also write settlement when all primary facts are final. It never seals learning evidence: the
task result and outbox transaction cannot depend on learning-specific consistency work.

Every terminal commit carrier supplies the typed cause. A split approval path first persists its
resolution cause with the approval compare-and-swap. If a legacy or damaged run lacks that fact, the
receipt records `unknown` or `incomplete`; code never reconstructs the cause from `RunState` or audit.

Evidence sealing also requires a durable settlement marker proving that no later usage, approval or
execution fact can arrive. The last primary fact and settlement marker commit together, and every
primary fact, message and usage writer rejects writes after settlement. Ordinary success may write
terminal and settlement together. Cancellation and supersession settle through the shared session-lane
finalizer after live work unwinds; approval recovery settles after its placeholder is resolved. After
run and approval reconciliation, boot reconciliation marks every prior-process bound terminal run
without settlement, including `CANCELLED` and `SUPERSEDED`, as explicitly `incomplete` or `unknown`.
Approval reconciliation may register asynchronous lane work. The boot fallback excludes runs owned
by a current-process lane, and each lane must commit settlement before it unregisters. The sealer never
guesses settlement or lane quiescence from a timeout.

Primary-run code appends bounded tool lifecycle facts immediately after every dispatch, independently
of complete `ToolExchange` values, and carries them through every early exit. Each proposed call has a
provider-call identity plus segment, round and call ordinals. Its lifecycle records tool-call ID,
resolved tool name, proposal/approval/dispatch/final disposition, observation status, policy decision,
policy-produced canonical target digest, result size, `ingestedUntrusted`, `readPrivateData` and an
optional policy-permitted redacted excerpt. Raw arguments, secrets and private excerpts are excluded.
Settlement requires one allowed final disposition for every proposed-call ordinal.

Each context assembly and provider segment also writes an immutable ordered execution-segment receipt
while route and context values remain available. This captures primary-to-fallback changes and
approval-resume segments without reconstructing them from mutable state. Audit remains observability
and is not learning provenance.

### 6.3 Sealing and eligibility

After settlement, `ScheduledLearningService` runs one idempotent transaction that verifies source
digests and complete tool lifecycles, compares the binding epoch with current job state and the purge
barrier, snapshots ordered segment receipts, and writes either sealed evidence or `excluded(reason)`.
An old-epoch or purging claim may write only a content-free stale tombstone; it cannot recreate
evidence or eligibility. Sealed evidence copies the complete canonical final-output bytes within the
evidence cap, source message ID and digest; it never substitutes a digest-only or truncated result. A
cap mismatch, retention loss or corruption produces `insufficient_evidence`.

The same transaction writes the immutable eligibility receipt for the sealed evidence or exclusion
digest and classifier version. An ineligible receipt is a terminal classification, not pending work
that a later worker may reinterpret. No evaluator receives a partial reconstruction.

The learning service atomically claims only bound terminal runs whose versioned eligibility receipt
is eligible, evaluation state is pending, and current job epoch permits a call. One current attempt
per logical hypothesis prevents two workers or a restart from committing two results for the same
operation generation.

The initial deterministic eligibility taxonomy is:

```text
eligible_task_evidence
transient_infrastructure_failure
policy_or_security_block
owner_interruption
insufficient_evidence
unsupported_terminal_state
```

Provider, credential, storage and budget failures do not produce behavioral lessons. Cancellation,
supersession, unresolved/rejected approval and security-policy blocks never enter reflection.

## 7. Evaluation and reflection

The evaluator receives only a whitelisted, condition-neutral carrier:

- the frozen job prompt and quality rubric;
- one final output;
- the safe bounded evidence projection;
- optional task input facts supplied by an adapter before any oracle join.

It receives no applied lesson text or identity, trial/candidate identity, stable digest, prior score,
promotion state or expected direction of improvement. The call has no tools.

Adapter gold data, oracle results, holdout inputs, expected labels, regression gates and their raw
results never enter evaluator, reflector or candidate-synthesis carriers. Trusted code may join a
scoped deterministic receipt only after the candidate has frozen. The model never receives the
verification inputs or oracle result.

The evaluator returns a closed structured result such as:

```text
no_issue | reusable_issue | transient_issue | uncertain
```

with bounded issue codes and evidence references. This is heuristic evidence, not semantic proof or
a calibrated probability.

Before either call, the exact serialized carrier passes the configured privacy/provider policy and
secret-redaction checks. A second learning call is not automatically permitted merely because the
primary provider saw the task output. A denied carrier terminates that learning operation as
`failed_no_call(carrier_policy_denied)` and leaves the immutable task-evidence eligibility receipt
unchanged.

Reflection is a separate fresh, tool-free call over a closed, code-built `ReflectorCarrier`. It
contains compatible saved evaluations, normalized issue references, bounded policy-permitted evidence
excerpts, bounded owner-feedback payloads and the current stable lesson set at a frozen cutoff. Each
lesson, evidence and feedback body has its own ordinary untrusted-data fence.

The carrier excludes owner and transport IDs, feedback nonces and challenge state, raw evidence,
audit rows, private observations and provider replay state. Its canonical bytes and digest bind the
learning operation and candidate source manifest. Reflection may return one complete replacement set
or no candidate. Evaluation failure cannot start reflection; reflection failure cannot create a
candidate.

Compatible evidence must share the same job semantics and compatible evidence, execution-surface,
rubric and adapter versions. Exact grouping rules and support counts belong to M2.

## 8. Owner feedback and candidate admission

Owner feedback is durable, authenticated, typed, append-only and bound to an exact subject digest.
The authenticated envelope is trusted control; free-text correction and edit bytes remain untrusted
task data. The store atomically claims the external update, verifies the numeric owner and private
chat, validates the target/nonce, appends the event, advances a monotonic feedback revision and
writes a redacted audit event. Candidate rejection and evaluation dispute also close an exact matching
open trial in this transaction when epoch, trial generation, candidate, replacement and base digests
still match. Duplicate transport events or consumed nonces cannot append twice.

The audit stores actor and action, subject IDs and digests, signal kind, payload byte count and outcome.
Correction, edit and evidence bytes never enter audit arguments, decisions or logs.

Every feedback-bearing result or review notice commits its durable target and all outbox chunks in one
transaction. Multipart delivery places the keyboard on the final chunk and every resend carries the
same opaque nonce. Free-text correction and candidate edit use a separate durable one-shot input
challenge committed with its prompt outbox. No committed target or challenge means no valid feedback
action. A challenge binds job, learning epoch and exact target digest; consumption compares the current
epoch in the same transaction that appends feedback. One owner private DM may have at most one live
free-text challenge. Creating a newer correction or edit prompt atomically supersedes the prior live
challenge, so the next owner message has one exact subject.

Supported signals are:

- **result useful / not useful:** supporting or contradicting sentiment for one output;
- **result correction:** owner-attested expected behavior and a possible one-run reflection/trial seed;
- **evaluation confirm / dispute:** confirmation creates an immutable `owner_confirmed` claim for that
  exact evaluation; dispute blocks dependent admission or promotion;
- **candidate approve / reject:** approval permits a trial through the common gate; rejection vetoes
  or closes that exact candidate/trial;
- **candidate edit:** creates a new immutable candidate and digest; prior approvals do not carry over.

Simple thumbs-up and thumbs-down map to `result useful` and `result not useful`. M1 carries them over
authenticated `fb:` controls because native Telegram reaction updates do not provide the required
actor binding in the current client. Native reaction transport and unbound reply inference are
deferred. Feedback never writes the stable lesson pointer and never grants tools, destinations,
recipients, policy exceptions or budget increases.

A candidate is one complete replacement set bound to the exact incumbent digest and revision. Its
candidate-record digest and replacement lesson-set digest are distinct. Trusted code attaches one
closed origin and an immutable source manifest with the exact evidence, evaluation, feedback, base-set
and predecessor-candidate edges. A cutoff alone is not provenance.

The same admission validator runs on reflector output and owner edits before lesson bytes persist or
a trial opens. It validates only boundaries that provide concrete value now:

- closed versioned schema and canonical encoding;
- finite lesson count and UTF-8 byte caps;
- rejection of control, invisible, zero-width and bidirectional formatting characters;
- exact-loaded-secret and credential leakage checks;
- exact job, epoch, base and source bindings.

Lessons are not parsed into schedule, route, tool, recipient, path, command or approval
configuration. Lexical scanning may flag suspicious text as defense in depth, but it is not relied on
to prove safety and must not reject ordinary useful prose merely for mentioning a file, URL or
command. The candidate schema contains no authority-operand fields. Runtime policy remains
authoritative for every model-proposed tool argument.

Repeated compatible evidence may admit an automatic heuristic trial. An explicit owner correction
or approval may admit a trial after one eligible occurrence. In both cases admission requires a
repeatable non-cancelled job, a matching current base, no unresolved veto, successful validation,
available learning budget and no open trial. Admission compare-and-swaps the candidate's frozen
feedback revision against current job state and verifies that every feedback edge in its source
manifest remains effective and unsuperseded. The same transaction verifies that the job remains
repeatable and non-cancelled, the immutable validator/gate receipt still matches, and the learning
budget reservation succeeds. A mismatch makes the candidate stale; the worker cannot rebind it to a
newer cutoff. Passing admission means only that the candidate may enter a bounded experiment.

## 9. Trial, promotion, fallback and rollback

One job may have one nonterminal trial. The stable pointer remains unchanged while the scheduler
assigns the candidate lesson set to a bounded number of runs.

The trial stores two absolute deadlines:

- **assignment deadline:** after this point, or after assignment exhaustion, new runs use stable
  lessons and the trial drains;
- **decision deadline:** by this point, assigned runs must provide enough eligible evidence or the
  trial closes without promotion.

Only settled runs with the exact trial digest, eligible evidence and a completed evaluation count as
positive support. Technical failures consume exposure but do not support the candidate. Silence,
uncertain evaluation, missing evaluation and absence of contradiction do not count as success.

Promotion waits until assignment closes and the frozen cohort has settled, or until the decision
deadline classifies its missing members. One early positive run cannot promote a candidate while
already assigned trial runs remain capable of producing contradictory evidence.

Immediate hard stop conditions include security/deterministic veto, critical failure or regression,
owner candidate rejection, an evaluation dispute invalidating required evidence, job cancellation
or trial-state corruption. Hard vetoes outrank heuristic support.

Promotion is one transaction that:

1. verifies that the job remains repeatable and non-cancelled;
2. verifies learning epoch, exact trial/generation, candidate and replacement digests;
3. verifies the stable pointer and revision still equal the recorded base;
4. verifies the reviewed feedback revision and absence of unresolved reject/dispute;
5. verifies the required evidence and versioned gates;
6. inserts a decision receipt, compare-and-swaps the stable pointer and closes the trial.

A compare-and-swap miss is stale. The worker never retries the same candidate against a new base.
Fallback or rejection closes only the exact trial and leaves stable lessons untouched.

A veto or verified regression discovered after promotion may make rollback eligible. Rollback is a
separate transaction bound to the current learning epoch, exact promotion, candidate-record and
replacement digests, retained base, current stable revision, and exact trigger ID/digest/version. An
owner-feedback trigger must remain effective, not superseded, and match the frozen feedback revision;
a failure or regression trigger must match its immutable receipt and gate version.

The transaction restores the retained base only while the current stable digest and revision still
identify that promotion. A stale epoch, trigger or compare-and-swap miss cannot retarget a later
activation. Recording feedback alone never mutates stable state.

## 10. Operations, restart, budgets and data lifecycle

Claiming an operation cannot dispatch a provider request. Before HTTP handoff, one transaction
rechecks job state, learning epoch, exact carrier privacy result, global and proactive breakers, then
records `started` with a unique provider-call ID, route and budget reservation. The logical operation
key covers phase, source digest and prompt, schema and rubric versions. The attempt key also includes
a monotonic generation; at most one generation is current.

A prior-process `claimed` operation may be reclaimed because durable state proves that no provider
call started.

After a response, one transaction with `state == started` writes exactly one structured result or
rejection, usage linkage and terminal operation state. A prior-process `started` operation becomes
`interrupted_unknown` at boot and is not automatically resent as the same logical inference. The boot
transaction records any missing conservative usage reservation or ceiling under the saved call ID
before changing state. A later authorized attempt uses a new operation generation and provider-call
ID, links `supersedes` to the interrupted attempt, and compare-and-swaps which attempt is current. It
does not reuse or rewrite the earlier result.

This provides idempotent database results and honest ambiguity at the network boundary. It does not
claim exactly-once dispatch or provider billing.

Evaluation and reflection usage:

- counts toward global and proactive learning budgets;
- remains separate from primary task-run totals;
- is recorded even when a sent call later becomes unusable because of cancellation or purge;
- never delays persistence or owner delivery of the task result.

Job cancellation atomically blocks new learning calls, closes the exact open trial with a receipt, and
prevents admission or promotion. Existing bound runs retain their pinned lesson digest and may settle,
but their evidence cannot activate new learning decisions. History remains until retention or purge
removes it.

Cancellation is not purge. Purge uses a separate authenticated, confirm-gated owner control. Export
uses the same owner-only control path, a code-defined bounded scope and a no-follow `0600` file below
the application state root; only the fixed owner DM receives its path. No model, lesson or tool chooses
the export scope, path or recipient, and the export omits raw trajectories, private observations and
provider replay state.

Every binding, operation, feedback target, input challenge, candidate and trial carries a monotonic
`learning_epoch`. Purge first increments the epoch and installs a durable barrier that:

- disables new learning starts, admission and promotion for the old epoch;
- invalidates outstanding feedback targets and input challenges, then closes the exact trial;
- resets stable lessons to the canonical empty set or an ancestor proven unaffected by exact source
  manifest traversal;
- prevents late old-epoch results from creating evaluations, candidates, trials or activations.

A late provider result may still record mandatory usage and terminal operation status. Purge removes
owner-derived learning payloads and provenance only after old-epoch live runs and `started` learning
operations settle. Export, retention and purge cover run bindings, terminal and settlement receipts,
evidence, eligibility, evaluations, feedback targets, input challenges, events, candidates, lesson
sets, trials, operations and decision/verification receipts. Deleting source data cannot leave an
active lesson that still encodes it. The purge transaction follows exact candidate-source edges to
invalidate dependent candidates, decisions and lesson sets; a cutoff digest alone cannot prove
independence.

### Transaction and restart matrix

| Boundary | Atomic durable effect | Crash/replay rule |
|---|---|---|
| Fire | occurrence/overlap claim + run + binding + optional trial assignment | no committed run means no assignment; committed run keeps its digest |
| Segment facts | append tool lifecycle facts and route/surface receipt with their owning segment or suspension commit | duplicate identity must match; missing final disposition makes evidence incomplete |
| Terminal | winning run state + terminal receipt | unique and idempotent; conflicting duplicate is a consistency failure |
| Settlement | final primary fact + settlement marker | every later primary-fact writer rejects the write; no timer-based settlement |
| Evidence/eligibility | compare epoch/barrier + verify receipts/digests + snapshot facts + evidence/exclusion + eligibility | stale purge-era work cannot recreate payload; replay uses run/schema/classifier identity |
| Feedback notice | target or input challenge + every outbox chunk | resend carries the same opaque target; no notice means no valid action |
| Feedback event | transport claim + owner/target check + event + revision + audit + exact veto effect | update and nonce cannot be consumed twice; a conflicting replay is stale |
| Provider start | recheck epoch/privacy/breakers + attempt generation + reservation + unique call ID + `started` | a no-call denial becomes terminal; boot accounts ambiguous exposure and changes a started attempt to `interrupted_unknown` without resend |
| Provider result | structured result/rejection + usage + terminal operation state | `state == started` predicate permits one exact durable result |
| Trial admission | job/base/epoch/feedback + source/gate checks + budget reservation + unique trial + receipt | cancellation or stale input cannot open or rebind a trial |
| Promotion | current job status + exact predicates + decision receipt + stable CAS + trial close | cancellation or CAS loss prevents activation |
| Fallback/reject/cancel | exact trial close + receipt | stable pointer remains unchanged |
| Rollback | exact epoch/promotion/trigger/feedback/gate checks + stable CAS to retained base | stale or superseded trigger cannot overwrite later activation |
| Purge | epoch/barrier first, payload deletion after settlement | late old-epoch results cannot repopulate learning state |

## 11. Page-change adapter

Page-change monitoring is the first deterministic benchmark, not the production boundary. The
adapter supplies frozen task inputs, a deterministic scorer/oracle, version and regression fixtures
through generic contracts. The generic domain contains no page-specific types.

A verification receipt is scoped to the exact lesson digest, dataset/oracle, adapter version and
execution surface. A route, rubric, policy or adapter incompatibility requires revalidation or a
downgrade to heuristic evidence. Corpus size, split and score thresholds belong to the later
validation protocol, not this architecture RFC. Protocol 0.6 remains frozen.

The Protocol 0.6 controller batch stopped incomplete after exhausting its regression retry pool. The
completed direct experiment remains an exploratory scenario-selection result. Neither artifact proves
a production learning loop, protocol conformance or a second improvement claim, and neither may issue
a new deterministic verification receipt. M3 must freeze fresh validation inputs and keep oracle,
gold, holdout and regression data outside evaluator and reflector carriers.

## 12. Validation and implementation sequence

M2 first chooses the versioned algorithm parameters in section 13.

M3 then lands the generic harness and a fresh page-change adapter before production activation. It
freezes a new corpus, split, scorer, oracle and gates, then exercises clean, trial, active and
post-restart conditions through generic contracts.

M4 delivers the production capability in this order:

1. **Capture:** run binding, terminal and settlement receipts, complete bounded tool/segment facts,
   and safe evidence/exclusion; no behavior change.
2. **Pinned lesson read path:** immutable job lesson sets, exact-digest loading, whole-set context row
   and initial taint; stable remains the only production pointer.
3. **Eligibility and evaluation:** versioned deterministic taxonomy, durable learning operations,
   blind tool-free evaluator and budget accounting.
4. **Owner feedback:** atomic `fb:` notices, input challenges, typed append-only events and
   exact-subject veto/support.
5. **Reflection and inert candidates:** closed reflector carrier, exact source manifests, immutable
   replacement sets and deterministic admission; no activation.
6. **Lifecycle controls:** authenticated export/purge, retention, observability and restart fault
   injection. The production activation gate stays closed until this step and the M3 gates pass.
7. **Bounded activation:** one trial override, atomic assignment, draining, expiry, fallback, guarded
   promotion and active rollback.

Each increment must leave ordinary scheduled execution usable when learning is unavailable. After a
run binding commits, the task either loads the exact pinned lesson bytes or fails before provider
dispatch; it never substitutes another set.

## 13. Deferred to M2

M2 chooses and versions:

- compatible-evidence window and minimum support count;
- reflection timing and consolidation rules;
- lesson count and byte caps within finite M1 bounds;
- trial assignment count, assignment deadline and decision deadline;
- heuristic acceptance, regression and uncertainty rules;
- owner-signal weighting beyond hard veto precedence;
- evaluator/reflector routes and operation budgets;
- retention windows and deterministic-adapter thresholds.

M2 cannot change the M1 invariants: one attempt identity, job-scoped lessons, stable plus one bounded
trial, no stacking, evaluator blindness, feedback through the common gate, no authority expansion,
honest restart behavior, and distinct heuristic/owner/deterministic evidence claims.

## 14. Acceptance

This RFC satisfies Issue 167's architecture contract:

- existing `run_id` remains canonical and the generic core contains no page types;
- fire atomically pins exact occurrence, learning epoch and effective lesson digest; ordered segment
  receipts capture the actual execution surface later;
- every terminal path has a receipt, settlement blocks later primary writes, and asynchronous sealing
  copies the complete bounded output and emits versioned eligibility;
- independent ordered tool lifecycles preserve policy, approval, status and trust facts across early
  exits;
- eligibility precedes LLM evaluation; evaluator and closed-whitelist reflector carriers are separate,
  tool-free and isolated from deterministic oracle data;
- owner feedback is durable, authenticated, typed, append-only and exact-subject-bound;
- feedback notices bind atomically to delivery, hard vetoes close exact trials, and feedback or lesson
  text cannot activate themselves or expand authority;
- candidates distinguish record and replacement digests and retain exact transitive source manifests;
- one bounded non-stacking trial has separate assignment and decision deadlines and a frozen cohort;
- promotion, fallback and rollback use exact epoch, feedback, trigger and compare-and-swap predicates;
- positive eligible evidence is required and evidence-strength claims remain distinct;
- learning operations atomically bind provider-call identity, result, usage and restart ambiguity
  without fake runs; usage joins global and proactive budgets;
- the complete pinned lesson set reaches context intact and adds taint before memory selection and tool
  dispatch without replacing existing taint;
- restart handling does not claim exactly-once provider inference;
- owner-only export and epoch-barrier purge cover derived data, source deletion and late-result races
  before production activation;
- page-change remains the first deterministic adapter and benchmark, while M0 stays exploratory.

No known P0 architecture or security decision remains unresolved in M1. Exact algorithm parameters
and physical implementation details are intentionally deferred to their owning milestone.
