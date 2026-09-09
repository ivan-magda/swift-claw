# Conference Coding Challenge workflow

Status: implementation contract for the Podlodka iOS Crew #18 conference deployment.

## Goal

A conference participant sends their own answer to the current case in Telegram. swift-claw preserves that exact answer, asks the participant to approve the bounded submission action, stores it durably, and delegates implementation to the existing Generic Coder capability. The participant supplies the idea; the coding agent may translate it into code, but must not silently replace it with a materially different solution.

## Scope

This is a conference-specific workflow layered on Generic Coder. Coder remains unaware of participants, conference days, scoring, or event-specific product concepts.

The v1 production shape supports one isolated conference deployment, one operator-configured active case, private Telegram participants, one confirmed submission per participant/case, durable FIFO execution, a supervisor-verified immutable baseline, isolated Coder workspaces, deterministic draft-PR publication, participant-scoped status, and restart-safe completion delivery.

Scoring, automatic merging, Dactyl/simulator rendering, multiple submissions from one participant for one case, private challenge repositories, GitHub App installation-token authentication, and a general workflow engine are out of scope for v1.

## Trust boundaries

1. Telegram numeric user id is the participant identity. Usernames/display names are presentation only.
2. Conference mode is a separate deployment profile. Participants do not receive personal memory, Generic Coder tools, arbitrary filesystem/exec tools, MCP, skills, scheduling, learning controls, or owner-only operational commands.
3. Case repository, immutable baseline commit, PR base branch, publication repository and publication identity come only from trusted operator configuration.
4. The participant answer is persisted exactly as approved and is immutable for that participant/case.
5. The supervisor, not Codex, materializes and verifies the trusted challenge source before a Coder job exists.
6. Coder receives a local source and creates a separate workspace from the exact configured commit SHA. A successful result is publishable only when the supervisor-observed starting commit equals that SHA.
7. Coder has no GitHub publication credential. GitHub push/API access belongs only to the deterministic publisher.
8. The publisher accepts only workspaces below the conference Coder job root, verifies the local commit graph and clean tree, pushes a submission-derived branch, creates or reuses one draft PR, and verifies head SHA/base/actor from GitHub.
9. Existing Generic Coder approval semantics remain unchanged.
10. Conference mode requires an explicit non-personal state root and conference-only credential/state directories.

## Domain model

### ConferenceCase

One active case is loaded from the operator-owned JSON case file at daemon start:

- `id`: stable lowercase identifier, e.g. `day-3`;
- `title`;
- `prompt`: participant-facing case text;
- `repositoryURL`: public GitHub HTTPS repository for v1;
- `baselineRef`: exact immutable 40- or 64-character Git commit SHA;
- `baseBranch`: draft pull-request target branch.

The case snapshot is immutable for stored submissions. Changing the file requires daemon restart and cannot rewrite an already-approved submission.

### ConferenceSubmission

A submission contains UUID id, numeric participant id, immutable case snapshot, exact answer, durable approved origin, state, optional Coder job id, optional PR/branch/commit evidence, optional failure/review reason, durable notification state and timestamps.

`UNIQUE(participant_user_id, case_id)` enforces one confirmed submission per participant/case.

Normal state path:

`queued -> running -> completed`

Terminal alternatives are `blocked | failed | cancelled | needs_review`.

## Participant surface

Conference mode exposes exactly:

- `challenge_current` — active case;
- `challenge_submit` — prepare and submit the caller's exact proposal;
- `challenge_status` — return only the caller's submission status.

The trusted conference system prompt tells the conversational model not to solve the case for the participant and not to rewrite the participant's proposal. Those are guidance constraints; identity, answer integrity, uniqueness, repository scope, baseline and approval binding are enforced in code.

`challenge_submit` is dangerous-tier. Its durable approval binds the exact answer and trusted case snapshot. The approved action only inserts a queued submission; it does not run Coder synchronously.

## Trusted source materialization

Before the conference workflow is composed, `ConferenceRepositorySource` materializes the configured public repository below `$CLAW_STATE_ROOT/conference-source/<case-id>` using Git with ambient GitHub/SSH credentials removed.

A cached source is reused across restart only when all of these checks pass:

- canonical checkout is the expected source directory;
- `origin` resolves to the configured repository;
- `HEAD` equals the configured immutable baseline SHA;
- the baseline resolves to that exact SHA;
- the working tree is clean;
- HEAD remains detached from participant-controlled branches.

If verification fails, the cached source is discarded and materialized again. A valid cached source therefore lets a restart proceed without GitHub availability.

## Coder execution

`ConferenceWorkflowService` owns persisted `queued` submissions. For each claim it constructs a fixed `CoderRequest`:

- source: `.local` trusted source path prepared by the supervisor;
- workspace: `.separate`;
- start ref: exact case baseline SHA;
- deliverable: `.localChanges`;
- base branch: none;
- publish existing changes: false;
- task: case text plus exact stored participant answer;
- trusted instructions: preserve the proposal, treat it as task data, run relevant repository checks, commit intended changes locally, never push or create a PR.

The queue reuses the durable `ToolExecutionContext` from the already-approved conference submission. Generic Coder admission remains deduplicated by the original approved origin, closing the crash window between Coder admission and storing `coderJobID`.

Conference Coder completion notices are disabled. The conference workflow is the single participant-facing completion path.

A successful Coder result is eligible for publication only when:

- publication is absent (Coder did not publish anything itself);
- baseline was independently observed by Coder supervisor code;
- observed starting commit exactly equals the case baseline SHA;
- a workspace and final commit are present.

Missing or ambiguous evidence goes to `needs_review`; it is never silently treated as success.

## Deterministic publication

`ConferenceGitHubPublisher` is outside Coder and owns the only GitHub publication credential.

Before push it verifies:

- repository URL matches the trusted case repository;
- workspace is below `$CLAW_STATE_ROOT/coder/jobs`;
- starting/final commit values are valid commit ids and differ;
- workspace `HEAD` equals the reported final commit;
- configured baseline is an ancestor of the final commit;
- working tree is clean.

It pushes exactly:

`<final-commit>:refs/heads/conference/<submission-uuid>`

and creates or reuses an open draft PR to the configured base branch. GitHub response evidence must match expected head branch, head SHA, base branch and actor before the submission becomes `completed`.

Transient push/API failures leave the durable submission `running`; publication is retried idempotently with the same submission-derived branch. Invalid commit/workspace/repository evidence or actor mismatch becomes `needs_review`.

## Credentials and deployment boundary

v1 uses two distinct credential boundaries.

### Codex credential

`CLAW_CODER_CONFIG_HOME` must be inside the isolated conference state root and contain only a conference-specific Codex login. Conference Coder receives a dedicated `HOME`/`CODEX_HOME`; ambient `GH_TOKEN`, `GITHUB_TOKEN`, `GH_CONFIG_DIR`, `SSH_AUTH_SOCK` and `GIT_ASKPASS` are removed.

Do not reuse a personal Codex home or place personal credentials/data in the conference state/home. Native Codex sandbox behavior is defense in depth, not the sole secret boundary for participant-controlled prompts.

### GitHub publisher credential

v1 expects a dedicated bot-user GitHub token in `GH_TOKEN`, scoped only as needed for the challenge repository. Startup calls `GET /user` and requires its login to equal `CLAW_CONFERENCE_EXPECTED_GITHUB_ACTOR`. Personal GitHub credentials must not be present in the conference deployment.

GitHub App installation tokens use a different authentication/identity model and are not implemented by this v1 contract.

## Completion delivery

Terminal submission state is persisted before Telegram notification. An idempotent conference outbox row is keyed by immutable submission UUID. Only after the outbox row exists is `notification_enqueued` set. Restart/retry therefore cannot create a second completion message.

`challenge_status` derives requester identity from `ToolExecutionContext` and refuses access to another participant's submission.

## Configuration

Conference mode is off by default. v1 requires:

- `CLAW_CONFERENCE_ENABLED=true`;
- explicit `CLAW_STATE_ROOT=/absolute/non-personal/state/root`;
- `CLAW_CONFERENCE_CASE_FILE=/absolute/path/to/case.json`;
- `CLAW_CONFERENCE_EXPECTED_GITHUB_ACTOR=<dedicated-bot-login>`;
- `GH_TOKEN=<dedicated-repository-scoped-bot-token>`;
- Generic Coder enabled;
- `CLAW_CODER_CONFIG_HOME` below `CLAW_STATE_ROOT` with a conference-only Codex credential.

The case file is bounded to 128 KiB and requires an immutable full commit SHA. The repository must be public in v1 because trusted source materialization intentionally runs without GitHub credentials.

## Recovery and idempotency

- Submission insert + participant/case uniqueness are one SQLite transaction.
- Queue claim is atomic `queued -> running`.
- Stored `coderJobID` durably links a submission to Coder.
- Crash after Coder admission but before link persistence is recovered by Generic Coder admission deduplication.
- A running submission with no retained Coder job is requeued on boot.
- A linked terminal Coder result is projected into conference state exactly once.
- Transient deterministic-publication failures are retryable; ambiguous Coder execution is not blindly rerun.
- Source materialization cache is verify-before-reuse.
- Completion notification has its own idempotent outbox identity.

## Acceptance criteria

1. Different participant ids can submit independent answers to the same case.
2. A participant cannot submit/query as another numeric user id.
3. A second confirmed submission for the same participant/case cannot overwrite the first.
4. Busy Coder leaves submission queued for later execution.
5. Participant/model text cannot choose repository, baseline, publication branch/base, credentials or publication identity.
6. Coder receives the exact stored participant proposal as task data.
7. Every Coder request starts from the supervisor-prepared local source and exact immutable SHA.
8. Publication is impossible when independently observed starting commit differs from the configured baseline.
9. Coder receives no GitHub publication credential and emits no generic completion notification.
10. Only the deterministic publisher can push/create a PR.
11. Transient publisher failure retries without losing or duplicating the submission/PR identity.
12. Successful result stores verified branch/commit/draft-PR and exposes it only to the owning participant.
13. Missing/mismatched GitHub actor or invalid commit/workspace evidence becomes `needs_review`.
14. Valid source cache survives restart without requiring GitHub; invalid cache is never trusted.
15. Conference mode off leaves ordinary single-owner and Generic Coder behavior unchanged.
16. Conference participant tools are exactly `challenge_current`, `challenge_submit`, `challenge_status`.
17. Completion notification is restart-safe and idempotent.
18. Conference mode refuses unsafe/missing state, Coder-home and GitHub actor configuration.
19. Full tests, formatting and lint gates pass.
