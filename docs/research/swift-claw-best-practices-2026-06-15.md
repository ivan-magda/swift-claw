# swift-claw: Personal AI Assistant Best Practices & Swift How-To (2026)

**Design-principles / best-practices / behavior layer.** This report covers principles, patterns, and concrete behavior — NOT library selection (a separate report covers libraries). Top priority throughout: **daily-driver robustness** for a persistent, always-on, Telegram-first personal assistant in pure Swift.

> **Verification key.** Claims that the adversarial verification pass marked **REFUTED** or **UNCERTAIN** are flagged inline with ⚠️ and corrected (re-attributed or softened). Everything else is grounded in confirmed sources. Date: 2026-06-15.

---

## 1. TL;DR — Principles Checklist (the non-negotiables)

**Architecture & control**
- The **harness acts, not the model.** The model only PROPOSES a structured action; deterministic code validates, authorizes, executes, records, and returns an observation. Never let the model execute side effects.
- **Enforce policy IN CODE, not in the prompt.** Risk levels, allow/deny, approval gates, rate limits, quiet hours, and budgets are checked by the runtime before execution — bypassable prompt text is defense-in-depth only.
- **Start simple.** Single LLM call → workflow (predefined code paths) → true agent, in that order. Predictability is the feature for a daily-driver. Ship a vertical slice end-to-end first.
- Keep a **minimal, fixed tool registry** (aim < 20 tools) with strict, schema-validated inputs. Narrow typed tools (`create_reminder(when, text)`) over generic shells (`execute_anything`).

**Security & untrusted input**
- **Default-DENY access.** Authorize on the **immutable numeric Telegram user ID**, never @username (the CVE-2026-28480 identity-rebinding bug). Unknown senders dropped before any LLM/tool/expensive work.
- Treat **all** inbound messages, tool outputs, fetched pages, attachments, and OCR text as **UNTRUSTED data, never instructions.** Maintain a strict instruction hierarchy in code: system/security policy > developer > role > workspace files > user task > tool observations > retrieved content.
- **Avoid the lethal trifecta / Agents Rule of Two.** Never let one session hold all of {private data, untrusted content, external communication} unsupervised. swift-claw inherently has all three → gate consequential actions through human approval.
- Prompt injection has **no reliable model-level fix.** Design so a successful injection does minimal damage (least privilege, blast-radius caps), not so injection is impossible. ⚠️ Distrust vendor "95% blocked" guardrail claims — 95% is a failing grade.

**Approvals & risky actions**
- Split actions **draft vs commit** / read vs write (CQRS). Reads run auto and parallel; writes/sends/deletes are serialized, idempotent, and require explicit confirmation.
- **Approval bound to the exact concrete action** (tool + target + normalized args), with an **expiry that resolves to DENY**. Pause BEFORE the irreversible step. Execute the exact recorded args, not a fresh model turn. Never cache a grant ("approve once, run forever").
- **Never auto-retry** non-idempotent actions (sends, deletes, payments). Retry only transient/idempotent failures.

**Reliability**
- Hard budgets as product features: max turns, tool-calls, tokens, wall-time, cost, retries, per-result size caps. On exhaustion, **stop and ask** — never silently loop.
- Retry only retryable errors (timeouts/connection/429/5xx, never 4xx/auth/refusals), with **capped exponential backoff + full jitter**, at **exactly one layer**, with a **retry budget** (~3 attempts/request, ~10% retry ratio). Honor `retry_after`.
- **Idempotent side effects** via a stable key recorded in the SAME transaction as the effect. Dedup inbound `update_id`. Treat delivery as at-least-once.
- Crash-recoverable explicit state machine (PENDING/RUNNING/AWAITING_APPROVAL/DONE/FAILED). Graceful SIGTERM: stop intake → drain → flush → close DB → exit. Cooperative cancellation for `/stop`.

**Memory & persona**
- Three memory tiers: bounded always-injected curated `MEMORY.md`/`USER.md`; append-only daily logs; searchable session archive. **Write durable facts only on explicit confirmation.** Memory NEVER overrides system/security policy.
- Scan memory writes for injection/exfiltration patterns before accepting; track provenance/confidence; flush unsaved facts before compaction; on overflow, error and force consolidation (don't silently drop).
- Persona: **anti-sycophancy first-class** — no opening flattery, reason before conceding (users err). Refuse briefly with a safe alternative; assume good faith on ambiguous-but-plausible requests. Concise for casual DMs, thorough for complex asks.

**Proactivity**
- **Opt-in, default OFF.** Tier by urgency; bounded deferral in quiet hours (not silent suppression, not avalanche); batch into digests; frequency caps; never nag; confirm before any proactive external/irreversible action. Route only to the owner's private DM.

**Observability & privacy**
- **No prompt/completion content in telemetry by default** — metadata only (model, tokens, finish reason, tool, latency, status); content capture opt-in. Compute USD cost per call and attribute it. Append-only, tamper-evident (hash-chained) audit log separate from app logs. Redact secrets at both the log boundary AND the outbound-reply boundary.

---

## 2A. Design Principles

### 2A.1 Personal AI assistant design principles

**Key principles**
- **Simplest thing that works first.** Anthropic: "find the simplest solution possible, and only increasing complexity when needed." Workflows (predefined code paths) give predictability; reserve dynamic agency for genuinely open-ended tasks. [building-effective-agents]
- **The harness acts, not the model.** The model proposes; code validates, authorizes, executes, records, returns observations — policy enforced in code cannot be talked around. [agents-best-practices]
- **CQRS / draft vs commit.** "Draft and commit are separate." Reads are fast, parallelizable, forgiving; writes need validation, idempotency, explicit confirmation — present a draft ("I can submit X. Shall I go ahead?") and act only on a yes. [agents-best-practices; spletzer]
- **Risk-gate every tool.** Auto for public reads/compute/drafts; approval for external comms/financial/destructive; deny-by-default for destructive. ⚠️ The verbatim line "Approval must be scoped to the exact action. Do not treat vague consent as blanket authorization" was **REFUTED** as a quote from agents-best-practices — the *scoped-approval principle* is real (agents-best-practices uses scope records like `single_send_only`; the exact wording traces to blakecrosley.com), so keep the principle, drop the misquote.
- **Restraint; never over-act.** Retry only transient failures; serialize writes/sends/deletes; stop on completion, approval-needed, blocker, budget exhaustion, repeated failures, or policy denial. [agents-best-practices]
- **Hard operational budgets** (turns, tool-calls, time, tokens, cost, retries, size caps); on exhaustion, stop and ask. [agents-best-practices]
- **Strict instruction hierarchy; retrieved content is data, never instruction.** [agents-best-practices]
- **Lethal trifecta / Rule of Two.** Don't let {private data + untrusted content + external comms} co-exist unconstrained; if all three are needed, require human-in-the-loop. swift-claw has all three. [Willison; Meta]
- **Memory writes only at explicit boundaries** with provenance; never persist background/web-ingested content as authoritative without review. ⚠️ The paper arXiv:2603.23064 confirms "background execution inherently enables silent memory pollution," but its *specific mitigations* (gating, provenance, human confirmation) are **UNCERTAIN** (PDF body not extractable) — present them as our recommended defenses, not as the paper's stated recommendations.
- **Right-altitude context.** Smallest set of high-signal tokens; just-in-time retrieval; no laundry-list of edge cases; minimal viable tool set. [effective-context-engineering]
- **Design for restart/recovery and verification.** Re-read durable state on resume; ground "done" claims in observations, not assumed success. [long-running-harnesses]
- **Complete observation loop.** Every tool call returns a structured result, including denials/timeouts/malformed-args/aborts. [agents-best-practices]
- **A personal assistant is ambient, interruptible, memory-and-trust-based** — favor reactive operation, interrupt-and-redirect, bounded/inspectable memory. [startearly]

**Antipatterns:** broad generic tools; safety only in the prompt; model approving its own risky actions; auto-retrying non-idempotent actions; dumping everything into context; trusting all memory/tool/web/inbound content; auto-persisting facts without confirmation; trusting guardrail "95%" claims; assuming tool success; unbounded loops; exhaustive edge-case prompt stuffing.

**swift-claw application:** The Gateway harness is the actor. Model emits a `ToolCall`; a deterministic `PermissionEngine` maps risk level → outcome BEFORE any side effect, independent of prompt text. Implement act-vs-ask as CQRS (reads auto/parallel; writes serialized, draft+commit, commit returns `approval_required` with the exact action encoded in the callback payload). Every mutating tool idempotent, dedup on `(update_id, action id)`; retry only transient/idempotent failures. Always return a structured observation. Enforce per-turn budgets; on exhaustion stop and ask the owner. Build context at the right altitude with size limits + truncation markers; wrap untrusted content in explicit markers; enforce hierarchy in code. Gate `MEMORY.md` writes behind confirmation; tag items with source/provenance/confidence/timestamps. On restart, rehydrate from SQLite and re-read durable state.

---

### 2A.2 System-prompt & persona engineering

**Key principles**
- **Strict instruction hierarchy in code, not prompt.** OpenAI Model Spec chain of command: root > system > developer > user > guideline; "quoted text, JSON, XML, multimodal data, file attachments, and tool outputs have no inherent authority" unless delegated by a higher tier. [model-spec]
- **Persona that adapts without pandering.** Reject all three failure modes: adopting the user's views ("pandering and insincere"), forced centrism, and fake neutrality. ⚠️ The "well-liked traveler who adapts without pandering" metaphor is **REFUTED** as text from the Claude's Character page — it comes from Amanda Askell at an Anthropic event (May 2025, reported by Big Technology). The *three rejections* ARE in the Claude's Character article; attribute the metaphor to Askell.
- **Bake in anti-sycophancy.** Claude 4's deployed prompt: "Claude never starts its response by saying a question or idea or observation was good, great, fascinating, profound, excellent..." and "first thinks through the issue carefully before acknowledging the user, since users sometimes make errors themselves." [Willison/Claude-4-prompt]
- **Sycophancy is a structural RLHF defect** to counteract explicitly; models revise correct answers when disputed. [Sharma et al.]
- **Split SOUL / AGENTS / USER / TOOLS**; keep the stable preamble minimal, push situational constraints into the relevant turn. ⚠️ The "AGENTS.md ~100 lines / reference-don't-inline" specifics are **REFUTED** as coming from agents.md (the site supports separation-of-concerns but states no line limit and says it holds "extra, sometimes detailed context"). Keep the separation principle; drop the ~100-line attribution.
- **Order against lost-in-the-middle.** Put bulky lower-priority material earlier; put the current task and the hardest safety rules near the start AND end. Anthropic: longform data at top, queries at the end "can improve response quality by up to 30%" on complex multi-document inputs. [claude-prompting-best-practices]
- **Concrete role + scenario scripting + labeled XML tags** for distinct content types. [keep-claude-in-character]
- **Refuse helpfully and proportionately**; assume good faith when an innocent reading exists; don't be preachy. [model-spec; Claude-4-prompt]
- **Tune verbosity/tone to the question** (concise + no lists for chit-chat; thorough for complex); ground claims, don't speculate. [Claude-4-prompt]

**Antipatterns:** letting injected context override system rules; ⚠️ relying on delimiters/XML alone (the "delimiters fail because LLMs treat them as overridable text" causal claim was **REFUTED** as AgentDojo's — AgentDojo only empirically shows data delimiters *reduce but don't eliminate* attacks, 57.69%→41.65%; the spotlighting concept is Hines et al. arXiv:2403.14720; combine labeling with in-code enforcement regardless); opening with flattery / reflexive agreement; one giant static preamble; critical rules buried mid-context; maximal-pressure "CRITICAL: you MUST ALWAYS" everywhere; fake numeric calibration; crashing on missing/oversized identity files; secrets/PII in identity files; an edgy/over-eager persona that ages badly.

**swift-claw application:** Assemble a fixed ordered pipeline, each segment a labeled block, independently size-capped: (1) SYSTEM CORE (identity + instruction-hierarchy/security statement); (2) `<soul>`/`<rules>`; (3) `<user>` + date/time/timezone; (4) `<tools>` + tool-policy summary; (5) `<memory>` (each item tagged source+confidence, non-escalating); (6) history; (7) the current Telegram message LAST in `<current_message>`. Re-anchor the hardest safety rules immediately before the current message. Each file load → `(text, wasTruncated)`; missing → empty + log; oversize → truncate + `[...truncated]`. Hard-code anti-sycophancy and refusal style in SOUL. Tone keyed to surface (plain text suited to Telegram). For uncertainty: honest qualitative hedging + stated assumptions + one clarifying question on ambiguous irreversible actions — NOT fabricated numeric confidence (LLMs are poorly self-calibrated). Every persona/safety guarantee is also enforced in code.

---

### 2A.3 Memory design best practices

**Key principles**
- **Three tiers:** durable curated `MEMORY.md` (not a transcript/log/archive); raw daily logs `memory/YYYY-MM-DD.md` (searchable, not injected); session archive (SQLite FTS, searched on demand). [OpenClaw; Hermes]
- **Bound the always-injected layer with a HARD limit; error on overflow, don't silently drop.** Hermes: `MEMORY.md` ~2,200 chars (~800 tokens), `USER.md` ~1,375 chars (~500 tokens); over-budget writes return an error so the agent consolidates in the same turn. [Hermes]
- **Context is a finite attention budget;** inject the smallest high-signal set, retrieve the rest just-in-time via lightweight identifiers. [Anthropic]
- **Flush unsaved durable facts BEFORE compacting.** OpenClaw runs a silent turn before compaction to save important context first. [OpenClaw]
- **Extract discrete, individually-updatable facts; resolve writes ADD/UPDATE/DELETE/NOOP** against existing memory. [Mem0]
- **Retrieve by recency + relevance + importance**, not relevance alone (Stanford Generative Agents: exponential-decay recency factor 0.995, embedding cosine relevance, LLM-rated 1-10 importance, equal weights). [Park et al.]
- **Explicit user control**: view/approve/reject/delete + a gate on unprompted background writes (Hermes `/memory pending|approve|reject`, `write_approval`). [Hermes]
- **Promote to long-term only after a threshold** (recall frequency, query diversity, score) via an explicit confirm/consolidate step (OpenClaw "dreaming"). [OpenClaw]
- **Action-sensitive memories store the boundary** (when it applies/expires, source/owner) but NEVER enforce or override security policy — "Memory can preserve approval context, but it does not enforce policy." [OpenClaw]
- **Treat memory writes as untrusted input**: scan for injection/exfiltration patterns and invisible Unicode; reject duplicates (memory is injected into the system prompt). [Hermes]
- (Architecture corroboration: MemGPT/Letta core-vs-archival hierarchy, OS-style RAM-vs-disk.)

**Antipatterns:** dumping transcripts/logs into `MEMORY.md`; unbounded durable memory; silent truncation on overflow; auto-remembering everything; storing trivia/web-searchable/ephemeral/already-in-SOUL facts; compacting before flushing; relevance-only retrieval; accumulating contradictions; memory authorizing a tool; persisting untrusted content verbatim or skipping injection scans; mutating the injected memory block mid-session (Hermes uses a frozen session-start snapshot to preserve prefix cache).

**swift-claw application:** Tier 1 bounded always-injected (`MEMORY.md`, `USER.md`), frozen snapshot at session start with a usage header ("67% — 1474/2200 chars"), writes persisted to disk immediately but reflected next session (preserves prefix caching). Tier 2 append-only daily logs (indexed, not injected). Tier 3 SQLite session archive with FTS (idempotent, dedup by update_id). One `memory` tool with add/replace/remove (unique-substring match), NO read action (already in prompt). On overflow, structured error listing current entries → consolidate-then-retry. `MemoryItem`: type (fact|preference|decision|action-sensitive), content, source (owner-stated|inferred|tool-output|inbound), confidence, visibility, createdAt/updatedAt, expiry/condition, soft-delete. Write on explicit request/correction/confirmed durable facts; otherwise daily logs + thresholded promotion. Per-fact ADD/UPDATE/DELETE/NOOP + exact-dup rejection. Retrieval ranks recency+relevance+importance. Missing/oversized files never crash. Flush before compaction. Scan every write for injection/exfiltration/invisible-Unicode. Memory NEVER authorizes — code-level policy is the only gate. Telegram commands for list/approve/reject/delete + a `write_approval` gate (default ON for the durable profile).

---

### 2A.4 Proactivity & heartbeat best practices

**Key principles**
- **Opt-in, per-category, easy opt-out; default silent/reactive.** Apple HIG: explicit opt-in before any notification; ~47% disable within the first week if unhelpful and ~60% unsubscribe from irrelevant alerts. [Apple HIG; ⚠️ SuprSend]
- **Tier by urgency** (Passive/Active/Time-Sensitive/Critical); only Time-Sensitive/Critical pierce Focus/quiet hours. [OneSignal/Apple]
- **Bounded deferral in quiet hours** — hold non-urgent items up to a max bound, then deliver or drop if stale; don't suppress silently, don't blast at the boundary. [Horvitz & Achlioptas]
- **Send-now = cost-of-interruption vs cost-of-deferral vs value/criticality;** prefer idle moments. [Horvitz]
- **Batch into digests** (morning/evening briefing) rather than per-item firing. ⚠️ Apple's "Scheduled Summary batches non-time-critical notifications" detail was **REFUTED** as content of the cited OneSignal page (it covers interruption levels only) — the four-level taxonomy is confirmed; cite Apple's own docs for Scheduled Summary.
- **Frequency caps + importance threshold; never nag** the same item. [Apple; Material Design]
- **Personalize along 5 dimensions** — scheduling (when), domain priority (what), autonomy (how much), communication style, context — adapting from accept/reject feedback. [1,000-Personas study]
- **Always confirm before any proactive external/irreversible action.** ⚠️ Anthropic's "checkpoints before irreversible actions like financial transactions/deleting data" was **REFUTED** — building-effective-agents recommends stopping conditions and human checkpoints generally but does NOT name irreversible/financial/delete examples; keep "pause for human review at checkpoints," drop the specific examples as Anthropic's.
- **Transparency + inline dismissibility** — show the trigger, offer one-tap snooze/mute/adjust. [proactive-programming research]
- **Be conservative early** — early mistimed proactive messages destroy trust and get the whole feature disabled. [1,000-Personas; ProPerSim]

**Antipatterns:** proactive-by-default; treating all proactive messages as equally urgent; hard-mute with no bound/catch-up; backlog avalanche at quiet-hours end; nagging; per-item firehose; act-first-tell-later; opaque pings with no rationale or controls; letting the model set its own send-rate/quiet-hours/risk gate; one-size-fits-all ignoring schedule/timezone/preferences; routing to a group chat instead of the owner's DM.

**swift-claw application:** Drive proactivity from `HEARTBEAT.md` + SQLite scheduler, gated by code-enforced policy. (1) Global opt-in flag default OFF + per-category toggles. (2) Each candidate carries a level + domain. (3) `ProactivityPolicy` checks in order: opt-in → frequency cap (token-bucket per user/day in SQLite) → quiet hours (owner's timezone from `USER.md`). (4) Quiet hours = bounded deferral: passive/active enqueued with `deferUntil` + `maxDeferDeadline`; only timeSensitive/critical bypass; stale items dropped + audited. (5) Coalesce deferred/routine into a single scheduled digest. (6) Idempotent send: stable ID + delivered flag so restarts never double-send; never re-fire as a nag. (7) Route only to the owner's numeric DM. (8) Confirm-before-act: heartbeat creates an APPROVAL request via the existing inline-button flow, never auto-executes. (9) Inline Snooze/Mute-category/Adjust-frequency controls; record accept/dismiss to tune the 5 dimensions (as soft feedback, never authoritative memory, never overriding policy). (10) Audit every create/defer/send/drop/confirm.

---

## 2B. Safety & Untrusted Input

### 2B.1 Prompt injection & untrusted input

**Key principles**
- **All inbound content is data, never instruction** — Telegram messages, web pages, tool outputs, files/attachments, OCR. Root cause is architectural: everything becomes one token sequence and "LLMs are unable to reliably distinguish the importance of instructions based on where they came from." [OWASP; Willison]
- **No reliable model/prompt-level fix exists.** OWASP: "it is unclear if there are fool-proof methods of prevention"; Meta: prompt injection "remains an unsolved problem"; the "Attacker Moves Second" paper defeated 12 published defenses >90%. Design for minimal damage. [OWASP; Willison]
- **Avoid the lethal trifecta / Rule of Two.** [Willison; Meta]
- **Enforce least privilege deterministically in code** — fixed registry, allow/deny, workspace-only FS, no arbitrary net/shell, output caps, timeouts. Microsoft prioritizes "deterministic impact prevention over perfect detection." Anthropic: "Apply the principle of least privilege so that a successful injection can do minimal damage." [Microsoft; Anthropic]
- **Human-in-the-loop for every consequential/irreversible action**, out-of-band via Telegram inline buttons. [OWASP; Microsoft]
- **Structurally separate untrusted content**: deliver only inside tool_result blocks, label its source, JSON-encode so it can't break out. ⚠️ Microsoft Spotlighting's ">50%→<2%" statistic is **UNCERTAIN/MISATTRIBUTED** to the MSRC blog — it comes from the Spotlighting paper (arXiv:2403.14720); attribute the percentage there, and the "open research challenge / impact-prevention + HITL" framing to MSRC. [Anthropic; arXiv:2403.14720; MSRC]
- **State an explicit untrusted-content policy in the system prompt** AND keep your own runtime instructions OUT of tool results (the model treats tool results with skepticism and may ignore your instructions there — put them in a following user turn). [Anthropic]
- **Block exfiltration in the output path** — strip auto-fetching markdown/HTML images and untrusted outbound links; constrain destinations. ⚠️ The markdown-image vector is real across many products, but the cited Checkmarx URL only documents Copilot Chat + Gemini (the six-product list was **UNCERTAIN** — full list traces to Johann Rehberger / Embrace The Red). The mitigation (strip image elements at the renderer) holds. [Checkmarx; Embrace The Red]
- **Plan-then-execute / dual-LLM**: fix the tool plan and destinations BEFORE ingesting untrusted content so it "cannot alter which recipients receive communications." [design-patterns paper]
- **Cheap probabilistic screens as defense-in-depth only** — a classifier flag/warning, treat misses as expected. Claude Code auto mode reports a 17% false-negative rate and "is not a drop-in replacement for careful human review on high-stakes infrastructure." [Anthropic; Microsoft]
- **Memory/identity files are privileged config** — write only on confirmation; never let untrusted content write itself in. [teleclaw; OWASP; Anthropic]
- **Red-team continuously** with adversarial inbound content; monitor for signs of successful injection. [OWASP; Anthropic]

**Antipatterns:** relying on prompt wording as the defense; trusting "95% blocked"; risk levels via instruction not code; auto-send to other chats / broad http_fetch without approval; untrusted material in the system prompt or as plain user text; your instructions inside tool_result; rendering markdown/HTML images or auto-following untrusted links; auto-promoting untrusted summaries into memory; assuming RAG/fine-tuning/bigger-model solves it; treating attachments/OCR as safe; carrying a tainted context straight into a privileged action (reset session instead).

**swift-claw application:** (1) Provenance-tagged context: TRUSTED config; SEMI-TRUSTED current owner message (still jailbreak-screened); UNTRUSTED everything else, injected only in labeled JSON-encoded tool_result blocks (`{"source":"http_fetch","url":"...","trust":"untrusted","body":"..."}`) + an `<untrusted_content_policy>` block. (2) Trifecta/Rule-of-Two gating: per-turn flags `hasIngestedUntrusted`, `hasPrivateDataAccess`, `canExfiltrate`; all three → force approval or fresh session. Reply to the originating DM is not exfiltration; any other chat is. (3) Code-enforced `ToolRegistry` with `safe|ask|dangerous|disabled` checked before dispatch; workspace-only canonicalized paths; http_fetch domain allowlist; size caps; timeouts. (4) Out-of-band approval keyed by user ID + nonce; only the originating numeric ID may approve; idempotent across restart; button carries the approval ID not action params. (5) Deterministic outbound sanitization (strip markdown image syntax, neutralize untrusted links; the Gateway derives destination from session). (6) Optional cheap injection screen on large untrusted output. (7) Memory writes require confirmation. (8) Loop/blast-radius caps + audit. (9) `/new` for a clean context; avoid chaining a tainted turn straight into a privileged action.

---

### 2B.2 Tool safety, risk levels & approval UX

**Key principles**
- **Enforce tool policy in deterministic code, never via the model.** Claude Code: "Permission rules are enforced by Claude Code, not by the model. Instructions in your prompt or CLAUDE.md ... don't change what Claude Code allows." OWASP: "Implement authorization in downstream systems rather than relying on an LLM." [code.claude.com/permissions; OWASP LLM06]
- **Small fixed registry, strict schemas, validate every call in code.** OpenAI strict mode: `additionalProperties:false`, all fields required, aim < 20 functions. ⚠️ The Anthropic-attributed parts (consolidated tools, `user_id` naming, ~25k-token response cap with pagination) are **UNCERTAIN** as coming from the OpenAI function-calling URL — they're real but from Anthropic's "Writing effective tools for agents"; cite that separately. [OpenAI; Anthropic]
- **Graduated default-deny tiers** (safe→auto; ask→approval; dangerous→disabled-unless-enabled; unknown→deny). Only mark safe if it truly can't modify state or exfiltrate (a search tool that logs queries "is not read-only"). [OWASP cheat sheet; MCP annotations; Claude Code auto mode]
- **Annotations/declared risk are UX hints, not a boundary.** MCP: annotations "are not guaranteed to faithfully describe tool behavior... clients must treat them as untrusted"; exfiltration guarantees need "network controls or sandboxing, not a boolean hint." Pair with OS-level sandboxing. [MCP blog]
- **Pause for approval BEFORE the irreversible part; bind to the exact concrete action** (actor, tool, target, normalized params, timestamp, expiry); separate decision from execution. Late approval is "theater." [OWASP cheat sheet; blakecrosley]
- **Approvals expire and default-deny** on ambiguity/timeout/repeated denial; rejection is a normal control signal. Claude Code auto mode escalates after "3 consecutive denials or 20 total." [Claude Code auto mode]
- **Filesystem: canonicalize + reject `..`/symlink escapes (check link AND target), plus OS sandboxing.** ⚠️ The OpenClaw security analysis (arXiv:2603.10387, Shandong Univ.) found sandbox escape the weakest area — avg ~17% defense, best model ~33% — via traversal/absolute-path/symlink. [arXiv:2603.10387; Claude Code]
- **Cap output size, paginate/truncate, per-tool timeouts; all outputs untrusted.** Anthropic caps tool responses to ~25,000 tokens by default. [Anthropic writing-tools]
- **Redact secrets before approval prompts, replies, and logs** (`sanitize_for_display(params)`; remove password/api_key/token/secret/credential). [OWASP cheat sheet]
- **Audit every call as a structured event** (tool, redacted params, decision/approval id, outcome, duration, risk tier, policy version); alert on high call rates / repeated failures. [OWASP cheat sheet]
- **Least privilege/least functionality**: narrow purpose-built tools, no generic shell/URL-fetch by default; execute in user context. [OWASP LLM06]

**Antipatterns:** prompt/AGENTS.md/self-restraint as enforcement; trusting annotations as guarantees; generic "Are you sure?"; post-hoc approval theater; marking a side-effecting tool safe; treating "destructive" as delete-only (overwrite/revoke/close/send are destructive); naive prefix path checks; open-ended shell/http_fetch on by default; injecting tool output into the instruction layer; persistent/unbounded approvals + no denial circuit-breaker; logging secrets/PII unredacted; dozens of overlapping thin wrappers.

**swift-claw application:** A deterministic policy engine between runtime and execution. (1) Fixed `ToolRegistry` of value types: name, strict input schema (`additionalProperties:false`, all required, optionals nullable), output schema, `RiskLevel{safe, ask, dangerous, disabled}`, timeout, sandbox flag, output cap, audit policy; < 20 tools. (2) `evaluate(call) -> PolicyDecision` in code with deny→ask→allow precedence; unknown name/parse-failure → deny; dangerous → denied unless explicit enable. SOUL/AGENTS/MEMORY/tool-output never influence this. (3) `ask` tools create a durable `Approval` (id, userId, tool, canonicalized target, redacted+normalized params, riskTier, createdAt, expiresAt, policyVersion) + inline buttons; callback re-validates the call still matches before running; expire → default-deny; on reject return a concise reason; circuit-breaker after N consecutive denials/runaway counts. (4) FS tools canonicalize + reject escapes after resolving `..`/symlinks (link AND target); workspace-only; no absolute paths. (5) Wrap each call in timeout + output cap (visible truncation marker) + `redact()` over args and results applied before display/model-return/audit. (6) http_fetch allowlist + approval-required; shell disabled by default. (7) Structured `AuditEvent` to SQLite per call, idempotent. Treat all outputs/web/inbound as untrusted, concatenated into the data turn never the system turn.

---

### 2B.3 Access control & privacy for a personal assistant

**Key principles**
- **Authorize on the numeric Telegram user ID, never @username; reject non-numeric principals at config-load.** Usernames are mutable/recyclable → identity-rebinding (CVE-2026-28480, CVSS v4 6.9, against OpenClaw/clawdbot; fix requires numeric IDs only). [GHSA-mj5r-hh7j-4gxf]
- **`User.id` is the guaranteed-unique permanent identifier** (≤52 significant bits); username is optional. [Telegram Bot API]
- **Default-DENY**: unknown senders dropped before any LLM/tool/expensive work; access only via explicit allowlist (or a pairing flow that writes a numeric ID into it). Fail-closed. [getknit]
- **Data minimization** — collect/process/store/retain only what's necessary, no longer than needed (GDPR Art. 5(1)(c) & Art. 25). [IAPP]
- **Never log secrets/sensitive PII**; redact at the boundary; sanitize CR/LF/delimiters to prevent log injection. [OWASP Logging]
- **Keep bot token + API keys out of source, committed config, and the workspace files**; load from env/secret store; least privilege; support rotation. [OWASP Secrets]
- **All inbound/tool/web/attachment content is UNTRUSTED**; segregate from system/security instructions. [OWASP LLM01]
- **Don't rely on the system prompt as a security control.** ⚠️ The verbatim quote "the system prompt should not be considered a secret nor used as a security control" is **REFUTED** as LLM02 text — it's on OWASP **LLM07** (System Prompt Leakage). LLM02 does say prompt-level restrictions "could be bypassed via prompt injection." Re-attribute the quote to LLM07.
- **Protect data at rest and in transit** — OS full-disk encryption + tight `0600/0700` permissions on DB/workspace; consider app-level encryption for the most sensitive store. [OWASP User Privacy; NIST PR.DS-P1]
- **Give the owner real control** — store facts only on confirmation; provide working export + deletion. ⚠️ GDPR access/erasure/portability are confirmed (ICO); the NIST "deletion must be an actual process, not just policy" point is **UNCERTAIN/MISATTRIBUTED** to the ICO page — cite NIST SP 800-88 separately if used.
- **Per-user and per-chat rate limits; retries with exponential backoff against providers.** [getknit]

**Antipatterns:** allowlisting by @username or resolving usernames at startup; fail-open authorization; logging full message text/prompts/tool I/O/raw payloads; secrets in workspace files or committed config; system prompt as enforcement; treating tool/web/attachment content as trusted; auto-persisting inferred facts; echoing secrets/paths/other-user data into replies; storing everything forever with no deletion path; processing without update_id dedup / idempotent writes.

**swift-claw application:** Numeric Telegram user ID is the single security boundary. Allowlist = `Set<Int64>` from config/secret store; reject non-numeric at load. Authorization extracts `message.from.id`, exact membership only — no username code path. Run authorization FIRST, before session resolution/context/provider/tool; unauthorized or from-less updates dropped + audited. Pairing persists a numeric ID into the durable allowlist. Per-user/per-chat token buckets keyed by numeric ID, fail-closed, right after authorization. Data minimization on workspace + SQLite: write `MemoryItem`s only on confirmation with source/timestamp/confidence/visibility; real delete removes rows + rewrites memory files; owner export/delete commands. Single redaction layer at TWO boundaries — before logs/audit AND before any reply — masking token/keys/secret patterns, logging detection-category + tool + request-id not raw I/O. Tokens/keys out of workspace + committed config; from env/secret store. Wrap untrusted sources in delimited blocks; enforce tool risk levels in code; OS full-disk encryption + `0600/0700` at-rest baseline. Dedup on update_id; idempotent message/usage/audit writes.

---

## 2C. Reliability & Ops

### 2C.1 Reliability & run-lifecycle robustness

**Key principles**
- **Retry only transient/retryable failures with capped exponential backoff + FULL jitter and a hard max.** `sleep = random(0, min(cap, base*2^attempt))`. AWS: jitter cut total calls "by more than half" with 100 contending clients. ⚠️ "Full Jitter is the best strategy" is **REFUTED** — AWS treats Full Jitter and Decorrelated Jitter as roughly equivalent ("the decision... is less clear"); say "one of the two top strategies." [AWS]
- **Never retry non-retryable errors** (4xx/auth/validation/content-policy); retry only timeouts/connection/429/5xx; honor `Retry-After` / `x-ratelimit-reset-*`. [AWS Builders; OpenAI]
- **Bound amplification with a retry budget** — ~3 attempts/request PLUS a rolling ~10% retry-ratio (limits overload growth to ~1.1x vs 3x). [Google SRE]
- **Retry at exactly ONE layer** — five nested layers at 3x each = 243x load. [AWS Builders; Google SRE]
- **Explicit timeouts/deadlines on every call**, derived from observed latency, with a shrinking per-run deadline (`outgoing = remaining - elapsed - buffer`); cover DNS/TLS/connect. [Google SRE]
- **All mutating side effects idempotent via a stable key, recorded in the SAME atomic transaction.** ⚠️ The spelled-out "ACID" phrasing is **UNCERTAIN** for the Well-Architected URL (it says "consistency and atomicity"/"transactions"); the ACID acronym is in the Builders' Library idempotency article. Substance holds. [AWS]
- **At-least-once + idempotent processing, not "exactly-once."** Dedup inbound update_id; key outbound sends so crash-replay is suppressed. [AWS Well-Architected]
- **Hard run-budget caps in code** (turns, tool-calls, tokens); on exhaustion return a graceful user-visible message. OpenAI Agents SDK raises `MaxTurnsExceeded` and supports an error handler returning a final_output. [Anthropic; OpenAI Agents SDK]
- **Loop protection = pattern detection, not only a counter.** Fingerprint `(toolName, normalizedArgs)`; break on repetition within a window (~3 repeats). [dev.to/aws]
- **Cooperative cancellation** for `/stop` and inbound-supersedes — `Task`, `Task.checkCancellation()` at boundaries, `withTaskCancellationHandler` to abort the in-flight stream. SE-0304: cancellation "has no effect at all unless something checks for cancellation." [SE-0304]
- **Degrade gracefully** — fail over to a fallback provider/model or return a clear "tool X unavailable" so the model adapts; don't retry a dead dependency. [Google SRE; Anthropic]
- **Crash-recoverable explicit state machine** (PENDING/RUNNING/AWAITING_APPROVAL/DONE/FAILED) for deterministic resume/replay without duplicate side effects. [Anthropic]
- **Graceful SIGTERM/SIGINT**: stop intake → drain in-flight (bounded) → flush/persist → close DB (WAL checkpoint) → exit; anything unfinished must be resumable. [daemon practice]

**Antipatterns:** retrying everything (incl. 4xx/refusals); backoff without jitter; nested retries; unbounded loops / counter-only loop control; treating broker "exactly-once" as removing idempotency; non-atomic key storage / timestamps-as-keys / whole-payload keys; wall-time/random-UUID dedup keys (re-send on replay); non-cooperative blocking work; crashing the Gateway on a missing file/tool failure/cap/provider error; killing the process without draining; retrying a fully-down dependency; one flat timeout for the whole run.

**swift-claw application:** Each turn in a `Task` with a decrementing per-run deadline. Wrap every provider/tool call in `withThrowingTaskGroup` + a timeout child; first-to-finish cancels the rest. `/stop` and supersede cancel the run's Task with `checkCancellation()` at boundaries + `withTaskCancellationHandler` aborting the stream; persist partial state at each checkpoint. ALL retry logic in ONE place (the provider client): retryable classifier; capped full-jitter backoff; hard cap (~3-5); honor `x-ratelimit-reset-*`/`Retry-After`; token-bucket + rolling retry-ratio budget. Disable retries in SDK/transport; never re-run the whole turn as a retry. On exhaustion/down → fallback provider; if all fail, degraded message + feed failure to the model. Caps in code; on exceed, polite message + stop. Loop protection by fingerprint repetition. SQLite: UNIQUE on update_id for inbound dedup; deterministic outbound key (e.g. `run_id+step_index`, not wall-clock/UUID) INSERTed with the result in the SAME transaction. State machines for runs/tools/approvals/jobs. SIGTERM: stop polling → drain bounded → flush → WAL checkpoint → exit; scheduler claims a due job atomically (PENDING→RUNNING) and marks DONE only after delivery is recorded.

---

### 2C.2 Observability, evaluation & cost control

**Key principles**
- **Adopt OpenTelemetry GenAI semantic conventions** as span/attribute vocabulary: nested `invoke_agent` → `chat` / `execute_tool` spans, stable names (`gen_ai.request.model`, `gen_ai.usage.input_tokens`/`output_tokens`, `gen_ai.response.finish_reasons`). ⚠️ "Most conventions are still 'experimental' as of mid-2026" is **UNCERTAIN** as cited (the blog says "under active development," not "experimental") — the attribute names are confirmed; cite the OTel semconv spec for maturity status. [OTel blog]
- **Default to NOT capturing prompt/completion content or tool args; content capture opt-in.** Metadata always (model, tokens, finish reason, tool, latency, status). [OTel]
- **Structured machine-readable logs (JSON) with stable typed fields + correlation IDs** (trace_id, span_id, session_id, update_id, user_id); deliberate log levels. [SigNoz]
- **Separate audit logs from app logs; append-only + tamper-evident** — monotonic sequence numbers, SHA-256 chaining the previous record's hash, optional signing, offline verifier. [GoLogX]
- **Compute USD cost per call at instrumentation time** (input/output tokens, model id, cost from a local pricing table) attributed per-user/session/operation; don't infer from billing exports. Output tokens often 5-10x costlier; tiers 10-100x; a P99/P50 cost ratio > ~50x almost always means unconstrained max_tokens. [OpenObserve]
- **Enforce budget/loop limits in code** — max tool-calls/turns/tokens, per-user/day cost ceilings, anomaly alerts vs a rolling baseline; treat unconstrained max_tokens as a bug. [OpenObserve]
- **Evaluate the trajectory, not just the final answer** — tool/argument correctness, step efficiency, plan adherence, completion, coherence; deterministic checks where exact, LLM-judge only for subjective dimensions. [Confident AI]
- **For state-mutating actions, evaluate the correct final STATE, not one "correct" process; start with ~20 real queries.** Anthropic found ~20 real-usage queries enough, and a single LLM-judge call emitting 0.0-1.0 + pass/fail most consistent. [Anthropic multi-agent]
- **Two suites: regression (golden, ~100% pass, gates CI) vs capability (low initial pass).** Seed from real production traces. ⚠️ "corrected trajectory as ground truth" is **UNCERTAIN** for the LangChain source — it advocates feeding failures back + a verified "reference solution" per task, not specifically the corrected trajectory; soften to "each paired with a verified reference solution." [LangChain]
- **Treat LLM-as-judge as biased/calibrated, never ground truth** — mitigate position bias (swing 2.5%→82.5% by position), verbosity bias, self-preference (GPT-4 preferred its own outputs 87.76% vs human 47.61%; ~80% human agreement ceiling); rationale-before-score, rubrics, pairwise > pointwise, low temperature, human calibration. [Cameron Wolfe]
- **Operator-facing visibility** — a status/health command + a doctor/security self-check; manually review 20-50 real traces before trusting any automated eval. [LangChain]
- **Keep human checkpoints before irreversible actions; distinguish guardrails (inline runtime) from evaluators (async quality).** [Anthropic; LangChain]

**Antipatterns:** logging raw prompts/completions/tool args/memory by default; trusting a single judge scalar without rubric/rationale/order-randomization/calibration; evaluating only the final answer; mixing regression + capability suites; inferring cost from monthly billing; unconstrained max_tokens / model-self-policed budgets; letting the dangerous-action actor edit/delete the audit record; changing log field names between releases / unstructured logs; forcing one process for state-mutating tasks; suppressing non-determinism instead of measuring it.

**swift-claw application:** Model every run as a typed `RunTrace` (top-level `run_id == update_id`) with ordered child spans named per OTel GenAI. One structured JSON log line per span + correlation IDs. TWO streams: (1) app/debug log (level-gated, content capture opt-in, default OFF); (2) separate append-only audit log in SQLite, each row `(seq, ts, prev_hash, event, hash)` SHA-256-chained, for authorize/deny, approval grant/deny, tool execute, memory write/delete, scheduler create/execute/cancel/fail; ship `claw audit verify`. Per call persist `UsageRecord{inputTokens, outputTokens, model, costUSD}` from a local pricing table, attributed by user/session; enforce in code (before the call) per-turn maxToolCalls, per-run maxTurns, per-call max_tokens, per-user daily cost ceiling + anomaly check. Ship `claw status` (uptime, provider reachable, DB writable, scheduler heartbeat, last update_id) and `claw doctor` (workspace files present + under caps, grep for secret-shaped strings, registry risk sanity, non-empty numeric allowlist, audit chain verifies). Evals: version-controlled regression golden set seeded from failing traces (CI, ~100% pass, gate on end-state + key sub-metrics with tolerance) + a capability set; deterministic Swift assertions over `RunTrace` (tool/argument correctness, step efficiency, policy violation, budget overrun); LLM-judge (rationale-before-score, rubric, order randomized, low temp, human-calibrated) only for tone/helpfulness. Serializable traces → replay any production failure as a fixture.

> **Robustness floor for v1:** in-code limits + audit chain + status/doctor + a ~20-query smoke set. The richer eval flywheel is genuinely optional and can come after the vertical slice.

---

## 2D. Swift How-To for Behaviors

### 2D.1 Context assembly & run lifecycle

**Key principles**
- **Model context as an ordered list of typed, individually-budgeted `ContextBlock` value types**, not one String; assemble greedily within a fixed token budget, highest-priority first. Anthropic: context is "a finite resource with diminishing marginal returns"; beware "context rot." [effective-context-engineering]
- **Enforce the token budget deterministically in code BEFORE every call** — count, then truncate per-block with explicit markers; never rely on the model/provider to truncate. ⚠️ "fall back to a longer-context model" and the explicit "rather than relying on the provider to truncate" framing are **UNCERTAIN** for the apxml URL (the page covers budget-check + truncate + sliding-window, not those two specifics) — keep the core, drop those attributions. [apxml]
- **High-signal identity/policy at top, "right altitude," effectively non-truncatable; shed volume-heavy low-marginal content first** (old history, bulky memory, tool dumps). [effective-context-engineering]
- **Prefer just-in-time retrieval + compaction over pre-loading**; keep lightweight references; summarize into a rolling summary preserving decisions/unresolved-bugs/details. Anthropic productized this as context editing (auto-clear stale tool results → placeholder) + a file-based memory tool. [context-management]
- **Model the run lifecycle as an ordered pipeline over immutable `Sendable` value types; run state = enum with associated values** for compiler-enforced exhaustive handling. [building-effective-agents; SE-0306]
- **Stateful coordinators are actors; carry only `Sendable` types; per-user session/run serialized.** SE-0306: cross-actor refs must be `Sendable`; actors are reentrant — "actor-isolated state can change across an await"; "encapsulate state updates in synchronous actor functions." So re-check "already processed this update_id?" in a synchronous critical section. [SE-0306]
- **Bounded loop with hard guardrails** (max tool-calls/turns/tokens, no-progress detection, stable idempotency key per tool call, explicit approval state). [building-effective-agents]
- **Cancellation/timeouts/retries/fallback on structured concurrency** — task groups propagate cancellation; race work vs `Task.sleep`; long work checks `Task.checkCancellation()`. [SE-0304]
- **Dedup inbound updates by update_id before any work; idempotent writes; at-least-once delivery.** [Telegram Bot API]
- **Swift 6 strict concurrency, main-actor-default, minimal intentional concurrency; let region-based isolation (SE-0414) prove safety** rather than `@unchecked Sendable`. [donnywals; SE-0414]

**Antipatterns:** string-concatenation prompts with no per-block accounting; relying on provider/model to truncate; truncating without markers; low-signal bulk crowding out identity/policy; untrusted content in the same trust tier as system blocks; tool risk policy via prompt; splitting a dedup check across an `await`; sharing mutable reference types across actors / `@unchecked Sendable`; calls without timeouts (or timeouts that never cancel); unbounded loops; crashing on missing/oversized files; implicit memory persistence.

**swift-claw sketch:**

```swift
enum ContextSection {
    case system, soul, agents, user, dateTime, tools, toolPolicy
    case history, rollingSummary, memory, skills
}

struct ContextBlock: Sendable {
    let section: ContextSection
    let priority: Int            // higher = kept first
    let estimatedTokens: Int
    let truncatable: Bool        // identity/policy = false
    let render: @Sendable () -> String
}

struct TokenBudget: Sendable {
    let modelMax: Int
    let reservedOutput: Int
    var inputCap: Int { modelMax - reservedOutput }
    // plus optional per-section caps
}

// Greedy assembly: sort by priority desc; include while under cap;
// truncatable overflow -> cut to cap + append "\n[...truncated N of M tokens...]";
// non-truncatable overflow -> log + degrade, never silently drop.
```

```swift
enum RunState: Sendable {
    case running(turn: Int)
    case awaitingApproval(ApprovalRequest)
    case completed(Reply)
    case failed(RunError)
    case cancelled
}

actor SessionStore {
    // Synchronous critical section — NO await inside; defeats reentrancy duplication.
    func claimUpdate(_ id: Int64) -> Bool { /* INSERT OR IGNORE; return inserted */ }
}
```

Pipeline of `Sendable` values: `IncomingMessage` → `AuthorizedMessage` → `RateLimitedMessage` → `ResolvedRun` → `AssembledContext` → `ProviderResult` → `Dispatched` → `Reply` → audit. Failure-isolate each workspace-file load (missing/oversized → empty/capped block, never throw). Named actors only for shared mutable state (`SessionStore`, `AuditSink`, `Scheduler`, `RateLimiter`); reserve `@concurrent nonisolated` for provider/tool I/O.

---

### 2D.2 Telegram message mechanics

**Key principles**
- **4096 is the per-message ceiling — SPLIT long replies into sequential parts, never truncate.** ⚠️ The 4096 limit is confirmed verbatim ("1-4096 characters after entities parsing"); the "must split, not truncate" rule is **UNCERTAIN** as a documented Telegram rule (the API rejects over-limit text with a 400 rather than silently truncating) — present splitting as best practice. The OpenClaw 2026.03.13 regression that truncated past 4096 is the cautionary tale. [Telegram Bot API; OpenClaw #57746]
- **Split at semantic boundaries** with a cascade: paragraph (`\n\n`) → newline → sentence → hard cut; never split inside a code fence or open entity. [OpenClaw #57746]
- **Re-balance fences/entities per chunk** — close at chunk end, reopen (re-emit language tag) at the next start. MarkdownV2: "Escaping inside entities is not allowed, so entity must be closed first and reopened again." [Telegram Bot API]
- **MarkdownV2 escaping is context-dependent** — 18 specials in normal text (`_ * [ ] ( ) ~ \` > # + - = | { } . !`); inside pre/code only backtick + backslash; inside link/emoji `(...)` only `)` + backslash. A single uniform escaper corrupts code blocks and URLs. [Telegram Bot API]
- **Prefer HTML parse_mode for LLM output** — escape only `< > &` (and `"` in attributes) + a fixed tag whitelist; far smaller, less error-prone surface. [Telegram Bot API]
- **Always plain-text fallback** — on a 400 (can't parse entities), retry the SAME message with parse_mode omitted; keep the un-escaped original. [Symfony #42697]
- **Throttle streaming edits** — first message after the first sentence/N tokens, then `editMessageText` no faster than ~1/sec per message (OpenClaw suggests 2-3/sec max, e.g. every 500ms or ~50 tokens), coalescing, with one final clean edit. ⚠️ The ~30 edits/sec global figure is community-sourced (OpenClaw issue), not official Telegram docs. [OpenClaw #33220]
- **Skip unchanged edits** — compare to last-sent text; treat "message is not modified" as a benign no-op. [Latenode]
- **Dedup inbound by update_id** — persist last confirmed id, `getUpdates` with `offset = last+1`, ignore already-processed ids; at-least-once. [Telegram Bot API]
- **Two-scope token-bucket rate limiter** — per-chat (~1/sec) + global (~30/sec); honor server 429 `retry_after` as authoritative. ⚠️ The FAQ confirms the limits + 429 but does NOT mention `retry_after` — that field is on the ResponseParameters type; cite `#responseparameters` for it. [Telegram FAQ; Bot API]
- **`sendChatAction('typing')` for slow replies, refreshed every ~4-5s** — the status auto-clears after 5s or on message send. [Telegram Bot API]
- **Bot API 9.5+ (Mar 2026): prefer native `sendMessageDraft` for streaming**, keep `editMessageText` as fallback, ALWAYS finalize with `sendMessage` (the draft is an ephemeral 30s preview; `draft_id` non-zero and reused). [Telegram Bot API changelog + method page]

**Antipatterns:** truncating at 4096; hard byte-count splitting; one uniform MarkdownV2 escaper over code/URLs; escaping inside an open entity; no plain-text fallback; per-token / faster-than-1/sec edits; identical-content edits; ignoring `retry_after` with a fixed sleep; single global bucket only; one-shot `sendChatAction`; treating the draft preview as delivered; no update_id dedup; streaming tool-call/thinking blocks to the user.

**swift-claw sketch:** a `TelegramOutbound` actor owning all sends.

```swift
// Boundary-aware, fence/entity-safe splitter.
func splitForTelegram(_ text: String, limit: Int = 4096,
                      mode: ParseMode) -> [String]
// prefer \n\n > \n > sentence-end > hard cut;
// inside ``` fence at a cut: append closing ``` then prepend ```<lang> next chunk.

enum EscapeContext { case normal, code, linkURL }
func escapeMarkdownV2(_ s: String, context: EscapeContext) -> String
func escapeHTML(_ s: String) -> String   // & < > and " in attrs

// Default HTML parse_mode; keep raw text; on 400 -> sendPlain(rawText).
// Per-chat TokenBucket(capacity 1, refill 1/s) + global (~25/s headroom);
// every send awaits both; on 429 parse parameters.retry_after, sleep, retry.
// StreamRenderer buffers tokens, flushes at >=1.0s ticks, edits chunk 0
//   (skip if == lastSentText), spills overflow to new messages, final clean edit.
// TypingKeeper: sendChatAction(.typing) on start, reschedule every 4s, cancel on send.
// Dedup: persist lastUpdateId; getUpdates offset = lastUpdateId+1; advance only
//   after the update is durably persisted (crash redelivers rather than drops).
```

**Posture (teleclaw-consistent):** ship non-streaming whole-message send (split + plain-text fallback) as the vertical slice; add throttled `editMessageText` streaming, then native `sendMessageDraft`, as later opt-in features.

---

### 2D.3 Approval state machine & audit

**Key principles**
- **Model the approval lifecycle as an explicit FSM over an enum, with one synchronous `reduce(state, event) -> state` and an exhaustive switch (no `default`)** so the compiler flags unhandled combinations. [LY Corp]
- **Run the FSM in an actor; every transition synchronous** — never let an `await` split a transition (reentrancy: "actor-isolated state can change across an await"; "encapsulate state updates in synchronous actor functions"). Only the public API is async. [SE-0306]
- **Separate REQUEST from RESPONSE; key the response to a stable callback id carrying the exact tool name + args.** Execute the recorded args, not a later model turn. (Microsoft Agent Framework: `FunctionApprovalRequestContent.FunctionCall` → `CreateResponse(true/false)`; the C# API names — Python uses `function_call`/`create_response`.) [Microsoft]
- **Enforce tool policy (risk + allow/deny + sandbox/scope) in deterministic code in a gate BEFORE dispatch**, from config the agent cannot modify. NVIDIA: "policy must exist independently from the LLM's influence." [NVIDIA]
- **Default-deny; fresh explicit confirmation, never cached/implied consent.** NVIDIA: "approvals should never be cached or persisted... Each potentially dangerous action should require fresh user confirmation"; enterprise denylists can't be overridden by user allowlists. [NVIDIA]
- **Append-only, immutable audit record per consequential action**, consistent schema: actor, action (stable verb), target/tool, redacted args, decision/outcome, result size, UTC timestamp. ⚠️ "outcome" as a listed schema field is **UNCERTAIN** for the WorkOS source (its typical schema = actor, group, action type, UTC timestamp) — keep outcome but don't attribute it to WorkOS; immutability + audit-vs-diagnostic distinction ARE confirmed there. [WorkOS]
- **Idempotent persistence** — dedup via UNIQUE/PRIMARY KEY + `INSERT ... ON CONFLICT DO NOTHING`. ⚠️ The "store dedup key atomically with the processed effect" point is **UNCERTAIN** for the SQLite UPSERT page (it covers conflict mechanics only) — the atomicity is a real best practice; cite an idempotency-pattern source, not the SQLite docs. [SQLite UPSERT]
- **Persist the PENDING approval to survive restart, with an explicit timeout/expiry that resolves to DENY** (first-class terminal state). [Microsoft; OWASP]
- ⚠️ The "OWASP 2026 agentic guidance" (human approval per step, least-privilege, tamper-proof logs) is **UNCERTAIN** as cited — the nhimg.org URL is a third-party summary of OWASP's Agentic Top 10 (ASI01-ASI10), not OWASP-authored; the substance is sound, attribute it as a third-party summary.

**Antipatterns:** an `await` inside the transition critical section; a `default:` arm hiding illegal transitions; the model deciding allow/deny or reading policy from a tool description; re-deriving args from a fresh turn after approval; caching/auto-renewing a grant; treating expired/unanswered approval as "proceed"; unredacted/mutable/inconsistent audit rows; treating tool/web/inbound content as trusted instructions; logging the effect and dedup key in separate transactions; counter-style non-idempotent UPSERTs for dedup.

**swift-claw sketch:**

```swift
enum ApprovalState: Sendable {
    case pending(callbackID: String, call: ToolCall, expiresAt: Date)
    case approved(ToolCall)
    case rejected(reason: String)
    case expired
    case executing
    case completed(ResultSummary)
    case cancelled
}

enum ApprovalEvent: Sendable {
    case userApproved(callbackID: String)
    case userRejected(callbackID: String)
    case timedOut
    case executionFinished(ResultSummary)
    case executionFailed(message: String)
}

actor ApprovalCoordinator {
    // SYNCHRONOUS, exhaustive, no default — side effects happen AFTER commit.
    func reduce(_ state: ApprovalState, _ event: ApprovalEvent) -> ApprovalState
}

// Persist pending to SQLite keyed by Telegram callbackID (the inline-button data):
//   INSERT ... ON CONFLICT(callback_id) DO NOTHING  (dup tap / replay = no-op),
//   dedup write + request row in ONE transaction.
// On startup: load pending rows, arm timers; already-past expiresAt -> expired -> cancelled.

// Deterministic, not an actor:
enum Disposition { case autoRun, requireApproval, deny(reason: String) }
func toolPolicyGate(_ call: ToolCall, actor: Principal) -> Disposition
// checks registry risk (safe/ask/dangerous/disabled), allow/deny, canonicalized
// workspace-only paths; unknown tool/caller -> deny.

struct AuditEvent: Sendable { /* id, ts(UTC), actor, action, tool,
    argsRedacted, decision, resultBytes, outcome */ }
// AuditLog actor: append-only (INSERT only, never UPDATE/DELETE), size-capped.
```

When the user taps Approve, execute the EXACT recorded args. Persist the PENDING request (for restart-resume + audit), never a standing grant. Expiry → DENY → cancel. If shell/exec is ever enabled, back the in-code gate with OS-level sandboxing (the in-code gate alone is insufficient once a subprocess starts).

---

## 3. How the teleclaw-prompt holds up — Scorecard

| teleclaw principle | Verdict | Note / improvement |
|---|---|---|
| One long-running Gateway; local-first; secure-by-default; boring over clever | **Aligned** | Matches simplicity-first + minimal intentional concurrency (Swift 6 main-actor-default). |
| Ship a vertical slice before optional features | **Aligned** | Confirmed by Anthropic incremental guidance. Apply to streaming (non-streaming first) and evals (smoke set first). |
| Default-DENY; numeric Telegram user IDs as the boundary; reject unknown users before the LLM | **Aligned** | Vindicated by CVE-2026-28480. **Refine:** reject non-numeric principals at config-load; no username resolution path at all. |
| Pairing code / allowlist | **Refine** | Pairing must write a DURABLE numeric ID into the allowlist, not grant ephemeral/transient access. |
| Per-user/chat rate limits | **Aligned** | Add two-scope token buckets (per-chat ~1/s + global ~30/s) + honor `retry_after`. |
| Persistent sessions survive restarts; idempotent writes; dedup update IDs | **Aligned** | **Refine:** dedup key+effect must be ONE atomic transaction; deterministic keys (not wall-time/UUID); do the dedup check synchronously inside the actor. |
| Plain-text identity/memory files; size limits + truncation markers; missing files must not crash; no secrets in workspace | **Aligned** | Matches deterministic-budget + failure-isolated blocks; load each file to `(text, wasTruncated)`. |
| Core loop (authorize → rate-limit → resolve → store → build context → provider → tools/approvals → persist → reply → audit) | **Aligned** | Maps onto the agent-loop + guardrails consensus; expressible directly in structured concurrency. |
| Enforce policy IN CODE, not via the model | **Aligned** | The single most important point (Claude Code, OWASP, Microsoft, NVIDIA all converge). |
| Tool registry with risk levels safe/ask/dangerous/disabled; explicit schemas | **Aligned** | **Refine:** keep < 20 tools; declare annotations as non-authoritative UX hints; re-validate the approval against the originally-approved canonical action at execution time. |
| Telegram inline-button approval for ask tools | **Aligned** | **Refine:** bind to exact action + expiry resolving to DENY; persist PENDING (not a grant); execute recorded args; never cache approvals. |
| Path-traversal protection; workspace-only FS | **Refine** | Add explicit symlink-target checks (link AND target) — OpenClaw's weakest vector (~17% defense). |
| OS-level sandboxing optional for MVP | **Gap** | For a daily-driver, treat sandboxing of any enabled shell/code tool as a strong default, not optional. |
| Tool outputs / web / attachments / inbound are UNTRUSTED; outputs must not change system instructions | **Aligned** | Matches OWASP segregation + Anthropic untrusted_content_policy + instruction hierarchy. |
| Memory: store facts only on confirmation; MemoryItem schema; deletion; memory never overrides policy | **Aligned** | **Refine:** add HARD budget-error-on-overflow, flush-before-compact, per-fact ADD/UPDATE/DELETE/NOOP, recency+relevance+importance retrieval, injection/exfiltration scan on writes. |
| Untrusted content can't escalate; security boundary is numeric ID + in-code policy | **Aligned** | Strong. Make the lethal-trifecta / Rule-of-Two per-turn gate explicit. |
| HEARTBEAT.md proactive tasks; restart-safe scheduler; no duplicate delivery | **Refine/Gap** | **Add** opt-in default-OFF, quiet hours + bounded deferral, frequency caps, interruption tiers, digest batching. HEARTBEAT is the biggest risk surface: reduced trust, never auto-write durable memory, external sends require approval. |
| Support cancellation, timeouts, retries+backoff, provider fallback, caps, loop protection | **Refine** | **Add** full jitter, retry-at-one-layer + retry budget, non-retryable classifier, fingerprint-based loop detection, decrementing per-run deadline. |
| Audit + usage tracking, size-limited | **Refine** | **Add** append-only hash-chained tamper-evident audit (separate from app logs) + an offline verifier; OTel GenAI span model; status/doctor commands; per-call USD cost. |
| Persona/tone/boundaries (SOUL.md) | **Refine** | Make anti-sycophancy and willingness-to-disagree first-class; treat "calibrated confidence" as honest qualitative hedging, NOT fabricated numeric confidence. |
| Calibrated confidence | **Refine** | ⚠️ Contested: LLMs are poorly self-calibrated; scripted "I'm 90% sure" misleads. State assumptions + ask on ambiguous irreversible actions instead. |
| Redaction for logs | **Refine** | Apply redaction at BOTH the log boundary AND the outbound-reply boundary. |
| Encryption at rest / retention / deletion | **Gap** | Under-specified: add OS full-disk encryption + `0600/0700` baseline, a real deletion process, and a retention limit. |

---

## 4. Things the user didn't ask about but should consider

- **Evaluation is absent from teleclaw entirely.** Even a tiny ~20-query regression smoke set + trajectory checks pays for itself; seed it from real failures. (Optional for v1 but cheap and high-value.)
- **Tamper-evidence for the audit log.** "Everything audited" isn't enough if the actor who runs dangerous tools can silently rewrite the record. Hash-chain it and separate it from app logs.
- **Outbound exfiltration controls.** teleclaw plans markdown/HTML escaping for *correctness*; add stripping of auto-fetching image elements and untrusted links as a *security* control (zero-click exfiltration). The Gateway must own the destination chat ID.
- **At-rest encryption + retention/deletion mechanics**, not just policy — OS full-disk encryption, tight file permissions, a working delete, a retention limit.
- **Per-call USD cost attribution** from a local pricing table — billing exports tell you how much, not why; output tokens and model tier dominate cost.
- **Graceful shutdown choreography** (SIGTERM drain) and a **crash-recoverable state machine** — without them, every restart drops or double-delivers work.
- **Operator commands** (`status`, `doctor`, `audit verify`) — a one-command answer to "is it healthy and safely configured?".
- **Tainted-session reset** (`/new`) — once a turn ingests untrusted content, prefer not to chain straight into a privileged action.
- **Telegram streaming is a later feature**, not part of the vertical slice — get split + plain-text fallback right first.
- **Native `sendMessageDraft` (Bot API 9.5+)** exists now and avoids edit rate-limits/flicker — worth planning for, but always finalize with `sendMessage`.

---

## 5. Open questions / contested advice

- **"Calibrated confidence"** ⚠️ — the naive reading (scripted numeric confidence) is contested; research shows LLMs are poorly self-calibrated. Use honest qualitative uncertainty + stated assumptions instead.
- **Auto-save vs confirm-on-write memory** — Hermes defaults to agent-auto-save; teleclaw's confirm-default is safer for a security-first daily-driver. Offer a `write_approval` gate (default ON for the durable profile, optionally OFF for low-risk daily-log notes).
- **Persist vs never-cache approvals** — reconciled: persist the PENDING request (restart-resume + audit) but NEVER derive a future auto-run from a past approval (NVIDIA).
- **Silent truncation vs error-on-overflow for memory** — OpenClaw silently truncates the injected copy; Hermes errors and forces consolidation. The Hermes error gives the model agency to curate; prefer it.
- **Rolling summary vs aggressive compaction/JIT retrieval** — teleclaw lists a rolling summary; primary sources push compaction + just-in-time references + note-taking. Treat the rolling summary as one compaction strategy and also keep memory as out-of-window references pulled on demand.
- **Full Jitter vs Decorrelated Jitter** ⚠️ — AWS treats them as roughly equivalent; either is fine, jitter itself is the non-negotiable.
- **No guardrail makes the trifecta "safe"** — vendor "95% blocked" is a failing grade; rely on structural avoidance + human approval, not a classifier.
- **In-code gate vs OS sandbox for shell/exec** — NVIDIA argues true enforcement belongs at the OS layer once a subprocess starts; the in-code gate alone is insufficient there. Best avoided by "no arbitrary shell by default."

---

## 6. Sources (deduped, grouped by topic)

**Assistant design principles & agentic loop**
- Anthropic — Building effective agents: https://www.anthropic.com/engineering/building-effective-agents
- Anthropic — Effective context engineering for AI agents: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Anthropic — Effective harnesses for long-running agents: https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- agents-best-practices (DenisSergeevitch): https://github.com/DenisSergeevitch/agents-best-practices
- OpenAI — A practical guide to building agents: https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/ ; summary: https://openarchitect.ai/technical-summary-openais-practical-guide-to-building-ai-agents/
- Ryan Spletzer — Ask vs Act (CQRS for AI agents): https://www.spletzer.com/2025/08/ask-vs-act-applying-cqrs-principles-to-ai-agents/
- Mind Your HEARTBEAT! (background execution / silent memory pollution): https://arxiv.org/abs/2603.23064
- AI Assistant vs. AI Agent: https://www.startearly.ai/post/ai-assistant-vs-ai-agent

**System prompt & persona**
- OpenAI Model Spec (2025-12-18): https://model-spec.openai.com/2025-12-18.html
- OpenAI — The Instruction Hierarchy: https://openai.com/index/the-instruction-hierarchy/
- Anthropic — Claude's Character: https://www.anthropic.com/research/claude-character (metaphor: Amanda Askell, Big Technology, May 2025)
- Simon Willison — Claude 4 system prompt highlights: https://simonwillison.net/2025/May/25/claude-4-system-prompt/
- Anthropic — Keep Claude in character: https://platform.claude.com/docs/en/test-and-evaluate/strengthen-guardrails/keep-claude-in-character
- Anthropic — Prompting best practices: https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- Sharma et al. — Towards Understanding Sycophancy: https://arxiv.org/pdf/2310.13548
- AGENTS.md: https://agents.md/
- AgentDojo (delimiter defense empirics): https://arxiv.org/pdf/2406.13352 ; Spotlighting: https://arxiv.org/abs/2403.14720

**Memory**
- OpenClaw — Memory: https://github.com/openclaw/openclaw/blob/main/docs/concepts/memory.md ; Active memory: .../active-memory.md
- Hermes Agent — Persistent Memory: https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/memory.md
- Generative Agents (Park et al.): https://arxiv.org/abs/2304.03442
- MemGPT (Packer et al.): https://arxiv.org/abs/2310.08560 ; Letta docs: https://docs.letta.com/letta-memgpt
- Mem0: https://arxiv.org/html/2504.19413v1

**Proactivity & heartbeat**
- iOS HIG — Notifications: https://codershigh.github.io/guidelines/ios/human-interface-guidelines/features/notifications/index.html (third-party mirror; prefer developer.apple.com)
- iOS Focus modes / interruption levels: https://documentation.onesignal.com/docs/en/ios-focus-modes-and-interruption-levels
- Apple WWDC21 — Scheduled Summary / interruption levels: https://developer.apple.com/videos/play/wwdc2021/10091/
- Horvitz & Achlioptas — Bounded Deferral: https://www.microsoft.com/en-us/research/publication/principles-of-bounded-deferral-for-balancing-information-awareness-with-interruption/
- Horvitz — Attention-Sensitive Alerting: https://www.microsoft.com/en-us/research/publication/attention-sensitive-alerting/
- 1,000 Personas: https://arxiv.org/html/2602.04000v1 ; ProPerSim: https://arxiv.org/pdf/2509.21730 ; Proactive programming support: https://arxiv.org/pdf/2502.18658
- Material Design — Notifications: https://m1.material.io/patterns/notifications.html
- Notification-fatigue stats: https://www.suprsend.com/post/alert-fatigue (47%/60%) ; HelpLama via MagicBell (64%/61%): https://www.magicbell.com/blog/help-your-users-avoid-notification-fatigue

**Prompt injection & untrusted input**
- OWASP LLM01 Prompt Injection: https://genai.owasp.org/llmrisk/llm01-prompt-injection/ ; Top-10 PDF: https://owasp.org/www-project-top-10-for-large-language-model-applications/assets/PDF/OWASP-Top-10-for-LLMs-v2025.pdf
- Willison — Lethal trifecta: https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/ ; Rule of Two / Attacker Moves Second: https://simonwillison.net/2025/Nov/2/new-prompt-injection-papers/ ; Design patterns: https://simonwillison.net/2025/Jun/13/prompt-injection-design-patterns/
- Meta — Agents Rule of Two: https://ai.meta.com/blog/practical-ai-agent-security/
- Anthropic — Mitigate jailbreaks/prompt injections: https://platform.claude.com/docs/en/test-and-evaluate/strengthen-guardrails/mitigate-jailbreaks ; Claude Code auto mode: https://www.anthropic.com/engineering/claude-code-auto-mode
- Microsoft MSRC — Defending against indirect injection: https://www.microsoft.com/en-us/msrc/blog/2025/07/how-microsoft-defends-against-indirect-prompt-injection-attacks ; Spotlighting: https://www.microsoft.com/en-us/research/publication/defending-against-indirect-prompt-injection-attacks-with-spotlighting/
- Checkmarx — Markdown injection (Copilot Chat + Gemini): https://checkmarx.com/zero-post/exploiting-markdown-injection-in-ai-agents-microsoft-copilot-chat-and-google-gemini/ (broader list: Embrace The Red)

**Tool safety, risk levels & approval UX**
- Claude Code — Configure permissions: https://code.claude.com/docs/en/permissions
- MCP — Tool annotations as risk vocabulary: https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/
- OWASP — AI Agent Security Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/AI_Agent_Security_Cheat_Sheet.html ; LLM06 Excessive Agency: https://genai.owasp.org/llmrisk/llm062025-excessive-agency/
- OpenClaw security analysis: https://arxiv.org/abs/2603.10387
- Anthropic — Writing effective tools for agents: https://www.anthropic.com/engineering/writing-tools-for-agents
- OpenAI — Function calling: https://developers.openai.com/api/docs/guides/function-calling
- MCP builder best practices: https://github.com/anthropics/skills/blob/main/skills/mcp-builder/reference/mcp_best_practices.md
- Blake Crosley — Approval prompts are not authorization: https://blakecrosley.com/blog/ai-agent-approval-prompts-not-authorization

**Access control & privacy**
- CVE-2026-28480 / GHSA-mj5r-hh7j-4gxf: https://github.com/advisories/GHSA-mj5r-hh7j-4gxf ; advisory: https://github.com/openclaw/openclaw/security/advisories/GHSA-mj5r-hh7j-4gxf
- Telegram Bot API: https://core.telegram.org/bots/api
- OWASP — Logging: https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html ; Secrets Management: .../Secrets_Management_Cheat_Sheet.html ; User Privacy: .../User_Privacy_Protection_Cheat_Sheet.html
- OWASP LLM02 Sensitive Information Disclosure: https://genai.owasp.org/llmrisk/llm022025-sensitive-information-disclosure/ ; LLM07 System Prompt Leakage (for the "not a security control" quote): https://genai.owasp.org/llmrisk/llm072025-system-prompt-leakage/
- IAPP — Data minimization: https://iapp.org/news/a/data-minimization-an-increasingly-global-concept ; NIST Privacy Framework: https://www.nist.gov/document/nist-privacy-framework-version-1-core-pdf
- ICO — Individual rights: https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/individual-rights/individual-rights/
- API rate limiting best practices: https://www.getknit.dev/blog/10-best-practices-for-api-rate-limiting-and-throttling

**Reliability & run-lifecycle**
- AWS — Exponential backoff & jitter: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/ ; Timeouts/retries/backoff: https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/ ; Idempotent APIs: https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/ ; REL04-BP04: https://docs.aws.amazon.com/wellarchitected/latest/framework/rel_prevent_interaction_failure_idempotent.html
- Google SRE — Handling Overload: https://sre.google/sre-book/handling-overload/ ; Cascading Failures: https://sre.google/sre-book/addressing-cascading-failures/
- OpenAI Agents SDK — Running agents: https://openai.github.io/openai-agents-python/running_agents/ ; Rate limits: https://developers.openai.com/api/docs/guides/rate-limits
- SE-0304 Structured Concurrency: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md
- Preventing reasoning loops: https://dev.to/aws/how-to-prevent-ai-agent-reasoning-loops-from-wasting-tokens-2652 ; Graceful shutdown: https://dev.to/axiom_agent/nodejs-graceful-shutdown-the-right-way-sigterm-connection-draining-and-kubernetes-fp8

**Observability, evaluation & cost**
- OpenTelemetry — GenAI observability: https://opentelemetry.io/blog/2026/genai-observability/ ; semconv (maturity): https://github.com/open-telemetry/semantic-conventions-genai
- Confident AI / DeepEval — Agent evaluation: https://www.confident-ai.com/blog/llm-agent-evaluation-complete-guide
- LangChain — Trajectories vs outputs: https://www.langchain.com/resources/llm-evaluation-framework ; Readiness checklist: https://www.langchain.com/blog/agent-evaluation-readiness-checklist
- Anthropic — Multi-agent research system: https://www.anthropic.com/engineering/multi-agent-research-system ; Building effective agents (research): https://www.anthropic.com/research/building-effective-agents
- Cameron Wolfe — LLM-as-a-judge: https://cameronrwolfe.substack.com/p/llm-as-a-judge
- SigNoz — Structured logs: https://signoz.io/blog/structured-logs/ ; Sonar — Audit logging: https://www.sonarsource.com/resources/library/audit-logging/ ; GoLogX (hash-chained audit): https://github.com/AyoubTadlaoui/GoLogX
- OpenObserve — LLM cost monitoring: https://openobserve.ai/blog/llm-cost-monitoring/ ; Traceloop — cost per user: https://www.traceloop.com/blog/from-bills-to-budgets-how-to-track-llm-token-usage-and-cost-per-user

**Swift how-to**
- SE-0306 Actors: https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md ; SE-0414 Region-based Isolation: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md
- Anthropic — Context management (context editing + memory tool): https://claude.com/blog/context-management (redirected from anthropic.com/news/context-management)
- apxml — Managing token budgets: https://apxml.com/courses/getting-started-with-llm-toolkit/chapter-3-context-and-token-management/managing-token-budgets
- Donny Wals — Task timeout: https://www.donnywals.com/implementing-task-timeout-with-swift-concurrency/ ; Actor reentrancy: https://www.donnywals.com/actor-reentrancy-in-swift-explained/ ; Swift 6.2 concurrency: https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/
- Hacking with Swift — Sending data across actor boundaries: https://www.hackingwithswift.com/quick-start/concurrency/sending-data-safely-across-actor-boundaries
- Splinter — State machines with enums: https://www.splinter.com.au/2019/04/10/swift-state-machines-with-enums/
- Telegram Bot API: https://core.telegram.org/bots/api (sendMessage `#sendmessage`, formatting `#formatting-options`, ResponseParameters `#responseparameters`, Update `#update`, sendChatAction `#sendchataction`, sendMessageDraft `#sendmessagedraft`) ; FAQ: https://core.telegram.org/bots/faq ; Changelog: https://core.telegram.org/bots/api-changelog
- OpenClaw issues — truncation #57746: https://github.com/openclaw/openclaw/issues/57746 ; streaming via editMessageText #33220: https://github.com/openclaw/openclaw/issues/33220 ; sendMessageDraft #31061: https://github.com/openclaw/openclaw/issues/31061
- GramIO — rate limits: https://gramio.dev/rate-limits ; Symfony #42697 (MarkdownV2 escaping): https://github.com/symfony/symfony/issues/42697 ; Latenode (message-not-modified): https://community.latenode.com/t/telegram-bot-menu-error-404-on-edit-when-no-changes-made-using-official-api-docs-code/8038 ; aiogram sendChatAction: https://docs.aiogram.dev/en/latest/api/methods/send_chat_action.html
- LY Corp — Swift state machine with concurrency: https://techblog.lycorp.co.jp/en/20250117a
- Microsoft Agent Framework — Tool approval (HITL): https://learn.microsoft.com/en-us/agent-framework/agents/tools/tool-approval
- NVIDIA — Sandboxing agentic workflows: https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/
- OWASP Agentic Top 10 (third-party summary): https://nhimg.org/complete-guide-to-the-2026-owasp-top-10-risks-for-agentic-applications
- WorkOS — Audit logs / SIEM: https://workos.com/blog/the-developers-guide-to-audit-logs-siem
- SQLite — UPSERT: https://sqlite.org/lang_upsert.html ; ON CONFLICT: https://sqlite.org/lang_conflict.html
- OpenAI Agents SDK — Human in the loop: https://openai.github.io/openai-agents-js/guides/human-in-the-loop/ ; Gunnar Morling — Idempotency keys: https://www.morling.dev/blog/on-idempotency-keys/
