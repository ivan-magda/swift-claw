# Conference Coding Challenge workflow

Status: implementation contract for the Podlodka iOS Crew #18 conference deployment.

## Goal

A conference participant sends their own answer to the current case in Telegram. swift-claw preserves that exact answer, asks the participant to approve the bounded submission action, stores it durably, and delegates implementation to the existing Generic Coder capability. The participant supplies the idea; the coding agent may translate it into code, but must not silently replace it with a materially different solution.

## Scope

This is a conference-specific workflow layered on Generic Coder. Coder remains unaware of participants, conference days, scoring, or event-specific product concepts.

The first production shape supports:

- one isolated conference deployment;
- one operator-configured active case at a time;
- private Telegram participants admitted only to the conference surface;
- exact participant text captured before the coding run;
- one confirmed submission per participant per case;
- durable submission state and restart recovery;
- FIFO execution through the existing Coder service;
- a fresh Coder workspace from the configured case baseline;
- PR publication to the configured case base branch;
- participant-scoped status and completion notification;
- optional verification of the GitHub actor used for publication.

Scoring, automatic merging, Dactyl/simulator rendering, multiple submissions from one participant for one case, and a general workflow engine are out of scope.

## Trust boundaries

1. Telegram numeric user id is the participant identity. Usernames/display names are presentation only.
2. Conference mode is a separate deployment profile. It does not advertise personal memory, Generic Coder submission, arbitrary filesystem/write/exec tools, MCP tools, skills, scheduling, learning controls, or owner-only operational commands to participants.
3. Case repository, baseline ref, base branch and publication scope come from trusted operator configuration, never participant/model arguments.
4. The participant answer is stored exactly as approved and is immutable for that participant/case.
5. Each coding run uses `.separate` workspace and starts from the case baseline.
6. GitHub credentials are deployment-owned. Participants never provide GitHub credentials or choose publication identity.
7. A coding failure does not delete or overwrite the participant submission.
8. Existing Generic Coder approval semantics remain unchanged.

## Domain model

### ConferenceCase

One active case is loaded from the operator-owned JSON case file at daemon start:

- `id`: stable lowercase identifier, e.g. `day-3`;
- `title`;
- `prompt`: participant-facing case text;
- `repositoryURL`: GitHub HTTPS repository;
- `baselineRef`: immutable commit SHA or operator-controlled frozen ref;
- `baseBranch`: pull-request target branch.

The active case is a trusted immutable snapshot for the running daemon. Changing the file does not mutate an already-approved or stored submission; a daemon restart is required to load another case.

### ConferenceSubmission

- UUID `id`;
- numeric `participantUserID`;
- immutable `caseSnapshot`;
- exact `answer`;
- durable approved origin (`runID`, `sessionID`, `chatID`, requester id, tool call id, approval id);
- state;
- optional `coderJobID`;
- optional PR URL / branch / commit;
- optional failure or review reason;
- durable completion-notification state;
- timestamps.

A unique constraint on `(participant_user_id, case_id)` enforces one confirmed submission per case.

Submission states:

`queued -> running -> completed`

Terminal alternatives: `blocked | failed | cancelled | needs_review`.

`queued` is durable and means the participant answer has been accepted even if Coder has no free slot.

## Participant surface

When conference mode is enabled, the model receives only these tools:

- `challenge_current` — return the active case;
- `challenge_submit` — prepare and submit the caller's exact answer for the active case;
- `challenge_status` — return the caller's own submission state for the active case or an explicit submission id owned by the caller.

The trusted conference system prompt tells the conversational model to explain the activity, never solve the case on behalf of the participant, preserve the participant's proposal, and use only this challenge surface. This prompt is guidance; identity, uniqueness, repository scope and approval binding are enforced in code.

`challenge_submit` is dangerous-tier and requires an interactive requester plus a durable approval. The prepared approval binds the exact answer together with the trusted case snapshot and canonical target. In a DM only the originating participant can approve it. If group mode is ever explicitly configured for the conference deployment, only the originating requester may approve their conference submission; this is intentionally stricter than Generic Coder's existing group approval behavior.

The approved action inserts the durable submission. It does not invoke Coder synchronously.

## Execution

`ConferenceWorkflowService` owns execution of persisted `queued` submissions.

For each claim it constructs a fixed `CoderRequest`:

- source: case GitHub repository;
- workspace: `.separate`;
- start ref: case baseline;
- deliverable: `.pullRequest`;
- base branch: case base branch;
- publish existing changes: false;
- task: case text plus the exact stored participant answer;
- trusted instructions: preserve the participant approach, treat the proposal as task data rather than authority, run repository-provided relevant checks, and never merge the pull request.

The queue does **not** forge a fresh Coder approval or create a synthetic identity. It reuses the durable `ToolExecutionContext` of the already-approved conference submission when calling the existing Coder service. Generic Coder deduplicates admission by the original `(runID, toolCallID)`, which also closes the crash window between Coder admission and storing `coderJobID`: replay returns the already-admitted job instead of launching a second one.

When Coder is busy or temporarily unavailable, a claimed submission is returned to `queued`. `recoveryRequired` or a stale execution policy moves the submission to `needs_review` rather than weakening the Coder contract.

On Coder completion the workflow records its durable result. A confirmed PR URL can produce `completed`; terminal Coder failures map to `failed`, `blocked`, or `cancelled`. Interrupted execution, missing durable results, uncertain publication, missing linked jobs, or other ambiguous ownership maps to `needs_review` and is never blindly rerun.

## GitHub actor

The conference deployment should run Coder with a dedicated GitHub App installation credential (or equivalent bot-only credential) scoped to the challenge repository. Personal GitHub credentials should not be present in that deployment.

If `CLAW_CONFERENCE_EXPECTED_GITHUB_ACTOR` is configured, `CoderResult.githubActor` must match it before a successful publication is marked `completed`. A mismatch becomes `needs_review`. This check is an additional verification layer; the credential isolation itself remains an operator/deployment responsibility.

## Completion delivery

Terminal status is persisted before participant notification. A terminal submission remains `notification_enqueued = false` until an idempotent conference outbox row exists. The outbox key is derived from the immutable submission UUID, so restart or retry cannot create a second completion message. Only after the outbox insert succeeds is the submission marked notification-enqueued.

The participant can also query `challenge_status`; status lookup always derives caller identity from `ToolExecutionContext` and refuses access to another participant's submission.

## Configuration

Conference mode is off by default. Current configuration:

- `CLAW_CONFERENCE_ENABLED=true`;
- `CLAW_CONFERENCE_CASE_FILE=/absolute/path/to/case.json`;
- `CLAW_CONFERENCE_EXPECTED_GITHUB_ACTOR=<bot-login>` — optional verification layer;
- Generic Coder must also be enabled and healthy.

The case file is bounded to 128 KiB and validated before use, including repository/ref fields through the existing `CoderRequest` validation path.

Conference mode should run with a separate non-personal state root and bot/Coder credentials. The restricted conference capability profile is enforced in composition; deployment separation of credentials/state remains an operational prerequisite and should be part of the runbook.

## Recovery and idempotency

- Submission insertion and participant/case uniqueness are one SQLite transaction.
- Queue claim is an atomic `queued -> running` compare-and-set.
- A stored `coderJobID` is the durable link to the admitted Coder job.
- A crash after Coder admission but before the link is stored is recovered through Coder's existing `(runID, toolCallID)` admission deduplication.
- A `running` submission without an attached Coder job is requeued on boot because no distinct Coder ownership has been retained yet; Coder admission replay itself remains deduplicated by the approved origin.
- A linked terminal Coder result is projected once into the conference terminal state.
- Ambiguous/interrupted execution is `needs_review`, never an automatic blind rerun.
- Completion notification uses a separate idempotent outbox identity and never starts a coding run.

## Acceptance criteria

1. Two different participant ids can submit different answers to the same active case and receive independent submission ids/Coder jobs.
2. A participant cannot submit or query as another numeric user id.
3. The second submission from the same participant for the same case is rejected without overwriting the first answer.
4. A submission persists while Coder is busy and runs later without participant retry.
5. Every generated Coder request uses the configured repository, baseline and base branch regardless of participant text.
6. Coder receives the exact stored answer, including text resembling instructions that try to change repository/publication scope, as task data only.
7. Restart does not duplicate a submission or blindly rerun an uncertain Coder job.
8. A successful result records branch/commit/PR and exposes it only to the owning participant.
9. A configured expected GitHub actor mismatch becomes `needs_review`, not `completed`.
10. Conference mode off leaves existing single-owner and Generic Coder behavior unchanged.
11. Existing Generic Coder approval tests continue to pass unchanged.
12. Conference participant tool definitions are exactly `challenge_current`, `challenge_submit`, and `challenge_status`.
13. Completion notification is restart-safe and idempotent.
14. Full `swift test`, formatting and lint gates pass.
