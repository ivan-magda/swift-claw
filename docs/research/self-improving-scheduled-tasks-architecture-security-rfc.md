# RFC: Self-improving scheduled tasks — architecture and security boundaries

| | |
|---|---|
| Status | Proposed — M1 / #167 |
| Date | 2026-08-28 |
| Parent | #115 |
| Evidence baseline | #118, frozen Protocol 0.6 |
| Production scope | Generic job-scoped learning for every executable scheduled task |
| First deterministic adapter | Scheduled page-change monitoring |

## 1. Decision

Every created scheduled run uses one generic job-scoped learning control plane. Existing `run_id` remains the only task-attempt identity. The fire transaction binds it to the exact occurrence, fire kind, job-definition digest, execution surface and effective lesson-set digest; execution remains the ordinary proactive `TurnRunner`/`AgentRuntime` path with existing tools, policy, approvals, budgets and delivery.

Every terminal transition writes an immutable terminal receipt. After late usage/approval observations settle, an idempotent worker seals a bounded evidence projection or a technical exclusion. A deterministic eligibility classifier runs before any learning LLM call. Eligible evidence may enter a fresh, tool-free, procedurally blind evaluator. Reflection is a separate fresh, tool-free call and may only propose an immutable complete replacement lesson set.

Owner feedback is durable, authenticated, typed, append-only and bound to an exact subject/digest. It is evidence, never direct activation.

Each job has one stable lesson-set pointer and at most one bounded trial override. Trials cannot stack. Only a created run consumes an assignment. Promotion CASes the stable pointer from the recorded base digest to the candidate digest; fallback closes the trial and leaves stable untouched.

**Capability guarantee:** any scheduled task swift-claw can execute can participate in capture → eligibility → evaluation → feedback → reflection → candidate → bounded trial → promote/fallback. This is not a guarantee that subjective tasks are objectively verifiable or will improve. Natural runs/LLM evaluation are heuristic; owner feedback establishes owner intent; only a deterministic adapter over a named frozen oracle/dataset may issue scoped `deterministically_verified` evidence.

No unresolved P0 architecture/security blocker remains. Exact policy parameters are deferred to M2 (§14).

## 2. Invariants

1. `run_id` is canonical; no parallel attempt entity.
2. Generic core contains no page/HTML/selector/region/snapshot types.
3. Scheduled execution remains an ordinary proactive agent run.
4. Lessons are data, never authority. They cannot change job prompt, schedule, budgets, model route, tool catalog/risk, approvals, recipients, paths, commands or destinations.
5. Lessons use a trusted harness wrapper around bounded untrusted payload and never enter global/workspace memory, conversation history or FTS.
6. Non-empty lessons establish taint before sensitive-memory selection, first provider call and first tool-policy decision.
7. Evaluation/reflection get fresh contexts with no tools, workspace memory, session history, approvals or provider replay state.
8. Evaluator is blind to lesson text/IDs, stable/candidate digests, trial condition, prior scores, promotion state and expected improvement.
9. Deterministic eligibility precedes learning LLM spend.
10. Feedback cannot activate lessons or expand authority.
11. One stable pointer + at most one trial; no stacking.
12. Promotion needs positive eligible evidence. Silence, evaluator failure and ineligible runs never count positive.
13. DB claims/effects are idempotent; external LLM inference is not exactly-once.
14. Export/retention/purge cover derived learning data; deleting private source data cannot leave an active lesson encoding it.

## 3. Existing-seam map

**Scheduler/fire.** `ScheduledJobStore.claimAndFire` already fuses occurrence compare-and-advance with session/trigger creation, `PENDING` run and audit; `fireNow` reuses the insert set without schedule advance; overlap prevents a second live job-session run. Extend the successful fire transaction with `learning_run_binding(run_id, job_id, occurrence, fire_kind, job_definition_digest, execution_surface_version, effective_lesson_set_id/digest, stable_base_digest, trial_id/generation?)`. Resolve trial expiry first; consume one assignment only after overlap passes and `run_id` is created. Misfire, overlap skip and CAS loser consume none.

**Run persistence.** `RunStore` owns pickup, completion/degradation, cancel/supersede, approval suspension/resume and boot reconciliation. Extend every legal terminal transition (`DONE/FAILED/CANCELLED/SUPERSEDED`, including boot reconciliation) to write one `learning_terminal_receipt` in the same SQLite transaction. Seal evidence later unless a normal `DONE` transaction already has all settled facts.

**Context/taint.** `TurnRunner` loads bounded context/budgets and calls `AgentRuntime` with taint/private-data state. Add a job-scoped lesson section whose wrapper is trusted but payload untrusted. Non-empty lessons set initial taint before context memory selection.

**Policy/approvals.** Existing canonical-args, policy-version, owner and approval gates stay authoritative. Candidate text scanning is defense in depth. Lessons never become policy operands and cannot weaken approval, exfiltration, SSRF or proactive-budget policy.

**Usage/budgets.** Learning calls are durable runless operations, not fake agent runs. Their provider usage counts toward global and proactive/learning budgets. Owner delivery never waits for learning calls.

**Telegram feedback.** Reuse the security pattern of approval callbacks (claim update, numeric allowlist, strict namespace, random nonce, owner binding, CAS, redacted audit), but use separate `fb:` targets/events. Feedback never reuses tool approvals or `AWAITING_APPROVAL`.

## 4. Architecture

```text
SchedulerService
  → fire txn: resolve lessons → create ordinary run_id → pin digests → consume trial assignment
  → TurnEnqueuer → TurnRunner → AgentRuntime → existing policy/tools/outbox
                                      → terminal txn + terminal receipt

LearningCoordinator (async, post-delivery)
  → EvidenceSealer → sealed evidence | exclusion
  → EligibilityClassifier (deterministic)
  → Evaluator (fresh/tool-free/blind)
  → durable owner feedback
  → Reflector (fresh/tool-free)
  → CandidateAdmissionPolicy
  → TrialController → promote CAS | fallback

Optional LearningEvaluatorAdapter
  → page-change first: frozen inputs + deterministic scorer + regression fixtures
```

Learning sits beside scheduler/persistence. `AgentRuntime` consumes pinned lessons and produces ordinary run facts; it does not own evaluation, reflection, trial or promotion.

## 5. Generic data model

Conceptual contracts; migrations/Swift names are implementation work.

- `learning_job_state`: job PK, stable lesson ID/digest, nullable open trial ID, monotonic generation. Stable pointer is the only production activation pointer.
- `learning_lesson_sets`: immutable complete replacement set, job/digest, bounded ordered payload, base digest, source reflection/owner edit, schema/timestamps. No in-place edit.
- `learning_run_bindings`: one per created scheduled `run_id`; exact occurrence/fire kind and pinned job/execution/lesson/trial digests.
- `learning_terminal_receipts`: one immutable row per terminal scheduled run; winning terminal state, timestamp, schema/digest.
- `learning_evidence`: one `sealed` projection or typed `excluded` result per binding. Projection contains bindings/digests, terminal classification, bounded final output or digest, bounded tool facts (name/status/policy decision/result size/trust flags), actual model route, primary-run usage refs, versions and optional adapter facts. Excludes raw tool args, secrets, private raw observations, replay state and audit projections.
- `learning_operations`: durable evaluation/reflection ID, kind, source evidence, phase/status, model route, schema, attempts, usage/cost refs, timestamps; includes `interrupted_unknown`.
- `learning_evaluations`: immutable evidence/digest binding, rubric/adapter versions, result `no_issue | reusable_issue | transient_issue | uncertain`, bounded findings, digest/timestamp.
- `learning_feedback_targets`: random one-time nonce, owner ID, exact subject type/id/digest, expiry/consumed state.
- `learning_feedback_events`: append-only owner/job/run/output identity, optional evaluation/candidate, typed signal/payload, Telegram update ID or nonce, timestamp, optional superseded-event link.
- `learning_trials`: job, base/candidate digests, generation, state, deadline, max/consumed assignments, admission evidence. Unique open trial per job.
- `learning_decision_receipts`: immutable promotion/fallback/reject decision, trial/base/candidate, considered evidence/feedback, evidence-strength label, policy/version inputs, CAS generations, digest/timestamp.
- `deterministic_verification_receipts` (adapter-only): adapter/version, frozen dataset/oracle, execution surface, subject digests, deterministic result/digest.

Feedback signals: `result_useful`, `result_not_useful`, `result_correction`, `evaluation_confirm`, `evaluation_dispute`, `candidate_approve`, `candidate_reject`, `candidate_edit`. Edit creates a new immutable digest and invalidates old approvals/support.

## 6. Lifecycles

```text
created run → terminal receipt → settlement
  ├─ cannot safely seal → technical exclusion
  └─ sealed evidence → deterministic eligibility
       ├─ ineligible → retain; no learning LLM
       └─ eligible → evaluation
            ├─ failed/interrupted_unknown → stop
            └─ saved evaluation → reflection (when policy permits)
                 ├─ failed/interrupted_unknown → stop
                 └─ immutable candidate → admission validation → inert | trial
```

```text
candidate → admitted TRIAL (stable pointer untouched)
  ├─ expiry / assignment exhaustion / security veto / regression / owner reject-dispute /
  │  insufficient positive eligible evidence → close + FALLBACK
  └─ acceptance satisfied → decision receipt → CAS stable(base→candidate)
       ├─ CAS lost → close stale trial
       └─ CAS won → ACTIVE; close trial
```

Lifecycle and evidence strength are independent:

```text
lifecycle: candidate | trial | active | rolled_back | superseded
evidence:  heuristic | owner_supported | owner_confirmed | deterministically_verified
```

An active lesson may remain heuristic. LLM evaluation never produces `deterministically_verified`.

## 7. Evidence and eligibility

The terminal receipt is settlement-independent so every terminal path can commit it. The sealer is idempotent by run + evidence-schema version and waits for required usage/approval observations. It writes immutable sealed evidence or `excluded(reason)`; ordinary audit is observability, not provenance.

Initial deterministic eligibility taxonomy:

- `eligible_task_evidence`;
- `transient_infrastructure_failure`;
- `policy_or_security_block`;
- `owner_interruption`;
- `insufficient_evidence`;
- `unsupported_terminal_state`.

Provider/storage/credential/budget failures do not produce behavioral lessons. Cancellation, supersession and security-policy blocks do not enter reflection. One-shot jobs can retain evidence/evaluation/feedback but cannot exercise a trial without another occurrence.

## 8. Evaluator, reflector and candidate firewall

Evaluator input is exactly the frozen job prompt, frozen quality rubric, final output, safe evidence projection and optional adapter facts. It has no tools and returns the closed result above plus bounded findings. This is heuristic evidence.

Reflection is a separate call receiving compatible saved evaluations/multi-run evidence plus current lesson set; it proposes one complete immutable replacement set. Evaluation failure cannot start reflection; reflection failure cannot create a candidate. Compatibility must account for job semantics, evidence schema, execution surface, rubric and adapter version.

Before persistence/trial, deterministic admission validates schema/canonical encoding, lesson count/size, Unicode/invisible/bidi handling, exact-loaded-secret leakage, base digest/source integrity, and forbidden authority operands (schedule, recipients, model route, budgets, tools/risk/approval config, paths, commands, destinations, credentials). Text classification is defense in depth: runtime policy remains the security boundary.

## 9. Owner feedback

Feedback transaction: claim external event → numeric-ID allowlist → parse `fb:` only → load random-nonce target → verify owner + exact subject digest → append event → consume one-time target if applicable → append redacted audit in the same write.

Semantics: useful/not-useful supports/contradicts one result; correction is owner-attested expected behavior and possible one-run trial seed; evaluation confirm/dispute overlays exact evaluation and dispute blocks dependent promotion; candidate approve permits owner-supported trial through the common gate; reject vetoes/stops exact candidate; edit creates a new candidate/digest and reruns every gate. Owner statements establish owner intent, not deterministic verification.

## 10. Trial rules

A candidate is a complete replacement set with incumbent/base digest. Repeated compatible evidence may admit an automatic heuristic trial; explicit owner correction or candidate approval may admit a trial after one eligible occurrence. Exact support thresholds are M2.

The fire transaction atomically: resolve expiry → pass existing occurrence/overlap guard → create run → pin stable/trial digest → consume one assignment. A created run consumes its assignment even if it later fails technically; only eligible completed evaluations count positive. Trials cannot stack.

Expiry, assignment exhaustion, critical failure/regression, deterministic/security veto, explicit rejection/dispute, or insufficient positive evidence closes the exact trial and future runs use untouched stable. Promotion writes a decision receipt, CASes stable only if base digest/generation still match, then closes trial. Hard security/deterministic veto and owner reject/dispute outrank heuristic support.

## 11. Trust and data lifecycle

Trust zones:

```text
CONTROL (trusted code): scheduler claims, policy, budgets, admission, trial/CAS, owner auth
DATA (untrusted): lesson payloads, outputs, tool-derived facts, evaluator/reflection prose
OWNER-ATTESTED: authenticated feedback for exact subject
DETERMINISTIC: scoped adapter receipt for frozen oracle/dataset only
```

Learning never grants capabilities. Evaluation/reflection have no tools. Raw private observations and tool arguments are excluded from evaluator evidence. Lessons are job-scoped and excluded from memory/history/FTS. Non-empty lessons taint the run before memory/tool decisions.

Export/retention/purge cover evidence, evaluations, operations, feedback, candidates, lesson sets, trials, verification/decision receipts and provenance links. Job cancellation blocks new learning spend and promotion but retains immutable history until policy removes it. Explicit job-learning purge must either remove/deactivate derived active lessons whose provenance depends on purged private source data, or conservatively reset stable to an unaffected ancestor/empty set; it may not leave encoded deleted private facts active.

## 12. Transaction + crash/restart matrix

| Operation | Atomic durable boundary | Crash/restart rule |
|---|---|---|
| Fire | existing occurrence/overlap claim + run + binding + trial assignment | no run ⇒ no assignment; created run keeps pinned digest forever |
| Terminal | run terminal transition + terminal receipt | receipt agrees with winning terminal state; duplicate is idempotent |
| Evidence seal | sealed projection/exclusion keyed by run+schema | retry DB construction idempotently; never duplicate evidence |
| Feedback | external-event claim + owner/target validation + event + audit | duplicate update/nonce cannot append twice |
| Eval/reflect start | operation row → `in_flight` before request | pre-crash in-flight becomes `interrupted_unknown`; do not auto-repeat same synthesis |
| Eval/reflect finish | structured result + operation terminal status + usage refs | committed result reusable; ambiguous external inference is not replayed as exactly-once |
| Trial admission | validate candidate + create single open trial + job-state trial pointer CAS | unique/CAS prevents stacking |
| Trial assignment | successful fire + binding + assignment increment | run exists ⇒ assignment consumed even if run later fails |
| Promotion | decision receipt + stable-pointer CAS + trial close | CAS winner activates once; loser closes stale/re-evaluates, never overwrites newer stable |
| Fallback/reject | decision receipt + exact trial close | stable pointer unchanged; future fires resolve stable |
| Job cancel | cancel state + block-new-learning marker/state | no new learning spend/promotion after cancel; history retained per lifecycle policy |

External LLM inference is at-least-attempted, not exactly-once. Restart reconciliation never silently reissues an ambiguous synthesis.

## 13. Page-change adapter

Page-change is the first deterministic benchmark, not the product boundary. The adapter supplies frozen benchmark inputs, deterministic scorer/oracle, adapter version and regression fixtures through generic contracts. Generic persistence/lifecycle types contain no page concepts.

A deterministic verification receipt is valid only for its named dataset/oracle, adapter version and execution surface. Route/rubric/policy/adapter incompatibility requires revalidation or downgrade to heuristic use. Protocol 0.6 from #118 remains frozen and is not rewritten by M1.

## 14. Deferred to M2

M2 selects, with benchmark evidence rather than architectural guesswork:

- compatible-evidence window/recency policy;
- minimum supporting runs/evaluations;
- owner-signal weighting and conflict policy beyond hard veto precedence;
- trial assignment count and wall-clock