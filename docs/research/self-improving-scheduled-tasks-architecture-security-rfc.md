# RFC: Self-improving scheduled tasks — architecture and security boundaries

**Status:** Proposed — M1 / #167 · **Date:** 2026-08-28 · **Parent:** #115 · **Baseline:** #118 frozen Protocol 0.6

**Scope:** generic job-scoped learning for every executable scheduled task. **First deterministic adapter:** scheduled page-change monitoring.

## 1. Decision and guarantee

Every created scheduled run uses one generic learning control plane. Existing `run_id` remains the only task-attempt identity. The fire transaction binds it to exact occurrence, fire kind, job-definition digest, execution surface and effective lesson-set digest; execution stays on the ordinary proactive `TurnRunner`/`AgentRuntime` path with existing tools, policy, approvals, budgets and delivery.

Every terminal transition writes an immutable receipt. After late usage/approval observations settle, an idempotent worker seals bounded evidence or a technical exclusion. Deterministic eligibility runs before learning LLM spend. Eligible evidence may enter a fresh, tool-free, blind evaluator. Reflection is a separate fresh/tool-free call and may only propose an immutable complete replacement lesson set.

Owner feedback is durable, authenticated, typed, append-only and exact-subject-bound. It is evidence, never activation. Each job has one stable lesson pointer and at most one bounded trial override; trials cannot stack. Promotion CASes stable from recorded base to candidate; fallback closes trial and leaves stable untouched.

**Guarantee:** any executable scheduled task can participate in capture → eligibility → evaluation → feedback → reflection → candidate → bounded trial → promote/fallback without expanding authority. This does not guarantee objective verification/improvement for subjective tasks. Natural runs/LLM evaluation are heuristic; owner feedback establishes owner intent; only a deterministic adapter over a named frozen oracle/dataset may issue scoped `deterministically_verified` evidence.

No unresolved P0 architecture/security blocker remains. Exact algorithm parameters are deferred to M2 (§12).

## 2. Invariants / security boundary

- `run_id` is canonical; no parallel attempt entity. Generic core contains no page/HTML/selector/region/snapshot types.
- Scheduled execution remains an ordinary proactive agent run.
- Lessons are data, never authority: they cannot change job prompt, schedule, budgets, model route, tool catalog/risk, approvals, recipients, paths, commands or destinations.
- Lessons use a trusted harness wrapper around bounded **untrusted payload** and never enter global/workspace memory, conversation history or FTS.
- Non-empty lessons establish taint before sensitive-memory selection, first provider call and first tool-policy decision.
- Evaluation/reflection get fresh contexts with no tools, workspace memory, session history, approvals or provider replay state.
- Evaluator is blind to lesson text/IDs, stable/candidate digests, trial condition, prior scores, promotion state and expected improvement.
- Deterministic eligibility precedes learning LLM spend. Feedback cannot activate lessons or expand authority.
- One stable pointer + at most one trial; promotion requires positive eligible evidence. Silence/evaluator failure/ineligible runs are never positive.
- DB effects are idempotent; external LLM inference is not exactly-once.
- Export/retention/purge include derivatives; deleting private source data cannot leave an active lesson encoding it.

## 3. Existing-seam map

**Scheduler/fire.** `ScheduledJobStore.claimAndFire` already fuses occurrence compare-and-advance with session/trigger, `PENDING` run and audit; `fireNow` reuses the insert set without schedule advance; overlap prevents a second live job-session run. Extend the successful transaction with `learning_run_binding(run_id, job_id, occurrence, fire_kind, job_definition_digest, execution_surface_version, effective_lesson_id/digest, stable_base_digest, trial_id/generation?)`. Resolve trial expiry first; consume an assignment only after overlap passes and `run_id` exists. Misfire, overlap skip and CAS loser consume none.

**Run persistence.** `RunStore` owns pickup, completion/degradation, cancel/supersede, approval suspension/resume and boot reconciliation. Every legal terminal transition (`DONE/FAILED/CANCELLED/SUPERSEDED`, including reconciliation) writes one `learning_terminal_receipt` in the same transaction. Seal later unless normal `DONE` already has all settled facts.

**Context/taint.** `TurnRunner` loads bounded context/budgets and calls `AgentRuntime` with taint/private-data state. Add a job-scoped lesson section: trusted wrapper, untrusted payload. Non-empty lessons set initial taint before context memory selection.

**Policy/approvals.** Existing canonical-args, policy-version, owner and approval gates stay authoritative. Candidate scanning is defense in depth; lessons never become policy operands and cannot weaken approval, exfiltration, SSRF or proactive-budget policy.

**Usage/budgets.** Evaluation/reflection are durable runless learning operations, not fake runs. Usage counts toward global and proactive/learning budgets. Owner delivery never waits for learning calls.

**Telegram feedback.** Reuse the fail-closed callback pattern (claim update → numeric allowlist → strict namespace → random nonce → owner binding → CAS → redacted audit) in a separate `fb:` domain; do not reuse tool approvals or `AWAITING_APPROVAL`.

## 4. Architecture and data model

```text
SchedulerService
 → fire txn: resolve lessons → create run_id → pin digests → consume trial assignment
 → TurnEnqueuer → TurnRunner → AgentRuntime → existing policy/tools/outbox
                                      → terminal txn + receipt
LearningCoordinator (async; post-delivery)
 → EvidenceSealer → EligibilityClassifier → Evaluator → Feedback/Reflector
 → CandidateAdmissionPolicy → TrialController → promote CAS | fallback
Optional LearningEvaluatorAdapter → page-change frozen scorer/fixtures first
```

Learning sits beside scheduler/persistence; `AgentRuntime` only consumes pinned lessons and produces ordinary run facts.

Conceptual records (names are not M1 migrations):

- `learning_job_state`: job PK, stable lesson ID/digest, nullable open trial, monotonic generation; stable pointer is the only production activation pointer.
- `learning_lesson_sets`: immutable complete replacement set, bounded payload, digest/base digest, source, schema/timestamps; no in-place edit.
- `learning_run_bindings`: one per created scheduled `run_id`; exact occurrence/fire kind and pinned job/execution/lesson/trial digests.
- `learning_terminal_receipts`: one per terminal run; winning terminal state, timestamp, schema/digest.
- `learning_evidence`: sealed projection or typed exclusion. Projection contains bindings/digests, terminal classification, bounded final output/digest, bounded tool facts (name/status/policy decision/result size/trust flags), actual model route, primary usage refs, versions and optional adapter facts. Excludes raw tool args, secrets, private raw observations, replay state and audit projections.
- `learning_operations`: durable evaluation/reflection ID, source evidence, phase/status (`pending/in_flight/succeeded/failed/interrupted_unknown`), model route/schema, attempts, usage/cost refs, timestamps.
- `learning_evaluations`: evidence binding, rubric/adapter versions, result `no_issue | reusable_issue | transient_issue | uncertain`, bounded findings/digest.
- `learning_feedback_targets/events`: random one-time nonce + owner + exact subject digest; append-only typed event with Telegram update/nonce and optional superseded link.
- `learning_trials`: job, base/candidate digests, generation, state, deadline, max/consumed assignments, admission evidence; unique open trial/job.
- `learning_decision_receipts`: immutable promotion/fallback/reject inputs, evidence/feedback, evidence strength, CAS generations/digest.
- adapter-only `deterministic_verification_receipts`: adapter/version, frozen dataset/oracle, execution surface, subject digests and deterministic result.

Feedback types: result useful/not-useful/correction; evaluation confirm/dispute; candidate approve/reject/edit. Edit creates a new digest and invalidates old support.

## 5. Lifecycles

```text
created run → terminal receipt → settlement → sealed evidence | exclusion
sealed → deterministic eligibility
  ├─ ineligible → retain; no learning LLM
  └─ eligible → evaluation
       ├─ fail/interrupted_unknown → stop
       └─ saved evaluation → reflection (when policy permits)
            ├─ fail/interrupted_unknown → stop
            └─ immutable candidate → admission → inert | trial
```

```text
candidate → TRIAL (stable untouched)
  ├─ expiry/exhaustion/security veto/regression/owner reject-dispute/
  │  insufficient positive evidence → close + FALLBACK
  └─ acceptance satisfied → decision receipt → CAS stable(base→candidate)
       ├─ lost → close stale trial
       └─ won → ACTIVE; close trial
```

Keep dimensions separate: `lifecycle = candidate | trial | active | rolled_back | superseded`; `evidence = heuristic | owner_supported | owner_confirmed | deterministically_verified`. An active lesson may remain heuristic. LLM evaluation never yields deterministic verification.

## 6. Evidence, evaluator and reflection

Terminal receipt is settlement-independent and unique by run. Sealer is idempotent by run + evidence-schema version, waits for required usage/approval observations, and writes sealed evidence or `excluded(reason)`. Audit is observability, not provenance.

Initial eligibility taxonomy: `eligible_task_evidence`, `transient_infrastructure_failure`, `policy_or_security_block`, `owner_interruption`, `insufficient_evidence`, `unsupported_terminal_state`. Provider/storage/credential/budget failures do not create behavioral lessons; cancellation, supersession and security blocks never enter reflection. One-shot jobs may retain evidence/evaluation/feedback but cannot trial without another occurrence.

Evaluator input is exactly frozen job prompt, frozen quality rubric, final output, safe evidence projection and optional adapter facts. No tools. Reflection is a separate call over compatible saved evaluations/multi-run evidence plus current lesson set and proposes one complete replacement. Evaluation failure cannot start reflection; reflection failure cannot create a candidate. Compatibility includes job semantics, evidence schema, execution surface, rubric and adapter version.

## 7. Candidate firewall and owner feedback

Admission deterministically validates schema/canonical encoding, lesson count/size, Unicode/invisible/bidi handling, exact-loaded-secret leakage, base/source integrity and forbidden authority operands (schedule, recipients, model route, budgets, tools/risk/approval config, paths, commands, destinations, credentials). Text classification is defense in depth; runtime policy is the boundary.

Feedback transaction: claim external event → numeric-ID allowlist → parse `fb:` → load random-nonce target → verify owner + exact subject digest → append event → consume one-time target if applicable → append redacted audit in same write.

Useful/not-useful supports/contradicts one result; correction is owner-attested expected behavior and possible one-run trial seed; evaluation dispute blocks dependent promotion; candidate approve permits owner-supported trial through common gate, never direct activation; reject vetoes/stops exact candidate; edit creates a new candidate and reruns all gates. Owner statements establish intent, not deterministic verification.

## 8. Trial semantics

Candidate is a complete replacement set with incumbent digest. Repeated compatible evidence may admit automatic heuristic trial; explicit owner correction/approval may admit after one eligible occurrence. Exact thresholds are M2.

Fire atomically resolves expiry → passes existing occurrence/overlap guard → creates run → pins stable/trial digest → consumes one assignment. A created run consumes it even if later technically failed; only eligible completed evaluations count positive. Trials cannot stack.

Expiry, assignment exhaustion, critical failure/regression, security/deterministic veto, explicit rejection/dispute or insufficient positive evidence closes exact trial; future runs use stable. Promotion writes decision receipt, CASes stable only if base/generation match, then closes trial. Hard veto and owner reject/dispute outrank heuristic support.

## 9. Trust, lifecycle and restart

Trust classes: **CONTROL** = scheduler claims/policy/budgets/admission/trial-CAS/owner auth; **UNTRUSTED DATA** = lessons/outputs/tool facts/evaluator-reflection prose; **OWNER-ATTESTED** = authenticated exact-subject feedback; **DETERMINISTIC** = scoped adapter receipt only.

Export/retention/purge cover evidence, operations/evaluations, feedback, candidates, lesson sets, trials and verification/decision receipts. Job cancellation blocks new learning spend/promotion but retains history per policy. Purge must deactivate/remove active lessons depending on purged private data or reset stable to unaffected ancestor/empty set.

Transaction/restart rules:

- **Fire:** occurrence/overlap claim + run + binding + trial assignment; no run ⇒ no assignment; created run keeps pinned digest.
- **Terminal:** state transition + receipt; unique/idempotent and agrees with winning state.
- **Evidence:** seal/exclusion keyed by run+schema; DB retry idempotent.
- **Feedback:** event claim + owner/target validation + event + audit; duplicate cannot append twice.
- **Eval/reflect:** durable `in_flight` before request; crash-window operation becomes `interrupted_unknown`; do not automatically repeat same logical synthesis.
- **Trial admission:** validation + unique open trial + job-state CAS prevents stacking.
- **Promotion:** decision receipt + stable CAS + trial close; loser never overwrites newer stable.
- **Fallback/reject:** exact trial closes; stable unchanged.

## 10. Page-change adapter

Page-change is first deterministic benchmark, not product boundary. Adapter supplies frozen inputs, deterministic scorer/oracle, version and regression fixtures through generic contracts; generic types contain no page concepts. Verification is scoped to named dataset/oracle + adapter/execution-surface version. Route/rubric/policy/adapter incompatibility requires revalidation or downgrade to heuristic. Protocol 0.6 remains frozen.

## 11. Implementation increments

1. Capture: run binding + terminal receipt + safe evidence/exclusion; no behavior change.
2. Eligibility/evaluator: deterministic taxonomy, durable operations, blind tool-free evaluation, budget accounting.
3. Owner feedback: `fb:` targets/events and exact-subject overlays.
4. Reflection/inert candidates: immutable replacement sets + admission firewall; no activation.
5. Bounded trial: stable pointer + one trial override, atomic assignment, initial lesson taint, expiry/fallback/no stacking.
6. Promotion/rollback: decision receipts, positive-evidence gate, CAS promotion, veto precedence.
7. Page-change adapter: deterministic fixtures/scorer and scoped verification receipts.
8. Lifecycle completion: export/retention/purge, doctor/observability, restart fault injection.

## 12. Deferred to M2

Compatible-evidence window/recency; minimum supporting runs; owner-signal weighting beyond hard veto precedence; trial assignment count/deadline; automatic-trial threshold; acceptance/regression formula/uncertainty band; reflection cadence/consolidation; exact lesson caps; evaluator/reflector model and operation budgets; retention durations; deterministic-adapter score thresholds/revalidation window.

## 13. Acceptance

This RFC satisfies #167's acceptance contract: canonical `run_id`; generic core; atomic occurrence/lesson pinning; terminal receipt + post-settlement sealing; deterministic eligibility before LLM; blind evaluator separated from reflector; durable authenticated feedback; no feedback activation/authority expansion; one bounded non-stacking trial with CAS; positive-evidence requirement; distinct heuristic/owner/deterministic claims; global + proactive learning budget participation; initial lesson taint; defense-in-depth candidate validation; honest restart semantics; derivative export/retention/purge; page-change as first deterministic adapter; and no unresolved P0 blocker.

**M1 remains architecture-only:** no production Swift/migrations/tests, exact thresholds/windows/trial duration/consolidation, page-change importer/benchmark implementation, global/cross-job lessons, generic global-memory platform, authority changes through lessons, policy weakening, Protocol 0.6 rewrite, merge, or issue closure.