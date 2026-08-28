# Issue 167: Generic scheduled-task learning architecture

| | |
|---|---|
| **Status** | Proposed M1 RFC/ADR |
| **Date** | 28 August 2026 |
| **Parent** | [Issue 115](https://github.com/ivan-magda/swift-claw/issues/115) |
| **Scope issue** | [Issue 167](https://github.com/ivan-magda/swift-claw/issues/167) |
| **M0 evidence** | [Issue 118 decision](118-scenario-decision.md) |

`docs/ARCHITECTURE.md` remains the normative technical specification. This RFC defines the M1
decision for the Hacker Sprint project. A production increment must amend the normative context and
persistence sections before it changes their contracts.

## 1. Decision

Swift Claw will add one durable learning control plane for scheduled jobs. A scheduled job keeps its
ordinary prompt, runtime, tools, policy and delivery path. The learning control plane records the
run, evaluates task quality, collects owner feedback, proposes a bounded job-scoped lesson set and
runs that set under a finite trial before promotion.

The capability applies to the task expressed by any scheduled job. Page-change monitoring supplies
the first deterministic evaluator adapter and benchmark. Page, HTML, region, selector and snapshot
types stay outside the generic learning domain.

The production lifecycle is:

```text
scheduled fire
  -> bind the occurrence and effective job-scoped lesson set to run_id
  -> assemble context with initial lesson taint
  -> execute the ordinary proactive AgentRuntime
  -> commit terminal state and a terminal receipt
  -> record that no more primary-run facts can arrive
  -> seal bounded learning evidence
  -> classify learning eligibility in code
  -> run a procedurally blind, tool-free evaluator
  -> combine evaluation with durable owner feedback
  -> run tool-free reflection when evidence supports it
  -> validate one immutable replacement candidate
  -> assign a finite trial override
  -> promote with compare-and-swap or fall back to the stable set
```

This RFC makes two guarantees.

**Capability guarantee.** A repeatable scheduled job can persist and reuse its own lessons across
process restarts. Its runs, evaluations, feedback, candidates, trials and decisions retain
job-scoped provenance.

**Evidence guarantee.** The system labels the strength and scope of each learning decision. Generic
LLM evaluation and natural runs provide heuristic evidence. Owner feedback provides
`owner_supported` or `owner_confirmed` evidence for a bound subject. A deterministic adapter can
provide verification only for the claim covered by its trusted inputs and versioned gate.

A one-shot job still records its run, evaluation and owner feedback. It cannot exercise a trial
until another occurrence exists.

## 2. Goals

M1 defines the smallest architecture that can support the Hacker Sprint result:

1. Preserve the existing `run_id` as the scheduled-task attempt identity.
2. Give each job an isolated, durable and bounded lesson namespace.
3. Separate task quality from `RunState`.
4. Apply a lesson only through a finite, attributable trial.
5. Make owner feedback a durable learning input with explicit strength.
6. Keep lessons outside the authority, tool and scheduling control planes.
7. Count learning calls against global and proactive budgets.
8. Resume safe work after restart without claiming exactly-once inference.
9. Support an optional deterministic evaluator without teaching the core about one task type.
10. Preserve export, retention and deletion semantics for derived learning data.

## 3. Non-goals

M1 does not define or implement:

- a global memory or evaluation platform;
- cross-job lessons;
- a second agent runtime;
- a page-specific production coordinator;
- exact reflection thresholds, evidence-window sizes or trial duration;
- automatic changes to prompts, schedules, tools, model routes, recipients or budgets;
- semantic proof that an arbitrary subjective result improved;
- native Telegram reaction support;
- a live page importer or the M3 benchmark corpus;
- Swift production code, migrations or tests;
- edits to the frozen Protocol 0.6 artifact.

M2 will choose the algorithm parameters. M3 will build the generic evaluation harness and the
page-change adapter. M4 will implement the production path.

## 4. Existing seams and confirmed gaps

The design reuses the current agent and persistence paths.

| Concern | Existing seam | M1 gap |
|---|---|---|
| Fire identity | `ScheduledJobStoreGRDB.claimAndFire` atomically advances an occurrence, applies the overlap guard and inserts the trigger plus `PENDING` run | The transaction does not bind the logical occurrence, fire kind or lesson digest to the run |
| Attempt identity | `runs.id` links the scheduled job, trigger, messages and provider usage | No second attempt type is needed; the run lacks a learning binding |
| Task output | `commitAssistantTurn` stores the final assistant message, exchanges, usage and outbox with `DONE` | `DONE` means technical completion and does not carry task quality |
| Failure outcome | Run stores commit `FAILED`, `CANCELLED` and `SUPERSEDED` through several legal FSM paths | The row does not retain a precise terminal cause or learning disposition |
| Tool evidence | `TurnOutcome` carries tool name, status and trust flags; the assistant anchor retains proposed tool names | Observation rows keep call ID and content but drop status and trust flags, and early exits can lose already-dispatched calls before a complete exchange exists |
| Context | `ContextBuilder` builds the proactive prompt and excludes sensitive memory when `snapshot.isTainted` | No lesson row exists; lesson taint would arrive too late for memory selection and the first tool call |
| Policy | `ToolPolicyGate` enforces risk, exfiltration and approval rules in code | A poisoned lesson can still influence behavior within existing authority, so admission needs bounded lexical and authority-operand checks |
| Usage | `provider_usage` counts global spend; origin totals join usage through `run_id` | A runless learning call would miss the proactive total |
| Delivery | The outbox records `run_id` and the Telegram message ID after send | No durable feedback target or callback namespace exists |
| Telegram intake | The poller receives messages, edits and callbacks | Wire models omit reply targets and reaction updates; callbacks route only to tool approval |
| Evaluation harness | `ClawEvaluation` runs sealed experiments through internal targets | Production must not depend on harness-only page records or process controls |

The current stores expose no single terminal-run choke point. The implementation must cover
completion, degradation, fallback failure, approval rejection or expiry, stale policy, boot
reconciliation, cancellation and supersession. Audit rows cannot fill the gap because some audit
writes occur after the state commit and most audit errors do not fail the run.

## 5. Domain model

The following names describe logical records. They do not require one Swift protocol or one table
per row. The first implementation should expose one cohesive `ScheduledLearningStore` seam and
split it only when callers need distinct responsibilities.

### 5.1 Immutable records

| Record | Purpose | Required identity and provenance |
|---|---|---|
| `LessonSet` | Canonical bounded lesson bytes for one job | job ID, schema version, content digest, lessons, creation time |
| `RunLearningBinding` | The learning condition selected for one run | run ID, job ID, learning epoch, logical fire time, fire kind, job-definition digest, stable and effective lesson-set digests, selection kind, optional trial ID and generation |
| `RunTerminalReceipt` | The technical terminal event | run ID, terminal state, typed cause, terminal time, initial evaluation disposition |
| `RunSettlementReceipt` | Proof that no more primary-run facts may arrive | run ID, settlement kind, completeness code, settled time |
| `RunToolFact` | Ordered dispatch and observation lifecycle | run, segment, round and call ordinals, provider-call and tool-call identities, tool name, policy-produced safe invocation binding, dispatch disposition, observation status, result size and trust flags |
| `RunExecutionSegmentReceipt` | Frozen surface for one provider segment | run and segment identity, pinned lesson-set digest, policy, context, tool and skill versions, configured route, outbound and terminal models, carrier digest |
| `RunLearningEvidence` | Bounded server-side evaluation provenance | run binding, terminal and settlement receipts, canonical final-output bytes and digest, ordered tool facts and segment receipts, usage references, evidence schema and digest |
| `LearningEligibilityReceipt` | Deterministic classification of sealed evidence | evidence digest, classifier version, disposition and closed reason code |
| `EvaluatorCarrier` | Whitelisted model-visible projection | evidence digest, carrier schema, condition-neutral task bytes and facts, payload digest |
| `ReflectorCarrier` | Whitelisted model-visible synthesis projection | job and learning epoch, frozen source cutoff, bounded typed evaluations and feedback signals, current lesson set, carrier schema and digest |
| `TaskEvaluation` | One evaluator result for exact evidence | evaluation ID, evidence digest, rubric and evaluator versions, structured result, optional adapter receipts, operation ID, digest |
| `OwnerFeedbackEvent` | Append-only owner signal | target ID, owner ID, signal kind, bounded payload or decision, transport event identity, created time, optional superseded event |
| `CandidateSourceManifest` | Exact provenance membership | candidate ID, reflector-carrier digest, referenced evidence, evaluation and feedback IDs, base lesson-set edge and optional predecessor candidate edge |
| `LessonCandidate` | One complete replacement set | candidate ID and record digest, job ID and learning epoch, base lesson-set digest and revision, replacement lesson-set digest, source-manifest digest, origin and optional predecessor |
| `LearningDecisionReceipt` | Admission, promotion, fallback or veto decision | job, candidate and trial identities, expected epoch, base, stable and feedback revisions, generation, evidence class, gate versions, decision and time |

Immutable records use insert-only semantics. A correction adds a new event. A candidate edit creates
a new candidate and digest. A later verification adds a new receipt for the same lesson bytes.

### 5.2 Operational records

A small set of records needs mutable operational state:

| Record | Mutable fields | Constraint |
|---|---|---|
| `JobLearningState` | stable lesson-set pointer and revision, learning epoch, enabled or purging state, feedback revision | one row per job; compare-and-swap updates only |
| `TrialLease` | lifecycle, assignment count and close metadata | at most one nonterminal trial per job; exact epoch, generation, base revision and three distinct candidate/base/replacement digests |
| `LearningOperation` | claim and provider-call lifecycle | monotonic transitions with unique logical identity |
| `FeedbackTarget` | owner, exact subject digest, epoch, allowed actions, expiry, nonce and consumption state | one action per target nonce; compare-and-swap consumption |
| `FeedbackInputChallenge` | one bound free-text correction or candidate edit | owner private chat, target and purpose, prompt delivery binding, epoch, expiry and consumed, superseded or cancelled state |

Lesson bytes remain content-addressed. The empty set has one schema-versioned canonical encoding and
digest, so a clean run receives the same binding shape as a lesson-conditioned run.

### 5.3 State and evidence remain separate

Activation state and evidence strength answer different questions:

```text
activation: candidate | trial | active | rolled_back | superseded
evidence:   heuristic | owner_supported | owner_confirmed | deterministically_verified
owner_review: none | trial_approved | rejected
```

A lesson may move from heuristic to deterministically verified without changing its bytes or active
pointer. A verified lesson may later become superseded. The implementation must not encode both
dimensions in one enum.

An owner-evidence claim is bound to the exact run, evaluation or candidate that the owner reviewed.
`owner_supported` covers supporting sentiment, a correction or other non-confirming evidence.
`owner_confirmed` requires an explicit confirmation of the exact evaluation. Neither proves causal
improvement or generalization. Candidate consent belongs to the separate `owner_review` axis.
Product surfaces render any active digest without a deterministic receipt as `ACTIVE_HEURISTIC` and
`active + deterministically_verified` as `ACTIVE_VERIFIED`; they never describe owner sentiment or
an observational cohort as deterministic proof.

`deterministically_verified` means that an exact lesson digest passed a named adapter, corpus,
oracle, rubric and execution-surface version. It does not assert correctness on future inputs.

## 6. End-to-end ownership

```text
SchedulerService
  -> ScheduledJobStore fire transaction
       -> create run
       -> pin lesson condition
       -> consume trial assignment when present
  -> existing session lane and TurnRunner
       -> loadTurnInputs(runId) verifies binding and loads pinned lessons
       -> ContextBuilder receives the immutable pinned set
       -> AgentRuntime executes with ordinary tools and policy
       -> RunStore commits task result and terminal receipt
       -> execution owner commits settlement receipt
  -> ScheduledLearningService scans durable pending work
       -> seal evidence
       -> classify eligibility
       -> evaluate
       -> reflect when warranted
       -> validate candidate
       -> open or settle trial
  -> later fire reads stable state plus optional trial override
```

The scheduler does not evaluate or reflect. The session lane does not wait for learning. Owner
delivery does not wait for learning. A missing or delayed evaluation leaves the next occurrence on
the last committed stable state unless an unexpired trial assignment already exists.

The learning service discovers work through durable queries. It does not depend on an in-memory
callback from `TurnRunner`.

## 7. Fire binding and lesson selection

### 7.1 Fire transaction

The existing fused fire transaction remains the assignment point. After the live-run overlap guard
passes, the same `writeMapping` must:

1. create `run_id`;
2. select the current learning epoch and stable lesson set or an eligible trial override;
3. insert `RunLearningBinding` with that epoch and exact effective lesson-set digest;
4. consume one trial assignment when it selected the trial;
5. insert the trigger, pending run and existing audit side effects.

Any failure rolls back the occurrence advance and every inserted row. A CAS loser, misfire skip or
overlap skip creates no run and consumes no trial assignment. A coalesced catch-up creates one run
and consumes one assignment.

The binding records `scheduled` versus `runnow`. Current `runs.origin` cannot distinguish them.
`/runnow` counts as a trial assignment because it executes the same job and lets the owner test a
paused schedule. A live-run overlap still consumes none.

### 7.2 Stable state and trial override

The stable pointer never points at an unaccepted trial candidate. The scheduler computes:

```text
effective_lesson_set_digest =
  eligible_trial.replacement_lesson_set_digest ?? stable_lesson_set_digest
```

It writes `effective_lesson_set_digest` to the run binding. Candidate-record digests identify review
and decision subjects; they are never loaded as lesson bytes. In-flight and resumed runs load the
exact replacement lesson-set digest from their binding and never reread a current pointer.

The shared initial and approval-resume path becomes `loadTurnInputs(runId:...)`. It loads the run,
requires `RunLearningBinding.job_id == runs.job_id`, verifies the bound digest against canonical
lesson bytes and passes an immutable `PinnedJobLessons` value to `ContextBuilder`. After a binding
commits, missing bytes or a digest mismatch fails that run before provider dispatch. It cannot fall
back to another lesson set. Empty or stable fallback is legal only inside the fire transaction
before the binding exists. Retention and purge cannot collect lesson bytes referenced by a live
`PENDING`, `RUNNING` or `AWAITING_APPROVAL` run.

Trial eligibility uses the transaction's actual `now`, not the logical fire time. Boot catch-up
cannot revive an expired trial. Assignment expiry and the maximum assignment count stop new trial
runs. Runs that already hold the trial digest continue to completion.

If the assignment deadline or maximum count has arrived, the fire transaction moves that exact
trial from active to draining and uses the stable set for this fire; it does not terminally reject
the candidate before its decision deadline. Decision expiry closes the draining trial as
insufficient evidence. A stale, corrupt or base-mismatched row is instead quarantined through its
exact epoch, trial ID, generation, candidate-record digest and base revision. If the stable pointer
or content is corrupt, the scheduler pins the canonical empty set, records a learning-health failure
and creates an owner-visible notice. Learning-state corruption must not stop the underlying
scheduled task or widen its authority.

### 7.3 Schedule status

- `PAUSED` stops ticker fires only. It does not cancel a bound run or learning lifecycle, extend a
  deadline, block `/runnow`, prevent an already-admitted learning call from starting or prevent a
  completed decision from settling. `/runnow` may consume a trial assignment while paused.
- `CANCELLED` blocks new learning provider starts, admission and promotion. Cancellation closes only
  the exact current trial through its epoch, ID, generation, candidate-record digest and base
  revision. A scheduled run already created before cancellation keeps its pinned digest and may
  terminalize, but its evidence cannot start new calls or promotion. A provider call that won the
  start race may finish and record usage; its result is ineligible for later activation. Already
  committed evidence and feedback remain subject to retention and purge.
- `COMPLETED` one-shot jobs may retain evaluation and reflection artifacts. They cannot open an
  automatic trial with no future execution.
- Resume preserves the stable pointer and any still-valid trial state.

## 8. Context assembly and initial taint

The context builder receives `PinnedJobLessons` before it selects memory. Lesson taint augments the
two existing taint inputs instead of replacing either one:

```text
memory_exclusion_taint = persisted_session_taint OR has_pinned_lessons
initial_run_ingested_untrusted = existing_untrusted_tool_metadata OR has_pinned_lessons
session_tainted = persisted_session_taint
```

The implementation applies these values in two places:

1. `ContextBuilder` uses `memory_exclusion_taint` for both memory fetch and ranking. Its result
   carries `hasTaintingContext` or an equivalent explicit bit.
2. `AgentRuntime` combines that bit with the current untrusted-tool-metadata seed before the first
   provider call and first `ToolDispatchContext`.

The run-level value stays sticky through suspension, resume, degradation and terminal commit. A
restart derives it from the run binding, not a mutable job pointer. Superseding the old run through
`/new` does not transfer that run's lesson taint into the new conversation window.

Lessons occupy one dedicated context section with a stable label such as `job_lessons`. Trusted
policy text describes the section as bounded advisory experience for the current job. The lesson
bytes render inside the ordinary untrusted fence. They cannot mint a fence label or claim system
authority.

M1 fixes its context policy: add `ContextRowID.jobLessons` at priority `35`, tier
`.untrustedLabeled`, with `truncatable = false`. The row is one whole-set unit in the fixed sections,
after trusted metadata and before `userFile`, and is included before `BudgetFitter` calculates its
residual. A single shared `job_lessons` label constant is used by the trusted policy text and
renderer.

The section contains the complete pinned set. The implementation validates its cap before
persistence, so context assembly never truncates one lesson or drops a subset. Missing bytes or a
digest mismatch produce a context failure before provider dispatch.

The future normative `ARCHITECTURE.md` update must add this fixed row and taint contract to the
canonical order in section 9. The lesson digest remains separate from
`policy_version`; the policy fingerprint covers the trusted wrapper and policy, while the run
binding covers the untrusted payload.

## 9. Terminal receipts, settlement and evidence

### 9.1 Terminal receipt

Every legal transition of a run created with `RunLearningBinding` to `DONE`, `FAILED`, `CANCELLED`
or `SUPERSEDED` inserts one terminal receipt in the same transaction as the state change. The fused
commit carrier supplies the typed cause, all available ordered tool facts and route observations.
`RunState.FAILED` alone cannot distinguish provider outage, budget refusal, policy denial, approval
expiry, storage failure or boot recovery.

For ordinary success and in-band failure, this remains the existing transaction that stores durable
output or degradation delivery, completed exchanges and usage, run state and outbox intent. The
receipt and bounded facts are not appended by a later background task.

A uniqueness constraint on `run_id` makes an exact repeated receipt idempotent; a conflicting
duplicate is a consistency failure and is quarantined. The store must add the receipt to every
public terminal seam, not only the two ordinary turn commits.

Migration may encounter scheduled runs created before bindings exist, including a suspended
approval. Such a run finishes through the existing core path and is recorded as
`legacy_unbound/not_evaluable` without invented fire or lesson provenance. Missing learning state
must never roll back an otherwise legal terminal transition.

### 9.2 Settlement receipt

Terminal state does not always mean that all evidence has arrived. `/stop` or `/new` may win while a
provider call still owes usage. An approval waiter may fill a placeholder after cancellation. Boot
reconciliation may settle an unknown approved action in a second transaction.

The execution owner writes a settlement receipt only after no code path can append another
primary-run fact. The last fact and settlement receipt commit together, and every primary-fact
writer rejects a write after settlement:

- ordinary `DONE` and in-band `FAILED` commits may write terminal and settlement receipts together;
- cancellation and supersession write the terminal receipt first, then the shared session-lane
  finalizer records available facts, late usage and settlement after unwind;
- approval recovery records settlement after it resolves the observation placeholder;
- after run and approval reconciliation, a required boot pass finds every prior-process bound
  terminal run without settlement and records an explicit `incomplete` or `unknown` settlement.

The evidence sealer requires both receipts. It never uses a timer as a settlement guess. This boot
pass includes `CANCELLED` and `SUPERSEDED` runs; it cannot rely on the current live-run-only sweep.

### 9.3 Lossless bounded facts

The primary run must preserve evaluator-relevant facts before transient `TurnOutcome` values vanish.
Facts accumulate independently of complete `ToolExchange` values immediately after every dispatch
and travel through every early-exit and terminal outcome. Each provider-proposed call has segment,
round and call ordinals plus a provider-call identity. Its append-only lifecycle records:

- tool-call ID and resolved tool name;
- `proposed`, `approval_required`, dispatch and `resolved`, `rejected` or `expired` dispositions;
- observation status and policy decision class;
- a policy-produced canonical target or argument digest and, only when an adapter permits it, a
  bounded redacted resource identifier;
- result byte count;
- `ingestedUntrusted` and `readPrivateData`;
- optional redacted, capped excerpt when policy permits it.

The fact excludes raw arguments, canonical secrets and provider replay state. A private observation
stores no excerpt. Settlement verifies that every proposed call ordinal has one allowed terminal
disposition; otherwise evidence is incomplete. Audit remains a separate observability stream.

### 9.4 Sealed evidence

Every context assembly and provider segment commits an immutable `RunExecutionSegmentReceipt` while
the exact context and route values are still available. A receipt includes the pinned lesson-set
digest, context, policy, tool and skill versions, configured route, outbound model, terminal model
and model-visible carrier digest. Evidence preserves the ordered segment receipts instead of
reconstructing them later from a mutable workspace. A cohort either accepts the complete versioned
sequence or classifies the run as incompatible.

After settlement, the learning service creates one immutable server-side evidence projection. It
contains:

- `RunLearningBinding` and terminal classification;
- the complete canonical final-output bytes within the evidence cap, source message ID and content
  digest;
- bounded tool facts in call order;
- ordered execution-segment receipts;
- primary-run usage row identities and totals;
- context, policy, tool-catalog and evaluator-carrier versions;
- an execution-surface digest;
- evidence schema version, creation time and evidence digest.

One `writeMapping` transaction verifies terminal plus settlement receipts, reads the complete fact
snapshot, verifies the referenced final message and other digests, copies the complete canonical
output into the bounded immutable evidence blob, inserts the unique evidence row and inserts the
unique `LearningEligibilityReceipt` for `(evidence_digest, classifier_version)`. It never truncates
an output into a different task result; an impossible cap mismatch becomes `insufficient_evidence`.
Separate read-then-write sealing is forbidden. If retention or deletion removed a required source
row, the transaction records `insufficient_evidence` and sends nothing to an evaluator.

Evidence excludes raw tool arguments, raw private observations, hidden provider reasoning, audit
projections and opaque replay payloads.

## 10. Learning eligibility

Code classifies sealed evidence before an LLM sees it.

```text
eligible
transient_infrastructure_failure
policy_or_security_block
owner_interrupted
insufficient_evidence
unsupported_terminal_state
```

The initial policy treats a complete `DONE` run with a usable final output as eligible only after it
checks every ordered tool fact. A failed run requires an explicit allowlisted task-level failure
class, usable evidence and no infrastructure, resource, policy or owner-interruption cause. Only
allowlisted execution errors inside an otherwise completed run remain ordinary evidence; policy
decisions do not.

The following events do not create behavioral lessons:

- provider outage, quota or credential failure;
- storage or accounting failure;
- global or proactive budget refusal;
- per-run tool, turn, input, output or wall-clock resource stop;
- cancellation, supersession or owner stop;
- unresolved, rejected or expired approval, even when a later model round produced `DONE`;
- SSRF, exfiltration or other security-policy blocks;
- stale policy or unknown post-crash effect.

The classifier records the exclusion reason. It does not ask a model to explain or work around a
policy decision.

The learning service atomically claims terminal scheduled runs whose sealed evidence has an
`eligible` classification receipt, whose evaluation state remains pending and whose current job and
learning epoch permit a new operation. Unique evidence and operation identities prevent two workers
or a restart from producing two durable results for one stage. An ineligible receipt is a terminal
learning result for that classifier version, not pending work to recompute on every restart.

## 11. Evaluation, reflection and deterministic adapters

### 11.1 Procedurally blind evaluator

The evaluator uses a new tool-free request with a closed JSON schema. The control plane builds a
whitelisted `EvaluatorCarrier`; it never passes `RunLearningEvidence` or `RunLearningBinding`
through to the model. The carrier contains:

- the owner-confirmed job prompt;
- a rubric frozen before the evaluated occurrence;
- one final output;
- condition-neutral, policy-approved output and tool facts;
- task-specific input facts when an adapter can supply them without revealing the condition or
  oracle result.

It does not receive:

- lesson text, lesson IDs or stable or effective lesson-set digests;
- selection kind, trial or candidate IDs, generation, clean or trained labels;
- prior scores or promotion state;
- the expected direction of improvement;
- owner feedback that arrived after this output.

Adapter oracle scores, verification gates and critical-failure results join the saved LLM evaluation
only after the call. Owner-authored criteria may enter a future rubric only when frozen before the
occurrence. Post-run feedback remains a separate overlay, so it cannot steer the primary evaluator
toward the owner's later verdict. Blindness is procedural: the output itself may reveal an effect,
but the control plane does not disclose which learning condition produced it.

The evaluator returns a schema such as:

```text
verdict: no_issue | reusable_issue | transient_issue | uncertain
issue_codes: bounded list
problems: bounded list with evidence references
positive_observations: bounded list with evidence references
critical_failures: bounded closed list
```

The system does not treat model-reported confidence as a calibrated probability. A second call from
the same model or provider is another correlated heuristic, not an independent judge.

### 11.2 Reflection

Reflection runs as a separate tool-free operation. The control plane constructs a closed
`ReflectorCarrier` with bounded typed evaluation results, policy-approved evidence excerpts,
effective feedback signal kinds plus bounded correction text, and the current stable lesson set at
a frozen cutoff. Each untrusted lesson, evidence and feedback body has its own ordinary untrusted
fence.

The carrier excludes owner and transport IDs, update IDs, nonces, challenge state, raw run evidence,
audit data, private observations and provider replay state. Its exact serialized digest, learning
epoch and cutoff bind the `LearningOperation` and `CandidateSourceManifest`. Reflection may propose
one complete replacement set or no candidate.

Reflection cannot activate its output. Evaluation failure cannot start reflection. Reflection
failure cannot create a candidate.

The service may trigger reflection after repeated compatible reusable issues. An explicit owner
correction or rejection of a run result may support reflection after one eligible run. Candidate
rejection is a veto, not evidence for synthesizing the same candidate again. M2 chooses the exact
support threshold, normalization and window.

### 11.3 Compatible natural-run cohort

Natural runs form an observational cohort only when they have:

- distinct run and evidence identities from distinct occurrences;
- the same job-definition digest and pre-trial stable digest;
- compatible ordered execution-segment receipts, including policy, tool catalog, context carrier,
  skill catalog and configured and terminal model routes;
- the same evaluator rubric, schema and adapter versions;
- a technical completion class that yields usable output.

Provider retries, repeat evaluation of one output and two judges of one output do not count as
distinct task evidence. A route, prompt, policy or evaluator-version change closes the cohort.

Natural inputs still differ. Repeated issue disappearance under a trial supports a heuristic claim;
it does not prove causal improvement or non-regression.

### 11.4 Optional deterministic adapter

The generic domain accepts an optional adapter receipt with:

- adapter ID and version;
- trusted input or corpus digest;
- oracle and rubric version;
- deterministic facts, scores and critical failures;
- the exact output and execution-surface digests it covers.

The adapter cannot change policy or activate a candidate. Its hard failure may veto admission or
promotion. `deterministically_verified` requires paired evaluation on immutable inputs with a
trusted oracle and a versioned regression gate.

The Issue 118 artifacts cannot create this receipt. The canonical Protocol 0.6 controller ended
incomplete, and the completed direct experiment is frozen exploratory scenario-selection evidence.
M3 uses a fresh 15 to 20 instance corpus, keeps related page families in one split and holds out at
least four instances. Verification inputs, gold and gate thresholds remain unavailable to reflection
and candidate synthesis until the candidate cutoff. A verification receipt binds the exact base and
replacement lesson-set digests, both output-set digests, corpus and split digest, model and execution
surfaces, oracle version and frozen thresholds. Existing M0 fixtures remain frozen evidence for the
scenario decision and cannot support a second post-hoc improvement claim.

Page-change implements the first adapter in M3. `ClawEvaluation` may host benchmark code, but the
daemon and generic core must not import harness-only page types. If production later needs a live
adapter, a trusted owner configuration selects its registry ID; model output never selects one.

## 12. Durable owner feedback

### 12.1 Trust split

Owner feedback contains a trusted control envelope and an untrusted payload.

The control envelope includes the authenticated numeric owner ID, exact target, typed action,
transport event identity and time. The free-text correction or edit may quote external or hostile
content, so the learning pipeline treats those bytes as untrusted task data.

Feedback grants authority over the bound quality decision. It cannot grant a tool, destination,
recipient, path, command, schedule change, policy exception or budget increase.

### 12.2 Targets and events

`FeedbackTarget` binds one owner-visible message or decision to one exact subject:

```text
run_result(run_id, output_digest)
evaluation(evaluation_id, evaluation_digest)
candidate(candidate_id, candidate_record_digest)
```

The store may denormalize job, run, evaluation and candidate IDs for queries only when one
transaction verifies the complete tuple. The target stores the learning epoch, allowed action set,
expiry and a random single-use nonce with at least 128 bits of entropy. The callback carries the
nonce and a short action; IDs and text stay server-side.

`OwnerFeedbackEvent` is append-only. A later opinion points to `supersedes_feedback_id`; it never
updates the earlier row. The transaction that records feedback must:

1. claim the Telegram update ID for transport deduplication;
2. verify the sender is allowlisted and equals `target.owner_id`;
3. verify `chat.type == private`, `chat.id == sender.id` and the target's owner chat;
4. check the learning epoch, target kind, digest, expiry and permitted action;
5. compare-and-swap the unconsumed nonce;
6. append the feedback event and increment the job's monotonic feedback revision;
7. append a redacted audit event.

These checks and writes form one transaction. Both update-ID deduplication and nonce consumption are
required. A later correction or superseding opinion uses a newly issued target and nonce; one tap
cannot contribute evidence twice.

Candidate rejection and an evaluation dispute are hard vetoes. Their transaction also closes a
matching open trial only when learning epoch, trial ID, generation, candidate-record digest, base
lesson-set digest and base revision all match. It never writes the stable pointer. If the candidate
has already been promoted, the event instead makes a separate guarded rollback decision eligible;
that decision can restore the parent only when the stable digest and revision still identify the
same promotion. Promotion independently rechecks the latest feedback revision and unresolved vetoes,
so a racing reject either wins the close or makes promotion's compare-and-swap fail.

The audit stores IDs, digests, signal kind and payload size. It never stores correction text.

### 12.3 Signal strength and effects

| Feedback | Meaning | Allowed control-plane effect |
|---|---|---|
| useful / not useful | Weak sentiment about one delivered result | Supporting or contradicting evidence; a negative trial result may cause precautionary fallback without a claim that the lesson caused the problem |
| result correction | Owner-attested expected behavior for that occurrence | Strong reflection input; may satisfy the owner-evidence arm for a one-run trial |
| evaluation confirm | Owner explicitly agrees with the bound evaluation | Immutable `owner_confirmed` claim for that evaluation; no deterministic upgrade |
| evaluation dispute | Owner rejects the bound evaluation | Blocks dependent admission or promotion until a new decision resolves it |
| candidate approve | Owner consents to trial of the exact digest | Satisfies the owner-review predicate; all security and consistency gates still run |
| candidate reject | Owner vetoes the exact digest | Blocks admission or closes the exact trial |
| candidate edit | Owner supplies replacement intent | Creates a new immutable candidate-record digest; prior approvals and receipts do not carry over |

Silence has no weight. An approval of one candidate does not approve descendants. Owner feedback
never produces `deterministically_verified`.

### 12.4 Telegram binding

The canonical M1 transport uses an `fb:` callback namespace and a durable nonce. The callback
router dispatches `apr:` to tool approval and `fb:` to feedback before either handler claims the
update. Feedback does not reuse approval rows, approval FSM states or run suspension.

Every feedback-bearing run result, evaluation review and candidate review or edit notice commits its
`FeedbackTarget` and all outbox chunks in one transaction. Multipart delivery associates every
chunk with the same target and places the keyboard on the final chunk only. If Telegram accepts a
send and `markSent` fails, the outbox may resend. Both visible copies still carry the same nonce, so
callback feedback resolves.

Callbacks without verifiable sender, private chat and message context fail closed. A message-ID-only
reply or reaction to an earlier visible copy whose send was never recorded cannot be guessed from
chat, time or nearby deliveries. It appends no feedback event and offers a fresh bound control.

The current client requests neither reaction updates nor reply metadata. Native reactions and
explicit reply-based correction may adapt into the same events after the product verifies
authenticated private-DM behavior. Aggregate reaction-count updates lack an authenticated actor and
cannot record owner feedback.

Free-form correction and candidate edit use a durable one-shot `FeedbackInputChallenge`. It binds
the owner, private chat, exact target and digest, purpose (`result_correction` or `candidate_edit`),
prompt outbox/message identity, learning epoch, expiry and state. The router checks this flow before
generic text, confirmation and normal-turn routing. It atomically consumes the challenge and appends
the feedback event, or does neither. An ordinary reply or the word `yes` remains inert without this
bound challenge.

## 13. Candidate admission

### 13.1 Candidate shape

A candidate contains one complete replacement lesson set. It never means `stable + candidate`.
That rule keeps the cap, digest and attribution explicit and prevents hidden trial stacking.

The candidate binds:

- its candidate-record digest, exact base lesson-set digest and base revision, and distinct
  replacement lesson-set digest;
- the learning epoch and a frozen source-evidence and feedback cutoff;
- normalized reusable issue classes;
- a `CandidateSourceManifest` containing the exact evidence, evaluation, feedback, base lesson-set
  and predecessor-candidate edges plus the reflector-carrier digest;
- one closed origin: `reflection(operation_id, prompt_and_schema_versions)` or
  `owner_edit(feedback_event_id, predecessor_candidate_id)`.

The reflector returns lesson payload only. Trusted code attaches job, epoch, base, cutoff, operation
and manifest fields. Owner edits create a new candidate record and replacement lesson set; prior
approvals and evidence claims remain bound to the predecessor digest.

### 13.2 Deterministic validator

The same validator runs on reflection output, owner edits and every future candidate source before it
persists a `LessonSet` or opens a trial. It enforces:

- a closed, versioned JSON schema and canonical encoding;
- a finite lesson count plus per-lesson, set and UTF-8 byte caps;
- project-standard grapheme limits and explicit NFKC normalization;
- rejection of control, invisible, zero-width and bidirectional formatting scalars;
- secret-value, token-shape and high-entropy scans using the loaded redaction set;
- the first rollout's versioned printable-ASCII plus safe-whitespace repertoire; a broader language
  repertoire requires a versioned mixed-script and confusable profile;
- rejection of known syntactic URI, address, email, handle, path, command and recipient operands;
- leakage comparison against the exact frozen reflection carrier for every job, including bounded
  private and source-text substring indexes; an adapter may add task-specific IDs and selectors;
- exact job, base, source and schema bindings.

Lesson prose may express a semantic preference, but it cannot durably introduce a recognized
authority-bearing operand. An owner mention of an operand inside feedback does not approve it. The
ordinary runtime may still let the model propose tool operands from task context; existing
canonicalization, containment, egress and approval policy remains the authority boundary.

The validator stores only a digest and reason code for rejected model output. It does not log or
persist the rejected body. Owner-authored correction text follows the existing local user-data
policy: the store keeps bounded bytes for provenance, while the learning provider receives only a
policy-approved, redacted projection.

Lexical checks provide hygiene and leakage control. They cannot find every encoded destination,
semantic paraphrase, prompt injection or policy-bypass intent. A poisoned lesson may still influence
safe calls already inside the scheduled job's ordinary authority. Security continues to rely on
untrusted fencing, initial taint, the tool policy gate, canonicalization, endpoint pinning, approvals
and blast-radius caps. A task that cannot accept this residual requires a narrower tool allowlist or
report-only runtime outside the generic lesson mechanism.

### 13.3 Admission gate

Admission requires:

- a repeatable job with a future execution path;
- an immutable candidate whose epoch, base digest and base revision still match stable state;
- a compatible evidence cohort or explicit owner correction/approval;
- no unresolved owner dispute or candidate rejection;
- successful schema, leakage and authority validation;
- no hard deterministic adapter failure;
- available global and proactive learning budget;
- no current nonterminal trial for the job.

Passing admission means that the candidate has enough support for a bounded experiment. It does not
mean that the candidate improved the task. Trial opening is one transaction: compare-and-swap the
learning epoch, stable digest and revision; verify a repeatable non-cancelled job, the feedback
cutoff and absence of a nonterminal trial; then insert the lease and immutable admission receipt.
The database's one-open-trial constraint is a second guard. A stale candidate cannot be rebound to a
new base after a CAS miss.

## 14. Trial, promotion and fallback

```text
TRIAL
  -> ACTIVE_HEURISTIC
  -> ACTIVE_VERIFIED
  -> ROLLED_BACK
```

`ACTIVE_HEURISTIC` means the bounded observational and owner gates passed without deterministic
proof. `ACTIVE_VERIFIED` additionally requires the exact adapter receipt from section 11.4.

### 14.1 Trial lease

One job may have one nonterminal trial. The lease records:

- trial ID, learning epoch and generation;
- job ID, candidate-record digest, base lesson-set digest and revision, and replacement lesson-set
  digest;
- absolute UTC assignment and decision deadlines fixed at admission;
- maximum assignments and assigned count;
- fixed evidence cohort cutoff and feedback revision;
- lifecycle and close reason.

The database enforces no stacking. M1 does not require a queue of stale candidates. A new candidate
may remain recorded, but it cannot open a trial until the prior trial settles and its base still
matches.

Each created run consumes one assignment, including a run that later fails for technical reasons.
Only runs with the exact trial digest, a settlement receipt, eligible evidence and a completed
evaluation count toward positive support. This split bounds exposure while preventing infrastructure
failures from becoming evidence for the candidate.

Once the assignment deadline or assignment limit closes admission, new fires use the stable digest.
The trial enters a draining state until assigned runs settle or its decision deadline expires. Both
deadlines are persisted absolute values and are never recomputed on restart or resume. Decision
expiry terminally resolves a draining trial as insufficient evidence. The promotion gate evaluates
one fixed cohort, which prevents early favorable results from selecting the decision set.

### 14.2 Immediate stop conditions

The control plane closes the exact trial and uses stable state for future fires after:

- a critical task or safety failure;
- a deterministic regression or hard adapter veto;
- explicit candidate rejection;
- an owner dispute that invalidates required evidence;
- repeated negative owner feedback under the trial, as a precautionary policy;
- trial-state corruption or base-pointer mismatch;
- job cancellation.

A negative result may justify precautionary fallback without proving that the candidate caused it.
The decision receipt records that distinction.

Every close or fallback is one transaction with this predicate:

```text
learning epoch, trial ID and generation match
candidate-record and replacement lesson-set digests match
base lesson-set digest and revision match
trial state permits the decision
job state permits the decision
```

The transaction inserts an immutable decision receipt and terminalizes that exact trial. Ordinary
trial fallback never writes the stable pointer because the trial never replaced it. A CAS miss is
stale or idempotent and cannot close a newer trial by `job_id` alone. Job cancellation either closes
the exact trial in its own transaction or wins through the same status predicate at provider start,
admission and decision boundaries.

### 14.3 Promotion and insufficient evidence

Promotion executes one transaction with this predicate:

```text
learning epoch matches
trial ID and generation match
candidate-record and replacement lesson-set digests match
base lesson-set digest and revision match
trial state permits decision
stable pointer and revision still equal the recorded base
job is not cancelled
feedback revision matches the reviewed cutoff
no unresolved candidate reject or dependent evaluation dispute exists
any required owner approval binds the exact candidate-record digest
all required gate receipts match their versions
```

The transaction inserts a decision receipt, updates the stable pointer and revision, and closes the
trial. A CAS miss yields a stale decision. The worker does not retry it against a new base.

The decision operation freezes the current feedback revision after assignment closes. Any later
feedback event invalidates that decision attempt; the worker does not move its cutoff forward and
retry the same promotion hypothesis.

Heuristic acceptance requires positive eligible observations under the M2 rule. Trial expiry,
silence, evaluator errors and absence of contradiction do not count as support. Insufficient evidence
at the decision deadline closes the trial without promotion. M2 may permit one explicit bounded
extension, but M1 forbids implicit renewal.

An adapter may upgrade the exact active digest to `deterministically_verified` through another
receipt. A later surface-version mismatch removes the effective verification claim or requires
revalidation; it does not silently rewrite lesson bytes.

### 14.4 Active rollback

An owner veto, critical failure or verified regression discovered after promotion may make an active
rollback eligible. A separate transaction checks the learning epoch, promotion decision ID,
candidate-record and replacement lesson-set digests, retained base lesson-set digest, and the exact
current stable digest and revision. It also requires the exact rollback-trigger ID, digest and
version. An owner-feedback trigger must remain effective, not superseded, and match the frozen
feedback revision; a critical-failure or regression trigger must match its immutable receipt and
gate version. The transaction then inserts a rollback receipt, compare-and-swaps the stable pointer
back to the retained base, increments its revision and marks the promoted activation `rolled_back`.

The rollback cannot overwrite a later promotion or owner change. A CAS miss is stale and never
retargets a newer stable set. Recording owner feedback only makes this decision eligible; the
feedback handler does not update stable state itself.

## 15. Learning operations, budgets and restart

### 15.1 Operation identity

Each evaluation and reflection call has a durable `LearningOperation` with:

- operation ID, job ID and phase;
- source run, evaluation or evidence-set digest;
- learning epoch, exact model-visible carrier digest and frozen source cutoff;
- prompt, schema and rubric versions;
- configured route and provider-call ID;
- preflight token and cost estimate;
- attempt exposure, usage identities and cost;
- monotonic state and terminal cause;
- creation, claim, start and finish times.

The state machine is:

```text
PENDING -> CLAIMED -> STARTED -> COMPLETED
                  |           -> FAILED
                  |           -> INTERRUPTED_UNKNOWN
                  -> FAILED_NO_CALL
                  -> CANCELLED
```

A `CLAIMED` operation is structurally unable to dispatch. Before HTTP handoff, one transaction
rechecks job status, learning epoch, privacy policy and global plus proactive breakers, then commits
`STARTED` with a unique local call ID, route and preflight reservation. A no-call refusal moves
directly to `FAILED_NO_CALL` or `CANCELLED`. A worker may reclaim `CLAIMED` only while durable state
proves that no provider call started.

A process restart treats every prior-process `STARTED` operation as `INTERRUPTED_UNKNOWN` and never
automatically resends that logical inference. One `writeMapping` recovery transaction inserts any
missing conservative reservation or ceiling under the saved unique call ID and transitions the
operation to `INTERRUPTED_UNKNOWN`. It cannot terminalize the operation while omitting an ambiguous
call from global or proactive totals.

After a response, one `writeMapping` with `state == STARTED` inserts exactly one structured phase
result or rejection, its usage linkage and the terminal operation state. The logical key includes
phase, source digest and prompt, schema and rubric versions. This yields at most one durable result
per logical operation and exactly-once database commit semantics when a result exists. It does not
claim exactly-once wire dispatch or provider billing. A later owner- or epoch-authorized synthesis
uses a new operation and call ID.

### 15.2 Usage attribution

Learning usage stays separate from task-run totals. The persistence model adds a nullable learning
operation relation or equivalent accounting scope to `provider_usage`.

- Global day totals include all usage rows, as they do now.
- Proactive totals include usage owned by scheduled and heartbeat runs plus scheduled-learning
  operations.
- Task-run denormalized totals include only provider calls that executed that task.
- Learning operations use their own per-call output, token, wall-clock and retry caps.
- The global and proactive breakers run before each learning provider call.

The implementation must not attach a multi-run reflection call to one completed source run or create
a fake `RunState` row. Evaluation and reflection can reuse the existing `LLMProvider`, structured
output, route, accounting and budget concepts. Code should extract a shared helper from
`ScheduleDraftParser` only if the concrete implementation would otherwise duplicate those paths.

### 15.3 Failure propagation

- Task output and its outbox intent commit before learning begins; network delivery need not finish.
- An evaluation failure leaves the run evaluation pending or terminally failed under its operation
  policy; it starts no reflection.
- A reflection failure creates no candidate.
- A candidate-validation failure creates only a rejection receipt.
- A promotion failure leaves the stable pointer unchanged.
- Repeated `uncertain` or infrastructure failures cannot keep a trial alive beyond its assignment
  and decision deadlines.

### 15.4 Transaction and restart matrix

| Boundary | One durable transaction | Crash or replay result |
|---|---|---|
| Fire and binding | advance occurrence, insert trigger and pending run, pin epoch and effective lesson-set digest, consume one trial assignment and write audit | Before commit, none exist; after commit, initial run and resume use the exact binding |
| Segment facts | append ordered tool lifecycle facts, route and surface receipt with the segment or suspension commit | Duplicate identity must match; missing final disposition makes later evidence incomplete |
| Terminal and settlement | terminal state plus receipt commit together; the final available fact and settlement commit together | Lane finalizer settles live work; boot finalizer marks prior-process gaps incomplete or unknown |
| Evidence and eligibility | verify receipts and source digests, snapshot facts, insert evidence and deterministic classification | Unique evidence and classifier key make replay idempotent; no evaluator sees a partial snapshot |
| Feedback notice | insert target or input challenge plus every outbox chunk | Retry carries the same opaque target; no committed notice means no valid feedback action |
| Feedback event | claim update ID, consume nonce or challenge, append event and audit, increment feedback revision and apply an exact trial veto when required | All effects occur once; a conflicting replay is stale |
| Provider start | validate epoch, job, privacy and budgets, reserve accounting and commit call ID plus `STARTED` before HTTP handoff | One boot transaction records missing conservative usage and moves prior-process `STARTED` to unknown; it is not resent |
| Provider result | insert one structured result or rejection, usage and terminal operation state | Replay is exact-idempotent; a conflicting second result is rejected |
| Trial admission | compare epoch, stable digest and revision, job and feedback state, then insert lease and admission receipt | No partial lease; replay is idempotent or stale |
| Promotion | compare exact trial, base, epoch, feedback and gate revisions, insert receipt, update stable pointer and close lease | A CAS miss never retries against a new base |
| Fallback or cancel | compare exact trial and base, insert receipt and close lease without rewriting stable state | A CAS miss cannot close a newer trial |
| Active rollback | compare exact promotion, trigger digest or feedback revision, epoch and current stable revision, insert receipt and restore its retained base | A stale or superseded trigger cannot overwrite a later stable decision |
| Purge | raise epoch and barrier first; delete only after old-epoch work settles | Late calls can record usage but cannot repopulate purged learning state |

## 16. Security and authority

### 16.1 Authority matrix

| Input | May influence task strategy | May authorize trial | May change stable pointer directly | May expand tools, policy or targets |
|---|---:|---:|---:|---:|
| LLM evaluation | yes | supports gate | no | no |
| LLM reflection | proposes only | no | no | no |
| Owner reaction | weak evidence | supports gate | no | no |
| Owner correction | yes | supports one-run admission | no | no |
| Owner candidate approval | yes | satisfies owner-review predicate | no | no |
| Deterministic adapter | supplies scoped facts or veto | supports gate | no | no |
| Promotion transaction | no | applies completed gate | yes, through CAS | no |
| Rollback transaction | no | applies a bound veto or regression decision | yes, through CAS | no |

The candidate cannot activate itself. The feedback handler cannot activate or roll it back. Only a
promotion or active-rollback decision transaction may update stable state.

### 16.2 Policy invariants

- Learning records never alter `ScheduledJob.prompt`, recurrence or owner identity.
- Lessons never alter the tool registry, risk metadata, approval policy, policy version or model
  route.
- Learning records are never parsed or interpolated directly into tool arguments, delivery targets
  or owner configuration. Ordinary tool operands remain model-proposed values that existing code
  canonicalizes and gates.
- The model never selects an evaluator adapter.
- Evaluation and reflection receive no tools.
- Learning failures cannot relax the ordinary proactive runtime or its budgets.
- Every store maps GRDB failures through `MappedDatabase.readMapping` and `writeMapping`.

### 16.3 Private data

Learning artifacts derive from owner prompts, outputs and tool evidence, so the product treats them
as owner data. Learning preflight applies an explicit exact-secret redaction set, secret-shape guard,
private-evidence rules and provider policy to the exact serialized `EvaluatorCarrier` or
`ReflectorCarrier`. The persisted carrier digest must match the checked bytes. A policy-denied
projection yields `insufficient_evidence`; the worker does not weaken the guard to obtain an
evaluation.

The final output may contain private task material that the primary configured provider already saw.
The RFC does not treat a second provider call as automatically permitted. The learning preflight
must apply the configured provider and privacy policy to the exact learning carrier and fail closed.

## 17. Retention, export and purge

Cancel and purge have different meanings.

- Cancelling a job stops future scheduled occurrences and learning promotion. It retains history.
- Purging job learning state is a separate confirm-gated owner action.

The data lifecycle covers run bindings, receipts, tool facts, evidence, evaluations, feedback,
candidates, lesson sets, trials, operations and decisions. These records never enter FTS or global
memory.

An owner export includes active lesson bytes, evidence-strength labels, evaluations, feedback and
provenance in a bounded structured form. It uses the authenticated, confirm-gated owner control
path, writes an immutable manifest to a no-follow owner-only `0600` file below the application state
root and reports that path only to the fixed owner DM. No LLM call participates, and no lesson,
evaluator or tool selects the scope, path or recipient. This is ordinary owner-data export, not a
general RL trajectory exporter. Raw run or tool trajectories, private tool observations and
provider replay state are absent.

Purge is a durable barrier, not one best-effort delete. Its first transaction:

1. marks job learning `purging` or disabled and increments its monotonic learning epoch;
2. invalidates outstanding feedback nonces and input challenges;
3. closes the exact trial, blocks new lesson-conditioned fires and marks pending or claimed learning
   operations terminal;
4. compare-and-swaps the stable pointer to the canonical empty set;
5. records the purge scope and provenance cutoff.

Every binding, feedback target, operation, candidate and trial carries the epoch. Provider-start,
result, admission, promotion and fallback transactions compare it. Late results from an old epoch
may record mandatory usage, but cannot recreate an evaluation, candidate or active set.

A provider call already sent cannot be recalled. Purge does not report completion until every live
lesson-conditioned run and `STARTED` learning operation from the old epoch has settled. The owner may
choose normal cancellation for live runs or wait for settlement; lesson bytes remain pinned until
that choice completes. A final transaction then:

1. traverses immutable candidate-source manifest edges and invalidates every dependent decision and
   lesson set;
2. deletes job-scoped lesson bytes, canonical output blobs, serialized evaluator and reflector
   carriers, correction and edit payloads, evidence excerpts and other owner-derived payload columns;
3. deletes evaluations, candidates, evidence and tool facts for the target scope;
4. deletes bindings, manifests, operations, decisions and receipts, or reduces each retained row to
   a strictly content-free tombstone required by audit policy;
5. rebuilds or removes any derived indexes;
6. marks the purge receipt complete.

Lesson blobs are job-scoped in M1 and are deleted rather than marked invalid. A future shared
content-addressed store would require reference counting before it could retain a blob.

Source-run or conversation deletion joins the same epoch barrier and must not leave an active lesson
that still encodes the deleted private fact. Exact manifest edges, rather than a cutoff digest alone,
make the invalidation query deterministic.

M2 pins numeric retention windows. M1 requires finite caps and a purge path before production
activation.

## 18. Module placement

| Module | Milestone responsibility |
|---|---|
| `ClawCore` | Sendable domain values, lifecycle reducers and minimal store/evaluator protocols; no page types |
| `ClawData` | GRDB migrations, content-addressed lesson storage, durable operation claims, CAS and retention queries |
| `ClawAgent` | Pinned lesson context section, initial-taint propagation and existing ordinary task runtime |
| `ClawGateway` | Learning background service, eligibility orchestration, feedback routing and owner delivery |
| `ClawLLM` | Existing provider adapters and structured-output transport; no learning policy |
| `ClawTools` | Existing policy gate plus reusable secret and authority-operand validation primitives |
| `ClawTelegram` | Narrow callback/reply wire fields and transport mapping; no learning state machine |
| `ClawEvaluation` | M3 generic benchmark orchestration and the first page-change deterministic adapter; no daemon dependency |
| `clawd` | Composition only |

The implementation should search for and reuse `ProviderUsageAccountant`, `BudgetGate`, structured
response formats, `ExfilArgGuard`, callback nonce handling, outbox chunk binding and GRDB mapping
helpers before it adds another helper or protocol.

## 19. Parameters deferred to M2

M2 must decide and version:

- issue-class normalization;
- the natural-run evidence window and minimum support count;
- reflection timing and source cutoff rules;
- lesson count and text caps within the finite M1 bounds;
- trial assignment count, assignment deadline and decision deadline;
- heuristic acceptance and regression rules;
- the treatment of contradictory feedback;
- candidate replacement and consolidation policy;
- lesson staleness, supersession and revalidation;
- numeric retention windows;
- default evaluator rubric and prompt schemas.

M2 cannot change these M1 invariants:

- one attempt identity per run;
- job-scoped lessons;
- stable pointer plus separate bounded trial;
- no trial stacking;
- owner feedback through the common gate;
- no authority expansion;
- evaluator blindness to lesson condition;
- heuristic and deterministic evidence separation;
- global and proactive usage accounting;
- finite failure and restart behavior.

## 20. Validation and implementation sequence after M2

M3 lands the generic harness and fresh page-change adapter before production activation. It freezes
the new corpus, split, scorer, oracle and gates described in section 11.4, then exercises clean,
trial, promoted and post-restart conditions through generic contracts. No M0 fixture can be promoted
into new verification evidence.

M4 then lands the smallest usable production vertical in this order:

1. **Durable binding and evidence substrate.** Add run bindings, terminal and settlement receipts,
   lossless bounded tool facts, evidence sealing and lifecycle queries.
2. **Pinned lesson read path.** Add content-addressed job lesson sets, stable state, the dedicated
   context row and initial taint. Prove exact digest reuse after restart.
3. **Learning operations.** Add eligibility, tool-free structured evaluation and reflection with
   global plus proactive accounting and crash-safe operation states.
4. **Owner feedback.** Add durable targets, `fb:` callback routing, typed events and feedback-driven
   reflection or veto.
5. **Bounded trial control.** Add single-trial assignment in the fire transaction, fixed cohorts,
   CAS promotion and fallback.

As each production increment lands, the M3 harness reruns the applicable generic lifecycle and
page-change checks. Page types remain in `ClawEvaluation`; M4 supplies only the generic adapter
contract and trusted receipt ingestion.

Each increment must leave ordinary scheduled execution usable when learning is unavailable. A
learning degradation detected inside the fire transaction may select the empty or stable set and
notify the owner. After binding, the run either loads its exact lesson bytes or fails before provider
dispatch; it never substitutes another set. Neither path can block the task indefinitely or widen
authority.

## 21. Rejected alternatives

### Page-specific production core

A `PageChangeLearningCoordinator` would make the benchmark the product boundary. The generic core
keeps page state inside an adapter.

### Second task-attempt entity

`run_id` already owns the lifecycle spine and related messages and usage. A second attempt row would
duplicate identity and create reconciliation work. The design adds a one-to-one learning binding.

### Global memory for lessons

Global memory would leak behavior between jobs, mix provenance and expose lessons to unrelated
tasks. Lesson lookup uses only the pinned job and digest.

### Trial candidate as the active pointer

A crash could leave unaccepted bytes active and a later rollback could overwrite a newer decision.
The stable pointer remains untouched until promotion.

### Evaluator receives applied lessons

That input creates framing and confirmation bias. The control plane retains lesson provenance while
the model-visible evaluator input omits it.

### Audit as learning evidence

Audit is best-effort observability and does not preserve the required tool facts. The terminal path
writes dedicated receipts and evidence.

### Runless learning usage with no proactive scope

Current origin totals cannot count a row with no run. Learning operations receive their own usage
relation and join into the proactive total without contaminating task-run totals.

### Exactly-once LLM inference

The provider exposes no cross-process idempotency guarantee. Durable operation states choose a
conservative unknown outcome instead of reissuing ambiguous work.

### Semantic prompt-injection classifier as a security gate

No text classifier can prove that lesson prose lacks bypass intent. The design limits payload shape
and operands while code policy remains authoritative.

## 22. M1 acceptance mapping

This RFC resolves the Issue 167 acceptance criteria as follows:

- sections 1 and 2 define capability and evidence guarantees;
- sections 4 and 5 keep `run_id` as the sole attempt identity;
- sections 1, 11.4 and 18 isolate page-change behind an adapter;
- section 7 pins occurrence and effective lesson digest in the fire transaction;
- section 9 covers every terminal path and post-terminal settlement;
- sections 10 and 11 separate eligibility, evaluation and reflection;
- section 12 makes owner feedback durable, authenticated, typed and append-only;
- sections 13, 14 and 16 prevent feedback or candidates from expanding authority;
- section 14 defines one finite trial, no stacking and CAS decisions;
- sections 5.3 and 11 distinguish heuristic, owner and deterministic evidence;
- section 15 accounts for learning usage and ambiguous restart outcomes;
- section 15.4 fixes transaction, replay and crash-restart behavior;
- section 8 applies initial taint before memory selection and tool dispatch;
- sections 13.2 and 16 keep prompt-injection security in code;
- section 17 extends retention, export and purge to derived learning data.

No unresolved P0 architecture or security decision remains in M1. M2 owns the finite algorithm
parameters listed in section 19.
