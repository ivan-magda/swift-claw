# Scheduling & Proactive Behavior in Always-On Agents: Verified Patterns for Inc 4

*Prepared 2026-07-06 as design input for swift-claw Inc 4 ("Scheduler & proactive"). Inspiration only — clean-room; no code was copied. Method: multi-angle web research (5 search angles, 25 sources fetched, 125 claims extracted), with the top 25 claims each put through 3-vote adversarial verification: 24 confirmed, 1 refuted, 0 unverified. Systems surveyed: OpenClaw, Hermes, ChatGPT Tasks, Gemini scheduled actions, Claude Code scheduled tasks/routines, plus scheduler prior art (Quartz, APScheduler, systemd timers, cron/anacron).*

---

## TL;DR

The surveyed systems converge on the exact architecture ARCHITECTURE.md §14 already prescribes, and sharpen its parameters:

- **Durable SQLite job store** — OpenClaw migrated off live JSON files after real persistence bugs; Hermes still pays a JSON tax (atomic temp-file-rename writes). Persist run history per job, not just definitions.
- **Coarse periodic tick over the store** (Hermes: exactly a 60s gateway tick), not per-job timers.
- **Skip-or-coalesce misfire semantics, never replay-each-missed-occurrence** — universal across every surveyed system. Quartz contributes the vocabulary: a per-job *misfire instruction* gated by a *misfire threshold* (its default: 60s).
- **Scheduled runs are isolated and privilege-reduced everywhere**; OpenClaw additionally gates job *creation* above agent privilege (`operator.admin`), so an agent turn cannot self-schedule. That admin-gated write path is the reference model — the claim that Hermes blocks recursive self-scheduling was refuted (0-3).
- **Heartbeat and cron are distinct mechanisms** in OpenClaw (heartbeat = scheduled main-session turn with an in-band `HEARTBEAT_OK` ack token that suppresses delivery; cron = isolated detached runs with task records). Keep them separate in swift-claw too.
- **NL→schedule with an echoed-back confirmation** (normalized cadence + job ID + disclosed rounding + timezone) is the universal owner UX. swift-claw's confirm-before-arm is a stricter blocking variant of the same pattern.
- **Notification fatigue is fought with hard mechanisms**, not prompt requests: ack-token stripping, timezone-aware quiet-hour windows (skip, don't queue), notify-only-on-meaningful-change with persisted state, minimum-interval floors, max-active-job caps, and lifecycle auto-pause of dead jobs.
- **Security research treats any durable store the model later re-reads as a prompt-injection persistence vector.** The two enforcement points are the job-store write path (owner-only) and fire-time context assembly (reduced-privilege, stored payload = data, never instructions). They are complements, not alternatives.

---

## Verified findings

### 1. Job persistence: SQLite beats a live JSON file

OpenClaw persists cron job definitions, runtime state, **and run history** in its shared SQLite state database — "restarts do not lose schedules" — having migrated off a legacy `jobs.json` (pre-migration issue #6460 was literally "cron jobs do not persist across gateway restarts"). Hermes still uses `~/.hermes/cron/jobs.json` and must compensate with atomic write-to-temp-then-rename, storing per-run output as timestamped markdown under `~/.hermes/cron/output/{job_id}/`. Validates the `scheduled_jobs` table; suggests also persisting per-job run history/output. *(3-0 ×2; OpenClaw cron docs, Hermes cron docs + scheduler.py)*

### 2. Tick design: one coarse tick over the store

Hermes ticks its scheduler every 60 seconds from the gateway process — exactly the §14 design ("The gateway ticks the scheduler every 60 seconds, running any due jobs in isolated agent sessions"). Claude Code's session-scoped scheduler checks every second but only fires between turns. Minute-granularity schedules driven by a 60s tick are established precedent. *(3-0 ×2)*

### 3. Misfire policy: skip-or-coalesce has won, industry-wide

No surveyed system replays each missed occurrence:

- OpenClaw reschedules overdue isolated jobs to their next occurrence on gateway startup (explicitly to keep model/tool bootstrap out of the channel-connect window).
- Claude Code fires a missed task **exactly once** when the agent becomes idle, coalescing all missed intervals ("not once per missed interval").
- OpenClaw heartbeats outside the active window are skipped, never queued.
- Quartz unifies scheduler-shutdown gaps and worker exhaustion under one concept — a *misfire* — resolved per-trigger by a configured *misfire instruction*, gated by `misfireThreshold` (default 60,000 ms).

Takeaway: make misfire policy an explicit per-job field with a skip-to-next / fire-once-coalesced default, and adopt a threshold distinguishing "late" from "missed" (§6.3's catch-up cap = the coalesce bound). *(2-1 + 3-0 ×3; the 2-1 reflects conflicting OpenClaw issues #33092 vs #46287, reconciled as scoped to isolated agent-turn jobs)*

### 4. Isolation + an admin-gated write path

OpenClaw runs each isolated cron job in a fresh per-job session holding only a narrow self-scoped grant: read scheduler status, see only its own job and history, remove only its own job. Creating/updating/removing/manually-running jobs requires `operator.admin` — **an agent turn cannot self-schedule**. Hermes runs each due job in a fresh agent session with no chat platform attached. The stronger claim that Hermes disables cron-management tools inside cron-run sessions was **refuted 0-3** — no evidence Hermes blocks recursive self-scheduling. OpenClaw's owner-gated write path is the model to emulate. *(2-1 + 3-0)*

### 5. Heartbeat ≠ cron

OpenClaw's heartbeat is a periodic **main-session** turn (default 30m; 1h under Anthropic OAuth; `0m` disables) driven by a fixed prompt that reads an optional `HEARTBEAT.md` checklist: "If nothing needs attention, reply HEARTBEAT_OK." Heartbeats run in full main-session context and create no background task records; cron jobs run detached/isolated and always create task records. Two mechanisms, deliberately distinct. *(3-0)*

### 6. Ack-token suppression for heartbeat delivery

When nothing needs attention, the model replies `HEARTBEAT_OK`; the gateway strips the token (at start or end of reply) and **drops the entire reply** if the remainder is ≤ `ackMaxChars` (default 300). `showOk` / `showAlerts` / `useIndicator` flags govern what reaches the owner; the default suppresses OK-acks and delivers alerts. Directly reusable: proactive turns message the owner only when the model produces substantive non-ack content — enforced in gateway code, not by asking the model nicely. *(3-0)*

### 7. Quiet hours: timezone-aware window, skip semantics, a validation footgun

OpenClaw's `activeHours` is a start–end window in a named IANA timezone; ticks outside it are skipped until the next in-window tick — no queueing, no replay. Documented footgun: `start == end` is a zero-width window in which heartbeats are **always** skipped. swift-claw should reject that at config-validation time (doctor). *(3-0)*

### 8. Overlap guards at two levels

Hermes takes a file lock on the tick itself (`.tick.lock`) so overlapping ticks can't double-run a batch, and serializes jobs that mutate process-global state (exclusive writer under a read-write lock; stateless jobs run in a parallel pool). Claude Code gets overlap protection implicitly: scheduled prompts fire only between turns. For swift-claw: tick-level mutual exclusion is trivial in a single actor-owned ticker; §14's atomic DB CLAIM (PENDING→RUNNING) is the per-job guard; the per-session lane is the between-turns analogue. *(3-0 ×2)*

### 9. Hard rate/count caps + lifecycle auto-pause (ChatGPT Tasks)

Tasks cannot run more than once per hour; active tasks are capped per plan (FAQ: 3/5/15 — body text inconsistently says 10 for Business); unattended tasks "may automatically pause"; deleting the associated chat pauses the task (dead-job garbage collection). Single-owner analogues: a configurable minimum-interval floor, a max-active-jobs cap, auto-disabling jobs whose delivery target or context disappears. *(3-0 ×2)*

### 10. Notify-on-meaningful-change monitoring (ChatGPT)

"Monitoring tasks let ChatGPT periodically check for a change and notify you only when there is something worth reporting. Previous runs are remembered, and monitored tasks can stop when the end condition is met." Pattern: persist last-observed state per job, message only on delta, support a self-terminating end condition. *(3-0)*

### 11. NL→schedule with echoed-back confirmation is universal

ChatGPT confirms the created task explicitly; Gemini replies with a summary of the scheduled action (echo-back acknowledgment, editable afterward — not a blocking gate); Claude Code normalizes NL to a 5-field cron expression and confirms cadence + an 8-char job ID, **disclosing rounding** ("7m or 90m are rounded … and Claude tells you what it picked"). For swift-claw: parse NL → `Calendar.RecurrenceRule`, echo the normalized schedule + timezone + next-fire time + job ID over Telegram, disclose any rounding — and, stricter than all three, require explicit owner confirmation before arming (confirm-before-arm). *(3-0 ×2 + 2-1 on Gemini's non-blocking nature)*

### 12. Timezones are pinned explicitly, per job

Claude Code interprets cron in the user's local timezone ("0 9 * * * means 9am wherever you're running Claude Code, not UTC") — while its cloud Routines default to UTC, a per-surface divergence to avoid. Gemini pins location/timezone context at creation for all future occurrences. OpenClaw's `activeHours` takes a named IANA zone. For swift-claw: store an explicit IANA timezone identifier per job alongside the recurrence rule, evaluate per-occurrence, and state the timezone in the confirmation. **No surveyed doc specifies DST nonexistent/ambiguous-time behavior — swift-claw must define and document its own policy.** *(3-0 ×2)*

### 13. The security frame: durable stores are injection persistence vectors

Unit 42 demonstrated indirect prompt injection poisoning Amazon Bedrock Agents' long-term memory via session summarization: instructions persisted across sessions, re-entered orchestration prompts, and silently exfiltrated conversation history to a C2 server — persistent-behavior compromise **without any scheduler** (triggered on the victim's return). arXiv 2606.04425 generalizes: "persistence transforms prompt injection from an ephemeral model-level threat into a long-lived system-level vulnerability," and "context incorporation mechanisms emerge as a critical security boundary, since persistent artifacts become dangerous only when they are later reincorporated into execution context" (measured 32–42% end-to-end stored-injection success). arXiv 2605.13471 names scheduled jobs a "sleeper channel" and demonstrates an end-to-end cron confused-deputy attack **on OpenClaw** (see also OpenClaw issue #29442, cron prompt-injection privilege separation).

For Inc 4: (a) only the owner writes to the job store — no agent tool creates jobs (mirrors `operator.admin`); (b) fire-time context assembly, where the stored job prompt re-enters model context, is the incorporation boundary — reduced-privilege isolated runs, stored payload handled under §12 data-not-instructions; (c) write-time gating and fire-time isolation are complements, not alternatives. *(3-0 ×4, merged)*

---

## Refuted

- "Hermes prevents self-scheduling C2-style loops by disabling cron management tools inside cron-run sessions" — **0-3**. No evidence Hermes blocks recursive self-scheduling; do not cite Hermes as precedent for that control.

## Caveats

All product claims are present-tense snapshots of fast-moving 2026 docs (verified live 2026-07-05/06). OpenClaw's SQLite cron store is a recent migration — don't project it backward. Two findings rest partly on 2-1 votes (OpenClaw's reschedule-not-replay policy: conflicting issues #33092 vs #46287, reconciled by scoping to isolated agent-turn jobs; Gemini's "confirmation" is an echo-back, not a blocking approval gate). OpenAI's help article is internally inconsistent on the Business-plan cap (15 vs 10) and hedges auto-pause ("may pause"). The security bridge from memory poisoning to job-store abuse is an analytic extension corroborated by arXiv 2605.13471, but both core papers are unreviewed preprints; the Unit 42 PoC ran with Guardrails disabled and AWS disputes severity (not mechanism). Claude Code's local-timezone rule applies only to session-scoped tasks (cloud Routines default UTC).

## Open questions no surveyed system answers

1. **DST semantics for recurring jobs** — 02:30 daily on a spring-forward day (nonexistent time) or fall-back day (ambiguous time): fire-skip vs shift vs double-fire is documented nowhere. The Inc 4 spec must define policy for `Calendar.RecurrenceRule` evaluation and test it.
2. **Same-job re-entrancy across ticks** — what OpenClaw/Hermes do when a job's previous run is still executing at its next occurrence (skip vs queue vs kill) is not documented; verified evidence covers tick-level and global-state guards only. (swift-claw's answer: the §14 atomic CLAIM makes it a skip.)
3. **Delivery idempotency across a crash** between "run executed" and "run recorded" — at-least-once with dedup keys vs accepted duplicates is not documented anywhere. (swift-claw's answer: the §6.4 outbox with deterministic dedup keys.)
4. **Misfire threshold value** for a 60s ticker — Quartz defaults to 60s, but no agent product documents its chosen value; interacts with tick jitter and mac sleep/wake.

## Sources

Primary: docs.openclaw.ai (automation/cron-jobs, gateway/heartbeat, automation), hermes-agent.nousresearch.com cron docs + open-source `scheduler.py`, hermes-agent.ai cron feature page, help.openai.com Scheduled Tasks article, support.google.com Gemini scheduled actions, code.claude.com scheduled-tasks docs, quartz-scheduler.org (misfire tutorial + best practices), apscheduler.readthedocs.io, systemd.timer(5) + systemd issue #8647, unit42.paloaltonetworks.com (Bedrock memory poisoning), arXiv 2606.04425, arXiv 2606.30755. Secondary/blog: nurkiewicz.com (Quartz misfire), putorius.net (cron vs anacron), jasongorman.uk (SQLite job system), giskard.ai, penligent.ai, christian-schneider.net, androidauthority.com, makerkit.dev, usecarly.com. Forum: OpenClaw GitHub issues #6460, #33092, #46287, #29442, #73644.
