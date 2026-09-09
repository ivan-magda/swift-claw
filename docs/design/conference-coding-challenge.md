# Conference Coding Challenge workflow

Status: implementation contract for the Podlodka iOS Crew #18 conference deployment.

## Goal

A conference participant submits their own answer to the current case in Telegram. swift-claw preserves that exact answer, turns it into a bounded coding task, delegates implementation to the existing generic Coder capability, and publishes a draft pull request in the configured challenge repository using bot-owned GitHub credentials.

The participant supplies the idea. The coding agent may translate that idea into code, but must not silently replace it with a materially different solution.

## Scope

This is a conference-specific workflow layered on the generic Coder capability. Coder remains unaware of participants, conference days, scoring, or Wildberries.

The first production shape supports:

- one configured conference deployment and repository;
- one active case at a time;
- private Telegram participants admitted only to the conference surface;
- exact participant text captured before the coding run;
- one confirmed submission per participant per case;
- durable submission state and restart recovery;
- bounded FIFO execution through the existing Coder service;
- a fresh Coder workspace from the case baseline;
- draft PR publication to the case base branch;
- participant-scoped status and completion notification;
- bot-owned GitHub authentication kept outside participant/model input.

Scoring, automatic merging, Dactyl/simulator rendering, multiple concurrent answers from one participant for one case, and a general workflow engine are out of scope.

## Trust boundaries

1. Telegram numeric user id is the participant identity. Usernames/display names are presentation only.
2. Conference mode is a separate deployment/state root. It does not expose personal memory, general Coder submission, arbitrary write/exec tools, MCP configuration, or owner-only controls to participants.
3. Case repository, start ref, base branch and publication scope come from trusted operator configuration, never from participant/model arguments.
4. The stored participant answer is immutable after confirmation. Coder receives the exact stored answer plus trusted workflow instructions.
5. Each submission starts from the case baseline in a separate Coder workspace.
6. GitHub publication uses bot-owned credentials. The participant does not provide GitHub credentials and is not the GitHub PR actor.
7. A coding failure does not delete or invalidate the participant submission.

## Domain model

### ConferenceCase

- `id`: stable lowercase identifier, e.g. `day-3`
- `title`
- `prompt`: full participant-facing case text
- `repositoryURL`: configured GitHub HTTPS repository
- `baselineRef`: immutable commit SHA or operator-controlled frozen ref
- `baseBranch`: PR target branch
- `status`: `draft | active | closed`
- timestamps

Exactly one case may be `active`.

### ConferenceSubmission

- UUID `id`
- numeric `participantUserID`
- optional participant display name snapshot
- `caseID`
- exact `answer`
- state
- optional `coderJobID`
- optional PR URL
- failure/review reason
- timestamps

A unique constraint on `(participant_user_id, case_id)` enforces one confirmed submission per case.

Submission states:

`queued -> running -> completed`

Terminal alternatives: `blocked | failed | cancelled | needs_review`.

`queued` is durable and means the answer was accepted even if Coder has no free slot.

## Participant surface

The model receives only the conference tools below when a Telegram DM is admitted in conference mode:

- `challenge_current` — return the active case.
- `challenge_submit` — store the participant's answer for the active case. The tool derives participant identity from `ToolExecutionContext`; callers cannot supply another user id, repository, branch, baseline or publication scope.
- `challenge_status` — return the caller's submission state for the active case or an explicit submission id owned by the caller.

The conference skill tells the conversational model to explain the activity, never solve the case on behalf of the participant, preserve the participant's proposal, and use these tools. It is guidance only; identity, limits and repository scope remain enforced in code.

Submission requires an interactive requester. The workflow treats one explicit `challenge_submit` call as the participant's confirmation of the exact `answer` argument; the approval system is not reused as a second confirmation layer because the tool only creates a bounded conference record and cannot choose publication scope.

## Execution

A `ConferenceWorkflowService` owns execution of persisted `queued` submissions.

For each claim it constructs a fixed `CoderRequest`:

- source: configured case GitHub repository;
- workspace: `.separate`;
- start ref: case baseline;
- deliverable: `.pullRequest` for the first implementation;
- base branch: case base branch;
- publish existing changes: false;
- task: case text plus the exact participant answer;
- instructions: preserve the participant's approach; do not substitute a materially different solution; run repository-provided relevant checks; create a draft PR if the backend supports draft publication, otherwise create a normal PR clearly marked as generated and never merge it.

The workflow uses a dedicated trusted service-origin admission seam into Coder rather than forging an interactive Telegram approval. That seam must accept only already-persisted conference submissions and fixed trusted case configuration; ordinary `coder_submit` keeps its existing approval contract unchanged.

When Coder is busy, the submission remains `queued`. Claims are atomic in SQLite so daemon restart or two workers cannot start the same submission twice.

On Coder completion the workflow records its durable result. A confirmed PR URL produces `completed`; a terminal Coder failure maps to `failed` or `blocked`. An interrupted/uncertain publication maps to `needs_review`, never an automatic blind rerun.

## GitHub actor

The conference deployment runs Coder with a dedicated GitHub App installation credential (or equivalent bot-only credential) scoped to the challenge repository. Personal GitHub credentials must not be present in the conference daemon/Coder environment.

`CoderResult.githubActor` is checked against an optional configured expected bot login. A mismatch never marks the submission completed; it becomes `needs_review` and is surfaced to the operator.

## Configuration

Conference mode is off by default. Minimum config:

- `CLAW_CONFERENCE_ENABLED`
- `CLAW_CONFERENCE_REPOSITORY`
- `CLAW_CONFERENCE_EXPECTED_GITHUB_ACTOR` (optional but recommended)

Cases are operator-managed durable rows. A minimal CLI surface publishes/activates/closes cases; changing files or a model turn cannot silently alter an active case.

Conference mode requires Coder to be enabled and a separate non-personal state root. Config validation rejects conference mode when these prerequisites are absent.

## Recovery and idempotency

- Submission insertion and uniqueness are one SQLite transaction.
- Queue claim is an atomic `queued -> running` transition.
- A stored `coderJobID` is the durable link to an admitted Coder job.
- Restart reconciliation examines `running` submissions. If the linked Coder job is terminal, consume that result. If execution/publication ownership is uncertain, mark `needs_review`; do not create another job automatically.
- Completion notification may be retried, but it must not start a new coding run.

## Acceptance criteria

1. Two different participant ids can submit different answers to the same active case and receive independent submission ids/Coder jobs.
2. A participant cannot submit or query as another numeric user id.
3. The second submission from the same participant for the same case is rejected without overwriting the first answer.
4. A submission persists while Coder is busy and runs later without participant retry.
5. Every generated Coder request uses the configured repository, baseline and base branch regardless of participant text.
6. Coder receives the exact stored answer, including text that resembles instructions trying to change repository/publication scope, as task data only.
7. Restart does not duplicate a submission or blindly rerun an uncertain Coder job.
8. A successful result records branch/commit/PR and returns it only to the owning participant.
9. A configured expected GitHub actor mismatch becomes `needs_review`, not `completed`.
10. Conference mode off leaves the existing single-owner and generic Coder behavior unchanged.
11. Existing Coder approval tests continue to pass unchanged.
12. Full `swift test`, formatting and lint gates pass.
