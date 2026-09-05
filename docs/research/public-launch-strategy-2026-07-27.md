# Launching swift-claw in public: what the evidence says about X, LinkedIn, and Show HN

*Prepared 2026-07-27 as input for the v0.3.0 public launch. Method: three parallel research
passes plus a repair pass. (1) A repo fact-extraction pass (12 agents: 6 area readers over
`PRD.md`/`ARCHITECTURE.md`/`README.md`/`Sources`/CI, then 5 adversarial fact-checks attacking the
riskiest headline claims) producing a verified fact sheet. (2) A platform-research pass (10
agents: 6 angles, then 3 adversarial verifications of contested tactics), grounded in primary
sources — X's open-sourced ranking code at `xai-org/x-algorithm`, HN's `showhn.html` and
`newsguidelines.html`, LinkedIn Engineering, and 2025-26 datasets. (3) A deep-research pass (98
agents, 16 sources fetched, 79 claims extracted, 25 put through 3-vote adversarial verification:
9 confirmed, 16 refuted) on whether this product category gains traction at all. (4) A repair
pass that gap-filled two angles the deep pass left empty and corrected one of its own findings by
direct API fetch. Six load-bearing facts were re-verified by hand against `Sources/`. Claims are
tagged **[OFFICIAL]** (platform docs / primary artifact / API pull), **[OBSERVED]** (a real thread
or retrospective outcome), or **[INFERRED]** (reasoning, no source).*

---

## TL;DR

The product category is saturated to the point of hostility, and the launch cannot be about the
category. An Algolia query for `tags=show_hn` plus "OpenClaw" returns **751 submissions with a
median score of 4 points**; a near-verbatim version of swift-claw's own pitch (*"ClawLite –
Local-first personal AI assistant on Telegram"*) scored **3 points with 0 comments on
2026-07-22**. "Self-hosted AI assistant" and "personal AI assistant" in a title are now negative
signals: they are the exact phrasing of hundreds of low-effort submissions.

Three findings should drive the launch:

- **swift-claw holds a differentiator that became newsworthy three weeks ago.** Wiz's
  "GhostApproval" research (2026-07-08) defeated human-approval gating in six agent products by
  displaying a harmless path while the write resolved through a symlink to
  `~/.ssh/authorized_keys`. `ToolApprovalPrompt.swift` renders the fully-resolved canonical target,
  gateway-authored, untruncated. That property is verifiable in twenty seconds and is currently
  scarce.
- **The incumbent's own documentation states this project's thesis.** `docs.openclaw.ai/gateway/security`:
  *"Prompt injection is not solved by system prompt guardrails alone - those are soft guidance;
  hard enforcement comes from tool policy, exec approvals, sandboxing, and channel allowlists."*
- **Framing is probably not causal, and the report says so.** Every winning formula in the corpus
  also appears on 1-to-4-point failures, and OpenClaw's own breakout was a third-party submission
  that followed five failed self-submissions of the same repo with the same framing.

Two hard gates constrain scheduling: HN's undocumented `/showlim` interstitial (April 2026) may
throttle accounts without much comment history, and r/selfhosted bars standalone posts for
projects under three months old, which for this repo means ~2026-09-15.

---

## 1. The verified fact base

Nothing in the launch may outrun the code. The fact-extraction pass produced a defensible
phrasing for every risky claim; the items below are the ones that changed what could be written.

### 1.1 Documentation contradictions found (fix before publishing)

| Where | Problem | Verified |
|---|---|---|
| `README.md:29-30`, `CUSTOMIZATION.md:38-40` | Claim durable memory has "full-text recall". Only `messages_fts` exists; memory items are ordered by `importance DESC, created_at DESC, id DESC` | by hand |
| `CLAUDE.md`, `ARCHITECTURE.md:694,746` | Say secrets use **sops + age**. Shipped code is a swift-crypto AES-GCM envelope with a local `0600` key | by hand |
| `ARCHITECTURE.md` §3.1 | Code map lists `SessionActor`; the real symbol is `SessionLaneRegistry` | by hand |
| `PRD.md:137` (FR-S4), SC4 | Promise conversation export and deletion in v1; no export path ships | by hand |
| `PRD.md:24` | "a single static binary" — false on both platforms | agent |
| `ARCHITECTURE.md:612` | "untrusted content cannot claim authority" — that layer is advisory | agent |
| `ARCHITECTURE.md` §6.1 | Promises a `dropped_updates` doctor counter that does not exist | agent |
| `PRD.md` NG3, `ARCHITECTURE.md:820` | Call voice a non-goal; voice transcription shipped | agent |
| `README.md:38-39` | Mentions the ChatGPT route with no caveat, while the spec says it must never be described as stable or supported | agent |
| `scripts/update-prices.sh` | Writes to `Sources/ClawLLM/Prices.json`; the real resource is `Sources/ClawLLM/Pricing/Prices.json` | agent |

### 1.2 Claims that must carry a qualifier

- **"Survives restarts"** — history, durable memory, queued replies, and pending approvals survive.
  A mid-flight turn does **not**; it fails with *"I didn't finish your last request. Please resend
  it."* The one thing that genuinely resumes is a run parked on an approval.
- **"Policy in code, not prompts"** — every side effect is authorized by deterministic Swift at the
  dispatch site, but "treat fenced content as data" remains a prompt rule. The honest framing is
  that the design assumes injection succeeds and gates the consequential actions behind something
  a subverted model cannot open.
- **"Sandboxed"** — only `execute_code`, off by default, macOS 26 arm64 only. Everything else runs
  in the daemon with the owner's privileges.
- **"Pure Swift"** — true of every line written here; the binary links BoringSSL, libyaml, and
  system SQLite like any Swift server binary.
- **"Private"** — Telegram sees every message and every streamed token; the model provider sees the
  profile and memory on nearly every turn. The defensible claim is that there is no *fourth* party:
  no telemetry, no analytics, no author-controlled endpoint.
- **Never claim** exactly-once delivery, a tamper-evident audit log, vector or semantic recall, MCP,
  signed or notarized binaries, or any coverage percentage.

### 1.3 Live limitation to disclose proactively

`WebFetchTool.swift:62-63` declares `egressClass: .arbitraryDestination` with `riskLevel: .safe`.
When no private-data leg is armed, an injected model can fetch an arbitrary public URL with an
arbitrary query string without approval, so anything typed in chat can leave that way. No code path
closes this today. Disclosing it is the right call: the launch narrative rests on candour, the
project already discloses the `file_write` symlink TOCTOU in the same register, and this is the
sharpest thing a hostile reader could otherwise find unaided.

---

## 2. Category saturation: the constraint that shapes everything

**[OBSERVED]** 751 Show HN submissions match "OpenClaw"; of the 100 most relevant, the **median is
4 points** and only two exceeded 100. The graveyard is specific and recent:

| Submission | Score | Date |
|---|---|---|
| HyperClaw – self-hosted AI assistant that replies on Telegram/Discord/+ | **1 pt, 0 cmts** | 2026-03-07 |
| **ClawLite – Local-first personal AI assistant on Telegram** | **3 pts, 0 cmts** | **2026-07-22** |
| Carapace – A security-hardened Rust alternative to OpenClaw | 2 pts, 0 cmts | 2026-02-12 |
| CoolWulf AI – A personal AI assistant built in Go, optimized for macOS | 1 pt | 2026-02-17 |
| WinClaw – Open-source personal AI assistant that runs locally on any OS | 1 pt | 2026-02-11 |
| Lilo – a self-hosted, open-source intelligent personal OS | 7 pts / 2 pts | 2026-04-24 / 05-22 |

**[OBSERVED]** Show HN is also structurally harder than it was: volume grew from 393 posts (2010)
to 28,372 (2025), and **37% of Show HN posts in January 2026 scored exactly 1 point** versus 26% of
non-Show submissions, replicated via the Algolia API (4,764 Show HNs, 1,762 at 1 point = 36.99%).
Show HN now underperforms ordinary submissions.

**[OBSERVED] The survivorship control matters more than any positioning advice.** Every framing that
appears on a winner also appears on a 1-point failure. OpenClaw's breakout was *not* a Show HN and
*not* posted by its author (third-party submission, 405 points, 2026-01-26), and **the same repo
with the same framing had been submitted five times before, scoring 2, 1, 2, 5, 32**. Hermes reached
220,741 stars **with no HN launch moment at all**. The largest events differ from the failures in
who submitted and when, not in wording.

**[INFERRED]** The one framing variable with no observed failure counterexample is a title asserting
a surprising, checkable constraint (*"in 500 lines of TS with Apple container isolation"*,
*"A 12MB binary"*, *"in under 888 KB, running on an ESP32"*) rather than a category name. That is a
pattern among survivors, not proof of causation.

---

## 3. Positioning

**Selected narrative: the agent loop was the easy part; the harness is the system, and the security
boundary belongs in code.**

It matches the strongest measured 2026 pattern, where the deliverable is comprehension
(*"I built a tiny LLM to demystify how language models work"*, 915 points / 134 comments), and that
shape is structurally immune to the clone charge. It leads with the mechanism the category is
anxious about rather than the category label that now hurts.

**[OBSERVED]** The nearest confirmation is HN item 47831437 (2026-04-20, **307 points / 333
comments**), *"OpenClaw isn't fooling me. I remember MS-DOS."*, whose author wrote in-thread:
*"Prompt injection has the shape of a confused-deputy problem and the answer to confused deputies
has always been capabilities and isolation, not asking the already confused deputy to try harder."*
That is a threat-model post, not a product post.

### 3.1 Differentiators, ranked by survivability under hostile questioning

1. **The approval boundary is Swift, not a prompt.** Bound to a SHA-256 of resolved arguments plus a
   policy fingerprint; resolved only by a single-use 128-bit nonce checked against the owner's
   numeric ID; execution replays recorded arguments rather than re-prompting. Survives restart with
   live buttons. A plain "yes" in chat is inert.
2. **One binary, nothing to install underneath.** No Node, Python, or Docker. Qualified: one binary
   per platform, and on Linux system `libsqlite3` is the only external dependency.
3. **Built to stay up.** ~70k lines of test to ~42.6k of source; a run FSM with no `default` arm so a
   new state is a compile error until handled everywhere; store errors typed at a seam whose type has
   no method for leaking a raw SQLite error.

### 3.2 Rejected narratives

- *"A local-first assistant written entirely in Swift"* fails twice. **[OBSERVED]** "local-first" is
  attacked on sight when a cloud LLM is involved: Rowboat (219 pts) drew *"You have completely
  misused and re-purposed this term. The common interpretation is that the software will continue to
  function without an internet connection."* Say instead that the data lives in one SQLite file
  readable with `sqlite3` and deletable with `rm`.
- *"I built it to understand how these work"* is the right backstory but too soft to lead.
- *"An existing Mac instead of a VPS"* invites the token-spend subthread, which sank other launches.

### 3.3 How to frame the relationship to prior art

**[OBSERVED] Never use the phrase "clean room."** Zero cases in 2025-26 of that claim landing well.
In the year's defining episode (chardet 7.0.0), the maintainer **explicitly disclaimed** clean-room
process and prevailed anyway on measurement, and the FSF's Zoë Kooyman put the 2026 reading plainly:
*"There is nothing 'clean' about a Large Language Model which has ingested the code it is being asked
to reimplement."* Note the venue split, since it is instructive: HN carried that dispute at **535
points / 373 comments** with top comments siding with the rewriter, while on the project's own issue
tracker the same argument lost roughly 2.4:1.

**[OBSERVED] Copy Moltis instead** (solo author, Rust, self-hosted personal agent, launched against
OpenClaw): Show HN 2026-02-13, **131 points / 52 comments, zero clone dismissals in the thread**. Its
README carried **one line of lineage** — *"Inspired by OpenClaw — just build it and run it"* — and
**no comparison table at launch**. Asked point-blank whether it was the same thing, the author
answered graciously and the asker replied *"I love different takes, so good luck!"*

**[OBSERVED] Naming the incumbent in the title is not a risk factor.** *Docs – Open source alternative
to Notion or Outline* took 1,952 points; *Nanobot: Ultra-Lightweight Alternative to OpenClaw* took
257. The risk lives in the body: speed-of-creation framing, an unmaintained-looking project, or a
licence contradiction.

**[OBSERVED] The pushback Moltis actually took is the one to pre-empt:** *"How does Rust alone make
it more secure and immune to Prompt injection attacks?"* His **language**-safety claim was challenged
immediately; his **architecture** claims were not. swift-claw must never imply Swift makes it secure.

### 3.4 The dismissal this category actually attracts

**[OBSERVED]** Not "clone" but fungibility. From the Nanobot thread: *"Why would I use this instead of
'vibecoding' it myself. It won't have exactly what I need, and the cost to create my own version is
measured in minutes… They are tailor-made, non-recyclable throwaway software for one person: The
creator."* No project in the corpus answers this successfully; NanoClaw's answer was auditability,
which addresses trust rather than fungibility. **[INFERRED]** The answer available here is that the
loop is an afternoon and the six weeks went into ordering, durability, and the approval fabric, with
the test suite as the evidence that part does not come free.

---

## 4. The security-claim environment

This is the best-verified angle in the research (four findings survived 3-vote verification) and the
most double-edged.

**[OFFICIAL] The incumbent's docs concede the design principle** (`docs.openclaw.ai/gateway/security`):
*"Prompt injection is not solved by system prompt guardrails alone - those are soft guidance; hard
enforcement comes from tool policy, exec approvals, sandboxing, and channel allowlists."*

**[OFFICIAL] Default-trust boundaries failed at scale in this category.** CVE-2026-29613 (2026-03-05,
CWE-306): OpenClaw *"authenticates requests based solely on loopback remoteAddress without validating
forwarding headers,"* fixed in 2026.2.12. Independent telemetry tracked exposed gateways from ~1,000
to 21,639 within a week (Censys), 30,000+ (Bitsight), and 42,900 across 82 countries
(SecurityScorecard STRIKE). **The CVE is patched, so asserting incumbent weakness in the present
tense would be wrong.**

**[OFFICIAL] Unqualified containment claims are pre-refuted.** Against NVIDIA's NemoClaw (Lasso
Security, 2026-04-23), injection exfiltrated credentials and rewrote the agent's own `SOUL.md`
**from inside an intact container with no escape**: *"both attacks weaponize pathways the sandbox is
required to permit for the agent to have basic functionality."* Independently replicated by a
non-vendor researcher. Cursor's "DuneSlide" chain reached non-sandboxed RCE at CVSS 9.3
(CVE-2026-50548).

**[OFFICIAL] Human-approval gating itself was defeated in July 2026.** Wiz, 2026-07-08,
"GhostApproval" (CWE-61 symlink following + CWE-451 UI misrepresentation): the prompt read
*"Make this edit to project_settings.json?"* while the resolved write target was
`~/.ssh/authorized_keys`. Six products reproduced — Amazon Q Developer, Claude Code, Augment, Cursor,
Google Antigravity, Windsurf — one disputed. CVE-2026-12958 (CVSS 8.5) and CVE-2026-50549 (CVSS 9.3,
*"canonicalization fallback writes without approval"*). Trade-press pull-quote:
*"Human in the loop only protects you if the loop tells the truth."*

**This is where swift-claw has a verifiable answer.** `ToolApprovalPrompt.swift` states that
*"Every owner-visible field is authored HERE, never by the model, and the fully-resolved canonical
target is never truncated,"* and renders `Target: \(recorded.canonicalTarget)` after symlink and
`..` resolution. **[INFERRED]** that "an approval gate must display the resolved target" is the
transferable requirement; GhostApproval is a canonicalization and UI-truthfulness failure rather
than a failure of approval durability, so this reading is layered on the reporting.

**The counterweight, stated plainly: no verified 2025-26 case shows a security claim *earning*
credibility for a solo author.** Every surviving case in this angle is a claim that was broken.
A security-forward narrative is therefore high-variance, and the mitigation is to publish a threat
model with named residuals and claim no safety.

---

## 5. Platform mechanics

### 5.1 X

- **[OFFICIAL]** Reach for a new account is capped by out-of-network discounting
  (`home-mixer/scorers/oon_scorer.rs`, plus a separate `NEW_USER_OON_WEIGHT_FACTOR`). One quote-post
  from a respected account moves the post into that account's undiscounted in-network lane.
- **[OFFICIAL] A thread cannot occupy more than one feed slot.** `dedup_conversation_filter.rs` keeps
  only the highest-scoring member of a `conversation_id`, and `author_diversity_scorer.rs` applies
  geometric decay per additional post from the same author. **Post one long standalone post.**
- **[OFFICIAL] Link placement is folklore with a real structural mechanism underneath.** A grep across
  all 216 files finds no link penalty. But of the 19 terms in `PhoenixScores`, `click_score` is
  opening the post detail, **not an outbound click** — there is no outbound-URL-click head, so a post
  whose payoff lands on another domain generates no trainable positive signal and trips `not_dwelled`
  on exit. The widely-cited "94% visibility reduction" traces to **n=2 posts by one person in 2024**.
  Best surviving number: text 3.56% versus link 2.25% median ER. **Decision: link in a self-reply, on
  asymmetry grounds rather than evidence strength.**
- **[OBSERVED] Media presence, not link placement, separates a dead launch from a live one.** 4,618
  followers with a 27s video: 63,776 views. 3,328 followers, no media, near-identical product: **122
  views**. Working video durations cluster at 25-35s.
- **[OFFICIAL] AI-sounding copy is scored.** `grox/classifiers/content/banger_initial_screen.py`
  screens every post at ingest with a Grok VLM emitting `quality_score` and an explicit `slop_score`.
- **[OFFICIAL] Hashtags are dead** — zero occurrences in the ranking tree; topics are Grok-inferred
  from prose, so name "Swift", "daemon", "SQLite" in plain text instead.

### 5.2 LinkedIn

- **[OFFICIAL] Dwell is a first-class ranking target.** LinkedIn Engineering (2026-03-12) describes a
  Generative Recommender with a Multi-gate Mixture-of-Experts head gating passive engagement (click,
  skip, dwell) separately from active. A post holding attention 15 seconds can outrank one harvesting
  fast likes.
- **[OBSERVED] Native document carousels lead by format:** 7.00% ER against text 4.50%, video 6.00%.
  Video views are down 36% YoY.
- **[OBSERVED] Target 1,300-2,500 characters** (2,001-2,500 measured best at 2.67% ER and 6 median
  comments; sub-400 is the worst tier). The mobile fold is ~140 characters.
- **[OBSERVED] The penalty attaches to the preview card, not the URL.** MagicPost (566,957 posts): no
  link 795 median impressions, attached preview card 414, **plain in-body URL 858**. The "-60% reach"
  and "first-comment is patched" claims trace to near-identical AI-generated blogs laundered into
  Forbes. **Plain URL in the body, card dismissed, no first-comment.**
- **[OBSERVED] Discussion comes from a contestable design claim, not a demo.** The one high-comment
  example named a specific architectural choice and drew a substantive reply; a polished demo post
  with video got 48 reactions and 2 comments.

### 5.3 Hacker News

- **[OFFICIAL] swift-claw qualifies unambiguously.** `showhn.html`: *"On topic: things people can run
  on their computers or hold in their hands,"* and *"The community is comfortable with work that's at
  an early stage."* Nothing in the rules mentions API keys, hosted demos, or free tiers. BYO-key reads
  as a feature.
- **[OFFICIAL] Title limit 80 characters** including the 9-character prefix; optimal is far shorter
  (titles with 5+ votes averaged 50). Mods rewrite metaphor and hype mid-launch, after the first hour
  is already lost.
- **[OBSERVED] One falsifiable number or hard constraint wins; an adjective dies.** Losers carried
  "lighter and easier," "safer," "intelligent." "Single binary" sold at 712 points attached to a verb
  and at 5 points without one.
- **[OBSERVED] Submit URL *and* text.** url+text reaches 30 points 5.5% of the time versus url-only
  2.3%. Never text-only: **[OFFICIAL]** *"How do I make a link in a text submission? You can't."*
- **[OFFICIAL] Generated prose is banned.** `newsguidelines.html` gained *"Don't post generated text
  or AI-edited text. HN is for conversation between humans"* in March 2026, and dang's tips comment
  adds *"Write your text by hand. Don't use an LLM to generate any of it (not even a tiny bit,
  including to edit or spruce it up)… LLM language leaves imprints on your text."* Enforcement is
  crowd-sourced. **The launch text must be hand-written.**
- **[OBSERVED] Do not lead with architecture.** The failure most likely to hit an author with a
  normative spec, from the Moltis thread: *"lots of stuff about how it's built and absolutely nothing
  about how it's useful to me."*
- **[OFFICIAL] Never solicit.** Coordinated arrival from a known-referrer cluster is what the
  anti-abuse software looks for, and voting-ring detection can ban a domain permanently.
- **[OBSERVED] Base rates:** across a 45-day census (n=5,797), 4.3% reach 30 points and 1.7% reach 100;
  median 2 points; 62.6% get zero comments.

---

## 6. Hard gates and scheduling

| Surface | Gate | Earliest |
|---|---|---|
| **Show HN** | **[OFFICIAL]** Undocumented `/showlim` interstitial shipped ~April 2026 for accounts *"without much HN history"*; dang: *"We're going to at least restrict Show HNs for a while."* No thresholds published, deliberately | Check `news.ycombinator.com/showlim` while logged in |
| **r/selfhosted** standalone | **[OFFICIAL]** Projects under 3 months old are megathread-only, measured from first public presence (first commit 2026-06-15) | **~2026-09-15** |
| **awesome-selfhosted** | **[OFFICIAL]** First release more than 4 months ago; PRs go to `awesome-selfhosted-data`, not the list repo | **~2026-11-20** |
| **r/swift** | **[OFFICIAL]** Self-promotion barred below 5 sub comments or 2 months of account age | Requires advance participation |
| **Lobsters** | **[OFFICIAL]** Invite-only; `NEW_USER_DAYS = 70` in `user.rb` bars the `show` tag for 70 days, enforced in production code | **Drop** |
| **Swift Forums, Community Showcase** | **[OFFICIAL]** No karma, age, or history gate; self-promotion is the category's purpose | **Open now** |
| **r/LocalLLaMA** | **[OFFICIAL]** 1/10th guideline, affiliation disclosed, LLM-generated copy barred | Open now |

**[OBSERVED] Timing.** All four independent measurements agree Friday is worst and 03:00-11:00 UTC is
dead; 70.2% of 2026 Show HNs scoring above 100 were submitted 12:00-21:59 UTC. Weekends maximize
threshold-clearing on thin competition, weekday afternoons maximize audience and comment volume.
For a discussion goal: **Wednesday or Thursday, 15:00-18:00 UTC**, avoiding the 12:00-14:00 UTC
volume peak.

**[OBSERVED] Sequencing: HN first.** Ranking is `(upvotes - 1) / (age_hours + 2)^1.8`, so 10-30 votes
in the first 30-60 minutes decide it, and pre-seeding elsewhere spends exactly the audience that
supplies that burst. **The one contrary datapoint deserves recording:** LeafWiki, a solo self-hosted
author, reported *"72 stars in one day. Then 64 the day after… Bigger than every press mention
combined"* from **r/selfhosted**, against **10 points and 2 comments** on HN. The counterweight
(Plane: 7,000 stars from HN versus 300 from Reddit) is a funded company in 2023, wrong category and
outside the window. The ordering is genuinely unresolved; HN-first survives here mainly because
r/selfhosted's standalone channel is closed until September.

**[OBSERVED] r/selfhosted flair economics, when it opens:** `Release (No AI)` n=49, median 7,
ceiling 803. `Release (AI)` n=86, **median 0**, 67% at ≤2 upvotes. Direct category precedent is
brutal — *Frona* scored 0 across three releases, *Jarvis* scored 0 — while **critique** of the
category outperforms it by roughly 100× (*"Self-hosting OpenClaw is a security minefield"*, 127).

---

## 7. Expected outcome

**[OBSERVED]** The median AI-tool HN launch gains **+39 stars at 24h, +57 at 48h, +82 at 7 days**,
recomputed from the shipped dataset of arXiv:2511.04453 (n=138); the headline means of 121/189/289
are inflated by a tail where the top decile captured 59% of all 7-day stars. The sample's median
baseline was 23 stars and `hn_score` was truncated at 10, so **a 0-star repo sits below those
medians**. HN score explains only 8% of star variance.

**Realistic band: 30-120 points, 15-50 comments, 40-120 stars**, with 92% of star movement inside 48
hours. Against a goal of technical discussion, a 60-point thread with 40 substantive comments beats a
300-point thread with 20.

**[OFFICIAL]** Roughly half the outcome is decided before submission: gradient boosting reaches
R²=0.48 on 7-day star growth from pre-launch signals alone.

*The ship plan and the drafted copy live in the companion file,
[`public-launch-content-2026-07-27.md`](./public-launch-content-2026-07-27.md).*

---

## 8. Pre-launch checklist

1. **Record a demo.** The repo has no `.gif`, `.mp4`, `.cast`, or screenshot, only branding art.
   Tap-to-approve is the most distinctive visible feature and no visitor can currently see it.
   dang's tips explicitly authorize a recording in place of a hosted demo. Show a **denial**, not
   only an approval.
2. **Demote `curl | bash`.** 230 HN comments since 2025-01-01 match it, and for a project pitching a
   policy engine and explicit approval it is a self-inflicted contradiction. Lead with the release
   binary plus `SHA256SUMS` and the provenance attestation.
3. **Fix §1.1**, starting with the three outright-false lines (`README` full-text recall, sops+age,
   single static binary).
4. **Set the GitHub social preview** to `docs/assets/branding/swift-claw-social-card-1280x640.png`;
   without it every shared link renders a generic card.
5. **Add a "Why another one" block** to the README between the one-liner and Features. ~95% of
   visitors arrive from a link and never read comments.
6. **Check `/showlim`** while logged in to HN.

---

## Appendix A — selected title candidates

| Title | Chars | Note |
|---|---|---|
| `Show HN: Clawd – an agent daemon whose approval prompt shows the resolved path` | 76 | **Preferred.** States the property GhostApproval made scarce; no adjective; every word appears in the README, so it survives a mod rewrite |
| `Show HN: Clawd – an agent daemon in one Swift binary; every write needs a tap` | 77 | Safer alternative; two checkable constraints |
| `Show HN: Clawd – six weeks of making a personal agent survive its own restarts` | 78 | Fits the comprehension pattern but promises a retrospective when the URL is a repo |

Swift stays out of the title and in the README. **[OBSERVED]** No top 2025-26 Swift Show HN put
"Swift" in its title; the closest analogue (*Apfel*, 743 points, ~66% Swift) named no language and
drew no language discussion across 153 comments. Swift is not a self-selling keyword the way Rust is,
though **[OBSERVED]** it does not repel either: *"Containerization is a Swift package for running
Linux containers on macOS"* took 769 points with the language in the title and no objection to it in
409 comments.

## Appendix B — the Swift-as-positioning verdict

**[INFERRED] Net neutral for the launch; a real limiter for the contributor pipeline and the Linux
story.**

- **[OFFICIAL]** "The Swift audience is too small" **fails**: RedMonk Q1 2026 ranks Swift **#11, above
  Go and Rust**; GitHub holds 1.65M Swift repos against Rust's 1.27M.
- **[OFFICIAL]** But Swift produces 0.60× as many ≥1,000-star repos as Rust, and **595 people posted
  on Swift Forums in the last 30 days** (against 22,320 lifetime accounts — use the former).
- **[OBSERVED]** Across the ~100 highest-starred Swift repos there is **not one non-Apple
  cross-platform Swift server or daemon**. Every non-Apple Swift daemon with traction sells a
  macOS-only capability, never the language.
- **[OFFICIAL]** The Linux story is a genuine ongoing cost: the Static Linux SDK has *"no support for
  dynamic linking whatsoever — even the `dlopen()` function will not work,"* and Swift chartered a
  Networking Workgroup in June 2026 to build a unified HTTP API that does not yet exist.

**Conclusion: lead with the capability, keep Swift in the README and body, and treat macOS-first
framing as where Swift is a net asset.**

## Appendix C — sources not to cite

- `github.com/webpro255/awesome-ai-agent-attacks` — anonymous, and its entry dates are curation dates;
  it produced at least one outright factual error (misdating the Semantic Kernel advisories and
  attaching prompt-injection framing found nowhere in the vendor advisories).
- VentureBeat, 2026-04-21, claiming Anthropic's Opus 4.7 system card says a tool is *"not hardened
  against prompt injection"* — a verifier extracted the 232-page PDF's full text and the phrase occurs
  **zero** times. The underlying disclosure is real; the system-card attribution is not.
- Any X ranking weight constant ("replies weighted 27×"). The `params` module is absent from the
  released code; every circulating number is extrapolated from the 2023 Scala system.
- `docs/alt-solutions/COMPARISON.md` scores. Three judges ranked four candidate swift-claw designs
  against each other; it is not a competitive result.

## Appendix D — coverage gaps and time sensitivity

**Two research angles returned nothing.** Clone positioning and Swift-as-positioning produced zero
claims surviving 3-vote verification in the deep pass; both were recovered only by a weaker
single-agent gap-fill pass, and are marked accordingly above. Whether "clean-room reimplementation to
understand the system" earns respect or invites a legitimacy fight remains unverified.

**Unfetchable, therefore uncovered rather than absent:** Reddit returned HTTP 403 to most automated
access; X entirely; Product Hunt retrospectives for this category; YouTube reviewer coverage;
Console.dev, Changelog News, iOS Dev Weekly, Swift Weekly Brief; Swift Package Index (Cloudflare).

**Vendor incentive is pervasive in §4.** Kaspersky, HiddenLayer, Archestra, Lasso, Wiz, and Trend
Micro all sell AI-agent security. This is partly neutralized where the incumbent's own docs concede
the point, where CVE records exist, and where a non-vendor replication reached the same conclusion,
but severity framing throughout comes from parties who profit from severity.

**Time sensitivity.** HN's `/showlim` gate is undocumented and can be tuned without notice. The 37%
one-point figure is a January 2026 snapshot on a moving series. The OpenClaw exposure numbers describe
a late-January-to-February 2026 window and the loopback CVE is **patched**. The GhostApproval and
Cursor work is 3-7 weeks old. r/selfhosted rewrote its new-project rule twice in four months
(2026-03-06, then 2026-04-07), so re-check before posting. **The most durable facts here are Lobsters'
70-day and invite gates, verified in enforcing source code.**
