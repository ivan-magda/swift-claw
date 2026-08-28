# RFC: Architecture and security boundaries for self-improving scheduled tasks

| | |
|---|---|
| **Status** | Proposed — M1 / Issue #167 |
| **Date** | 2026-08-28 |
| **Parent** | #115 |
| **Evidence baseline** | #118, frozen Protocol 0.6 |
| **Production scope** | Generic job-scoped learning for every scheduled task swift-claw can execute |
| **First deterministic adapter / benchmark** | Scheduled page-change monitoring |

## 1. Decision summary

Every created scheduled run participates in one generic, job-scoped learning control plane. The existing `run_id` remains the only task-attempt identity. The scheduler atomically binds each created run to the exact logical occurrence, job definition, execution surface, fire kind, and effective lesson-set digest. The ordinary proactive `AgentRuntime` executes the task; learning never replaces or bypasses that path.

After a run becomes terminal, the system writes an immutable terminal receipt and later seals a bounded learning-evidence projection after late usage and approval observations settle. A deterministic eligibility classifier decides whether that evidence may reach a fresh, tool-free evaluator. Evaluation and reflection are separate LLM operations with durable operation identities and budget accounting. Reflection may propose only an immutable complete replacement lesson set; it cannot mutate scheduler, runtime, tool, approval, model-route, recipient, path, command, destination, or budget authority.

Owner feedback is a durable, authenticated, append-only learning signal bound to exact subjects and digests. It may support, contradict, correct, approve, reject, edit, confirm, or dispute learning artifacts, but it never directly changes the stable lesson pointer.

A job owns one stable lesson-set pointer and at most one bounded trial override. Trial assignment is consumed atomically only when a run is actually created. Trials cannot stack. Promotion is a compare-and-swap (CAS) from the recorded incumbent digest to the candidate digest; fallback closes the trial while leaving the stable pointer untouched.

The capability guarantee is therefore:

> If swift-claw can execute a scheduled job, the architecture can capture its attempts, classify learning eligibility, accept owner feedback, evaluate eligible evidence, derive job-scoped lesson candidates, trial candidates on future occurrences, and promote or fall back without expanding the job's authority.

This is **not** a guarantee that every scheduled task can be objectively verified or will improve. For subjective tasks, natural runs, owner feedback, and LLM evaluation remain heuristic or owner-attested evidence. Only a deterministic adapter with a named frozen oracle/dataset may issue a scoped `deterministically_verified` receipt.

No unresolved P0 architecture or security blocker remains for implementation planning. Exact learning-policy parameters are intentionally deferred to M2 (§16).

## 2. Non-negotiable invariants

1. **One task-attempt identity.** `runs.id` / `run_id` is canonical. Learning adds immutable bindings and receipts; it does not create a parallel attempt entity.
2. **Generic core.** The core contains no page, HTML, selector, region, DOM, or page-snapshot types. Page-change behavior lives behind an adapter.
3. **Ordinary execution path.** Scheduled tasks still enter the existing session lane and `TurnRunner`/`AgentRuntime` path with existing proactive budgets, policy, tools, approvals, taint, and delivery semantics.
4. **Lessons are data, not authority.** Lessons may influence task strategy only. They cannot modify prompt ownership, schedule, budgets, model route, tool catalog, risk tiers, approvals, recipients, paths, commands, destinations, or policy.
5. **Initial taint.** A non-empty effective lesson set marks the run tainted before sensitive-memory selection, the first provider call, and the first tool-policy decision. This is conservative: learned text is durable model-generated/untrusted payload.
6. **Fresh learning contexts.** Evaluation and reflection receive no tools, workspace memory, session history, approval capability, or provider replay state.
7. **Blind evaluation.** Evaluators never see lesson text/IDs, stable/candidate digests, trial condition, prior scores, promotion state, or expected improvement.
8. **Deterministic eligibility first.** No evaluation/reflection LLM spend occurs before technical eligibility classification.
9. **Owner feedback is evidence, not activation.** Feedback cannot update the stable pointer or expand authority.
10. **Single bounded trial.** One stable pointer, at most one trial override, no stacking.
11. **Positive evidence required.** Silence, missing feedback, evaluator failure, interrupted learning operations, and ineligible runs never count as positive trial evidence.
12. **No exactly-once LLM claim.** Database effects are idempotent; external inference is not. Ambiguous crash windows become `interrupted_unknown` and are not blindly replayed.
13. **Derived-data lifecycle follows source provenance.** Export, retention, purge, and deletion cover learning derivatives. Removing source private data must not leave an active lesson encoding that fact.

## 3. Existing seam map

M1 extends existing seams rather than introducing a second scheduler/runtime.

### 3.1 Scheduler and fire transaction

Current `ScheduledJobStore.claimAndFire` already performs the occurrence compare-and-advance and then creates the session trigger, `PENDING` run, and audit in one database write. `fireNow` reuses the same fused insert set without advancing the schedule. The existing overlap guard prevents a second live run on the job session.

**M1 extension:** the same successful fire transaction must additionally persist a `learning_run_binding` keyed by `run_id` containing:

- `job_id`;
- logical `occurrence_at`;
- `fire_kind` (`scheduled`, `run_now`, later other explicit kinds);
- immutable `job_definition_digest`;
- `execution_surface_version` / digest;
- effective `lesson_set_id` and `lesson_set_digest` (empty-set digest allowed);
- trial identity/generation when the run consumed a trial assignment;
- schema version and creation timestamp.

The transaction resolves trial expiry first, then uses the existing occurrence/overlap guard, creates `run_id`, pins stable-or-trial lessons, and consumes a trial assignment. A CAS loser, misfire skip, or overlap skip creates no run and consumes no trial assignment.

### 3.2 Run persistence and terminal commits

Current `RunStore` owns `PENDING → RUNNING` pickup, completed/degraded commits, cancellation/supersession, approval suspension/resume, and boot reconciliation. `commitAssistantTurn` already fuses assistant output, `DONE`, provider usage, and outbox; degradation paths fuse failure state and delivery.

**M1 extension:** every legal transition into a terminal run state (`DONE`, `FAILED`, `CANCELLED`, `SUPERSEDED`, including boot reconciliation) writes exactly one immutable `learning_terminal_receipt` in the same transaction as the state transition. The receipt is intentionally small and settlement-independent. It proves what terminal state won and when.

A later evidence sealer reads the terminal receipt plus settled run-linked facts and writes one immutable bounded evidence projection or one technical exclusion. A normal `DONE` path may seal evidence in the terminal transaction when all required facts are already complete; cancellation/supersession and ambiguous approval/late-usage paths must not assume settlement.

### 3.3 Context building and taint

Current `TurnRunner` loads a bounded context snapshot, obtains global and proactive spend totals, then calls `ContextBuilder.assemble`. `AgentRuntime.runTurn` receives session taint/private-data state before any tool work.

**M1 extension:** effective lessons are a distinct context section with a trusted harness wrapper and bounded **untrusted payload**. They are job-scoped and never stored in session messages, global memory, workspace memory, or FTS. If the effective lesson set is non-empty, the run starts tainted before context memory selection. The lesson section is included only for `RunOrigin.scheduled` executions with a valid run binding.

### 3.4 Policy and approvals

Current policy/approval boundaries bind consequential actions to canonical arguments, policy version, owner identity, and durable approval state. These remain authoritative.

**M1 extension:** lessons cannot supply policy operands. Any lesson text that appears to request a new tool, destination, recipient, path, command, permission, approval bypass, model route, schedule, or budget is inert text and is also rejected by candidate admission as defense in depth. Existing code policy remains the security boundary.

### 3.5 Usage and budgets

Current `UsageStore` supports run-linked and runless provider usage; proactive totals are derived from scheduled/heartbeat run origins.

**M1 extension:** learning calls are **runless learning operations**, not fake agent runs. Each operation records its own durable operation ID and usage references. Its provider usage contributes to:

- the existing global daily budget; and
- the proactive/learning budget pool defined for scheduled work.

Owner delivery never waits for evaluator or reflector calls. A budget stop skips learning spend; it never delays or changes the already-completed task result.

### 3.6 Telegram owner-feedback binding

Current approval callbacks already demonstrate the required fail-closed pattern: claim Telegram update, numeric-ID allowlist, strict namespace parsing, random nonce lookup, exact owner binding, CAS, audit.

**M1 extension:** feedback uses a separate `fb:` callback namespace and separate learning-feedback tables. It does **not** reuse tool `approvals`, `AWAITING_APPROVAL`, or approval suspension. A feedback target is durable and binds a random one-time callback nonce to owner ID plus exact subject type/id/digest. Native reactions or reply-based correction may later adapt into the same event model.

## 4. Generic architecture

```text
SchedulerService
  │
  ├─ fire transaction
  │    ├─ resolve stable/trial lesson digest
  │    ├─ create ordinary run_id
  │    ├─ pin occurrence + job/execution digests
  │    └─ consume trial assignment if applicable
  │
  └─ TurnEnqueuer → TurnRunner → AgentRuntime → existing policy/tools/outbox
                                │
                                └─ terminal run transaction
                                     └─ immutable terminal receipt

LearningCoordinator (post-delivery, asynchronous)
  ├─ EvidenceSealer
  │    └─ terminal receipt + settled safe facts → sealed evidence | exclusion
  ├─ EligibilityClassifier (deterministic)
  ├─ Evaluator (fresh context, no tools, blind)
  ├─ FeedbackStore / fb: callback adapter
  ├─ Reflector (fresh context, no tools)
  ├─ CandidateAdmissionPolicy (deterministic validation)
  └─ TrialController
       ├─ admit one bounded trial
       ├─ collect eligible evidence
       ├─ promote via stable-pointer CAS
       └─ close/fallback without touching stable pointer

Optional LearningEvaluatorAdapter
  └─ page-change adapter first: frozen inputs + deterministic scorer + fixtures
```

The generic learning layer belongs conceptually beside scheduling/persistence, not inside `AgentRuntime`. `AgentRuntime` consumes a pinned lesson payload and reports ordinary run facts; it does not decide evaluation, reflection, trial, or promotion.

## 5. Generic data model

Names are conceptual M1 contracts; migrations and exact Swift names are implementation work.

### 5.1 `learning_job_state`

One row per scheduled job:

- `job_id` PK/FK;
- `stable_lesson_set_id`, `stable_digest`;
- `trial_id` nullable;
- `generation` monotonic CAS generation;
- timestamps.

The stable pointer is the only production activation pointer.

### 5.2 `learning_lesson_sets`

Immutable complete replacement sets:

- `id`, `job_id`, `digest` UNIQUE;
- bounded ordered lesson payload;
- `base_digest` nullable for initial empty set;
- `created_by` (`reflection`, `owner_edit`, migration/import if ever supported);
- source reflection/feedback IDs;
- schema version, timestamps.

No in-place edit. Owner edit creates a new set/digest.

### 5.3 `learning_run_bindings`

Exactly one per created scheduled `run_id`:

- run/job/occurrence/fire-kind binding;
- job-definition digest;
- execution-surface/schema versions;
- effective lesson-set id/digest;
- stable base digest;
- optional trial id/generation;
- created timestamp.

This is not an attempt entity; `run_id` remains canonical.

### 5.4 `learning_terminal_receipts`

Exactly one immutable row per terminal scheduled run:

- `run_id` PK;
- terminal `RunState` and terminal classification facts available at commit time;
- terminal timestamp;
- receipt schema version/digest.

### 5.5 `learning_evidence`

Exactly one terminal outcome per binding: `sealed` or `excluded`.

A sealed projection contains only evaluator-relevant bounded facts:

- run/job/occurrence bindings and digests;
- terminal classification;
- final output or bounded output/digest according to retention policy;
- tool facts: tool name, status, policy decision, result size, trust/taint flags — **not raw arguments or raw private observations**;
- actual model route and primary-run usage references;
- execution-surface/schema versions;
- optional adapter facts;
- evidence digest and timestamps.

Exclusions carry a typed technical reason. Evidence excludes secrets, provider replay state, audit-log projections, raw tool args, and private raw observations.

### 5.6 `learning_operations`

Durable evaluator/reflector operation record:

- operation ID and kind (`evaluation`, `reflection`);
- job ID and source evidence IDs/digests;
- phase/status (`pending`, `in_flight`, `succeeded`, `failed`, `interrupted_unknown`);
- model route, prompt/schema version;
- attempts, usage/cost references;
- created/started/finished timestamps.

A crash after request dispatch but before durable response commit resolves to `interrupted_unknown`; the same logical synthesis is not automatically replayed.

### 5.7 `learning_evaluations`

Immutable structured evaluator result:

- evaluation ID;
- evidence ID/digest;
- rubric/adapter versions;
- closed result: `no_issue | reusable_issue | transient_issue | uncertain`;
- bounded structured findings/reasons;
- evidence-strength classification (`heuristic` unless a deterministic adapter receipt is separately attached);
- timestamp/digest.

### 5.8 `learning_feedback_targets` and `learning_feedback_events`

Target:

- random one-time callback nonce;
- owner user ID;
- job ID;
- exact subject type/id/digest;
- expiry/consumed state.

Append-only event:

- owner user ID;
- job and run/output identity where relevant;
- optional evaluation/candidate identity;
- typed signal;
- bounded payload;
- Telegram update ID or callback nonce;
- created timestamp;
- optional `supersedes_event_id`.

Signals: `result_useful`, `result_not_useful`, `result_correction`, `evaluation_confirm`, `evaluation_dispute`, `candidate_approve`, `candidate_reject`, `candidate_edit`.

### 5.9 `learning_trials`

- trial ID, job ID;
- base stable digest + candidate digest;
- generation;
- state (`open`, `promoted`, `fallen_back`, `rejected`, `expired`, `exhausted`, `invalidated`);
- assignment deadline;
- maximum assignments and consumed assignments;
- admission reason/evidence IDs;
- timestamps.

At most one open trial per job.

### 5.10 `learning_decision_receipts`

Immutable promotion/fallback/rejection receipts:

- job/trial/base/candidate digests;
- evidence IDs and feedback overlays considered;
- decision + evidence-strength label;
- policy/version inputs;
- CAS generation before/after where applicable;
- timestamp/digest.

Audit rows may reference these receipts, but audit is observability, not provenance.

### 5.11 Optional `deterministic_verification_receipts`

Issued only by an adapter with a deterministic oracle:

- adapter ID/version;
- named frozen dataset/oracle version;
- execution-surface version;
- candidate/base/evidence digests;
- deterministic score/result;
- receipt digest.

A rubric, route, policy, adapter, dataset, oracle, or execution-surface incompatibility requires revalidation or downgrade to heuristic use.

## 6. Lifecycle state diagrams

### 6.1 Evidence and synthesis

```text
created scheduled run
      │
      v
terminal receipt
      │
      v
settlement pending ──technical impossibility──> evidence EXCLUDED
      │
      v
sealed evidence
      │
      v
deterministic eligibility classifier
   ┌──┴─────────────────────────────────────────────┐
   │ eligible                                      │ ineligible
   v                                               v
evaluation op                                  stop (retain evidence)
   │
   ├─ fail/interrupted_unknown ─────────────────> stop
   v
saved evaluation
   │
   ├─ no reflection support yet ────────────────> stop
   v
reflection op
   │
   ├─ fail/interrupted_unknown ─────────────────> stop
   v
immutable candidate
   │
   v
admission validation
   │
   ├─ reject/veto ──────────────────────────────> superseded/rejected