# RFC: Architecture and security boundaries for self-improving scheduled tasks

| | |
|---|---|
| **Status** | Proposed — M1 / Issue #167 |
| **Date** | 2026-08-28 |
| **Parent** | #115 |
| **Evidence baseline** | #118, frozen Protocol 0.6 |
| **Production scope** | Generic job-scoped learning for every scheduled task swift-claw can execute |
| **First deterministic adapter / benchmark** | Scheduled page-change monitoring |

## 1. Decision

Every created scheduled run participates in one generic job-scoped learning control plane. Existing `run_id` remains the only task-attempt identity. The fire transaction binds that run to its exact logical occurrence, fire kind, job-definition digest, execution-surface version and effective lesson-set digest. The task then executes through the ordinary proactive `TurnRunner` / `AgentRuntime` path with existing tools, policy, approvals, budgets and delivery.

After terminal execution, the system records an immutable terminal receipt and seals a bounded evidence projection after late usage/approval observations settle. A deterministic eligibility classifier runs before any learning LLM call. Eligible evidence may enter a fresh, tool-free, procedurally blind evaluator; reflection is a separate fresh tool-free call. Reflection may propose only an immutable complete replacement lesson set.

Owner feedback is durable, authenticated, typed, append-only and bound to an exact subject/digest. Feedback is evidence: it never directly changes the stable lesson pointer or expands task authority.

Each job has one stable lesson-set pointer and at most one bounded trial override. Trials cannot stack. A created run consumes a trial assignment atomically; skips and CAS losers consume none. Promotion compare-and-swaps the stable pointer from the recorded base digest to the candidate digest. Fallback closes the trial and leaves the stable pointer untouched.

**Capability guarantee:** if swift-claw can execute a scheduled job, this architecture can capture attempts, classify learning eligibility, accept owner feedback, evaluate eligible evidence, derive job-scoped lesson candidates, trial them on future occurrences, and promote or fall back without expanding the job's authority.

This does **not** guarantee objective verification or improvement for every task. Natural runs and LLM evaluation are observational/heuristic. Owner feedback establishes owner intent for its bound subject. Only a deterministic adapter over a named frozen dataset/oracle may issue scoped `deterministically_verified` evidence.

No unresolved P0 architecture or security blocker remains. Exact policy parameters are deferred to M2 (§15).

## 2. Non-negotiable boundaries

1. `runs.id` / `run_id` is canonical; no second attempt entity.
2. Generic core contains no page/HTML/selector/region/snapshot types.
3. Scheduled execution remains an ordinary proactive agent run.
4. Lessons are data, never authority: they cannot change job prompt, schedule, budgets, model route, tool catalog, risk tiers, approvals, recipients, paths, commands or destinations.
5. Effective lessons use a trusted harness wrapper around bounded **untrusted payload**.
6. A non-empty lesson set establishes taint before sensitive-memory selection, first provider call and first tool-policy decision.
7. Lessons never enter global memory, workspace memory, conversation history or FTS.
8. Evaluation/reflection use fresh contexts with no tools, workspace memory, session history, approval capability or provider replay state.
9. Evaluator input is blind to lesson text/IDs, active/candidate digest, trial condition, prior scores, promotion state and expected improvement.
10. Deterministic eligibility runs before learning LLM spend.
11. Feedback cannot activate lessons or expand authority.
12. One stable pointer + at most one trial; no stacking.
13. Positive eligible evidence is required for promotion. Silence, evaluator failure and ineligible runs are not positive evidence.
14. Database claims/effects are idempotent; external LLM inference is never claimed exactly-once.
15. Derived learning data follows source provenance through export, retention, deletion and purge.

## 3. Existing-seam map

### Scheduler / fire

`ScheduledJobStore.claimAndFire` already fuses occurrence compare-and-advance with session/trigger creation, `PENDING` run creation and audit. `fireNow` reuses the same insert set without schedule advance; the overlap guard prevents a second live run on the job session.

**Extension:** the same successful fire transaction writes one immutable `learning_run_binding` keyed by `run_id`: `job_id`, logical occurrence, fire kind, job-definition digest, execution-surface/schema version, effective lesson-set ID/digest, stable base digest and optional trial ID/generation. It resolves trial expiry before selection and consumes one trial assignment only after the existing overlap guard permits run creation. Misfire, overlap skip and CAS loser consume none.

### Run persistence

`RunStore` owns pickup, completion/degradation, cancellation/supersession, approval suspension/resume and boot reconciliation. Completed turns already fuse assistant output, `DONE`, usage and outbox.

**Extension:** every legal terminal transition (`DONE`, `FAILED`, `CANCELLED`, `SUPERSEDED`, including reconciliation) writes exactly one immutable `learning_terminal_receipt` in the same SQLite transaction as the state change. A settlement worker later seals evidence or a technical exclusion. A normal `DONE` may seal immediately only when all required facts are already settled; cancellation/supersession and ambiguous late-write paths may not assume this.

### Context / taint

`TurnRunner` loads a bounded snapshot, budgets and `ContextBuilder` output before calling `AgentRuntime.runTurn` with taint/private-data state.

**Extension:** effective lessons are a separate job-scoped context section. The wrapper is harness-controlled; lesson text is bounded untrusted data. Non-empty lessons set initial taint before memory selection, so high-sensitivity memory and tool/exfil policy see the conservative state from the beginning.

### Policy / approvals

Existing canonical-argument, policy-version, owner-binding and approval gates remain authoritative. Candidate text validation is defense in depth only. Lesson text never becomes a policy operand and cannot bypass or weaken approval, exfiltration, SSRF or proactive-budget policy.

### Usage / budget

`UsageStore` already supports run-linked and runless usage and global/proactive totals.

**Extension:** evaluation/reflection are durable **runless learning operations**, not fake agent runs. Their usage counts toward global and proactive/learning budgets. Owner delivery never waits for learning calls.

### Telegram feedback

The existing approval callback path demonstrates the reusable security pattern: atomically claim update, numeric-ID allowlist, strict namespace parse, random nonce lookup, exact owner binding, CAS and redacted audit.

**Extension:** learning feedback uses its own `fb:` namespace, feedback target/event domain and callback handler. It does not reuse tool-approval rows or suspend a run. Native reactions and reply-based corrections may later adapt into the same event type.

## 4. Architecture

```text
SchedulerService
  └─ fire transaction
       ├─ resolve stable/trial lessons
       ├─ create ordinary run_id
       ├─ pin occurrence + digests
       └─ consume trial assignment (if any)
             │
             v
TurnEnqueuer → TurnRunner → AgentRuntime → existing policy/tools/outbox
             │
             └─ terminal transaction → terminal receipt

LearningCoordinator (async; never blocks owner delivery)
  ├─ EvidenceSealer → sealed evidence | technical exclusion
  ├─ EligibilityClassifier (deterministic)
  ├─ Evaluator (fresh, tool-free, blind)
  ├─ FeedbackStore + fb: Telegram adapter
  ├─ Reflector (fresh, tool-free)
  ├─ CandidateAdmissionPolicy (deterministic)
  └─ TrialController → trial → promote CAS | fallback

LearningEvaluatorAdapter (optional)
  └─ page-change first: frozen inputs + deterministic scorer + fixtures
```

The learning subsystem sits beside scheduler/persistence. `AgentRuntime` only consumes a pinned lesson payload and produces ordinary run facts; it does not own evaluation, reflection, trial or promotion.

## 5. Generic data model

Conceptual names are contracts, not M1 migrations.

- **`learning_job_state`** — `job_id` PK, stable lesson-set ID/digest, nullable open trial ID, monotonic generation, timestamps. The stable pointer is the only production activation pointer.
- **`learning_lesson_sets`** — immutable complete replacement sets: job, digest, bounded ordered payload, base digest, source reflection/owner edit, schema version, timestamps. No in-place edit.
- **`learning_run_bindings`** — one per created scheduled `run_id`: job/occurrence/fire-kind, job-definition digest, execution-surface/schema versions, effective lesson-set ID/digest, stable base digest, optional trial/generation.
- **`learning_terminal_receipts`** — one immutable row per terminal scheduled run: run ID, winning terminal state/classification facts, timestamp, schema version/digest.
- **`learning_evidence`** — one terminal result per binding: sealed projection or typed technical exclusion. Projection includes run/job/occurrence bindings, digests, terminal classification, bounded final output or digest, bounded tool facts (name/status/policy decision/result size/trust flags), actual model route, primary-run usage references, versions, optional adapter facts, evidence digest/timestamps. It excludes raw tool args, secrets, private raw observations, provider replay state and audit projections.
- **`learning_operations`** — durable evaluation/reflection operation ID, kind, source evidence, phase/status, model route, schema version, attempts, usage/cost refs, timestamps. Status includes `interrupted_unknown`.
- **`learning_evaluations`** — immutable evidence binding, rubric/adapter versions, closed result (`no_issue | reusable_issue | transient_issue | uncertain`), bounded findings/reasons, digest/timestamp.
- **`learning_feedback_targets`** — random one-time nonce, authenticated owner ID, exact subject type/id/digest, expiry/consumed state.
- **`learning_feedback_events`** — append-only owner ID, job/run/output identity, optional evaluation/candidate identity, typed signal, bounded payload, Telegram update ID or nonce, timestamp, optional superseded-event link.
- **`learning_trials`** — job, base/candidate digests, generation, state, assignment deadline, max/consumed assignments, admission evidence, timestamps. Unique open trial per job.
- **`learning_decision_receipts`** — immutable promotion/fallback/reject decision, base/candidate/trial, considered evidence/feedback, evidence-strength label, policy/version inputs, CAS generations, digest/timestamp.
- **`deterministic_verification_receipts`** (adapter-only) — adapter/version, frozen dataset/oracle, execution surface, subject digests, deterministic result, receipt digest.

Feedback signals are: `result_useful`, `result_not_useful`, `result_correction`, `evaluation_confirm`, `evaluation_dispute`, `candidate_approve`, `candidate_reject`, `candidate_edit`. Candidate edit creates a new immutable digest and invalidates old approvals/support.

## 6. Lifecycle diagrams

### Evidence → candidate

```text
created run
  → terminal receipt
  → settlement
      ├─ impossible/incomplete → technical exclusion
      └─ sealed evidence
           → deterministic eligibility
              ├─ ineligible → retain; no LLM learning call
              └─ eligible → evaluation operation
                   ├─ failed/interrupted_unknown → stop
                   └─ saved evaluation
                        → reflection operation (when policy permits)
                           ├─ failed/interrupted_unknown → stop
                           └─ immutable replacement candidate
                                → admission validation
                                   ├─ veto/reject → inert history
                                   └─ trial admission gate
```

### Candidate / trial / activation

```text
candidate
   │
   ├─ insufficient support ───────────────> inert candidate
   │
   └─ admitted
        v
      TRIAL (base stable pointer untouched)
        │
        ├─ expiry / assignment exhaustion
        ├─ hard security/deterministic veto
        ├─ regression / critical failure
        ├─ owner reject/dispute
        └─ insufficient positive eligible evidence
              └───────────────────────────> FALLBACK / close trial
        │
        └─ acceptance policy satisfied
              → decision receipt
              → CAS stable(base → candidate)
                   ├─ CAS lost → close stale trial
                   └─ CAS won  → ACTIVE; close trial
```

Lifecycle and evidence strength are orthogonal:

```text
lifecycle: candidate | trial | active | rolled_back | superseded
evidence:  heuristic | owner_supported | owner_confirmed | deterministically_verified
```

An active lesson may still be heuristic. `deterministically_verified` is never produced by an LLM evaluator.

## 7. Evidence sealing and eligibility

### Terminal receipt

The terminal receipt is deliberately smaller than evaluation evidence so it can be committed on every terminal path without depending on late writes. Its transaction shares the run-state transition; duplicate terminal handling is `INSERT OR IGNORE`/unique-by-run and must agree with the winning terminal state.

### Post-settlement sealing

The sealer is idempotent by `run_id` + evidence schema version. It waits until required run-linked usage and approval observations are settled. It then writes either:

- `sealed` evidence with an immutable digest; or
- `excluded(reason)` when a safe/complete projection cannot be formed.

Sealing never reads the ordinary audit log as provenance.

### Initial eligibility taxonomy

The deterministic classifier must distinguish at least:

- `eligible_task_evidence`;
- `transient_infrastructure_failure`;
- `policy_or_security_block`;
- `owner_interruption`;
- `insufficient_evidence`;
- `unsupported_terminal_state`.

Provider/storage/credential/budget failures do not create behavioral lessons. Cancellation, supersession and security-policy blocks never enter reflection. A one-shot job may retain evidence/evaluation/feedback, but cannot exercise a trial without another occurrence.

## 8. Evaluator and reflector contracts

### Evaluator

Model-visible input is exactly: frozen job prompt, frozen quality rubric, final output, safe bounded evidence projection, and optional adapter facts. It excludes lessons, lesson IDs/digests, candidate/stable digest, trial assignment, prior score, promotion state and expected improvement.

The evaluator has no tools and returns a closed schema: `no_issue`, `reusable_issue`, `transient_issue`, or `uncertain`, plus bounded structured findings. This is heuristic evidence, not semantic proof.

### Reflector

Reflection is a distinct operation/call. It may receive compatible saved evaluations, compatible multi-run evidence and the current lesson set. It produces **one complete immutable replacement set**, never an imperative control-plane mutation. Evaluation failure cannot start reflection; reflection failure cannot create a candidate.

Compatibility requires matching or explicitly compatible job-definition semantics, evidence schema, execution surface, rubric and adapter version. Incompatible evidence is retained but not silently pooled.

## 9. Candidate admission and authority firewall

Before persistence/trial, deterministic validation checks:

- closed schema and canonical encoding;
- lesson count and per-item/total size limits;
- Unicode normalization and invisible/bidi handling;
- secret/exact-loaded-secret leakage;
- forbidden authority operands: schedule, recipient/chat, model route, budgets, tool/risk/approval configuration, paths, commands, destinations, credentials;
- job binding and incumbent/base digest;
- source operation/evidence integrity.

Text classification/pattern checks are defense in depth only. The actual security boundary is the data/control-plane split plus existing policy gates. A candidate that says “ignore approvals” is both rejected by admission and powerless if it reached runtime.

Lessons may describe strategy at the semantic task level (for example, “compare the stable article body before alerting”), but may not encode executable destinations/commands or grant new capabilities.

## 10. Owner feedback semantics

Feedback capture transaction:

1. atomically claim the external Telegram update/nonce;
2. enforce numeric-ID allowlist;
3. parse only the `fb:` namespace;
4. load target by random nonce;
5. verify exact owner and subject digest;
6. append immutable feedback event;
7. mark one-time target consumed where applicable;
8. append a redacted audit event in the same write.

Semantics:

- useful/not useful: supporting/contradicting sentiment for one delivered result;
- result correction: owner-attested expected behavior for that occurrence; may seed one-run trial support;
- evaluation confirm/dispute: overlay on exact evaluation; dispute blocks dependent promotion;
- candidate approve: permits owner-supported trial through the common admission gate, never direct activation;
- candidate reject: vetoes/stops exact candidate/trial;
- candidate edit: creates a new candidate/digest, invalidates prior approvals, reruns every gate.

Owner statements establish owner intent