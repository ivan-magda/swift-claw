# Conference Coding Challenge workflow

Implementation contract for the Podlodka iOS Crew #18 deployment. This is an explicit,
opt-in conference profile; the ordinary single-owner daemon and Generic Coder contracts
remain unchanged. Deployment and live verification: [conference runbook](../CONFERENCE.md).

## Goal and scope

Participant idea → exact confirmed answer → tool-free AI precheck → durable queue →
Generic Coder → locally committed prototype → deterministic bot-authored draft PR →
private completion notification.

The participant supplies the idea. The coding agent translates it into code and must
report blocking constraints rather than silently substitute a materially different approach.
The judge is an admission filter, not a correctness proof, sandbox, or competition score.

v1 has one operator-configured active case, private Telegram conversations, one confirmed
submission per participant/case, a durable FIFO queue and separate Coder working copies.
Case format is a small JSON file. Switching the file and restarting activates the next case;
queued submissions retain their original case, repository and immutable baseline.

Out of scope: a general workflow engine, a new Codex runtime policy, internal OS sandbox,
scoring, automatic merging, simulator/Dactyl rendering, private source repositories, repeated
contest submissions for the same participant/case, and GitHub App installation tokens.

## Responsibilities and boundaries

- Telegram numeric sender ID, not model arguments or display names, identifies a participant.
- Conference participants receive only `challenge_current`, `challenge_submit` and
  `challenge_status`. No personal memory, ordinary Coder tools, filesystem/exec tools,
  workspace skills, MCP sessions or owner operational commands are exposed.
- Conference context assembly uses empty workspace, memory and recall collaborators. Only the
  current participant's session history and the built-in conference policy are available to the
  conversational model (along with ordinary runtime metadata and conference tool results).
  Hiding tools alone is insufficient: ordinary DM recall spans the single owner's sessions.
  Ordinary mode retains its existing workspace, memory and cross-session recall behavior.
- Trusted operator configuration chooses repository, baseline, PR base and bot identity.
  Participant text cannot select those workflow parameters.
- The exact persisted triggering message is checked against the prepared answer. A model
  rewrite is refused before the judge, queue or Coder. The participant confirms an immutable
  case/answer snapshot through the existing approval machinery.
- Only the publisher is passed the configured GitHub publication credential. Coder gets a
  separate HOME/CODEX_HOME and no ambient GitHub token, GitHub CLI config or SSH agent socket.
  These are application boundaries, not a claim that native code execution is OS-isolated.
- A dedicated conference host/account with no personal secrets is a deployment prerequisite.
  No new permission framework or nonstandard Codex CLI mode is introduced.

## Domain and storage

`ConferenceCase`: `id`, `title`, `prompt`, public `repositoryURL`, immutable full 40/64-digit
`baselineRef` commit SHA, and `baseBranch`. The existing target base branch must be frozen at
that SHA. Case IDs must not be reused for different cases during a deployment.

`ConferenceSubmission`: UUID, numeric participant ID, exact answer, immutable case snapshot,
durable approved origin, state, optional Coder job ID, PR/branch/commit evidence, failure
reason, notification marker and timestamps. `UNIQUE(participant_user_id, case_id)` prevents
one participant's new answer from replacing their confirmed answer.

Normal states: `queued → running → completed`. Terminal alternatives: `blocked`, `failed`,
`cancelled`, `needs_review`. During retryable publication, state remains `running`; no new
inference attempt is started. Original submissions survive unsuccessful code generation.

## Admission and judge

The participant sends the entire proposal as one message. `challenge_submit` prepares an
approval card containing that exact text, case, repository, baseline, base branch and consent
to publish the proposal/code to GitHub. It is an approval-only dangerous-tier tool.

After confirmation, the workflow verifies the originating message and checks for an existing
submission before invoking the judge. Replaying the same approved submission returns its
existing UUID without another judge or Coder call. Competing inserts remain protected by
SQLite uniqueness.

`ConferenceSubmissionJudge` uses the configured primary LLM provider and model, without
conversation history or tools. The system instruction classifies the JSON-encoded case and
exact answer; it does not solve the case or assess the quality/novelty of the idea. Only an
explicit `SAFE` response admits work. `UNSAFE`, malformed output, tool calls, transport error
or timeout queues nothing and returns a participant-readable error. A rejected participant
can revise their message and confirm a new attempt because no submission was inserted.

The request has a 2,048-output-token allowance and a 30-second deadline; the enclosing tool
allows 45 seconds. Cancellation joins the provider operation. These side calls are not
currently included in ordinary conversational `/cost`; neither this limit nor the existing
Coder concurrency/time limit is a monetary budget.

## Source and Coder execution

`ConferenceRepositorySource` prepares `$CLAW_STATE_ROOT/conference-source/<case-id>` with
ambient GitHub/SSH credentials removed. It verifies canonical checkout and origin, resolves
the immutable baseline, checks it out detached and requires a clean tree. Valid cache reuse
requires no GitHub request. Invalid cache is replaced. The active source is preflighted at
boot; each queue claim resolves the source for its own stored case snapshot, not the newly
active case.

The fixed Coder request uses `.local`, `.separate`, exact `startRef`, `.localChanges`, no PR
base and `publishExistingChanges=false`. The task contains the case and unchanged proposal.
Instructions require preserving the approach, reporting actual checks/assumptions, committing
locally and not pushing. A local fixture identity is supplied as a fallback for clean Git
configuration; that commit author is distinct from the GitHub PR actor.

The existing Generic Coder prepares an independent copy and independently observes its
starting commit. Its approval/admission/policy checks are not weakened. A busy Coder leaves
the submission queued. Durable origin deduplication recovers the gap between Coder admission
and storing `coderJobID`. Interrupted/ambiguous inference requires review rather than replay.
Generic Coder completion notifications are disabled only for this conference composition.

## Publication

A successful Coder result must have absent publication, an independently observed baseline
matching the approved SHA, a workspace and a final commit. Otherwise it becomes `needs_review`.

The publisher first looks up the submission-derived branch across all PR states. A matching
open draft PR is reused before inspecting local state or pushing, which recovers a lost POST
response even if the old workspace is no longer available. Closed/merged, non-draft, foreign
actor, mismatched head/base/repository/commit evidence requires organizer review; it does not
cause a new competing PR.

For new publication, the publisher verifies the workspace lies below the Coder job root,
HEAD is the claimed final SHA, baseline is an ancestor, final differs from baseline and the
working tree is clean. It fetches the exact commit into a fresh, supervisor-owned bare Git
repository without publication credentials and checks ancestry there. Only the push from
this clean repository gets the bot token. No build, agent Git hook or agent-controlled Git
configuration is executed with that credential. The transfer directory is removed afterward.

Push refspec: `<final-sha>:refs/heads/conference/<submission-uuid>`, without force or merge.
The API creates a draft PR. The result is checked against the target repository, head branch,
head SHA, base branch, frozen baseline SHA, draft/open state, canonical PR URL and expected bot
login before storing `completed`.

The PR contains the case, original proposal, public submission UUID, baseline and explicitly
labelled Coder-reported checks. It does not publish private Telegram IDs. The organizer keeps
the participant-to-submission mapping in SQLite. All PRs in a public challenge repository are
public; conversation/status isolation is not confidentiality of published solutions.

Transient Git/network failures retain the same submission for publication retry. Permanent
invalid evidence requires review. If the database write after a successful publication fails,
the running submission remains recoverable through the existing-PR lookup.

## Completion and recovery

Terminal state is persisted before claiming one UUID-keyed conference outbox row. The row is
claimed idempotently before `notification_enqueued` is set. This yields one durable completion
notice per submission, not a claim of exactly-once Telegram network delivery: the inherited
outbox is at-least-once when a send acknowledgment is lost.

`challenge_status` derives identity from the trusted execution context and returns only the
requester's submission. A known UUID lets its owner query a previous day's submission.

Source/queue/publication/notification recovery reuse existing state; they do not introduce a
second workflow scheduler or an automatic retry of interrupted inference. Persistent remote
permission/push failures require operator intervention; v1 has no retry dashboard or retry
budget subsystem.

## Acceptance criteria and primary coverage

1. **Current case and exact human proposal:** `ConferenceWorkflowAcceptanceTests` and
   `ConferenceToolsTests`; reject rewritten answers before judge or queue.
2. **Confirmed identity, ownership and uniqueness:** real message/run/approval fixture,
   `ConferenceStoreTests`, `GroupApprovalCallbackTests` and workflow ownership/replay tests.
3. **Busy executor and original case after day switch:** workflow acceptance tests preserve
   FIFO work and use the queued case's own source/baseline.
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
   tests and the native CLI sentinel cover bot-token removal, fixed tools and startup identity.
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
