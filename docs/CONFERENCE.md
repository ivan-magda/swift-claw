# Running the conference coding challenge

The [architecture contract](ARCHITECTURE.md#133-conference-coding-challenge) defines the workflow;
[acceptance notes](design/conference-coding-challenge.md) map automated coverage. This guide covers
deployment, daily operation and the live smoke test.

## Deployment prerequisites

Use a dedicated conference Telegram bot and a dedicated host/OS account with no personal
files, SSH agent, GitHub CLI session or personal MCP integrations. A separate state directory
alone is not a sandbox. The existing native Codex installation remains responsible for its
normal execution permissions; this feature adds no new Codex permission framework.

Prepare the usual swift-claw Telegram and primary LLM configuration as described in
[local development](LOCAL_DEV.md) and [customization](CUSTOMIZATION.md). Conference mode
also needs a working authenticated Codex CLI, available Git, a public challenge repository,
and a **dedicated GitHub bot-user account** with write access to that repository. Use a
repository-restricted token with the permissions needed to push code and create PRs. Do not
use your personal token. GitHub App installation tokens are not supported in this version.

For the actual `wowlocal/crew18-sim` iOS project, use the repository's documented Xcode/toolchain
and run its baseline checks on that host before admitting participant work. CI tests for
swift-claw do not build the conference iOS application.

## Case and environment

Create one operator-owned JSON file per case. Example structure (replace the placeholder with
a real full commit SHA; do not use `main`, a tag or a shortened SHA as `baselineRef`):

```json
{
  "id": "day-1",
  "title": "Accessibility regression",
  "prompt": "Describe your own approach to fixing accessibility regressions after a component release.",
  "repositoryURL": "https://github.com/wowlocal/crew18-sim",
  "baselineRef": "REPLACE_WITH_FULL_COMMIT_SHA",
  "baseBranch": "challenge/day-1"
}
```

Create the target `challenge/day-1` branch in the challenge repository at that same commit
before running submissions. Freeze it for the case; do not merge participant solutions into
it. Each solution is published to a separate `conference/<submission-uuid>` branch.

Set the conference-specific environment in the same environment loaded by the daemon:

```sh
export CLAW_CONFERENCE_ENABLED=true
export CLAW_STATE_ROOT=/absolute/path/to/conference-state
export CLAW_CONFERENCE_CASE_FILE=/absolute/path/to/cases/day-1.json
export CLAW_CONFERENCE_EXPECTED_GITHUB_ACTOR=your-conference-bot-login
export CLAW_CODER_ENABLED=true
export CLAW_CODER_CONFIG_HOME="$CLAW_STATE_ROOT/codex-home"
```

Supply `GH_TOKEN` securely to the daemon, not to the Codex login command or a participant.
Do not paste credentials into case files, chat, PR descriptions or committed scripts. Sign in
to Codex using the conference-only `CODEX_HOME` matching `CLAW_CODER_CONFIG_HOME`; do not copy a
personal configuration directory with unrelated integrations. Keep the installed CLI and its
required flags compatible with the existing Generic Coder configuration.
The config home must remain within the state root after resolving symlinks; a path that only
appears to be inside it is refused at startup.

Startup refuses a missing token, wrong expected bot login, absent Coder, invalid case or
invalid conference configuration. It also materializes and verifies the active public source
without GitHub credentials. Use a new non-personal state root, not a copy of the ordinary
assistant's database. Start with one concurrent Coder job and review operating cost before
increasing it. One confirmed answer per participant/case is enforced, but there is no global
monetary budget or conference-registration system.

## Participant interaction

1. Ask the bot for the current challenge in a private message.
2. Send your **entire proposed solution in one message**. Sending only “submit my previous
   answer” does not select an earlier message in v1; resend the proposal itself.
3. Check and confirm the approval card. It binds the exact text and case, including consent
   to publish the proposal and generated code.
4. After the tool-free safety check, the bot returns a queued submission UUID. An unsafe or
   unavailable precheck queues nothing; the participant may correct/resend and confirm again.
5. Ask for status or use the eventual completion message. A successful result includes a draft
   PR URL. A failed/blocked/review-required implementation retains the submitted human answer.

The bot publishes the PR; the participant remains the author of the idea. The public PR
contains the proposal and submission UUID, while the private database retains the numeric
Telegram participant mapping. Participants do not need GitHub accounts or repository access.
Published solutions in a public repository are visible to everyone.

## Changing the question

Stop the conference daemon, select the next operator-authored case file (new unique `id`),
verify its base branch/SHA, and restart. Old queued submissions continue from their own
stored case snapshots; switching the active case does not change their answers or repositories.
An old unconfirmed approval may be rejected as stale and require a fresh current-case request.
Do not reuse a day ID with materially different conditions.

Changing the selected Coder executable, PATH, profile or config home also invalidates pending
approvals. Queued submissions keep the execution policy originally approved; if it differs at
admission, or an older stored submission has no policy binding, the submission becomes
`needs_review` without launching new Coder work. Arrange organizer review and renewed authorization;
there is no automatic reapproval or participant resubmission path for an already queued answer.

## Live acceptance checklist

Run this against the dedicated deployment before inviting participants. Keep a short receipt
with swift-claw commit, Codex version, baseline SHA and the two resulting PR URLs. Never include
credentials or private identifiers in public receipts.

- Use two real Telegram accounts. Both see the published case; each submits a different short
  proposal and confirms it. A participant cannot approve or query the other's private submission.
- Verify each proposal is reproduced unchanged in its own PR and each branch starts from the
  same baseline. PRs are **draft**, target the configured case branch and have the configured
  bot account as GitHub author, not the operator's account. Baseline/main remain unchanged.
- Verify each participant receives their own result, not a generic Coder completion followed
  by a second conference completion. Repeating confirmation must not create another submission.
- Inspect actual reported checks and the generated diff. “PR created” does not mean “iOS build
  succeeded”, “tests passed” or “the proposal was faithfully implemented”. Run the repository's
  checks independently when those claims matter for the event.
- Exercise the precheck with a harmless valid proposal and an explicit out-of-scope request
  such as asking for host credentials. Confirm refusal queues nothing. This is a smoke test,
  not evidence that a probabilistic filter cannot be bypassed.
- Queue work while Coder is busy and confirm it is retained. Restart with pending work and
  inspect status; interrupted inference is marked for review rather than silently rerun.
  Test publication-response-loss recovery deterministically through the automated suites.

## Operations and failure handling

Use `challenge_status` with a known submission UUID to query a previous day's answer. Durable
submission, Coder result, branch and PR identities remain linked in the conference SQLite
state. Review `needs_review` manually; do not delete rows to force an automatic rerun. Keep
retained Coder workspaces until their publication/review is settled.

Transient source Git failures keep the submission queued at its original FIFO position, including
same-second submissions, and preserve an existing source cache. Only known-invalid caches are
replaced; a failed new clone or its validation removes the partial source for the next attempt.
A source identity or baseline mismatch that persists after preparation requires review.
Transient publication failures retry the same branch and look for an existing PR first.
Persistent authentication, permission or push failures need operator repair. A closed,
merged, non-draft or mismatched existing PR is not automatically replaced or modified.
Completion delivery uses the existing at-least-once Telegram outbox, so a lost network
acknowledgment may still duplicate a send even though there is only one durable notice.

The safety judge and coding-agent inference are probabilistic. The judge is not an execution
sandbox, and its extra request is not currently included in conversational `/cost`. A dedicated
secret-free execution environment and limited publication credential are still required.
