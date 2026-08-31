# Demo storyboard for the v0.3.0 launch

*2026-07-27. Operational companion to [`public-launch-strategy-2026-07-27.md`](./public-launch-strategy-2026-07-27.md)
(§8, item 1: "Record a demo") and [`public-launch-content-2026-07-27.md`](./public-launch-content-2026-07-27.md)
(§1.1, item 1). One continuous master take, four derivatives, no narration. Every on-screen string
below that the daemon authors was read out of the shipped source; strings the model authors are
marked as illustrative.*

---

## 1. What this records, and what it deliberately does not

The subject is the approval fabric, and nothing else. Not the model's answers — those belong to the
provider and are the exact footage that invites *"why wouldn't I just vibecode this myself"*. Not
prompt injection: the demo makes no security claim, because no verified 2025-26 case shows a
security claim earning credibility for a solo author (strategy §4), and a claim that gets broken in
the thread costs more than the claim was ever worth.

What is left is a single falsifiable proposition, and it is enough:

> **The approval is a durable object in a database, not a message in a chat.**

Three shots prove it: a typed "yes" does nothing, the daemon dies and comes back, and the same
buttons still work.

### 1.1 One correction this storyboard depends on

The launch copy currently stages a symlink to `~/.ssh/authorized_keys` and expects the approval card
to display it (`public-launch-content-2026-07-27.md` §2.2, and the HN brief in §4). **That does not
reproduce.** `WorkspacePathContainment.resolveForCreation` resolves the deepest existing ancestor,
asserts containment at every step, and refuses the call before any approval row is written:

> That path resolves outside the workspace, so I can't write it.

No card is ever rendered, so there is nothing to film and nothing to screenshot. Both passages need
rewriting before publication regardless of what gets recorded — they currently describe behaviour
the product does not have.

---

## 2. What was actually shot, and what shipped

**Recorded 2026-07-27:** shots 1, 2 and 3, plus `/status` run before the take rather than after.
**Not recorded:** shots 4 and 5. There will be no reshoot. The consequence is stated plainly because
it changes the claim: nothing in the launch's visual material demonstrates that an approval survives
a restart. That property is true and covered by `restartThenOwnerCallbackStillResolves()`, so the
text may assert it — but no copy may invite the reader to *watch* it happen.

The surviving proposition, fully carried by the footage, is narrower and still worth the frame:

> **Every write stops and shows you the fully-resolved target before anything happens.**

The master is a 3456×2234, 120 fps, 55 s full-screen capture with Telegram left and a `tail -f` of
the daemon log right. Every deliverable crops the lower chat pane, which excludes the chat-list
sidebar, the macOS menu bar, and the previous conversation that scrolls through the upper half for
the first twenty seconds, while keeping the message input bar in frame. That bar is load-bearing:
watching the request get typed is what makes the stop that follows read as an interruption rather
than a screenshot.

| Output | Spec | Crop | Source window | Home |
|---|---|---|---|---|
| **README cut** | 1280×1264, 30 fps, 26 s | `1074:1060:624:1150` | t=11–37 | Upload to a GitHub issue, embed the attachment URL |
| **X cut** | 1080×1066, 30 fps, 13 s | `1074:1060:624:1150` | t=11–24 | Native upload |
| **`card-deny.gif`** | 644×414, 12 fps, 10 s, 0.97 MB | `1120:718:600:1492` | t=11–21 | `docs/assets/demo/`, in `README.md` under "The approval card" |
| **`card-approve-deny.png`** | 1010×560 | `1010:560:620:1560` | t=17 | LinkedIn carousel p.5 |
| **`card-privileged.png`** | 1010×580 | `1010:580:620:1500` | t=29 | The privileged-file banner, for the HN comment |

The GIF ends on the denial reply with the input bar empty again, so the loop closes instead of
cutting into the next request being typed.

**The GIF crop is deliberately shorter than the video crop, and that is a README-layout constraint
rather than a framing preference.** The first attempt reused the tall crop at 720 px wide, which
rendered as a ~710 px near-square block two paragraphs below the hero banner: two large images
stacked, and a top edge that opened on a `/status` table sliced mid-line, which reads as a broken
screenshot rather than a demo. The shorter crop is 1.5:1, fits the card with its buttons and the
denial reply, opens on ordinary chat scrollback, and carries a 2 px `#D0D7DE` border so it does not
bleed into GitHub's white page. It also sits below Features rather than above them — a reader meets
it while deciding whether to install, not before knowing what the thing is.

The two stills are the pair, not alternatives: the first carries the live `Approve`/`Deny` buttons
without a banner, the second carries the `PRIVILEGED FILE` banner after the buttons have scrolled
past. No single frame in the take holds both.

**Known defect visible in every asset.** `ToolApprovalPrompt` joins its fields with `"\n"` while
delivery goes out as markdown (`sendRichMessage(chatId:markdown:)` → `InputRichMessage`), where a
single newline is a soft break. The headline, `Target:`, `Effect:` and the privileged banner
therefore render as one paragraph instead of four lines. A deliberate decision was taken not to fix
it before the launch. It is recorded here because every published still shows it, and because the
resolved path — the entire point of the prompt — sits mid-sentence as a result. Telegram linkifies
the `.md` filename, which is the only thing currently drawing the eye to the target.

---

## 3. Frame

1920×1080, 60 fps, two panes, fixed for the whole take — no zooms, no pans, no cuts.

```
┌───────────────────────┬─────────────────────────────────────┐
│                       │                                     │
│   Telegram Desktop    │   shell                             │
│   narrowed to phone   │   pgrep / ls / cat / launchctl      │
│   proportions         │                                     │
│   ~620 px wide        │                                     │
└───────────────────────┴─────────────────────────────────────┘
```

The daemon on this machine already runs under launchd as `com.ivanmagda.swift-claw`, so the restart
in shot 5 is `launchctl kickstart -k` bracketed by two `pgrep` calls — the PID changing on camera is
tighter proof than a scrolling log, and it keeps the frame to two panes. The shell is what turns
every claim into a filesystem fact; without it this is a chat screenshot.

---

## 4. Pre-flight

**This records against the live install**, `~/.swift-claw`, not a throwaway state root. Ownership
is already claimed (`allowlist.owners 1`), the daemon is already running under launchd, and
`clawd doctor` reports every group `ok`. Nothing needs provisioning.

**The workspace files are in place.** `clawd run` creates the workspace directory at 0700 and ships
no templates (`GETTING_STARTED.md` §6); `clawd doctor` does not create it at all — only `RunCommand`
calls `ensureWorkspaceDirectory`. So the demo files had to be authored by hand, and they now exist:

```
~/.swift-claw/workspace/
├── hello.py          # pre-existing, unrelated, will appear in any bare ls
└── notes/
    ├── todo.md       # shot 1 reads this
    └── reading.md    # so `ls notes/` is a real listing, not one staged file
```

`notes/` matters only for shot 1's `file_read`, which refuses a path that does not already exist.
Shot 2 does not need it — `file_write` creates intermediate directories at commit time.

**`SOUL.md` is deliberately absent, and should stay that way until after the shoot.** The live
workspace has never had one. That turns shot 3 from an overwrite into a create, which removes the
single take-killer this storyboard had: no `overwrite: true` is required, so the gate cannot refuse
before the card. The privileged-file banner still fires either way — `isPrivilegedFile` matches the
basename of the resolved target, and a to-be-created target resolves the same.

**Two live-setup facts that change what you put on camera.**

`llm.auth` currently reads `provider=openai-chatgpt mode=oauth`. That route must never be described
as stable or supported (`public-launch-content-2026-07-27.md` §5), so it must not appear in any
frame. It does not: `llm.auth` is not a headline row, so Telegram's `/status` omits it, and shot 6
uses `/status` rather than the CLI table. Do not substitute `clawd doctor` output for that shot.

That same route reports `spend.today_usd 0.0000` with `cost_source_mix included_plan=7`, because a
subscription route has no per-token price. A zero on camera answers nothing and invites the question
it was meant to close. Either record shot 6 on an API-key route so the number is real, or cut shot 6
and answer cost in the post text instead.

**The chat window carries real history.** This is a working bot with real conversations in it. The
frame is fixed and the window sits pinned to the bottom, so nothing above the demo is visible —
provided you never scroll up, not once, in any take. Send `/new` before the first take so the
session context is fresh.

**Telegram.** Dark theme. Zoom 125–150%. Check what the bot's display name reads as in the header —
it is on screen for the entire take.

**Terminal.** Dark theme, 18–20 pt, minimal prompt (`~ $`, no git status, no hostname).

**Lines.** Every message you send is written out in a scratch file beforehand and pasted. Typing on
camera produces typos, backspaces, and dead air; all three cost a take.

**Rehearse once, end to end, before recording.** Three things below refuse *before* the card and
will silently kill a shot if they fire.

---

## 5. Storyboard

Timings are targets for the master. `Ω` marks a string authored by the daemon and verified in
source; `~` marks a line the model composes, shown here only as an illustration of shape.

---

### Shot 1 — 0:00–0:10 — a safe tool just runs

**Left.** You send:

> `Read notes/todo.md and tell me what's still open.`

The reply streams in as a live-edited message. `file_read` is not ask-tier: it executes with no card,
no interruption, no ceremony.

> ~ *Three items are still open: renew the domain, cancel the old backup plan, and reply to the
> invoice email.*

**Right.** Idle at the prompt. Nothing to show yet — that is the point.

**Purpose.** Establishes that this is a working assistant and that ordinary work is frictionless.
The card in shot 2 lands only because this shot exists.

---

### Shot 2 — 0:10–0:26 — the first card, and a denial

**Left.** You send:

> `Save a note at notes/domains.md saying the domain renews on 14 August.`

The stream stops. The card arrives:

```
Ω ⚠ I want to run file_write. This changes state and needs your explicit approval.
Ω Target: /Users/<you>/.swift-claw/workspace/notes/domains.md
Ω Effect: create, 46 B
Ω Preview:
Ω The domain renews on 14 August 2026.
Ω Tap Approve to allow this one action, or Deny to cancel.
```

Buttons: `Approve` `Deny`. **Tap Deny.** Telegram raises the toast `Ω Denied.`

The tool result handed back to the model is `Ω The owner declined this action.`, and the model then
says something to the effect of:

> ~ *Understood — I didn't write the file.*

**Right.** `ls notes/` before and after. `domains.md` is absent in both.

**Caption.** `Every write stops here.`

**Purpose.** The denial. No competitor in the category shows one, because a denial is only worth
filming if the refusal is real.

---

### Shot 3 — 0:26–0:44 — the privileged-file banner

**Left.** You send:

> `Write yourself an instructions file, SOUL.md, saying to answer briefly and to prefer metric
> units.`

The card carries an extra banner, because the resolved target's basename is one of
`SOUL.md` / `AGENTS.md` / `USER.md` / `MEMORY.md`:

```
Ω ⚠ I want to run file_write. This changes state and needs your explicit approval.
Ω Target: /Users/<you>/.swift-claw/workspace/SOUL.md
Ω Effect: create, 78 B
Ω ⚠ PRIVILEGED FILE: this path feeds my system prompt / private-data tier.
Ω Preview:
Ω Answer briefly. Prefer metric units.
Ω Tap Approve to allow this one action, or Deny to cancel.
```

**Tap Approve.** Toast `Ω Approved.`

**Right.** `cat SOUL.md` shows the file that did not exist a second ago.

**Caption.** `The gate knows which files feed the system prompt.`

**Purpose.** Shows the gate making a distinction the model never made, without a word about
security. This is also the frame to pull as the README hero still.

**Why this is a create and not an overwrite.** The live workspace has no `SOUL.md`, so the model
needs no `overwrite: true` and the gate has nothing to refuse. If you author a `SOUL.md` before
recording, this shot acquires a failure mode it does not currently have — the gate would refuse
before the card with `Ω SOUL.md already exists; pass overwrite: true to replace it.` Leave the file
absent until the shoot is finished.

**After the shoot,** the approved write leaves a real `SOUL.md` in the live workspace, and it will
shape the assistant's behaviour from the next turn on. Either keep it deliberately or delete it.

---

### Shot 4 — 0:44–0:58 — a typed "yes" is inert

**Left.** You send:

> `Save a note at notes/renewals.md listing what renews in August.`

The card arrives. Then you send, as an ordinary chat message:

> `yes, go ahead`

Nothing happens. No reply, no edit, no execution. The card sits exactly as it was. **Hold on the
still screen for a full four seconds** — the emptiness is the content, and cutting early reads as an
edit.

**Right.** `ls notes/` — `renewals.md` is absent.

**Caption.** `The run is suspended. A typed "yes" is queued behind it, not acted on.`

**Purpose.** Kills the most common assumption a viewer brings: that the confirmation is
conversational. It is not — `SessionLaneRegistry` chains each turn behind its session's previous
turn, so the message is admitted to the lane and waits there. This is covered by a passing
acceptance test, `ApprovalDoneWhenTests.restartThenPlainMessageQueuesFIFOBehindTheParkedApproval()`,
so the shot is filming a guaranteed behaviour rather than a hopeful one.

---

### Shot 5 — 0:58–1:20 — the daemon dies; the approval does not

**Right.** Three commands, slowly, with a beat between each:

```bash
pgrep -f "clawd run"                                       # 86103
launchctl kickstart -k gui/$(id -u)/com.ivanmagda.swift-claw
pgrep -f "clawd run"                                       # a different number
```

The PID changing is the proof. Let the new number sit on screen for two seconds before you touch
Telegram — a viewer needs that beat to register that the two numbers differ.

**Left.** The card from shot 4 is unchanged and untouched. **Tap Approve.** Toast `Ω Approved.`
The write executes against the arguments recorded at suspend time.

**Right.** `cat notes/renewals.md` — the content is there.

**Caption.** `Daemon restarted. Same approval. Still live.`

**Purpose.** The whole video. `ApprovalBootReconciler` re-parks a waiter for every unexpired
`PENDING` approval at boot, which is why the buttons still resolve. Pending approvals expire after
`CLAW_APPROVAL_EXPIRY` seconds, default 3600, so a restart taking under a minute is never near the
edge. Covered by `ApprovalDoneWhenTests.restartThenOwnerCallbackStillResolves()`, which is the
single most load-bearing test behind this recording.

**Known artefact.** The `yes, go ahead` from shot 4 is still queued on the lane. Once the approval
resolves it runs as its own turn and the model will answer it with something arbitrary. Two
acceptable handlings: end the README cut on the `cat`, or let it play — a stray reply *after* the
approval resolves is itself evidence the message was queued rather than acted on. Do not re-record
to hide it.

---

### Shot 6 — 1:20–1:35 — /status

**Left.** You send `/status` (`/doctor` parses to the same command). Telegram gets
`renderTelegramSummary()`, which is **not** the dotted table the `clawd doctor` CLI prints — it is a
verdict line plus one line per group, carrying only that group's headline rows:

```
Ω clawd: all systems healthy
Ω
Ω Config: ok
Ω Database: ok
Ω LLM & Runs: ok · consecutive_failures 0 · in_flight 0
Ω Context: ok · last_prompt_tokens 3412
Ω Spend: ok · today_usd 0.0412 · remaining_day_usd 9.96
Ω Storage: ok
Ω Scheduler: ok · due_count 0
Ω Approvals: ok
Ω Connectivity: ok
Ω Sandbox: ok
```

Only five rows are headlines, so the other groups really do render as a bare `Title: ok`. Amounts
carry no `$` — `USD.precise` renders four decimals and `USD.display` two. Failing rows are the only
ones that expand underneath their group.

Hold four seconds on the Spend line.

**Purpose.** Answers the cost question before it is asked. The values come from your live run —
capture what it prints, do not stage this frame.

**Watch the Connectivity row.** On a machine behind a fake-IP VPN it reads
`dns.fake_ip  detected (public hosts resolve into 198.18.0.0/15 …)`. That is correct behaviour and
it still reports `ok`, but it is a long, alarming-looking line to leave on camera with no
explanation. Record this shot with the VPN off.

**Cut this shot from the X version.** It is a README and LinkedIn asset only.

---

## 6. Derivative cuts

**X — 25–30 s.** Shots 4 and 5, nothing else. Card on screen inside the first second, because
autoplay is muted and the first frame is the whole pitch. Sequence: card → `yes, go ahead` → nothing
→ old PID → `kickstart` → new PID → `Approve` → `cat`. Burned-in captions, four lines maximum.
Native upload; nothing in the ranking path fetches an external video.

**README — 75–90 s.** Shots 1 through 5. Trim shot 1 to seven seconds; it is scene-setting.

**GIF — 12–15 s.** Shot 2 alone: card appears, `Deny`, file absent. It has to read with no sound, no
captions, and no context, which only shot 2 does. 960×540, 12–15 fps, under 10 MB.

**Stills.** The shot 3 card at full resolution (README hero, LinkedIn carousel p.5, and the still to
link from an HN comment); the shot 6 table; the shot 5 frame with a dead daemon pane beside a live
card, which is the single most compelling static image the project has.

---

## 7. The three refusals that fire before any card

Each one produces a chat message instead of an approval prompt. All three are correct behaviour and
all three destroy a take.

| Trigger | What you get instead |
|---|---|
| Writing an existing file without `overwrite: true` | `Ω <path> already exists; pass overwrite: true to replace it.` |
| A path containing `.` or `..` | `Ω Paths with "." or ".." components can't be written; name the target directly.` |
| A path resolving outside the workspace | `Ω That path resolves outside the workspace, so I can't write it.` |

---

## 8. Post-production

Master exported at 1920×1080; no upscaling anywhere downstream. H.264 MP4 for every video output.
Captions burned in — X plays muted and README video is often muted too. No music, no voice-over, no
intro card, no logo sting: the first frame is Telegram, the last frame is a filesystem.

For the README, an MP4 rendered by GitHub plus the GIF as the fallback that survives mirrors and
non-github.com renderers. Verify the embed on a real repo page before launch day rather than
assuming the markdown renders.

---

## 9. Not in frame

Real paths, names, tokens, chat history, or bot handles. Long model pauses — cut dead air, but never
cut inside an approval interaction. Voice notes: transcription ships but `PRD.md` NG3 still calls
voice a non-goal, and putting the contradiction on screen invites a question with no good answer.
Memory search framed as full-text recall — only `messages_fts` exists. Any impressive model output
for its own sake; the harness is the subject, and every second spent admiring the model is a second
arguing for the viewer to go build their own.

---

## 10. Budget

Rehearsal 30 min · takes 40 min · edit and export 50 min ≈ **2 hours**, matching the Monday
allocation in `public-launch-content-2026-07-27.md` §1.1.

A second asset, ~15 minutes and worth it: a terminal-only recording of the install path — download
the release binary, verify `SHA256SUMS`, run `clawd doctor`, green table. It answers "does this
actually start" for Linux readers, and it reuses in `GETTING_STARTED.md` and in HN replies.

---

## 11. Verification record

Everything below was checked against the built binary or the source on 2026-07-27, not inferred
from the docs. The `Ω` strings in §5 are the verified ones.

| Claim in this storyboard | How it was checked |
|---|---|
| Workspace is `<state root>/workspace/` | `StateFile.workspace = "workspace"` |
| The workspace is created empty, with no templates | `FileSystemWorkspace.ensureRootExists` only makes the directory; `GETTING_STARTED.md` §6 states it |
| `clawd doctor` does not create the workspace | Ran `doctor` against a fresh `CLAW_STATE_ROOT`: it produced `claw.sqlite*` and `clawd.lock` only. Only `RunCommand.swift:174` calls `ensureWorkspaceDirectory` |
| Shot 1 needs `notes/todo.md` to pre-exist | `file_read` resolves through `resolveExisting`, which refuses a missing path with `No file exists at <path>.` |
| Shot 1 shows no approval card | `FileReadTool` declares `riskLevel: .safe` |
| Shot 2 works without a `notes/` directory | `file_write` commits through `createDirectory(withIntermediateDirectories: true)` |
| `Effect: create, 46 B` / `overwrite, 1.1 KB` | `ByteCount.text` — raw bytes under 1024, `%.1f KB` at or above |
| Approval card field order and wording | `ToolApprovalPrompt.text(for:)` |
| Privileged banner fires on `SOUL.md` | `TurnRunner+Payloads.isPrivilegedFile`, basename match on the resolved target |
| Buttons read `Approve` / `Deny`; toasts `Approved.` / `Denied.` | `ApprovalKeyboard.markup`, `ApprovalCallbackHandler` toast constants |
| Deny hands the model `The owner declined this action.` | `ApprovalWaiter.swift:248` |
| A typed "yes" queues instead of executing | `SessionLaneRegistry` FIFO chaining, plus a passing `restartThenPlainMessageQueuesFIFOBehindTheParkedApproval()` |
| The approval survives a restart with live buttons | `ApprovalBootReconciler.reconcile`, plus a passing `restartThenOwnerCallbackStillResolves()`. Whole suite: 8/8 |
| Default approval expiry 3600 s | `CLAW_APPROVAL_EXPIRY`, `CUSTOMIZATION.md:137` |
| `/status` summary shape and the five headline rows | `DoctorReport.renderTelegramSummary` + every `headline: true` row in `HealthRowsBuilder` and `SchedulerHealth` |
| Ownership needs `CLAW_ALLOWLIST` and a restart | Ran `doctor` with and without it on a scratch root: `allowlist.owners` moves from `0` to `0 seeded, 1 configured (seeded at daemon start)`. On the live install it already reads `1` |
| The live install is ready to record against | `clawd doctor` with `~/.swift-claw/clawd.env` loaded: every group `ok`, `secrets backend=encrypted`, `llm.auth … status=fresh`, `approvals.pending 0` |
| The daemon runs under launchd, so shot 5 uses `kickstart` | `launchctl list` shows `86103  0  com.ivanmagda.swift-claw`; `pgrep -fl clawd` shows `~/.swift-claw/bin/clawd run` |
| The workspace has no `SOUL.md`, making shot 3 a create | Listed `~/.swift-claw/workspace/` before writing anything: `hello.py` only |
| `notes/todo.md` and `notes/reading.md` exist | Created in the live workspace on 2026-07-27 and listed back |
| The three pre-card refusals in §7 | `FileWriteTool.canonicalTarget`, `WorkspacePathContainment.resolveForCreation` |

**What remains unverified, and is therefore what rehearsal is for.** Whether the model picks the
tool and the path this script assumes — `file_read` on `notes/todo.md` in shot 1, `file_write` on
exactly `notes/domains.md` in shot 2, `SOUL.md` rather than some other filename in shot 3. That
depends on the model and on your phrasing, not on clawd. Every refusal path that could pre-empt a
card is now either eliminated (shot 3 is a create) or listed in §7. Everything the daemon controls
is settled.
