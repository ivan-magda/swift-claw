# Scheduled-learning v1 Live Readiness Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to execute this plan task-by-task. Each implementation
> task uses a fresh implementer, a task-scoped review, and a commit before the next task begins.

**Goal:** Make the existing M3 scheduled-learning harness live-runnable with the already encrypted
M0 OpenAI credential state, a conservative and internally consistent 38-send budget, and
manifest-bound score verification, then produce a new freeze and stop at an exact owner checkpoint
before one non-resumable live invocation.

**Architecture:** The experiment remains a two-root system. Python owns the M3 evidence root and
passes a mandatory, runtime-only credential root through its execution boundary to each Swift
process. Swift owns both roots only for the duration of a call: it locks them in a fixed order,
constructs `EncryptedLLMCredentialStore` from the credential root, keeps all lessons and publication
under M3 state, shuts credentials down, and then releases both locks. Scheduled-learning budget
validation is an explicit profile on the existing snapshot type; Protocol 0.6 keeps its legacy
validation and constants. Offline result verification reuses the existing freeze verifier before it
accepts active/restart score evidence.

**Tech Stack:** Swift 6.3 strict concurrency and Swift Testing; Python 3.11, unittest, Ruff, strict
Mypy, uv; canonical JSON and SHA-256; existing `ClawEvaluation`, `ClawSecrets`, and
`scheduled_learning_v1` contracts.

**Spec:** The owner-approved request that created this follow-up plan is authoritative, followed by
`docs/ARCHITECTURE.md`, `docs/TESTING.md`,
`docs/research/172-validation-protocol.md`, and
`docs/superpowers/specs/2026-08-29-scheduled-learning-v1-evaluation-harness-design.md`.

## Global Constraints

- Begin from clean `issue-172-page-harness` HEAD `6d0a8077`. Preserve historical approval and
  results byte-for-byte while Tasks 1–4 implement and test offline corrections. Commits `01fd1637`
  and `6d0a8077` remain the recoverable historical record; never amend or rewrite them.
- Do not reopen Task 9 or append another final-fix wave to the 2026-08-29 plan. This file and its own
  SDD workspace/ledger are the only execution record for the follow-up.
- Reuse only the existing encrypted M0 OpenAI credential store. Never read or reuse M0 lessons,
  active state, manifests, approvals, outputs, scores, recovery state, or decision evidence.
- `--credential-state-root` is mandatory and runtime-only on Python `scored`, Python internal
  restart `active`, Swift `claw-eval worker`, and Swift `claw-eval learning-call`. It has no default.
  The host-specific live value supplied by the owner is never hard-coded in source, tests, manifests,
  approvals, invocation/request/result evidence, or documentation examples that become frozen
  experiment evidence.
- The M3 root and credential root must be canonical absolute directories without symlink boundary
  crossings. Fail closed if the credential root equals or is contained by the M3 evaluation/results
  tree, or resolves to production `~/.swift-claw`. Tests use temporary encrypted stores only.
- Use the credential root only for `EncryptedLLMCredentialStore`, its `SecretStatePaths` credential
  lock, credential shutdown, and token rotation. Task lessons and active pointer remain in
  `results/state`; evaluator/reflector temporary publication remains in
  `results/.private-learning-state/<operation>`. Never read M0 `active.json` or `lesson-sets/`.
- Extract the already named `EvaluationWorkerResource`, `EvaluationWorkerLifecycle`, and lifecycle
  error from `EvaluationWorker.swift` to
  `Sources/ClawEvaluation/Runtime/EvaluationWorkerLifecycle.swift`. Do not add a lock framework,
  credential manager, registry, import mechanism, protocol invented to justify extraction, or login
  command.
- The two-root lifecycle acquires M3-state and credential-state locks in one deterministic order,
  defensively coalesces equal roots, preserves the existing M3 lock acquisition identity, shuts down
  the credential source before either lock is released, and then shuts down transport according to
  the existing lifecycle contract.
- Keep exactly 10 task attempts, 5 evaluator calls, 1 reflector call, 38 Responses sends, missing
  usage proxy 132,768, and all existing provider retry policies. The exact conservative
  accounted-token ceiling is `5_045_184 = 38 * 132_768`.
- For scheduled-learning only, snapshot stage/global token thresholds both equal the admitted
  `accounted_tokens`, and stage/global send caps both equal admitted `responses_sends`. Python
  validates against the admitted manifest and approval; after Swift admission, task invocation
  validates/binds all four caps to `admission.budgets`. Leave legacy
  `EvaluationSendBudgetSnapshot.validate()`, Protocol 0.6 constants `4_350_000/454`, legacy JSON,
  and legacy tests unchanged.
- Do not add a scorer wrapper or digest framework. If active or restart evidence exists,
  `reporting/verification.py` calls existing `freeze.verify_manifest(root, manifest)` before
  artifact closure and score-evidence acceptance. If neither exists, preserve the historical
  incomplete audit exactly under its current rules.
- Keep responsibilities out of `execution/lifecycle.py`, `reporting/builder.py`,
  `reporting/artifact_closure.py`, `EvaluationConfiguration.swift`, and
  `EvaluationAuthLogin.swift` unless an existing call site only needs the smallest signature
  forwarding change. Do not grow `score_evidence.py`.
- Before each test edit, inspect the reachable production branch and nearest existing test, then add
  a row to `tests/TEST_INTENT.md` naming the mutant, seam, nearest test, and why it misses. Keep
  Given/When/Then behavior in the test body; move only repeated construction to support. Run the
  `docs/TESTING.md` redundancy pass before each test-bearing commit. One independent agent must
  challenge cross-cutting test value/redundancy before freeze.
- Follow pragmatic SOLID: choose the smallest correct, testable, maintainable implementation for
  these concrete requirements. Split by named responsibility, not line count; preserve directed
  dependencies and public APIs; do not create one-function files or hypothetical extensibility.
- Every implementation task commits only its scoped source, tests, intent map, and documentation.
  Do not merge or push. Verify every newly created file is tracked.
- Tasks 1–4 are strictly provider-free: no device login, network, provider call, refreeze, scored
  invocation, or mutation of the host credential state. Task 5 may perform provider-free status/load
  checks only. Task 6 may perform exactly one provider invocation sequence only after exact owner
  approval.

### Task 1: Wire reusable credential state through Python and Swift with two-root lifecycle locking

**Files:**
- Modify: `experiments/scheduled-task-learning/scheduled-learning-v1/scheduled_learning_v1/run.py`
- Modify: `experiments/scheduled-task-learning/scheduled-learning-v1/scheduled_learning_v1/execution/lifecycle.py`
- Modify: `experiments/scheduled-task-learning/scheduled-learning-v1/scheduled_learning_v1/execution/operations.py`
- Modify: `experiments/scheduled-task-learning/scheduled-learning-v1/scheduled_learning_v1/worker_bridge/bridge.py`
- Modify: `Sources/claw-eval/ClawEvalCommand.swift`
- Modify: `Sources/ClawEvaluation/Runtime/EvaluationWorker.swift`
- Create: `Sources/ClawEvaluation/Runtime/EvaluationWorkerLifecycle.swift`
- Modify only as required by existing entry points:
  `Sources/ClawEvaluation/Learning/Call/EvaluationLearningCall.swift`
- Modify focused existing Python execution/bridge tests and Swift worker/learning/lifecycle tests.
- Modify: `experiments/scheduled-task-learning/scheduled-learning-v1/tests/TEST_INTENT.md`

**Interfaces:**
- Produces `run_scored(root, credential_state_root)` and
  `run_active(root, generation, credential_state_root)`.
- Produces `Operations(..., credential_state_root=...)` and
  `WorkerBridge(executable, journal, credential_state_root)`; every subprocess argv appends exactly
  `--credential-state-root <canonical-root>` without adding it to JSON evidence.
- Produces Swift worker/learning entry points that accept the CLI-only root and pass it to
  `EncryptedLLMCredentialStore` and the credential lock while retaining M3 state for task lessons and
  learning publication.

- [ ] Inspect `run.py`, restart launch, `Operations`, `WorkerBridge`, worker/learning composition,
  `EvaluationPathSecurity`, `SecretStatePaths`, and nearest tests. Record test-intent rows before
  adding tests.
- [ ] Add failing Python tests proving both public CLI paths require the argument, scored task and
  learning argv carry the same supplied temporary root, evaluator and reflector share it, restart
  preserves the exact argument in the fresh Python process, temporary learning state is removed, M3
  lessons still come only from M3 state, and serialized/committed evidence contains neither
  credential files nor the root string.
- [ ] Add failing Swift tests using temporary encrypted stores proving task and learning calls load
  the supplied external credential root, a held credential lock prevents the recording HTTP seam
  from observing dispatch, root rejection is fail-closed, and credential shutdown precedes release
  of both locks. Use a real encrypted store with inert/fake HTTP; do not refresh or contact a
  provider.
- [ ] Add one focused root validator at the narrow runtime boundary. Validate lexical canonicality,
  regular directory ancestry/no symlink crossing, separation from M3 evaluation/results, and
  production-state exclusion before any lock, credential load, or HTTP construction.
- [ ] Thread the root through Python CLI → lifecycle → `Operations` → `WorkerBridge` argv. Forward it
  unchanged to the internal `active` subprocess. Keep it out of request cores and terminal records.
- [ ] Move the existing lifecycle types unchanged in responsibility to
  `EvaluationWorkerLifecycle.swift`, then extend that cohesive lifecycle with fixed-order two-root
  locking and equal-root coalescing. Preserve the UUID identity returned for the M3 lock.
- [ ] Change Swift `worker` and `learning-call` to require the CLI option. Construct
  `EncryptedLLMCredentialStore` and its managed credential source from that root while all M3
  configuration, lessons, active pointer, and learning publication continue to use their existing
  M3 roots.
- [ ] Run bounded focused Python tests and Swift filters for lifecycle, worker bootstrap/managed
  provider, learning call, and command parsing. Run lint on changed files and the redundancy pass.
- [ ] Commit with `feat: wire external evaluation credential state`.

### Task 2: Make the scheduled-learning budget contract internally exact

**Files:**
- Modify: `docs/research/172-validation-protocol.md`
- Modify: `experiments/scheduled-task-learning/scheduled-learning-v1/scheduled_learning_v1/frozen_contract.py`
- Modify: `experiments/scheduled-task-learning/scheduled-learning-v1/scheduled_learning_v1/execution/budgets.py`
- Modify only the existing manifest/preflight projections that admit the budget.
- Modify: `Sources/ClawEvaluation/Runtime/EvaluationWorkerInvocation.swift`
- Modify: `Sources/ClawEvaluation/Runtime/EvaluationWorker.swift`
- Modify focused Python budget/preflight/interop tests and Swift snapshot/learning-worker tests.
- Modify: `experiments/scheduled-task-learning/scheduled-learning-v1/tests/TEST_INTENT.md`

**Interfaces:**
- `AGGREGATE_BUDGETS["accounted_tokens"] == 5_045_184` while operation counts, sends, proxy,
  output caps, and retry policies stay unchanged.
- Add one profile-specific validation method on `EvaluationSendBudgetSnapshot`, such as
  `validateScheduledLearning(approvedBudgets:)`; do not change the behavior of `validate()`.
- Python `task_snapshot()` emits four equal approved M3 thresholds/caps and validates them against
  both admitted manifest and approval before dispatch.

- [ ] Inspect every budget-producing and budget-validating branch plus nearest legacy and M3 tests;
  record one primary test layer per mutant before test edits.
- [ ] Add failing Python tests for first-operation admission, the complete frozen operation order
  under worst-case proxy accounting, active and restart admission after all preceding sends, exact
  38-send/5,045,184 ceiling, rejection of one additional send or token, and snapshot mismatch with
  manifest or approval.
- [ ] Add failing Swift tests proving the scheduled profile accepts exact admitted caps, rejects any
  one-cap difference, admits the active/restart task after 34 prior proxy sends, rejects the 39th send
  and token overflow, while existing Protocol 0.6 `validate()` admission behavior remains unchanged.
- [ ] Update protocol budget values from 120,000 to 5,045,184 and explain the conservative equation
  without changing send/order/retry semantics.
- [ ] Change only scheduled-learning constants and snapshot construction. Validate Python snapshot
  keys exactly against both manifest and approval. After Swift manifest admission, bind each task
  snapshot threshold/cap exactly to `admission.budgets` before provider composition.
- [ ] Regenerate only deterministic test fixtures whose expected M3 budget bytes legitimately
  change; do not touch historical approval/results or legacy Protocol 0.6 JSON.
- [ ] Run bounded focused Python budget/preflight/restart/interop tests and Swift budget/worker
  filters, then explicit legacy Protocol 0.6 admission tests. Run lint and the redundancy pass.
- [ ] Commit with `fix: align scheduled-learning budget admission`.

### Task 3: Bind active and restart score acceptance to frozen bytes

**Files:**
- Modify: `experiments/scheduled-task-learning/scheduled-learning-v1/scheduled_learning_v1/reporting/verification.py`
- Create: `experiments/scheduled-task-learning/scheduled-learning-v1/tests/reporting/test_frozen_score_identity.py`
- Modify: `experiments/scheduled-task-learning/scheduled-learning-v1/tests/TEST_INTENT.md`

**Interfaces:**
- `verify_results(root, manifest)` invokes existing
  `scheduled_learning_v1.freeze.verify_manifest(root, manifest)` before artifact closure whenever
  `results/active-evidence.json` or `results/restart-evidence.json` exists.
- The branch does not run when both are absent, preserving the legacy incomplete result audit.

- [ ] Inspect the current verification ordering, `freeze.verify_manifest`, manifest-bound scorer,
  source/gold files, active/restart score evidence, and nearest reporting tests. Add exactly one new
  test-intent row before creating the test.
- [ ] Create the focused test with one representative manifest-bound byte mutation (choose scorer,
  source, or gold), then recompute every internally owned score/evidence digest so the tree is
  internally consistent. Assert offline verification still rejects because the frozen manifest no
  longer verifies. Do not repeat the same mutant for the other two categories.
- [ ] Add or retain one assertion that a historical result with neither active nor restart evidence
  still verifies as `verified_legacy_incomplete` under its existing rules.
- [ ] Import and call the existing freeze verifier in `reporting/verification.py` before
  `verify_artifact_closure`; make no changes to `score_evidence.py`, builder, or artifact closure.
- [ ] Run the focused test plus existing reporting, freeze, and historical archival verification
  tests. Run experiment lint/Mypy and the redundancy pass.
- [ ] Commit with `fix: verify frozen score identity offline`.

### Task 4: Prove offline readiness and obtain independent reviews

**Files:**
- Modify only if required to describe the now-runnable, still-unapproved HEAD:
  `experiments/scheduled-task-learning/scheduled-learning-v1/README.md`
- Modify only if a committed invariant changed: the relevant scheduled-learning tests/intents.

- [ ] Run an independent cross-cutting test-value review. The reviewer challenges only reachable
  mutants, primary layer assignment, duplication, and hidden Given/When/Then behavior. Address every
  Critical/Important finding in the owning task area, commit fixes, and obtain scoped re-review.
- [ ] Run focused Swift credential/lifecycle and M3-budget tests.
- [ ] Run focused Python credential, budget, restart, and score-binding tests.
- [ ] Run the full bounded Swift suite; after timeout/failure, inspect and terminate only a leaked
  helper proven to belong to this worktree, then bisect before retrying.
- [ ] Run root `scripts/lint.sh --fix`, then root `scripts/lint.sh`.
- [ ] Run scheduled-learning `scripts/lint.sh` including strict Mypy, then its full Python suite.
- [ ] Run replay conformance and require exactly 24/24.
- [ ] Run legacy Protocol 0.6 tests and offline evidence verification unchanged.
- [ ] Prove credential status/load provider-free: use the existing offline auth doctor/load seam
  against the owner-supplied external state root, with network/refresh/device-login disabled. Record
  only status (present/usable or exact provider-free failure), never credential material or its path
  in frozen evidence.
- [ ] Run a broad independent final code review from `6d0a8077` through current HEAD on the most
  capable available reviewer. Require no Critical or Important finding; allow no freeze while one is
  open.
- [ ] If README wording needed a tracked change, commit it with
  `docs: document scheduled-learning live readiness`; otherwise record the green gates and reviews
  only in the SDD ledger. Confirm provider sends remain zero and historical approval/results bytes
  match `6d0a8077`.

### Task 5: Transition from archival evidence to a fresh freeze and stop for exact approval

**Files:**
- Remove from the current tree only after Task 4 is green:
  `experiments/scheduled-task-learning/scheduled-learning-v1/freeze/owner-budget-approval.json`
  and the historical canonical `experiments/scheduled-task-learning/scheduled-learning-v1/results/`
  tree.
- Modify only archival/readiness documentation and tests required for an unapproved runnable HEAD.
- Replace with fresh generated freeze artifacts only:
  `experiments/scheduled-task-learning/scheduled-learning-v1/freeze/manifest-input.json`
  and `experiments/scheduled-task-learning/scheduled-learning-v1/freeze/manifest.json`.

- [ ] Confirm Task 4 gates/reviews are green and no provider dispatch occurred. Verify historical
  evidence is recoverable at both `01fd1637` and `6d0a8077` before removing it from the current tree.
- [ ] Make one explicit tracked fresh-run transition: remove only canonical historical approval and
  results, update the archival/readiness README/tests required by the new state, run their focused
  tests/lint, and commit with `docs: prepare fresh scheduled-learning run`.
- [ ] Build exactly `swift build -c release --target claw-eval`.
- [ ] Generate a fresh `manifest-input.json` and `manifest.json` with the existing freeze builder.
  Verify the manifest offline and confirm it contains neither credential state, credential files,
  the runtime credential root, approval, nor results.
- [ ] Re-run the freeze-sensitive offline checks required by the builder. Commit only the two fresh
  freeze artifacts with `feat: freeze scheduled-learning live-readiness inputs`.
- [ ] Make no further tracked changes. Re-run read-only verification, require a clean worktree, and
  compute the manifest SHA-256, freeze commit, release executable SHA-256, exact budget
  `10/5/1/38/5045184`, provider-free credential status, all gate results, and provider sends zero.
- [ ] Obtain a read-only task review of the transition/freeze. Then report those exact values and
  stop. Old `go`, M0 authorization, historical M3 approval, or general issue approval is not
  authorization. Wait for an owner reply explicitly approving that exact manifest SHA-256, freeze
  commit, executable SHA-256, and budget.

### Task 6: Execute one owner-authorized live invocation and archive immutable results

**Owner gate:** This task is blocked until the owner explicitly approves the exact Task 5 manifest,
freeze commit, executable digest, and `10/5/1/38/5045184` budget. A generic “go” detached from that
checkpoint is insufficient.

**Files:**
- Create after exact approval:
  `experiments/scheduled-task-learning/scheduled-learning-v1/freeze/owner-budget-approval.json`
- Create exactly once:
  `experiments/scheduled-task-learning/scheduled-learning-v1/results/`

- [ ] Recheck the reused credential provider-free with no refresh. If missing, unreadable, expired in
  a way that requires browser login, or otherwise unusable without a provider action, stop for owner
  action; never create another profile.
- [ ] Materialize the exact owner approval object for the approved manifest/commit/budget. Verify it
  offline before execution.
- [ ] Run exactly one `scheduled_learning_v1.run scored` invocation with the mandatory runtime-only
  credential root. Never retry, resume, or launch a second scored invocation after consumption,
  including after `incomplete_failed`.
- [ ] Verify the complete evidence tree offline, including active and fresh-process restart evidence,
  frozen score identity, artifact closure, replay, exact sends/tokens, and final report status.
- [ ] Commit only the canonical approval and immutable results with
  `docs: record authorized scheduled-learning result`. Do not merge or push.
- [ ] Run one final independent review. Completion requires clean worktree, all offline gates green,
  exactly one authorized live invocation, a self-verifying pass/fail report with active/restart
  evidence, exact provider accounting, and no Critical/Important finding. Report final HEAD,
  commits, tests, accounting, and rulings. If status is `incomplete_failed`, report not merge-ready
  and require another exact authorization before any new run.
