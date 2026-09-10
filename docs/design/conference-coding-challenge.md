# Conference coding challenge acceptance notes

The accepted technical contract is
[ARCHITECTURE.md §13.3](../ARCHITECTURE.md#133-conference-coding-challenge).
This companion records acceptance coverage and test intent for the Podlodka iOS Crew #18
workflow; it does not define a separate implementation contract. Deployment and live
verification: [conference runbook](../CONFERENCE.md).

## Acceptance criteria and primary coverage

1. **Current case and exact human proposal:** `ConferenceWorkflowAcceptanceTests` and
   `ConferenceToolsTests`; reject rewritten answers before judge or queue.
2. **Confirmed identity, ownership and uniqueness:** real message/run/approval fixture,
   `ConferenceStoreTests` and workflow ownership/replay tests. Conference admission and approvals
   use private chats only; group Coder approval tests cover the separate group profile.
3. **Busy executor and original case after day switch:** workflow acceptance tests preserve
   queued work and use the queued case's own source/baseline. Store coverage proves insertion
   order for same-second submissions and after migration/restart; source retry coverage distinguishes
   transient Git failures from permanent source/baseline mismatches.
4. **Judge admission:** `ConferenceSubmissionJudgeTests` covers exact safe/unsafe/malformed
   output, provider failure and joined timeout; workflow tests prove rejection queues nothing.
   Scripted verdicts test the contract, not the real model's detection accuracy.
5. **Actual Coder/Git/publication composition:** `ConferenceNativeWorkflowTests` exercises
   real Coder supervisor/backend, independent Git copies, source verification, publisher,
   SQLite and outbox for two participants. CLI inference and GitHub transport are local test
   doubles; no real model, GitHub mutation, Telegram delivery or iOS build is claimed.
6. **Baseline evidence:** `ConferenceBaselineVerificationTests` prevents publication on a
   mismatched observed SHA, regardless of a successful Coder report.
7. **Lost responses and restart:** native publication test and
   `ConferencePublicationRecoveryTests` verify reuse without a second Coder job or PR identity.
8. **Credentials and participant surface:** `ConferenceSecurityBoundaryTests`, access-control
   tests and the native CLI sentinel cover bot-token removal, fixed tools, startup identity and
   config-home containment after symlink resolution. Approval-policy coverage rejects changed native
   execution authority and legacy queued work without a bound policy ID before a new Coder launch.
   `ConferenceContextIsolationTests` assembles real DM/FTS, memory and workspace fixtures through
   production composition: conference mode excludes all shared data, ordinary mode retains it.
9. **One completion producer:** `CoderSilentCompletionTests` plus native/acceptance outbox
   assertions; ordinary Generic Coder completion behavior remains unchanged by default.
10. **Schema compatibility:** existing migration/outbox suites plus conference store tests;
    pre-existing v15 tests assert their own migration, not that it is forever the latest.
11. **All build/test/lint gates:** required on the final PR SHA. Passing an earlier SHA is not
    evidence that a later revision passed.
12. **Deployment smoke test:** the live two-participant checklist in the runbook is required
    before opening the bot to the conference. CI cannot verify credentials, actual Codex model
    entitlement, Xcode or the external bot's authorship without that deployment.

## Test-intent review

Unique regressions targeted by the new tests: model-rewritten answers entering Coder; fake
foreign-key approval fixtures hiding admission errors; the current day's source replacing a
queued case's baseline; a successful report without baseline evidence; another inference or
push after a lost publication response; a generic and conference completion both firing; and
a failed/malformed judge response being treated as approval.

The context-isolation test targets a separate composition mutant: passing the real shared
retriever, memory store or workspace to the conference model even with all ordinary tools
hidden. Existing status/workspace isolation tests do not assemble conversational context.
Its ordinary-mode positive control proves the fixture contains reachable data, rather than
passing vacuously on an empty database or missing files.

Nearest existing coverage is Generic Coder's native process/workspace tests, approval callback
and persistence tests. The new native test supplies the cross-component proof those isolated
tests do not provide. No tests assert that an LLM reliably detects all attacks or faithfully
implements every human proposal. Those are not deterministic harness guarantees.
