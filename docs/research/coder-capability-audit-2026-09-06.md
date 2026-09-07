# Generic Coder capability: independent audit and design inputs

**Date:** 2026-09-06

**Status:** research for brainstorming; not an approved design or implementation plan.

**Repository examined:** `main` at `d47151764c74ae2b87799d2de58912f3b08b4283`.

This supplements [the September 5 study](coder-capability-2026-09-05.md). It distinguishes
verified implementation facts, version-specific observations, and proposed product choices.
`docs/ARCHITECTURE.md` remains normative.

The subsequent local design draft collects accepted product decisions and the proposed technical
contract. It lives under the repository's intentionally ignored `docs/superpowers/specs/` working
directory, not in the normative specification or an implementation plan.

## Product scope established in this discussion

- Coder is a general swift-claw capability: delegate a repository coding task and return its result.
- Codex headless is the first backend. A small internal seam should permit replacement without
  making the product contract depend on Codex terminology.
- Conference participants, cases, scoring, and submission tracking do not define this capability.
- A branch, commit, or PR can be an artifact; publishing is not the definition of successful coding.
- **GitHub integration and automated PR creation are required in v1.** The owner explicitly
  rejected deferring them. Local-only coding remains useful; publication is selected for the
  particular request rather than required for every coding task.
- **The owner explicitly requires both workspace modes in v1, selected for each launch:** editing
  the supplied directory in place, and producing changes in a separate working copy.
- **The owner accepted end-to-end delegation to Codex:** Coder orchestrates the job; Codex carries
  out the repository workflow, including Git and GitHub PR operations. A separate Swift publisher
  is not part of the initial approach.
- **In-place execution must support existing uncommitted work.** The owner supplied a concrete
  acceptance scenario: fix a bug in changes already made by the owner or another agent before
  those changes have been committed. A blanket clean-checkout prerequisite excludes this scenario.
- **Three source forms are accepted for v1:** an explicit local path, a GitHub repository URL,
  or a GitHub issue URL. A remote project is obtained as part of the task; a manual clone is not
  a prerequisite.
- The owner accepted existing Codex configuration by default with optional overrides, background
  task status/cancellation/completion, and preserving origin-based delivery for future group topics.
- The owner requires a configurable N-task concurrency limit in generic Coder v1. A fixed
  one-task-only implementation would not support the intended event use. A default of 1, the
  proposed 30-minute per-job deadline, and busy-versus-queue handling remain design defaults to
  review rather than independently accepted product requirements.
- After independent design review, the owner accepted conversational-model-dependent cancellation,
  managed-process-group-only teardown, and pending notification retry on later outbox activity or
  restart. Neither deterministic control commands nor a general delivery retry timer is required
  for v1. PR construction remains delegated to Codex without a mandatory independent splitting of
  pre-existing committed history; the task remains the publication scope. Publication-head
  uniqueness is still recommended for N jobs, but is not an owner-declared release blocker.

Support for Xcode builds, the execution boundary, the mechanics of preserving/comparing initial
dirty state, and the details/defaults of publication remain open product decisions. Accepting an
initially dirty in-place workspace and supporting GitHub/PR are established product requirements.

The owner subsequently questioned the implementation cost of installing Codex and project
dependencies in a container. The revised recommendation is to begin with the operator's installed
Codex and local development tools, with a deliberately specified host execution policy. This is
a candidate response to that concern, not an approved relaxation of the existing VM guarantees.

## Method and limits

Three independent readers examined current swift-claw integration, the Codex runtime contract, and
workspace/Git behavior. The coordinator re-read the principal tool, lane, approval, scheduler,
outbox, and architecture contracts. We fetched official OpenAI, Git, and Apple documentation.

Local CLI checks used `codex-cli 0.153.4`. Git experiments used version 2.55.0 and disposable
repositories outside the project. No coding-model invocation, account mutation, credential read,
remote Git write, or product implementation was performed. Current online documentation can
describe behavior newer than the installed binary; documentation is not an isolation test.

## 1. Background execution is justified, but the timeout argument needs correction

The chat run's default budget is 180 seconds (`Sources/ClawCore/LLM/RunBudget.swift:59`). The
runtime checks it before tool dispatch (`Sources/ClawAgent/Runtime/AgentRuntime.swift:477`);
this is not an enclosing timeout that mechanically prevents every longer tool execution.

The previous study's 50-second maximum is not a fixed contract. `ExecuteCodeTool.timeout` adds
20 seconds to a configurable execution timeout; the latter permits up to 300 seconds
(`Sources/ClawTools/Tools/ExecuteCodeTool.swift:73`,
`Sources/ClawCore/Config/ExecConfig.swift:191`). MCP timeouts are configurable too.

Likewise, cancel-and-abandon is path-specific. Ordinary dispatcher execution uses that race, but
approved DM execution directly awaits the tool
(`Sources/ClawGateway/Approval/ApprovedActionExecutor.swift:140–145`).

The decisive product argument survives: session work chains behind its predecessor
(`Sources/ClawAgent/Runtime/SessionLaneRegistry.swift:61–102`). Waiting for a long coding task
occupies that lane. An independently supervised job keeps the conversation responsive and makes
status, cancellation, shutdown, and restart behavior explicit. It need not change the conversational
FIFO contract or increase its budget.

**Recommendation:** make the tool submit a durable job and promptly return its ID. Keep job
execution outside the conversation lane. Cancellation must own process termination; changing a
database row to failed after restart does not terminate an orphan.

## 2. Submission and completion need real integration work

The current `Tool.execute(arguments:canonicalTarget:)` signature receives neither authenticated
origin nor run/session/chat/tool-call identity
(`Sources/ClawCore/Domain/Tools/ToolContracts.swift:308–329`). A persisted background job needs
trusted routing and deduplication data supplied by runtime code, not by model-authored arguments.

`TurnEnqueuer` only schedules an already-persisted PENDING agent run. It is not a generic durable
completion API (`Sources/ClawGateway/Turn/TurnEnqueuer.swift:5–32`). Scheduler firing provides a
useful transaction pattern, but resets/detaints a session and inserts its confirmed prompt as trusted
input (`Sources/ClawData/Stores/Scheduling/ScheduledJobStoreGRDB.swift:287–304`). A Coder result
must not inherit either behavior: it is external output and must not reset the owner's chat.

The existing outbox is keyed by agent run (`Sources/ClawCore/Persistence/OutboxStore.swift:3–12`).
Durably finishing a coding job and reporting it therefore needs an explicit identity/delivery
contract whichever presentation we choose.

**Smaller candidate:** deliver a deterministic, redacted completion report through the durable
delivery path. An additional LLM turn to interpret every result is optional. If later conversation
uses the report, preserve its untrusted provenance. Define whether `/stop` cancels a coding job and
whether `/new` affects eventual delivery; existing commands only cancel conversational lane work.

## 3. `exec --json` is a suitable first adapter, not the only credible transport

Local help confirms JSONL output, final-message output, output schemas, ephemeral execution, and
the config/rules switches. Official documentation describes these as automation surfaces. It also
shows why a schema is useful for a predictable report shape.
[Source: non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode).

App-server has a stable protocol subset as well as experimental features; the CLI still labels
the command experimental. It is worth reconsidering when steering, interactive approval exchange,
or persistent conversation ownership becomes a requirement. One process per job is possible with
either transport, so that is not an exclusive advantage of `exec`.
[Source: App Server](https://learn.chatgpt.com/docs/app-server).

**Recommendation:** one controlled native executable invocation per coding job; bounded progress
and diagnostics; final report; timeout/cancellation; process termination outcome. Avoid generic
session creation, resume/fork, backend capabilities negotiation, and opaque settings extension
machinery until a requirement uses them. Backend-specific configuration can live in the concrete
adapter constructed at the composition root.

The npm launcher's signal handling supports the earlier study's explanation of its observed
misleading exit status (`@openai/codex/bin/codex.js:255–295` in the installed package). This audit
inspected the launcher but did not repeat the live Codex termination experiment. A supervisor still
needs bounded process-group teardown and stream draining. A successful exit cannot override an
already-selected cancellation outcome. Process groups alone do not contain descendants that escape
the group.

## 4. Completion, changes, and verification are different facts

`turn.completed` plus exit zero establishes execution completion, not satisfaction of an arbitrary
coding task. A structured final report is still the worker's account of what happened.

An empty `git status --porcelain` is not a no-op test. In the disposable reproduction, the worker-like
edit was committed: porcelain became empty while the captured base-to-final comparison still
contained `file.txt`. Git status describes differences relative to the current index/HEAD.
[Source: git status](https://git-scm.com/docs/git-status).

**Recommendation:** report separately the execution outcome, actual changes relative to the
captured starting state, and checks with their evidence. Include committed changes, remaining
tracked edits, and new files. An initially dirty workspace needs a pre-run baseline; comparing only
with HEAD attributes existing work to Coder. If comparison fails, say it is unavailable instead of
reporting no changes. Do not infer test success from the final narrative.

Keep useful partial changes after cancellation or failure. The earlier study's suggestion to
delete an unusual Git workspace is inappropriate for in-place editing and can discard the owner's
work. Automated publication can have stricter readiness checks without defining every coding run.

## 5. Workspace separation is independent of process containment

| Workspace choice | What it provides | What it does not provide |
| --- | --- | --- |
| In place | Edits where the owner asked; can include existing local state | Protection from overwriting existing work or concurrent external edits |
| Linked worktree | Separate working files and branch | Separate repository configuration/refs/object store, or automatic inclusion of dirty source files |
| Independent clone | Separate repository metadata; standalone result | Process confinement; dirty source state unless deliberately copied; independent object storage if hardlinks/alternates remain |

Disposable experiments reproduced three relevant behaviors:

1. A local clone and its source shared packed-object inodes. Altering the clone's pack after
   changing its mode also damaged the source; `git fsck` exited 30. A clone made with
   `--no-hardlinks` had distinct object inodes. Objects are immutable by Git convention, not by
   protection against arbitrary same-user writes. [Source: git clone](https://git-scm.com/docs/git-clone).
2. Setting a harmless configuration key inside a linked worktree changed what the original
   checkout read. This sharing is documented. Worktree registration/cleanup recovery is also
   documented; it does not justify categorically rejecting worktrees.
   [Source: git worktree](https://git-scm.com/docs/git-worktree).
3. A harmless configured fsmonitor command ran during plain `git status`. Same-user ownership
   does not make repository configuration trustworthy. Git inspection is not automatically free of
   execution effects. [Source: git config](https://git-scm.com/docs/git-config).

These experiments tested Git topology without a Codex sandbox. Effective sandbox permissions can
prevent the writes they used. The useful boundary rule is: **do not give repository-controlled code
or configuration more authority during inspection/publication than it had while editing.** Git
can run within the same controlled boundary; a fresh pathname alone does not make imported content
trusted. The v1 publisher needs an explicit import and credential design wherever its authority
exceeds the coding process's authority.

**Implications of the owner's two-mode requirement:** resolve and report the actual target path;
serialize conflicting Coder jobs by canonical workspace identity; define initial-state handling;
retain the result. An in-place request should not silently switch the owner's branch to honor a
base-branch field. A base reference belongs naturally to separate-copy preparation. Coder's own
lock cannot prevent an editor or unrelated process from changing an in-place workspace.

**Dirty in-place scenario:** the current files, including relevant uncommitted changes, are the
input to the coding task. Codex can fix a defect within that existing work and leave the resulting
files for review. A comparison with the pre-run state describes changes during the run; it cannot
prove human-versus-agent authorship when another writer runs concurrently. Snapshot mechanics are
still to be designed and do not imply stashing or committing the owner's work as a prerequisite.

Editing and publication scope are distinct. A local bugfix request does not by itself authorize
committing all pre-existing work. If a PR is requested, its agreed scope may include the original
uncommitted feature together with the fix; a fix that depends on that feature cannot necessarily
be published as a standalone change against the base branch. Do not promise automatic semantic
separation of overlapping edits. For a separate-copy run, whether to include source uncommitted
work remains an explicit initial-state choice rather than silently omitting the reported bug.

Mirrors and clone caches are not prerequisites for these workspace modes. The required v1 PR path
does need branch/commit/push handling, GitHub authorization, and PR creation, but those operations
can be performed by Codex using the installed Git and GitHub CLI. A custom Swift publisher is a
separate design choice, not a requirement implied by supporting PRs. The choice of worktree versus
independent clone should follow the execution boundary and result workflow, not the conference's
anticipated concurrency.

## 6. Native Codex isolation deserves a version-pinned check

Current official documentation describes read-only protection for `.git`, including a linked
worktree's resolved Git directory, and for `.codex`/`.agents` under writable roots. Thus the earlier
study's unrestricted shared-Git-write claim needs an effective-permissions qualification.
[Source: protected paths](https://learn.chatgpt.com/docs/agent-approvals-security#protected-paths-in-writable-roots).

Beta permissions support restricting command reads and writes, not just workspace writes. They do
not compose with legacy sandbox settings: passing `--sandbox` selects the older system. Network
domain restrictions also require an active proxy; merely enabling networking is insufficient.
[Source: permissions](https://learn.chatgpt.com/docs/permissions).

Those controls concern local commands. Model traffic, MCP, hooks, plugins, inherited guidance, and
the Codex process itself need separate consideration. A workspace-write flag is not proof that the
entire integration cannot read host secrets. `--ignore-rules` does not mean ignore `AGENTS.md`;
`--ignore-user-config` help promises skipping user config, so its previously observed wider scope
must not become an untested guarantee. Project configuration and instruction discovery are distinct.
[Sources: configuration](https://learn.chatgpt.com/docs/config-file/config-basic#configuration-precedence),
[instruction discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md#how-codex-discovers-guidance).

Keep authentication owned by Codex/operator provisioning. The adapter need not parse another
program's auth cache or implement OAuth refresh. Official guidance favors API keys for automation
and documents advanced account-auth provisioning with restrictions. A login-status probe establishes
local availability, not that the next provider request will succeed.
[Source: authentication](https://learn.chatgpt.com/docs/auth).

Any execution choice must explicitly reconcile `ARCHITECTURE.md` §12/§13 and PRD FR-X1/FR-X2.
Do not silently weaken `execute_code`'s existing VM profile to make Coder fit.

## 7. Execution environment and Xcode compatibility

Apple's container tool runs **Linux** guests, whereas Xcode's supported host platform is macOS.
Therefore the existing Linux VM approach cannot itself run an Xcode build; an iOS build requirement
needs access to an appropriate macOS execution environment.
[Sources: Apple container](https://opensource.apple.com/projects/container/),
[Xcode system requirements](https://developer.apple.com/xcode/system-requirements/).

The viable approaches have different scope:

- **Native macOS Codex with deliberately restricted permissions:** recommended first candidate
  for local tools, both workspace modes, and lower setup cost. It needs demonstrated containment
  and an explicit architecture decision about trusting that boundary.
- **A new Linux VM Coder profile:** aligned with hardware isolation for Linux-compatible projects,
  but requires a writable workspace, toolchain image, credentials/network design, and does not
  supply Xcode. It is not a reuse of today's readonly `execute_code` profile unchanged.
- **A separate macOS worker/VM:** can combine a macOS toolchain with stronger isolation, but adds
  provisioning and workspace transport. Consider if required guarantees rule out the first option.

## 8. Minimal product direction to discuss

A local, opt-in, owner-DM Coder job with an explicit workspace mode, task and optional instructions;
a small one-job backend seam in `ClawCore`; a Codex implementation in a sibling target; durable
status, cancellation, retained changes, and completion delivery. The runtime owns origin, limits,
process lifecycle, and result evidence. V1 supports both a local result and a published GitHub PR.
Workspace mode (in-place/separate copy) and delivery choice (local changes/PR) are distinct inputs.

### Project source and the local execution directory

Separate the requested source from the eventual checkout. A local path refers to a directory on
the execution host. A GitHub repository URL identifies the project; it still needs a task supplied
by the request or conversation. A GitHub issue URL identifies both the repository and contextual
problem description. It does not necessarily specify a starting branch or PR base.

For a remote source without an explicitly selected existing checkout, the proposed v1 default is
a fresh job-owned directory. Coder allocates the directory and binds the requested source and
publication scope. Codex can obtain the repository with `git clone`/`gh repo clone`, read the issue
with `gh issue view`, and execute the task through PR creation. This keeps the accepted end-to-end
delegation model and needs neither a custom GitHub API client nor a repository mirror cache.
[Sources: cloning](https://cli.github.com/manual/gh_repo_clone),
[reading an issue](https://cli.github.com/manual/gh_issue_view).

The local Codex 0.153.4 help exposes `--skip-git-repo-check`, permitting an invocation to begin in
the allocated directory before a clone exists. This is a bootstrap candidate to validate in an
implementation probe, not filesystem containment. The chosen execution profile must still enforce
the permitted workspace. Explicitly selecting an existing local checkout is required for in-place
work; do not silently discover and reuse an arbitrary matching repository on the host.

Use the requested base when supplied, otherwise resolve the repository's default branch. Record
the resolved checkout, actual starting commit, and intended PR repository/base; make any repository
redirect or fork mapping visible. A source URL and an actual commit are not interchangeable.

Use the configured owner's GitHub identity. It needs read access for a private source; publication
may use a branch in that repository or a fork when permitted by the task and account. If neither
route is available, retain the available result and report the access blocker. A submitted URL
does not grant credentials or authorize a different Telegram sender: current single-owner intake
rules remain unchanged. Issue text, comments, and repository content are untrusted task data, not
authority to replace the source, credential profile, or allowed operations.

### Who performs Git and GitHub operations?

The owner challenged the initial recommendation to implement publication separately from Codex.
There are three materially different choices:

| Approach | Benefit | Cost |
| --- | --- | --- |
| Swift GitHub client plus deterministic publication workflow | Typed API errors and explicit publication transitions | New integration and workflow beyond delegating a coding task |
| Fixed orchestration commands using existing `git`/`gh` | Predictable publication steps without implementing Git or GitHub APIs | Still owns branch, dirty-state, no-op, failure/recovery, and credential rules |
| Codex performs editing through PR creation using `git`/`gh` | Smallest first integration; uses the coding agent's existing workflow abilities | Less deterministic sequencing and ambiguous partial publication after interruption |

**Accepted direction for this single-owner v1:** use the third approach. The reason is the
current requirement for general task delegation, not simply that the coding agent can invoke Git.
Do not add a separate publisher until deterministic publication or credential separation becomes a
concrete requirement. The second approach is a valid alternative, not inherently reinventing Git.

Coder owns the authorized scope, selected/prepared workspace, runtime configuration, process
lifecycle, durable status, and delivery of the result. Codex performs the requested repository work,
including branch/commit/push/PR where authorized. Keep lightweight artifact checks separate from
the worker's narrative. On this machine, `gh 2.98.0` is installed; `gh pr create --help` confirms
non-interactive arguments and a returned PR URL.
[Source: gh pr create](https://cli.github.com/manual/gh_pr_create).

Publication must retain its own outcome in the report even when Codex performs it. A cancelled or
crashed process may already have pushed or opened a PR. Preserve local work and report publication
as confirmed, absent, or unknown according to available evidence; do not automatically rerun an
ambiguous task. A follow-up attempt can use the retained workspace and known artifacts. Guaranteed
automatic recovery or exactly-once publication is not established by this design.

Delegation authorizes a scope of work rather than each later Git command. Workspace, runtime, and
credential permissions must enforce the actual boundary. Prompt instructions are not enforcement,
and swift-claw cannot claim it inspects or independently approves every child command. Giving the
child publishing credentials also gives it their effective authority; rejecting that trust model
would be a concrete reason to choose separate publication instead.

### GitHub credentials and identity

Authentication determines which account/app acts on GitHub. Git author/committer metadata is a
separate setting; changing `user.name` does not authenticate a bot. GitHub links commit attribution
using the commit email. A GitHub App installation token identifies the app's bot account, while
user credentials can authorize user actions.
[Sources: GitHub App identities](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps),
[commit identity](https://docs.github.com/en/account-and-profile/how-tos/email-preferences/setting-your-commit-email-address).

The initial integration can consume an operator-provisioned credential profile rather than build
GitHub App registration/token renewal. GitHub CLI supports environment-supplied authentication;
Git push also needs its own compatible credential configuration. Select identity outside the task
text and never put raw credentials into prompts. Exact secret delivery, scopes, and renewal remain
design work.
[Source: GitHub CLI environment](https://cli.github.com/manual/gh_help_environment).

### Operator setup is persistent configuration

The proposed operator experience is one-time setup per swift-claw installation, followed by reuse
for each job. The owner accepted reusing existing Codex settings by default, with optional settings
for swift-claw. This is the accepted product default for the current single-owner deployment:
avoid requiring a second configuration and login just to delegate the first coding task. A selected
profile is persistent; it is not recreated or authenticated manually for every task.

Reuse Codex's configuration loading rather than implement a second TOML merger or profile manager.
The installed CLI exposes `--profile` as a layer over user configuration and `--config` overrides.
Official precedence places CLI overrides first, then trusted project configuration, selected
profile, user configuration, system configuration, and defaults. A named profile is therefore not
an independent configuration home or an isolation boundary. Optional overrides should describe
only what differs; exact supported settings remain implementation-design work.
[Source: configuration precedence](https://learn.chatgpt.com/docs/config-file/config-basic#configuration-precedence).

Existing settings means the Codex configuration home available to the daemon's OS user, not the
transient settings of an open desktop conversation or an arbitrary interactive shell. Diagnose the
selected source without exposing secrets. Inherited preferences may change between jobs. Coder
must still bind its protocol/output settings, workspace, operational limits, and execution policy
explicitly; inherited configuration cannot silently expand admitted authority. Compatibility of
inherited MCP servers, hooks, and rules with the selected native execution policy still needs to
be established. This preference decision does not approve unrestricted access or a trust profile.

Keep non-secret settings such as the executable, profile selection, and default limits in the
existing environment-based configuration. `docs/LOCAL_DEV.md` documents `clawd.env`; the daemon
reads environment variables and does not automatically source that file itself. Configuration
owned by swift-claw takes effect at restart in this proposed v1; Codex loads its own inherited
configuration when each child starts. No per-job settings wizard or swift-claw hot-reload subsystem
is needed.

Reuse the existing secret mechanism for any static GitHub/API credentials owned by swift-claw:
environment input for development/setup and the encrypted `ClawSecrets` backend for persistent
deployment. This requires deliberately adding any new secret to the sealed/redacted set, not
assuming today's implementation already handles it. Codex-managed login state remains owned by
Codex; swift-claw configures its use without importing it into the LLM credential store. Revoked or
expired credentials can still require renewal or a new login. Ordinary job requests carry only the
repository/task/workspace/result choices, not raw credentials or executable configuration.

Main does not yet express this admission policy: `ToolDispatchContext` has no proactive-origin
input or `requiresInteractiveRun` flag. The dangerous gate uses the shared `execEnabled` switch,
hardcodes the `.codeExec` approval reason, and executes dangerous tools without approval in groups
(`Sources/ClawCore/Domain/Tools/ToolDispatching.swift:5–35`,
`Sources/ClawTools/Policy/ToolPolicyGate.swift:387,438–454`). Registering Coder alone would not
enforce owner-DM-only operation; this needs explicit policy work.

The delegation split is accepted; the detailed host execution policy, exact Swift API, and job
lifecycle have not yet been approved as an implementation design. The two workspace modes and
GitHub/PR publication are accepted v1 scope. A second backend, resume/steering, conference workflows,
and generic capability negotiation can be evaluated later.

`host-bash-tool` is unmerged at `7659cb14`. It has reusable process-lifecycle work, but its current
runner returns captured output at completion and offers inherited-environment filtering rather
than an explicit clean environment. It is not a ready-made streaming Coder runner, and importing
the entire branch would import unrelated changes. Reuse/extract the required primitive if its
contract fits; do not make that whole feature a prerequisite.

Before implementation, resolve Xcode support, initial-state capture and publication semantics,
the execution/trust profile, cancellation semantics, publication authorization/target handling,
and completion presentation. Then record accepted normative changes in `docs/ARCHITECTURE.md`,
including trusted submission identity, job lifecycle/delivery,
DM/proactive/group policy, child budget visibility, and configuration/health checks.

## 9. Compact contract proposal for the next design discussion

This section collects a candidate contract; accepting the source forms does not approve all of its
implementation details or the host execution policy.

### Task input

- **Source:** local repository path, GitHub repository URL, or GitHub issue URL. Issue resolution
  produces repository identity plus task context; it does not introduce a second execution engine.
- **Task:** the owner's requested outcome, informed by the supplied issue when applicable.
- **Workspace selection:** edit an explicitly supplied local checkout in place, or use an isolated
  working copy. In-place uses the current files. An isolated local copy can start from a selected
  ref or current local state; remote sources start from a selected/default repository ref.
  Snapshot rules for tracked, untracked, and ignored files still need an explicit decision;
  neither copying secrets/build caches nor silently dropping required source files is acceptable.
- **Desired result:** local changes or a GitHub PR. Both use the same backend job mechanism.
- **Additional instructions:** optional task constraints, separate from runtime access policy.

Authenticated origin, session/run/tool-call identity, deduplication key, runtime permissions,
credential selection, and operational limits come from trusted runtime context/configuration.
They are not model-authored task fields. An in-place selection without a local checkout is invalid;
the adapter must not silently substitute some discovered directory.
The publication scope must also specify whether existing uncommitted work belongs in the requested
commit/PR. Capturing a baseline does not grant permission to publish that work or reliably attribute
changes made by concurrent external writers.

### Lifecycle and ownership

The owner accepted the proposed user experience: background execution while conversation remains
available, task status/cancellation, an automatic completion report, retained partial changes, and
no automatic rerun after a daemon interruption. The store and process details below remain design
candidates, not implemented behavior.

After the required authorization, admission records a job and promptly returns its ID. The existing
approval flow can park the conversational lane while awaiting the owner; the responsiveness promise
applies to admitted coding execution, not to removing that approval step. A service owns the claimed
job and native Codex process outside the conversational lane. The request fixes the
authorized task scope; Codex chooses implementation commands and performs the repository workflow.
Status and cancellation address the job ID. Completion uses durable delivery, without requiring a
second model call simply to announce the outcome.

The minimal integration candidate keeps a Coder task distinct from the conversational `runs` FSM.
Persist the trusted origin run and tool-call identity at admission; compose the worker as a
`Service` at the daemon root. Status and cancellation are short ordinary tools, so natural-language
requests use the existing assistant flow. Preserve `/stop` as conversational-turn cancellation;
stopping a Coder task explicitly selects that task. A cancellation request is not evidence that
the supervised process has stopped, and neither cancellation nor failure implies a Git rollback.

Reuse the current Telegram outbox for completion. An independent code review found that existing
outbox insertion can target a completed origin run and already allocates the next chunk indices
inside a write transaction (`RunStoreGRDB+Helpers.swift`, `insertOutbox` and
`nextOutboxStepBase`). Add one atomic store operation that transitions the Coder task to terminal
and inserts its bounded, sanitized completion report against that origin run; a repeated terminal
transition does not insert another report. Then wake the existing dispatcher. Separately saving
the result and subsequently calling `claimOutbound` would leave a lost-notification crash window.
This reuses the existing at-least-once delivery contract rather than claiming exactly-once Telegram
delivery. The report is external-worker data, never a newly trusted scheduled prompt.

Proposed failure defaults: preserve partial work; bound process teardown; mark interrupted jobs
after daemon restart; do not automatically repeat a job whose remote effects are uncertain.
These are suggested operating defaults, not established guarantees of the current implementation.
Restart notification uses the same terminal-and-outbox transaction. Database recovery alone does
not establish termination of an orphaned Codex process; process ownership/reconciliation must be
designed separately. The initial user experience needs task admission, status/cancel, and a final
report; live terminal streaming and an interactive resume protocol are not required for it.

The later concurrency requirement applies to the same service: atomically reserve up to the
configured N active job slots. Startup, cancellation/draining and unreconciled surviving processes
must be included in capacity accounting; changing a row to interrupted is not process termination.
Independently reject in-place conflicts using canonical checkout/common-Git-directory identity;
separate job-owned clones may run concurrently. Per-job deadlines remain independent of N.

### Future group/topic delivery

The owner asked how conference participants could later receive completion in the requesting
Telegram topic. Existing `DeliveryTarget` already represents chat, optional forum topic, and the
triggering message; `outboxTarget` derives the topic/reply from the origin run's persisted session
and trigger. The Coder completion route should preserve that origin instead of hardcoding an
owner-DM destination. Telegram addressing belongs in the swift-claw submission/delivery layer,
not in the repository-task contract passed to Codex.

Topic delivery does not enable group execution by itself. Architecture section 12.1 currently
allows configured rooms as shared sessions, not isolated participant conversations; its dangerous
tool path can run without owner approval and relies on the existing VM boundary. An event adapter
must deliberately admit Coder jobs under an event execution policy rather than inherit this branch
accidentally. The current owner-DM v1 scope is not expanded merely by this future-use discussion.

For a future event, bind the sender's verified numeric identity and the originating conversation
to each submitted job in trusted code. A topic is the shared reply destination; a participant's
submission receives its own working copy, branch, and coding context containing the selected case
and that submission. Do not pass the whole shared topic as if it were one participant's solution.
Submission-to-case mapping, access to allowed event repositories, participant/operator cancellation
rights, and limits belong to event orchestration. Use the separately configured event deployment
required by architecture section 12.1; inheriting a personal daemon's credentials is not part of
the group-delivery proposal. These are future design inputs, not approved event implementation.

### Result

Keep execution disposition distinct from satisfaction of the requested task. The result includes
the worker's summary, actual workspace, changes relative to the starting state when observable,
available branch/commit/PR artifacts, checks with their evidence, and any failure reason/stage.
Unknown publication or unavailable comparison stays explicit. A successful process exit or a
well-formed worker report alone cannot establish that the requested fix or PR succeeded.

Source resolution, checkout preparation, and final artifact verification remain subordinate to
this one task lifecycle. A backend replacement must not require conference entities or a new
publication subsystem. The next design step must settle the native execution/credential profile
and concrete persistence/delivery seams before implementation planning.

## 10. Task 8 supervised validation evidence

This append records actual execution on **2026-09-06 22:00:18–22:05:02 UTC** (2026-09-07 in
Europe/Istanbul), against reviewed Task 7 commit `4340eb267733b4ece966b5dea1b3ff4d757eae71` on
`generic-coder`, in `/Users/jetbrains/Developer/swift-claw-worktrees/main-session-20260906`.
Host: macOS 26.6.2 (25G83). Native CLI: `codex-cli 0.153.4`. GitHub CLI's service version command
exited zero; supplemental foreground inspection retained `gh version 2.98.0 (2026-08-20)`.
The earlier audit above is preserved verbatim; this is new evidence rather than a rewrite of its
historical design discussion.

**Outcome: A passed in a controlled temporary service environment; B ran once but is inconclusive
for actual command-correlated denial; C passed. Required denial validation remains incomplete, so
these results do not establish release readiness.** No production service/configuration or credential
files were changed, no inference retry or broader permission fallback ran, and no new publication
was attempted.

### A — service account authorization

An actual temporary LaunchAgent in `gui/502` ran as UID 502, USER/LOGNAME `jetbrains`, HOME
`/Users/jetbrains`. Its private wrapper sourced `${CLAW_ENV_FILE:-$HOME/.swift-claw/clawd.env}` under
`set -a`, matching the installed wrapper contract, then executed the private helper. It never started
clawd or Telegram. Label:
`com.ivanmagda.swift-claw.coder-probe.6e81373b-91b0-439f-a968-2d5414ddf772`.
Private control root: `/tmp/swift-claw-coder-probes.vmrmm2wj`.

The unmodified installed service PATH resolved none of `codex`, `gh` or `node`. Only the temporary
probe selected:

```text
PATH=/Users/jetbrains/.nvm/versions/node/v24.4.1/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
Codex executable=/Users/jetbrains/.nvm/versions/node/v24.4.1/bin/codex
CODEX_HOME=/Users/jetbrains/.codex
profile=unset
GH_CONFIG_DIR=/Users/jetbrains/.config/gh
```

Child environment used the production `CodexInvocation.environmentKeys` allowlist, excluding
unrelated CLAW/Telegram/provider keys. SSH socket presence came from launchd; no interactive socket
or auth-file contents were copied. Each read-only command had no TTY, `/dev/null` stdin and a
20-second guard. Every command below exited zero without timeout:

- `/usr/bin/id -u` and `/usr/bin/id -un`: 502 / jetbrains.
- Selected `codex --version`, `codex exec --help`, `codex login status`: version above, required flags
  present, local ChatGPT authentication present.
- `/opt/homebrew/bin/gh --version` and `gh auth status --active --hostname github.com`: installed CLI,
  authenticated `ivan-magda` via keyring.
- `gh api user --jq .login`: `ivan-magda`.
- `gh api repos/ivan-magda/swift-claw --jq '{full_name,default_branch,permissions}'`: repository
  `ivan-magda/swift-claw`, default `main`, admin/maintain/pull/push/triage true.
- `/usr/bin/git -c core.hooksPath=/dev/null ls-remote --exit-code https://github.com/ivan-magda/swift-claw.git HEAD`,
  with `GIT_TERMINAL_PROMPT=0` and `GCM_INTERACTIVE=Never`: HEAD
  `d47151764c74ae2b87799d2de58912f3b08b4283`.
- `gh pr view 182 --repo ivan-magda/swift-claw --json url,state,isDraft,headRefName,headRefOid,baseRefName`:
  [PR #182](https://github.com/ivan-magda/swift-claw/pull/182) still open/draft, base `main`, head
  `codex/coder-smoke-timeout-doc-20260906-9fy3sqxw`, commit
  `74191294df5875c7f97aae7e374bbd566caa357c`.

This newly establishes service-context local login/keyring/API access with that temporary PATH.
Local status is not provider execution; GitHub API permissions are not a push test; public
`ls-remote` establishes public readability. PR #182's earlier 254.881-second foreground
clone/edit/lint/commit/push/draft-PR run remains the publication evidence. The service only inspected
that existing PR; no new service-context push or PR was attempted. Installed PATH/interpreter setup
remains an operator follow-up.

### B — native denial attempt, inconclusive

One exclusive mode-0600 rule was created at
`/Users/jetbrains/.codex/rules/swift-claw-denial-swift-claw-coder-probes.vmrmm2wj.rules`.
It forbade only `/usr/bin/touch` or `touch` with the exact argument
`/tmp/swift-claw-coder-probes.vmrmm2wj/denial-repository/denied-marker`.
The free `codex execpolicy check --rules <rule> -- <executable> <marker>` returned `forbidden` for
both executable spellings; the `denied-marker-other` control matched no rule. Evaluator results
alone do not prove execution-time refusal.

The one native invocation ran inside the same LaunchAgent at 22:00:50.688352–22:01:24.383493 UTC
(about 33.695 seconds), with finite stdin, no TTY, a 360-second outer guard, PID/PGID 60642, and:

```text
/Users/jetbrains/.nvm/versions/node/v24.4.1/bin/codex exec --json --approve-for-me -c 'approval_policy="on-request"' --skip-git-repo-check --ephemeral --color never -C /tmp/swift-claw-coder-probes.vmrmm2wj/denial-repository --output-schema /tmp/swift-claw-coder-probes.vmrmm2wj/schema.json -o /tmp/swift-claw-coder-probes.vmrmm2wj/native-result.json -
```

The schema matched `Sources/ClawCoder/Codex/CodexResult.schema.json`. This direct CLI probe exercised
the external native contract, not CoderService. Its finite input requested a retained file, then
exactly the forbidden touch command, stopping after denial without substitution, escalation, commit,
push or PR. The isolated local in-place repository had no remote.

Retained facts: exit zero; `thread.started`, `turn.started`, retained-file `command_execution`
with exit zero, then `turn.completed`; schema-valid final status `blocked`; worker-reported branch
and base `probe-denial`, null starting commit/commit/PR, changed file `retained.txt`. Independent
inspection found branch `probe-denial`, unborn HEAD (`rev-parse --verify HEAD` exit 128), no remotes,
only untracked `retained.txt` with exact contents `retained`, and no denied marker.

**No command-execution event for the denied touch or direct tool/policy refusal tied to that command
remains in the evidence.** Final narration reported the rule's rejection, while stderr extraction
retained only broad error/denied categories. Transient raw stderr was already discarded; no retry
was run. Blocked-result handling and retained work were observed, but native refusal execution is
unproven. This attempt cannot satisfy the required denial check.

No live members of PGID 60642 remained after exit; no timeout or emergency cleanup occurred. The
exact unique rule was removed, and private schema/report/control files were deleted after sanitized
extraction. Existing config/profile/auth/rules were outside the mutation scope; they were not
snapshotted or hashed.

### C — real Coder service cancellation and reservation reuse

A foreground scratch executable under UID 502 used actual `CoderService`, `CodexBackend`,
`CoderRequestPreparer`, `CoderProcessInspector`, `CoderJobStoreGRDB`, file-backed migrated GRDB and
`CoderApprovedOriginFixture`. It ran a harmless external CLI fixture that wrote retained work,
forked real `/bin/sleep 300`, emitted readiness and waited. The second invocation wrote `reused.txt`
and a valid success report. No inference, network or Telegram delivery ran; this proves native
process cancellation through Coder, not cancellation of a paid inference.

The scratch program linked existing Task 7 objects in an agreed stable host-build window (standalone
compile exit zero, 0.899 seconds). Runtime argv was:

```text
/Users/jetbrains/Developer/swift-claw-worktrees/main-session-20260906/.superpowers/sdd/2026-09-06-generic-coder/task8-cancellation/probe /tmp/swift-claw-coder-cancellation.ytlfrf9v /Users/jetbrains/Developer/swift-claw-worktrees/main-session-20260906/.superpowers/sdd/2026-09-06-generic-coder/task8-cancellation/fake-codex.sh
```

Runtime 22:04:02.624011–22:04:04.717114 UTC, exit zero, empty stderr, no timeout. The outer guard
was 90 seconds; readiness/state guards were 30 seconds, backend timeout 120 seconds and capacity
N=1. It selected a private empty config home, real user HOME, `/usr/bin:/bin` PATH and no credential
environment. This was foreground, not a LaunchAgent authorization check.

Private state root `/tmp/swift-claw-coder-cancellation.ytlfrf9v` retained `claw.sqlite`, `coder/jobs`
and `repository/`, with owner-only root/repository permissions. The request used the local in-place
checkout, localChanges, no ref/base/instructions and no existing-change publication. The real
approved-origin fixture established separate owner-DM approval/run/tool-call identities for each job.

- Job `25898636-5C0C-4088-BB29-89EA7FE26A30` reached running/owned/reserved with Codex-phase PID/PGID
  62175; descendant PID 62176 was live in that group, and the real inspector returned `liveOwned`.
- One `CoderServing.cancel(id:context:)` call produced a separate acknowledgement, followed by
  persisted cancelled/stopped/unreserved state. The original receipt inspector returned `stopped`,
  the descendant was absent, and reserved count was zero without a preceding manual group signal.
  `retained.txt` still held `retained` plus newline.
- The same canonical checkout/common Git directory admitted distinct job
  `11ADA2FF-873C-4873-BDC2-DAA755DE5D72` at N=1; it succeeded with observed `reused.txt`, absent
  publication and released reservation. Both capacity and checkout ownership were reusable.
- Service shutdown joined successfully with no reservations. Final snapshots found no live members
  of cancellation group 62175 or the second job's final inspection group 62196. No exact child
  termination signal is claimed by the public result/receipt API.

Independent Git inspection found branch `probe-cancellation`, unborn HEAD, no remotes and only
fixture/retained/reuse files. No commit or publication was created; retained work remains for inspection.

### Cleanup and evidence retention

`launchctl bootstrap gui/502 <private-plist>`, pre-cleanup `print` and exact-label `bootout` exited
zero. Final `print` of the removed unique label exited 113 at 22:05:02 UTC. Private wrapper/helper/
plist/stdout/stderr were removed, the exact rule was absent, all owned groups were empty, and
Coder shutdown/reservation settlement passed. Retained repositories and sanitized receipts remain;
no production service/configuration changes require rollback.

The complete sanitized report and command/result JSON remain under the ignored
`.superpowers/sdd/2026-09-06-generic-coder/` directory (`task-8-live-validation-report.md`,
`task8-live-evidence/{A,B,supervisor,C-supervisor,final-verification}.json`). C's sanitized state
snapshots remain in its private root. Raw auth, full environments, prompts and reasoning logs were
not retained. Required follow-up remains direct command-correlated denial evidence and the installed
service PATH setup; this append does not mark those checks complete.

## 11. Resumed validation and final review closure

**The required native-denial evidence gap V1 is closed, and the concrete temporary service
recipe passed independent evidence review.** Section 10 remains the unchanged historical record:
its first B attempt was inconclusive and its default service PATH lacked the native tools. One
later authorized native job supplied direct refusal evidence. The separate PATH candidate below
was actually tested; production configuration, enablement and deployment remained outside scope.
All earlier 49,260 bytes of this audit are preserved byte-for-byte, with SHA256
`daf8c89f380eabc0d1da201da286ba0a000a1677fbc438e0e70a5e3e45fcaefa`.

### Resumed native denial and temporary service recipe

The new run used actual CoderService, CodexBackend, CoderRequestPreparer, CoderProcessInspector and
on-disk GRDB with real migrations and a CoderApprovedOriginFixture-approved owner-DM origin. On
macOS 26.6.2 (25G83), a temporary LaunchAgent in `gui/502` ran as `jetbrains`, UID 502, HOME
`/Users/jetbrains`. Its sole ProgramArguments entry was the unchanged installed
`/Users/jetbrains/.swift-claw/bin/run-clawd.sh`. A separate `CLAW_ENV_FILE=<private root>/candidate.env`
supplied PATH and `CLAWD_BIN` for the private harness; no production env file was sourced or modified.

```text
private root=/private/var/folders/85/6nvq33kd48g2g1nwnjbp2k3m0000gp/T/swift-claw-resumed-denial.36ysj__w
label=com.ivanmagda.swift-claw.coder-denial.dd632ba5-3913-45b1-9589-f13028450e69
PATH=/Users/jetbrains/.nvm/versions/node/v24.4.1/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
native executable=/Users/jetbrains/.nvm/versions/node/v24.4.1/bin/codex
effective config home=/Users/jetbrains/.codex
profile=unset
```

Actual service preflight at **2026-09-06 23:08:28–23:08:31 UTC** established Codex CLI 0.153.4 and
local ChatGPT authorization; `gh` 2.98.0, keyring authorization and authenticated API identity
`ivan-magda`; repository `ivan-magda/swift-claw`, default branch `main`, and admin/maintain/pull/push/
triage permissions all true. Each check exited zero. The subsequent native turn adds provider
execution evidence. This verifies the concrete separate PATH candidate, not the current installed
production service configuration or a new Git push.

The selected Coder executable and approval identity were a transparent scratch observer at
`<private root>/observer`. It forwarded the original installed CLI's unchanged production argv,
finite stdin, actual schema, cwd, permitted environment values and stdout/stderr, keeping the native
child in Coder's PGID 76836. It removed Python's runtime-added `__CF_USER_TEXT_ENCODING`; no logging
override or wider policy was added. Its bounded collector retained command/rule-correlated native
ERROR evidence independently of worker messages and reasoning. Synthetic filtering/forwarding and
real-service fixture checks passed before inference. The unwrapped executable's approval identity
was not exercised. Exact supervisor/native argv and the sanitized evidence paths are in
`resumed-native-denial-report.md` and `resumed-native-denial-evidence/native-observation.json` under
the local evidence directory listed below. The observed schema SHA256 independently matched the
embedded `Sources/ClawCoder/Codex/CodexResult.schema.json`:
`b37dd63313fa5441ab530e2afb1d59b4fafe9d4994cbf41c4a2e1a3e18cceb03`.

One exclusive mode-0600 temporary forbidden rule covered the unique marker command for
`/usr/bin/touch` or `touch`, under both verified `/private/var/...` and `/var/...` repository aliases.
Four free positive controls returned forbidden/one match; two suffixed-marker controls did not match.
The controller then released exactly one native job:
**`ACBDFB71-7BA9-40EC-A78D-BD45559F0759`**, from **2026-09-06 23:09:51.253747 to 23:10:26.045886 UTC**,
approximately **34.792 seconds** (September 7 in Europe/Istanbul). The native launcher exited zero
and emitted `turn.completed`. Native stderr ERROR target **`codex_core::tools::router`** supplied:

```text
`/bin/zsh -lc '/usr/bin/touch /var/folders/85/6nvq33kd48g2g1nwnjbp2k3m0000gp/T/swift-claw-resumed-denial.36ysj__w/repository/denied-marker'` rejected: swift-claw native denial dd632ba5-3913-45b1-9589-f13028450e69; stop without escalation.
```

There was still no denied-command JSONL lifecycle. This exact command and unique forbidden-rule
justification supply the missing direct refusal proof. The worker's phrase "Automatic approval
review rejected" does not establish a separate Guardian decision: the proved event is **native
execpolicy denial**. The explanatory local Codex source checkout was not established as the installed
binary's exact revision; runtime proof stands independently. No controller/observer retry, escalation,
timeout, signal or emergency cleanup occurred.

Actual durable outcomes and independent retained-state verification established:

- **Failed / permission**, stopped ownership and native receipt, slotReserved false and reserved
  count zero after the previously observed running/owned/reserved state.
- **One new trusted completion outbox row** for the job at run 1/chat 7; two pending rows total,
  including the fixture's original approval prompt. No actual Telegram receipt, approval-button
  transport or network completion delivery ran in this probe.
- `retained.txt` contained exactly `retained`, without newline; denied marker absent. Product
  inventory observed changedFiles `[retained.txt]`, baselineObserved true. Independent Git found
  branch `probe-native-denial`, unborn HEAD (verify exit 128), no remotes and only `?? retained.txt`.
  Publication was absent and commit null.
- Actual `CoderService.shutdown()` joined; harness exit zero/PASS, empty stderr and no reservations.

At **23:12:25.768826 UTC**, final verification found the unique rule and LaunchAgent absent
(bootout exit zero; label print exit 113), recorded native/final-inspection groups **76836 and 77742
empty**, private launch/observer controls removed and no native protocol directory. The wrapper's
SHA256 remained `2cc91233564a5f45e05a76ed63c05a1e3a077bb8bb7ea6abbb9994c7e7a07b8e`.
The private root retains the database, repository and sanitized observations as work artifacts.
Independent read-only review beginning at 23:17:11 UTC reconfirmed SQL, file bytes, Git facts,
cleanup and mirrored evidence: **PASS, no required evidence defect**.

### Product acceptance boundaries and review closure

Task 8 `CoderDoneWhenTests`, committed at `d1ecb8e4652d775aeb3fa6c93c8e8db7558d4e64`, owns the
router/approval/service/GRDB/outbox/transport path with scripted model, backend and Telegram
boundaries. It observes an ordinary reply in the same DM while coding waits, then the saved result
and automatic trusted-origin completion without another model turn; wake replay preserves one
completion row. Its tool-lane-blocking mutant failed while the nearest approval/service tests passed.
This deterministic acceptance and the native probe establish their separate boundaries; neither is
relabeled as actual Telegram network delivery.

Cancellation remains the actual section 10 C run: a harmless long-running external CLI fixture
through the real Coder service/native backend, one cancel, observed descendant/group settlement,
retained work, N=1 capacity and same-checkout reuse, then joined shutdown. No paid inference
cancellation ran. Historical [draft PR #182](https://github.com/ivan-magda/swift-claw/pull/182) remains
the successful foreground clone/edit/lint/commit/push/PR baseline. Temporary-service authenticated
API permissions and read-only inspection were not a new service-context push or PR.

The additional whole-branch **Astra/ultra** review of `d4715176..d1ecb8e4` found two Important
guard/recovery gaps. Commit **`882f5b1a52a2145958e2a3c9878f84e098e60ece`** closed both: **R1** sends
all actual delegated prepared text through the existing secret/private-data guard; **R2** reconciles
earlier durable jobs and exposes persisted health when disabled, without native probes, tools or
admission. The architecture and reached public operating documents were updated in that commit.
Uncertain old ownership remains reserved; recorded PIDs are not blindly signaled.

The same commit addressed the independent test-only **T1** finding with a bounded missing-signal
guard, a pre-cancellation completion observation and joined failure cleanup in the existing
persistence-failure test. Its exact missing-latch mutant failed and finished in 31.150s; restored
production passed. Selected optional **M1** added one wrong-head-OID PR matrix specimen; removing
that comparison failed only the new specimen, and production was restored unchanged. Independent
actual-diff test-value review and the completed scoped code/spec rereview both **APPROVED**:
R1/R2/T1/M1 closed, zero new required findings. Some guard/composition/doctor paths remain
source-traced rather than separately mutation-tested. Deferred framing, callback-error,
interrupted-workspace-reporting and fixture-hygiene observations remain optional, not production
blockers; the reviews do not claim exhaustive native-installation coverage.

Separately, **`7d4066c3aba788e8b35f68dabdaa9d0b48f5b127`** fixed the demonstrated raw
`Network.NWError.posix(.ECONNREFUSED)` classification gap under `canImport(Network)`. Other errors,
timeouts and post-head failures remain conservative. Both unreliable released-ephemeral-port
refusal tests and their helper were removed with independent test-value/code approval; the pure
classifier covers NIO, AHC-wrapped and raw Network refusal plus a raw non-refusal control. Real
connected-then-closed transport tests remain. The accepted loss is explicit: no default-suite
observation of the dependency's live refusal representation, and no positive integration proof
that submission delegates clean errors to the classifier. A submission mutant that always wraps
errors conservatively could now survive. Bounded diagnosis demonstrated the representation gap and
a competing listener invalidating the fixture prerequisite, but **the natural cause of the earlier
intermittent failures remains unproven**.

### Latest executed source validation and retained evidence

Final source was `882f5b1a52a2145958e2a3c9878f84e098e60ece`, tree
`2f9dd09e3866ef6adfa803074d8336f47a16137e`. These are actual saved source-stage executions,
not fresh checks by the documentation writer or independent read-only reviewers:

| Check on final source | Actual result |
| --- | --- |
| Host `scripts/lint.sh` | Exit 0; `lint: ok`; 0/759 files require formatting; 11 inherited SwiftLint warnings in unchanged files. |
| Host `swift build` | Exit 0; build 15.02s. |
| Host default `swift test` | Exit 0; build 8.75s; **2,909 tests in 371 suites passed in 14.283s**. |
| Linux selected Coder/Codex/runtime-shutdown/HTTP tests | Exit 0; build 75.67s; **138 tests in 27 suites passed in 13.838s**; no warnings in this incremental log. |

Linux used Docker 29.7.2 and the Swift 6.3 Noble image
`sha256:1610513149191de464ac06d192b4c2b165433aa18e0053b196d1da1f0570b35f`, target
`aarch64-unknown-linux-gnu`, read-only `/src`, separate `/scratch`, one CPU (`--cpuset-cpus=0`),
and `swift test --scratch-path /scratch --jobs 4 --filter
'Coder|Codex|RuntimeShutdownAcceptanceTests|AsyncHTTPExecutor'`. Wall time was 92.264s, from
23:56:05.965339 to 23:57:38.230452 UTC on September 6. This was a selected Linux run, not a full
Linux-suite or live-service test.

Detailed local evidence remains ignored under `.superpowers/sdd/2026-09-06-generic-coder/`:

- `resumed-native-denial-report.md`, `resumed-native-evidence-review.md` and
  `resumed-native-denial-evidence/`: exact recipe/argv/schema hash, sanitized preflight,
  admission/running/receipt/terminal facts, rule journal, completion and cleanup evidence.
- `task-8-live-validation-report.md` and `task8-live-evidence/`: original inconclusive B and
  harmless cancellation, preserved as executed.
- `resumed-http-{report,fix-report,test-value-review,code-review}.md`: diagnosis, committed fix,
  actual gates and accepted integration-coverage loss.
- `final-branch-ultra-review.md`, `final-test-value-ultra.md`, `final-coder-fix-report.md`,
  `final-coder-test-value-review.md`, `final-coder-code-review.md`: findings, mutant evidence,
  committed corrections, approvals and source-traced/optional limits.
- `final-coder-gate-{lint,build,test}.log`, `final-linux-facts.json`, `final-linux-test.log`:
  exact source identity, commands, exits and printed validation results.

No required native live-contract gap remains in the executed Task 8 scope. Production installation,
enablement/deployment, actual Telegram network delivery, fresh service-context publication and paid
inference cancellation remain outside the claimed evidence. No credentials, prompts, full
environments, raw native streams or reasoning logs are copied into this append.
