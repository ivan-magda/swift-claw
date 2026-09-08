# Launch content and ship plan for v0.3.0

*2026-07-27. Companion to [`public-launch-strategy-2026-07-27.md`](./public-launch-strategy-2026-07-27.md),
which carries the research, the sourcing, and the reasoning behind every choice here. This file is
the operational half: the ordered checklist, the posting schedule, and the copy. Every factual claim
in the copy below traces to the verified fact base in §1 of the strategy doc; nothing here may be
published without the §1.1 documentation fixes landing first, because two of the drafts would
otherwise repeat a false README claim.*

> **On the Hacker News section.** HN's guidelines gained *"Don't post generated text or AI-edited
> text. HN is for conversation between humans"* in March 2026, and dang's tips comment adds
> *"Write your text by hand. Don't use an LLM to generate any of it (not even a tiny bit, including
> to edit or spruce it up)."* Enforcement is crowd-sourced and active. §4 below is therefore a brief
> — structure, verified facts, and pre-written answers to predictable questions — and **not** copy to
> paste. For a project whose pitch is craftsmanship, posting generated prose about an agent would
> discredit the claim it is making.

---

## 1. Ship plan

Today is Monday 2026-07-27. The launch window is **Wednesday 2026-07-29 or Thursday 2026-07-30,
15:00-18:00 UTC** (18:00-21:00 UTC+03), which is the intersection of both recent Show HN censuses
and the arXiv window, avoids the 12:00-14:00 UTC volume peak, and lands at an hour where sitting at
the keyboard for three consecutive hours is realistic. Friday is the worst day on every measurement,
so Thursday is the last usable slot this week.

### 1.0 Check first — this can invalidate the schedule

Open `news.ycombinator.com/showlim` while logged in to HN. That interstitial shipped around April
2026 and is what accounts *"without much HN history"* now see in place of a live Show HN. The gate is
undocumented and absent from `showhn.html`; dang declined to publish thresholds so they would not
*"end up on an LLM checklist somewhere."* If the interstitial appears, HN is unavailable this week and
the sequence collapses to X, Swift Forums, and the r/selfhosted megathread.

### 1.1 Monday — about three hours

1. ~~**Record the demo.**~~ **Done.** Shots 1-3 recorded; shots 4-5 dropped, no reshoot. Cuts, stills
   and a GIF live in `docs/assets/demo/` and `~/Downloads/demo-{readme,x}.mp4`; specs and the
   consequences are in [`demo-storyboard-2026-07-27.md`](./demo-storyboard-2026-07-27.md) §2.
2. ~~**Fix the three outright-false documentation lines.**~~ **Done**, each verified against the code
   rather than against a report. `README.md` + `CUSTOMIZATION.md`: memory has no full-text index —
   `messages_fts` covers the message archive, `memory_items` order by importance and recency.
   `CLAUDE.md` + `ARCHITECTURE.md` §15 and the decision table: not sops+age but a `swift-crypto`
   AES-GCM envelope with a local `0600` key. `PRD.md:24`: not a static binary — `otool -L` shows the
   platform runtimes, eight system frameworks, and `libsqlite3.dylib`.
   A fourth, not previously listed, was found and fixed: `ARCHITECTURE.md` §7.3 claimed at-rest
   encryption of the state root as the compensating control for un-redacted message content. There is
   none — `claw.sqlite` is plaintext and only the two secret envelopes are sealed.
3. **Demote `curl | bash` in the README (~20m).** Reorder only: lead with the release binary plus
   `SHA256SUMS` and the provenance attestation, keep the script beneath it with a link to its source.
   **Not a single-file edit** — install steps also live in `INSTALL.md` and `GETTING_STARTED.md`, and
   repo convention is to move the public set in lockstep. Still open, and a positioning call rather
   than a fact.
4. **Set the GitHub social preview (~5m)** to `docs/assets/branding/swift-claw-social-card-1280x640.png`.

### 1.2 Tuesday

Write the Show HN text by hand from §4. Add a "Why another one" block to the README between the
one-liner and Features, carrying **one line of lineage and no comparison table** — the Moltis pattern,
which drew zero clone dismissals across 52 comments. Never the phrase "clean room."

### 1.3 Wednesday or Thursday

| Time | Action |
|---|---|
| 15:00-18:00 UTC | **Show HN**, URL and text fields both filled. Then stay present for three hours. |
| +1 min | Check `news.ycombinator.com/shownew` to confirm the post is not `[dead]`. |
| +2 h | **X** standalone post; repo link in a self-reply seconds later. |
| Launch day | Comment in the current **r/selfhosted New Project Megathread** — the only channel open before ~2026-09-15, worth a median of ~5 stars, so a placeholder rather than a launch. |
| Day +1 | **Swift Forums, Community Showcase.** No karma, age, or history gate; self-promotion is the category's stated purpose. Best odds of substantive technical discussion. |
| Day +2 | **r/LocalLLaMA**, affiliation disclosed. |
| Tue 2026-08-04, 13:00-16:00 local | **LinkedIn.** |

### 1.4 Two standing rules

**Never solicit votes, anywhere.** FAQ, guidelines, and `showhn.html` each state it separately, and
voting-ring detection can ban `github.com/ivan-magda/swift-claw` on HN permanently. Do not tell a
Discord or Telegram group that the post is live.

**Do not argue back.** Expect "this is just OpenClaw with extra steps." dang treats that phrasing as a
guidelines violation and polices it unprompted. Answer the substance once, then move on.

### 1.5 Calendared for later

- **r/selfhosted standalone post**, `Release (No AI)` flair: ~2026-09-15. Median 7, ceiling 803, and
  the AI flair drops the median to 0.
- **awesome-selfhosted**: ~2026-11-20, four months after first release. The PR goes to
  `awesome-selfhosted-data`, not the list repo. The GenAI category holds 13 entries and contains no
  personal-assistant equivalent.
- **awesome-swift**: once 15 stars exist. Edit `contents.json`, and omit "written in Swift" from the
  description per their contributing guide.
- **Skip**: r/iOSProgramming (one app post per year, wasted on a daemon), r/homelab (unpublished karma
  gate, weak fit), Lobsters (invite-only plus a 70-day bar on the `show` tag, enforced in code).

---

## 2. X

Single standalone post, not a thread: `dedup_conversation_filter.rs` collapses a conversation to one
feed slot and picks which member survives, and `author_diversity_scorer.rs` decays each additional
post from the same author. No hashtags — there are zero occurrences in the ranking tree, and topics
are inferred from prose, so the plain words "Swift", "daemon", and "Telegram" do that work.

### 2.1 Standalone launch post

> I spent six weeks building an always-on personal agent in Swift, mostly to find out where the hard
> parts are.
>
> The agent loop was not one of them.
>
> The hard parts were all in the harness. A Swift actor does not serialize across `await`, so
> one-actor-per-session silently interleaves two turns the moment one suspends on a network call.
> Each turn now chains onto the previous turn's Task. The Telegram offset cursor advances only after
> the inbound write commits, because the other order drops messages with no error anywhere to find.
>
> And the part I care about most: every file write, memory write, and code execution suspends the run
> onto a durable row and waits for you to tap Approve in Telegram. The approval is bound to a hash of
> the exact resolved arguments. The callback carries a single-use 128-bit nonce checked against your
> own numeric ID. It survives a restart with the buttons still live. Typing "yes" in the chat does
> nothing.
>
> clawd is one Swift 6 binary. No Node, no Python, no Docker. Your LLM endpoint, your Telegram bot,
> your machine. MIT.

~1,150 characters, so any paid tier. The first ~215 characters carry the hook above "Show more."

### 2.2 Optional paragraph, if the demo shows a denial

Swap this in for the approval paragraph when the video is attached. It states a property that became
scarce three weeks ago (see strategy §4):

> Three weeks ago Wiz showed that approval dialogs in six agent products would display
> `project_settings.json` while the write resolved through a symlink to `~/.ssh/authorized_keys`.
> clawd resolves the path before it asks. Symlinks and `..` are followed at the gate; anything
> landing outside the workspace is refused before a prompt exists at all; what survives is printed
> as the canonical target, untruncated, authored by the gateway rather than the model. That does not
> make it safe. It makes the thing you are approving the thing that happens.

**Do not write the `~/.ssh/authorized_keys` version of this claim.** An earlier draft implied the
approval card would render that path. It cannot: `WorkspacePathContainment.resolveForCreation`
canonicalizes the deepest existing ancestor and asserts containment at every resolved step, so a
symlink escaping the workspace is refused with *"That path resolves outside the workspace, so I
can't write it"* and no approval row is ever inserted. The demonstrable property is the one written
above — resolution happens first, and escape is refused rather than displayed.

### 2.3 Alternative opening hooks

**Founder story.**
> I could not find a personal AI agent I actually wanted to run every day, and I could not tell from
> the outside which parts of one were hard. So I spent six weeks writing my own in Swift. The agent
> loop turned out to be the small part.

**Technical architecture.**
> A Swift actor does not serialize across `await`. It reentrantly admits the next call the moment your
> turn suspends on a network request, so one-actor-per-session does not order anything. That bug is
> why my agent's per-session lane chains Tasks instead, and it is the first of about six things I got
> wrong building an always-on agent.

### 2.4 First reply, posted within seconds

> Repo, MIT, prebuilt macOS arm64 and Linux x86_64 binaries with published checksums:
> https://github.com/ivan-magda/swift-claw
>
> Design notes are in docs/ARCHITECTURE.md if you want the per-session lane or the approval state
> machine in detail.

The link sits in the reply on asymmetry grounds rather than evidence strength (strategy §5.1). Treat
it as a click path for people already on the post, not a second shot at reach.

### 2.5 Thread variant, if a thread is used anyway

Post 1 must stand alone, because the algorithm may surface only that one.

**1/** I spent six weeks building an always-on personal agent in Swift to find out where the hard
parts are. The agent loop was not one of them. Everything expensive was in the harness: ordering,
durability, and deciding what the model is allowed to do without asking.

**2/** First thing that bit me. A Swift actor does not serialize across `await`. One actor per session
looks like it orders turns, then reentrantly admits the next one the moment the first suspends on a
network call. Two quick messages, two interleaved replies. The lane now chains each turn onto the
previous turn's Task.

**3/** Second. The Telegram offset cursor advances last, only after the inbound write commits. Advance
it first and a crash before the write loses the message permanently, with nothing logged, because
Telegram never redelivers. The failure is silent, which is what makes it worth the care.

**4/** Third, and the reason I built it this way. Every write and every code execution suspends the run
onto a durable approval row and waits for a tap in Telegram. Bound to a hash of the resolved
arguments, resolved by a single-use 128-bit nonce checked against your numeric ID. Restart the daemon
and the buttons still work.

**5/** That is the whole pitch: the boundary is Swift, not a sentence in a system prompt. I assume
prompt injection succeeds and put the consequential actions behind gates a subverted model cannot
open. One binary, no Node or Docker, your own LLM endpoint. MIT.

### 2.6 Visual

**Shot and cut on 2026-07-27** — see [`demo-storyboard-2026-07-27.md`](./demo-storyboard-2026-07-27.md)
§2 for the specs and the source windows. The X asset is `demo-x.mp4`, 1080×1066, 13 s: the request
being typed, the approval card with the fully-resolved target, `Deny`, and clawd confirming it wrote
nothing.

Native upload only: nothing in the ranking code fetches or embeds an external video, while native
video is transcribed and folded into the semantic embedding, so the readable text in frame works for
you twice. The clip is under the 25-35s band where working durations cluster, which is a deliberate
trade — it holds one complete idea rather than padding to hit a length.

**The video does not show restart survival.** Shots 4 and 5 were not recorded and there will be no
reshoot. The claim stays in the copy because it is true and covered by
`restartThenOwnerCallbackStillResolves()`, but no post may invite the reader to watch it happen.

---

## 3. LinkedIn

Personal profile, never a company page. Plain URL in the body at the end of a sentence, **preview card
dismissed** — the measured penalty attaches to the card, not the URL (795 median impressions with no
link, 414 with a card, 858 with a plain in-body URL). No hashtags. No first-comment link.

### 3.1 Opening line

> A Swift actor does not serialize across `await`, and that one fact rewrote the core of the assistant
> I spent six weeks building.

139 characters, inside the ~140-character mobile fold, with no line break before it, and it states
something a competent engineer might dispute.

### 3.2 Launch post

> A Swift actor does not serialize across `await`, and that one fact rewrote the core of the assistant
> I spent six weeks building.
>
> I wanted a personal AI assistant I actually ran every day, on hardware I already own, instead of
> renting a VPS for it. I had built a coding agent before, so I expected the agent loop to be the work.
> It was not. The loop is small. Everything around it is the system.
>
> Three things I got wrong, and what they cost:
>
> One actor per conversation looked like it serialized turns. It does not. An actor reentrantly admits
> the next call the moment the current turn suspends on a network request, so two quick messages
> produced two interleaved replies. The per-session lane now chains each turn onto the previous turn's
> Task and waits for it to finish.
>
> I advanced the Telegram update cursor before persisting the message. A crash in that window loses the
> message permanently and logs nothing, because Telegram only redelivers what you have not confirmed.
> The cursor now moves last, after the write commits.
>
> I assumed I could tell the model what it was not allowed to do. You cannot. So every file write,
> memory write, and code execution now suspends the run onto a durable database row and waits for me to
> tap Approve in Telegram. The approval is bound to a hash of the exact resolved arguments, resolved by
> a single-use nonce checked against my own numeric Telegram ID. It survives a restart with the buttons
> still working. Typing "yes" in the chat does nothing at all.
>
> That last one is the design I would defend hardest. I assume prompt injection succeeds, and I put the
> consequential actions behind gates a subverted model cannot open.
>
> It is one Swift 6 binary with strict concurrency, SQLite for durable state, and no Node, Python, or
> Docker underneath. Pre-1.0 and single-author, so treat it accordingly.
>
> Source, MIT: https://github.com/ivan-magda/swift-claw
>
> Genuine question for the Swift people here: has anyone found a cleaner way to serialize per-session
> work than chaining a stored Task? I keep feeling like I am missing a primitive.

~2,050 characters, inside the 2,001-2,500 band that measured best (2.67% ER, 6 median comments).

### 3.3 Shorter alternative

> A Swift actor does not serialize across `await`. I learned that from a bug.
>
> I spent six weeks building an always-on personal assistant in Swift, talking to it through a private
> Telegram bot, running on my own Mac. One actor per conversation looked like it ordered turns. It does
> not: an actor admits the next call as soon as the current one suspends on a network request, so two
> quick messages came back interleaved. Each turn now chains onto the previous turn's Task.
>
> The design I would defend hardest is the other one. Every file write and every code execution suspends
> onto a durable row and waits for me to tap Approve in Telegram, bound to a hash of the exact resolved
> arguments and resolved by a single-use nonce. It survives a restart. Typing "yes" does nothing. I
> assume prompt injection succeeds and gate the consequential actions in code instead of asking the
> model to behave.
>
> One Swift 6 binary, no Node or Docker, your own LLM endpoint. Pre-1.0, MIT:
> https://github.com/ivan-magda/swift-claw

~980 characters. Use this when publishing without a carousel.

### 3.4 Call to action

The open question at the end of §3.2, and nothing else. No "repost to help someone in your network,"
which sits adjacent to the pattern LinkedIn named as demoted in March 2026, and no comment bait.

### 3.5 Carousel

A 7-page native document, the format that measured 7.00% ER against 4.50% for text. Native documents
also carry the visual mass that starts the dwell clock once half the update is visible.

1. Title: the assistant, the machine, the boundary
2. Data flow: Telegram in, policy gate, tool call, SQLite and FTS5, reply out
3. The actor trap, wrong version and chained-Task version side by side
4. The offset-cursor ordering, showing the lost-message window
5. A real tap-to-approve prompt with the resolved path visible
6. What survives a restart and what does not, in two columns
7. Install line, platforms, license, repo URL

---

## 4. Hacker News — brief, not copy

**Write this by hand.** See the note at the top of this file.

### 4.1 Title candidates

| Title | Chars |
|---|---|
| `Show HN: Clawd – an agent daemon whose approval prompt shows the resolved path` | 76 |
| `Show HN: Clawd – an agent daemon in one Swift binary; every write needs a tap` | 77 |
| `Show HN: Clawd – six weeks of making a personal agent survive its own restarts` | 78 |

**Preferred: the first.** It states a property that six major agent products lacked as of 2026-07-08,
carries no adjective, contains neither "self-hosted AI assistant" nor "personal AI assistant" (the
phrasings the saturation data marks as fatal), and every word in it appears in the README, so it
survives a moderator rewrite. Swift stays out of the title and in the README (strategy Appendix B).

Submit **URL and text both** — url+text reaches 30 points 5.5% of the time against url-only's 2.3%.
Never text-only; links are unclickable there.

### 4.2 Structure

The shape that measured best, from NanoClaw (533 points) and LocalGPT (331): personal motive → what it
is → hard specifics → honest limitations → a targeted ask. Name the incumbent early and as a relative,
in one clause. Do not lead with architecture; the predictable failure for an author with a normative
spec is *"lots of stuff about how it's built and absolutely nothing about how it's useful to me."*

**Motive.** You had built a coding agent before, so you expected the loop to be the work. You wanted to
know which parts of an always-on personal agent are actually hard, and to run it on a Mac you already
own rather than a VPS you would have to maintain. You never found a use case in the existing ones that
made you reach for them daily.

**What it is.** A daemon you talk to through a private Telegram bot. Conversation history and durable
memory in SQLite. Recurring schedules. Six tools. Answers stream in as live-editable Telegram drafts.

**Three defensible claims.**
- Every write, memory write, and code execution suspends the run onto a durable approval row and waits
  for a tap, bound to a SHA-256 of the resolved arguments plus a policy fingerprint, resolved only by a
  single-use 128-bit nonce checked against your numeric ID, executing the recorded arguments rather than
  asking the model again. Survives restart with live buttons. A plain "yes" in chat is inert.
- One Swift 6 binary. No Node, Python, or Docker. On Linux, system `libsqlite3` is the only external
  dependency.
- Written to keep running: ~70k lines of test against ~42.6k of source, a run state machine with no
  `default` arm so a new state is a compile error until handled everywhere, and store errors typed at a
  seam whose type exposes no method that could leak a raw SQLite error.

**Engineering worth reading about.** The per-session lane, and why the tempting fix also fails. The
offset cursor advancing last. The attempt-exposure reducer that refuses to auto-retry a request it
cannot prove never left, because retrying would hide a billed attempt behind a later success.

**Limitations, volunteered.** This is the part that decides the thread.
- Telegram sees every message, every voice note, and every streamed token; bot traffic is never E2EE.
- Your model provider sees your profile, memory, and recalled history on nearly every turn.
- Only `execute_code` is containerized, it is off by default, and it needs macOS 26 on Apple Silicon.
  Everything else runs in the daemon with your user's privileges.
- The conversation database is plaintext; the two encrypted secret envelopes keep their key in the same
  directory.
- A mid-flight turn does not resume. Only a parked approval does.
- Prompt injection is contained, not prevented. **Name the live hole:** `web_fetch` is `safe` tier with
  an arbitrary destination, so with no private-file leg armed an injected model can fetch a public URL
  with an arbitrary query string, unapproved. Anything typed in chat can leave that way, and no code
  path closes it today.
- The approval prompt shows the resolved path, and execution re-resolves it: the recorded arguments
  must canonicalize to the exact approved target or nothing is written, and a create-approved write
  publishes with `link(2)` so a file that appeared while the approval was pending collides instead of
  being clobbered. What remains is a narrow symlink TOCTOU — a same-host process swapping a parent
  directory component between that re-resolution and the syscall. Accepted, outside the v1 threat
  model, not closed. Volunteer it in this shape: the mitigation is in the code and a reader will find
  it, so describing only the hole reads as not knowing your own system.
- v0.3.0, six weeks old, one author, no external users. Not production-ready.

**The ask.** Two or three specific questions, which measurably generates discussion. Candidates: a
cleaner Swift primitive for serializing per-session work than a chained `Task`; whether the trifecta
gate's per-turn private-data leg is the right granularity or should be session-scoped from the start;
and what should have been containerized that was not.

### 4.3 Predictable questions

**"Isn't this just OpenClaw in Swift?"** No shared code; prior art was studied openly and re-derived.
The differences that matter: single owner by design, one process with no runtime to install, and a
policy gate as a first-class component. OpenClaw has 25 channels, a skills registry, and 384k stars;
this has one channel and six tools. Say that plainly rather than defensively.

**"How is this private if Telegram and an LLM vendor see everything?"** They do, and neither is fixable
inside this design. What is narrow but true: no fourth party. No telemetry, no analytics, no update
ping, no author-controlled endpoint, no account. `CLAW_LLM_BASE_URL` accepts any OpenAI-compatible
endpoint including localhost, so vendor egress can be cut to zero. Leave the search key unset and that
tool does not exist.

**"Why Telegram and not Signal or Matrix?"** It already runs on the phone you carry, and it provides
push plus inline approval buttons that survive a restart. The honest cost is that bot traffic is never
end-to-end encrypted under any setting, so "I use secret chats" is not available. The channel sits
behind a normalized message envelope, but only Telegram is implemented. Say what you would not send
over it.

**"What does it cost per month?"** Give real numbers from actual usage; do not estimate. This question
sank comparable threads, one user reporting "$300+ in the last 2 days" on a competitor. Then name the
caps that ship: $0.50 per run, $10 per day, an offline per-day token ceiling, plus turn, tool-call, and
wall-clock limits. Then name the zero-cost path — an OpenAI-compatible local endpoint — and what
degrades on it.

**"Where is the audit log, and what is it doing right now?"** An append-only audit table, with every
approval transition written in the same transaction as the row it records. `/status` and `clawd doctor`
give a per-subsystem table. **Do not call it tamper-evident**; hash-chaining was declined deliberately,
because it is not tamper-evident against a same-host daemon that can re-seal the chain.

**"How much of this did an LLM write?"** Answer plainly, whatever the truth is, and point at design
decisions rather than a disclaimer. The judgment is inspectable: the actor-lane design, the FSM with no
default arm, the typed store seam, and the deferrals the docs mark as deferrals.

**"Swift on Linux — does that actually work?"** CI builds and tests on Ubuntu ARM and macOS 26 on every
PR, and releases ship a Linux x86_64 binary needing glibc 2.38+. Have ready: the toolchain version, the
~37 MB macOS binary size, RSS at idle, and why a fully static musl build is blocked (GRDB declares
SQLite as a system library the musl SDK does not ship).

**"Why would I use this instead of building my own?"** The dismissal this category actually attracts,
and unanswered by anyone in the corpus. The honest answer: the loop is an afternoon; the six weeks went
into ordering, durability, and the approval fabric, and the test suite is the evidence that part does
not come free.

**"Why another \*claw?"** Have one line ready. The prefix is crowded on HN already, and naming
complaints consumed both top-level comments on one 7-point submission.

**"Is it production-ready?"** No. v0.3.0, first commit six weeks ago, one author, no external users in
the tree. A well-tested pre-1.0 tool by one person.

---

## 5. Fact-check gate

Before anything is posted, confirm against strategy §1:

- The §1.1 documentation fixes have landed (they have, 2026-07-27). Two drafts above would otherwise
  repeat a false claim.
- **Never claim the approval card would display a path outside the workspace.** Escape is refused at
  the gate before any prompt exists. The claim is that resolution happens first — see §2.2.
- **Nothing points at the video for restart survival.** The footage shows the card, the resolved
  target, and a denial. It does not show a restart, and no copy may imply it does.
- **The approval card currently renders as one paragraph**, not four lines: fields are joined with
  `"\n"` and delivery is markdown, where a single newline is a soft break. This ships unfixed by
  decision. Do not describe the card as "scannable" or claim the path "stands out"; it is present,
  complete, and untruncated, which is all the copy should say.
- Numbers are exact: ~2,200 `@Test` declarations (a grep count; 129 are parameterized) across 286
  suites and 272 files, ~69,751 test lines against ~42,622 source lines, 835 commits, 10 direct
  dependencies, 6 tools, 12 Telegram commands, 4 CLI subcommands, 10 Bot API methods.
- **No coverage percentage** is stated anywhere. None exists, and `TESTING.md` argues against the metric.
- **No "passing tests" count** without running the suite.
- Platforms: macOS 15+ **arm64 only**; Linux **x86_64 only**, glibc **2.38+**; Swift **6.3** toolchain.
- Binaries are **not signed or notarized** — they carry provenance attestations and checksums.
- Not "exactly-once," not "local-first," not "tamper-evident," not "pure Swift" as a property of the
  binary, and no implication that the daemon as a whole is sandboxed.
- No implication of a team, contributors, or adoption: 834 of 835 commits are the author's.
- The ChatGPT subscription route is never described as stable or supported.
