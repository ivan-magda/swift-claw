# Persistent Personal Agents: What Users Actually Do, and the Stress Tests That Follow

*Prepared 2026-07-14 as design input for a swift-claw end-to-end stress-test suite — "is this reliable and useful enough to be a daily personal assistant?" Follows the earlier landscape report (`persistent-agents-openclaw-hermes.md`). Inspiration only — clean-room; no code was copied. Method: multi-angle web research (5 search angles, 22 sources fetched, 109 claims extracted), with the top 25 claims each put through 3-vote adversarial verification: 12 confirmed, 13 refuted, 0 unverified; synthesized by a separate pass. Angles targeted: primary project evidence, practitioner behavior reports, failure modes and abandonment, usage telemetry cross-check, agent eval methodology. This is a point-in-time research snapshot.*

---

## TL;DR

**The question's premise does not survive verification.** It asked for the ten most common real-world use cases of persistent personal agents grounded in actual user behavior. No such telemetry exists — not for Hermes, not for OpenClaw, not for any always-on personal agent. Thirteen of twenty-five claims were killed, including most of the ones a suite designer would instinctively reach for.

- **What we have instead is two things, neither of which is what was asked.** (a) Consumer *chatbot* telemetry — OpenAI's ~1.1M ChatGPT conversations (consumer plans only) and Anthropic's ~4.5M Claude.ai conversations. A different product category from a Telegram-resident always-on agent; Anthropic's own limitations section disclaims the generalization. (b) Hermes's shipped feature surface and source code — evidence of what the vendor *built*, not what users *do*. Every use-case weighting below rests on an unvalidated transfer, and should be read as a prior for allocating test budget rather than a target.
- **OpenClaw contributed zero surviving claims** despite being named in the question. The agent-behavior evidence is Hermes-only.
- **The unit of analysis is wrong in a way no amount of sourcing fixes.** Every percentage here is a population mean over millions of users; swift-claw serves one owner. A 2.9% affective share says nothing about any individual owner's mix.
- **Scheduled/unattended execution is the best-evidenced workload** — four schedule formats, a 60s tick, fresh isolated sessions with no conversation history, and `[SILENT]` delivery suppression whose implementation is stricter than its documentation.
- **Cross-session memory has a load-bearing constraint:** the system prompt is captured once at session start and never changes mid-session. Session-A-write / session-B-recall is the *only* valid shape for a prompt-level memory test.
- **Two non-obvious axes must be swept, not fixed:** compositional depth (success collapses past small depth, so a short-task-only suite certifies reliability while hiding the cliff) and recovery-after-early-mistake (early planning errors are path-dependent and rarely self-correct).
- **Six scenario families, not ten archetypes.** Each parameterized by horizon depth and injected-early-error. Padding to ten would require re-importing refuted material.

---

## Verified findings

### 1. Unattended scheduled execution is the best-evidenced workload — and it needs an NL-parsing test, not just a cron-syntax API test

Hermes exposes scheduled/recurring execution through three creation paths (chat `/cron`, standalone `hermes cron create`, and plain natural language — "Every morning at 9am, check Hacker News... send me a summary on Telegram"), all routed through a unified `cronjob` tool. Four schedule formats are accepted: relative delays (`30m`/`2h`/`1d`, one-shot), intervals (`every 30m`, recurring), 5-field cron (`0 9 * * *`, including ranges `1-5` and steps `*/6`), and ISO timestamps (one-shot). This is shipped rather than aspirational: `cron/scheduler.py` carries a 60s `tick()`, a `~/.hermes/cron/.tick.lock` preventing overlapping ticks, thread pools separating parallel from sequential workdir jobs, atexit shutdown hooks, and platform auth/rate-limit/timeout handling.

One verifier caveat sharpens the test design rather than undercutting it: DeepWiki's code-derived page states `parse_schedule` is pattern-based with no LLM conversion. That *relocates* the natural-language step rather than removing it — the agent's LLM must still emit a parseable string — so the end-to-end NL path remains a real surface with real failure modes. Separately, `slash-commands.md` files `/cron` under "Interactive CLI", so the first two entry points may both be CLI-resident (REPL vs standalone) rather than "chat" in the Telegram sense; swift-claw, being Telegram-only, inherits the NL path plus possibly a bot-command path, not a REPL. *(3-0 ×3, merged; https://hermes-agent.nousresearch.com/docs/user-guide/features/cron, https://hermes-agent.nousresearch.com/docs/user-guide/features/overview, https://github.com/NousResearch/hermes-agent, https://deepwiki.com/NousResearch/hermes-agent/10.3)*

### 2. Scheduled jobs run in fresh isolated sessions — the prompt must carry its own context

Canonical docs, verbatim: "The gateway ticks the scheduler every 60 seconds, running any due jobs in isolated agent sessions"; "Cron runs each job in a fresh agent session with no chat platform attached"; "The prompt must contain everything the agent needs that is not already provided by attached skills." The developer guide adds that each run creates a fresh session with no conversation history, has no memory of previous cron executions unless persisted, cannot ask clarifying questions, and that cron deliveries are not mirrored into gateway session history.

A verifier attempted refutation via `_open_continuable_cron_thread()` / `_seed_cron_thread_session()` and traced it to ground: opt-in (default off, per-job `attach_to_session`) and delivery-side only — it does not inject conversation context into execution.

One qualification must travel with this finding: "fully self-contained" overstates the docs. Hermes documents four sanctioned non-conversational injection paths — attached skills, `context_from` (which prepends prior *job* outputs, and is the sanctioned cross-run state chain), pre-run scripts returning `{"wakeAgent": true, "context": {...}}`, and `AGENTS.md`/`CLAUDE.md` injection when `workdir` is set. Also load-bearing for swift-claw: Hermes disables cron-management tools *inside* cron executions, specifically to prevent runaway recursive scheduling. *(3-0; https://hermes-agent.nousresearch.com/docs/user-guide/features/cron, https://hermes-agent.nousresearch.com/docs/developer-guide/cron-internals, https://github.com/NousResearch/hermes-agent)*

### 3. Silence suppression: the implementation is stricter than the documentation, and failures always deliver

Docs state that if the agent's final response "contains `[SILENT]`", delivery is suppressed entirely; no-agent mode documents the watchdog pattern explicitly — "Empty stdout → silent tick, no delivery... only say something when something is wrong."

Two qualifications change the test design, and both were found by reading the code rather than the docs. First, "contains" is looser than `_is_cron_silence_response()`, which recognizes `[SILENT]`, `SILENT`, `NO_REPLY`, and `NO REPLY` (case-insensitive, whitespace-normalized) only as a whole-response equality, as the marker alone on the first or last line, or via `upper.startswith("[SILENT]")`. A mid-sentence marker is **not** suppressed. Second: "Failed jobs always deliver regardless of the `[SILENT]` marker — only successful runs can be silenced" — failures route through `_summarize_cron_failure_for_delivery()`, bypassing suppression entirely. This narrows the mechanism while strengthening the notification-fatigue argument behind it. Test isolated-marker semantics, not substring containment. *(3-0; https://github.com/NousResearch/hermes-agent, https://hermes-agent.nousresearch.com/docs/user-guide/features/cron)*

### 4. Cross-session memory: the system prompt is captured once at session start, which fixes the only valid test shape

Verbatim: "Bounded, curated memory that persists across sessions. Hermes remembers your preferences, projects, environment, and things it has learned via `MEMORY.md` and `USER.md`." The specifics are falsifiable in a way no marketing page would risk: files under `~/.hermes/memories/`; `MEMORY.md` capped at ~2,200 chars (~800 tokens), `USER.md` at ~1,375 chars (~500 tokens); a built-in `memory` tool with add/replace/remove; and on overflow, "the memory tool returns an error instead of silently dropping entries." That this is a first-class surface rather than an add-on is confirmed architecturally: the two-file layer is built in, while eight external providers (Mem0, Honcho, Supermemory, …) are filed separately under Integrations.

The load-bearing constraint: "The system prompt injection is captured once at session start and never changes mid-session"; mid-session writes "are persisted to disk immediately but won't appear in the system prompt until the next session starts." Same-session prompt-level recall is impossible by design, which makes session-A-write / session-B-recall the only valid shape for a prompt-level memory test.

The contradiction hunt backfired into support. Real criticism exists — agents failing to flag facts worth persisting, nuance lost at the char cap, FTS5 keyword search missing synonyms ("auth service" vs "authentication microservice"), and one user reporting "It has no memory AT ALL." None of it refutes existence; all of it is evidence that agent-curation judgment is unreliable, which is an argument *for* the tests. The FTS5 synonym gap is directly relevant, since swift-claw's own recall path is FTS5/BM25 (`3a-recall-fts5-bm25.report.*`). *(3-0; https://hermes-agent.nousresearch.com/docs/user-guide/features/memory, https://hermes-agent.nousresearch.com/docs/user-guide/features/overview, https://github.com/NousResearch/hermes-agent)*

### 5. Horizon depth must be a swept variable, or the suite will certify reliability and hide the cliff

HORIZON (arXiv:2604.11978v1, 2026-04-13; 3,100+ trajectories, 4 domains, GPT-5 variants + Claude-4-Sonnet) states verbatim: "all domains exhibit a sharp performance drop beyond small s, where success transitions abruptly from partial robustness to near-systematic failure" and "Performance degrades non-linearly with increasing s." Corroborated directionally by Sinha et al. ("short-task benchmarks may give an illusion of slowing progress") and METR (task length vs success, R²=0.83 — horizon is the dominant explanatory variable).

Confidence is capped at medium for three stated reasons. *s* is compositional depth (nested sub-goals, conditional branches), not wall-clock horizon — conflating the two is a mild error. The domains are Web/OS/Embodied/DB agents, not personal-assistant workloads, so transfer to swift-claw is reasonable but unvalidated. And the best counter-argument attacks the *cliff framing* specifically: METR fits a smooth logistic in log(task time) and Sinha attributes decay to compounding per-step error plus self-conditioning — both of which render as "stable, then sharp drop" on a linear *s* axis. The cliff may be an axis artifact rather than a phase transition. The testing prescription survives either reading: sweep *s* ∈ {1, 2, 4, 8} sub-goals and report the curve, not a pass/fail. *(3-0, medium; https://arxiv.org/html/2604.11978v1, https://arxiv.org/abs/2509.09677, https://metr.org/time-horizons)*

### 6. Measure recovery-after-early-mistake as a metric separate from end-state success

HORIZON, §5: "Planning-related failures are particularly critical because they often arise early, propagate through downstream actions, and can convert recoverable local mistakes into irreversible trajectory-level failures" — and elsewhere calls early mistakes "highly path-dependent and costly to roll back." Three independent corroborations: AgentDebug (2509.25370) defines the critical error as "the earliest critical error that directly causes the final failure... the root cause that truly determines whether the overall trajectory succeeds or fails" and operationalizes it via counterfactual testing; 2601.22311 finds policies "deviate from optimal trajectories within the first few decisions and rarely recover thereafter"; PIVOT (2605.11225) finds "monotonic acceptance criteria cannot guarantee recovery from severely flawed initial trajectories."

The split vote (2-1) and medium confidence are earned, and the reason is worth recording: the prescriptive half is an inference *not* in the cited quote. HORIZON is a diagnostic taxonomy that does not evaluate recovery at all, gesturing at "execution-time plan verification and repair" only as future work. The prescription rests on AgentDebug instead — which is also the best template to copy, since it already implements it. Soften "irreversible" to "frequently unrecoverable without explicit repair mechanisms," given demonstrated recovery under scaffolding. *(2-1, medium; https://arxiv.org/html/2604.11978v1, https://arxiv.org/abs/2509.25370, https://arxiv.org/abs/2601.22311, https://arxiv.org/abs/2605.11225)*

### 7. τ²-bench's four-part domain contract is a directly reusable skeleton

Verbatim from the Sierra Research repo: "Each domain specifies: A **policy** that the agent must follow; a set of **tools** that the agent can use; a set of **tasks** to evaluate the agent's performance; Optionally: a set of **user tools** for the user simulator." Shipped domains: mock, airline, retail, telecom, banking_knowledge.

Refutation attempts all failed. The naming nit (τ-bench vs τ²-bench) is cosmetic — the repo self-titles "τ-Bench", though the four-part contract including user tools is τ²-era. The known critique fork (amazon-agi/tau2-bench-verified) states it "differs from the original tau2-bench only in the dataset... the evaluation framework, orchestrator, domains, and all other code remain identical," which corroborates the skeleton while fixing task instances. The domain-coupling objection (customer service vs single-owner assistant) does not bite, because only the structure transfers.

Honest caveat: the reusability half is a design inference, not a source finding — but a low-risk one. Note that the related "dual-control" claim was refuted 0-3, so do **not** build the suite around a simulated owner editing shared state out-of-band. Per swift-claw scenario: declare the policy (what the agent must and must not do), the tool surface exposed, the task, and a scripted owner with fixed replies. *(3-0; https://github.com/sierra-research/tau2-bench, https://arxiv.org/abs/2506.07982)*

### 8. Weight toward transform-my-text over from-scratch authoring — but the Asking/Doing split is contested by its own source

Verified verbatim from the PDF text layer (extracted locally; WebFetch could not read it): "about 49% of messages are Asking, 40% are Doing, and 11% are Expressing," with the authors' glosses — Asking is "seeking information or advice that will help the user be better informed or make better decisions"; Doing means the user "wants to produce some output or perform a particular task." The trend runs toward Asking ("Asking is growing faster than Doing", and is rated higher quality).

The Writing finding is stated three times as a headline result, including among the conclusion's eight facts: three of the five Writing categories (Editing or Critiquing Provided Text, Translation, Argument or Summary Generation) "are requests to modify text that has been provided to ChatGPT by the user... The former constitute two thirds of all Writing conversations." Writing is 23.9% of all messages and ~40% of work-related — material either way.

Three caveats must travel. **Scope:** consumer plans only ("Our sample includes the three consumer plans (Free, Plus, or Pro)") — this is chatbot usage, and the paper does not license transfer to Hermes/OpenClaw/swift-claw. **Work inversion:** "Doing constitutes nearly 56% of work-related queries, compared to 35% for Asking" — for an always-on task-executing assistant this is arguably the more relevant split, and it points the opposite way. **Method:** intent labels are LLM-classifier-assigned and never human-adjudicated by design, so the 49-vs-40 gap is classifier-sensitive. Data ends June 2025. The broader topic-share claims from the same paper were refuted 0-3 and must not be used. *(2-1 on the split, 3-0 on Writing, medium; https://cdn.openai.com/pdf/a253471f-8260-40c6-a2cc-aa93fe9f142e/economic-research-chatgpt-usage-paper.pdf, NBER w34255)*

### 9. Companionship is a rounding error — de-prioritize, but do not exclude

Exact numbers verified against the primary source (2025-06-27): "Only 2.9% of Claude.ai interactions are affective conversations", from ~4.5M conversations sampled, 131,484 affective in the final privacy-preserving Clio analysis. The claim understates its own case: companionship and roleplay together are <0.5% of conversations, romantic/sexual roleplay <0.1%. Refutation attempts failed — the one substantive critique found (Jared Moore, Stanford) attacks the study's *therapeutic-response* analysis, not the prevalence measurement. The real soft spot is 84.3% human-Claude rater agreement on affective classification, the lowest of any category, but that margin fuzziness cannot move 2.9% to dominance.

Three qualifications. **Population mismatch:** the denominator is Claude.ai Free/Pro consumer chat; Anthropic's limitations section says results "may not generalize to platforms specifically designed for affective use" and represent "a specific moment in time." **Wrong unit of analysis:** 2.9% is a share of *interactions* across a large population, but swift-claw serves one owner — and a small interaction share can still mean a meaningful share of *users*. **Age:** ~12.5 months. Because the stronger sibling claim ("therefore low-value stress tests") was refuted 0-3, state this as de-prioritization, not exclusion: allocate at most a token scenario and spend the budget on scheduling, memory, and transform-text. *(2-1, medium; https://www.anthropic.com/news/how-people-use-claude-for-support-advice-and-companionship)*

### 10. The evidence supports six scenario families, not ten use cases

Thirteen claims were voted down, and several are exactly what a suite designer would reach for (full ledger below). The two that tried to characterize canonical real-world cron usage from vendor docs were both refuted for a reason worth internalizing: **illustrative examples in vendor documentation are not evidence of user behavior** — which is the precise trap the original question was trying to avoid. What survives are six families: scheduled/recurring jobs, cross-session memory, notification suppression, decision-support Q&A, transform-user-supplied-text, and tool-using execution under a declared policy. Six families swept across two axes is both more honest and more discriminating than ten flat archetypes. *(derived from the refutation ledger)*

---

## The proposed suite

Six families, each parameterized by horizon depth *s* ∈ {1, 2, 4, 8} sub-goals and by injected-early-error. Score recovery-from-injected-error separately from end-state success; report the depth curve rather than a pass/fail.

### F1 — Scheduled and recurring jobs

- NL → schedule round-trip across all four formats, including ambiguous phrasing ("every weekday morning", "in a bit").
- Cron-expression parsing: the richest and highest-risk surface (ranges, steps).
- One-shot vs recurring default semantics: relative and ISO default to one-shot; interval and cron repeat indefinitely until removed.
- Timing assertions must tolerate the 60s tick granularity floor.
- A scheduled job must not be able to fan out unbounded further jobs.

### F2 — Isolated-session self-containment

- A job whose prompt references "the thing we discussed" must fail cleanly rather than hallucinate context.
- Cross-run state chaining (`context_from`-style): run N's output correctly feeds run N+1.

### F3 — Watchdog quietness

- Healthy monitoring run emits the marker → zero Telegram messages.
- Failing run emits the marker → message delivered anyway.
- Marker mid-sentence → message delivered (no accidental silence).

### F4 — Cross-session memory

- Write a fact in session A, recall it in session B.
- Supersede a preference in session B, then assert correct *non-recall* of the stale fact in session C.
- Overflow at the char cap → explicit error, never a silent drop.
- Synonym retrieval against swift-claw's own FTS5 index — a known weak spot in the analogous system.

### F5 — Transform user-supplied text

- Feed a supplied document to edit, critique, summarize, and translate — not "write me a post."

### F6 — Tool-using execution under a declared policy

- τ²-style: declare the policy, the exposed tool surface, the task, and a scripted owner with fixed replies.
- Do **not** center this on the owner editing shared state out-of-band (the dual-control claim was refuted 0-3).

---

## Refuted

Thirteen claims died under 3-vote adversarial verification. Recorded here because several are attractive enough to be reinvented later.

| Claim | Vote | Source |
|---|---|---|
| Vendor cron docs establish canonical use cases (infra monitoring / feed summarization / reminders) | 1-2 | hermes-agent docs |
| Scheduled digest/monitoring is a first-class *real-world* pattern (sibling of the above) | 0-3 | hermesagent.org.cn (mirror) |
| Hermes's tool surface (web search + terminal + file editing + memory) bounds the use-case space | 0-3 | hermes-agent docs |
| Long-horizon failures split 72.5% process-level vs 27.5% design-level | 1-2 | arXiv:2604.11978v1 |
| Practical Guidance + Seeking Information + Writing = 77-80% of conversations | 0-3 | OpenAI usage paper |
| Non-work usage grew from 53% to >70% of messages | 0-3 | OpenAI usage paper |
| Coding is the plurality workload at 15-25% of conversations | 0-3 | arXiv:2412.13678v1 |
| No single non-coding category dominates; need breadth across a long tail | 0-3 | arXiv:2412.13678v1 |
| The Clio methodology self-endorsement ("strongest available evidence base") | 0-3 | arXiv:2412.13678v1 |
| Companionship/roleplay <0.5% ⇒ such flows are low-value stress tests | 0-3 | Anthropic affective-use study |
| τ²-bench's core contribution is "dual-control" shared state | 0-3 | sierra-research/tau2-bench |
| Failure to *forget* superseded info is dominant (64% of recommendation errors) | 0-3 | arXiv:2604.20006v1 |
| Memory accuracy degrades 51.84 (weekly) → 25.05 (quarterly) | 0-3 | arXiv:2604.20006v1 |

The last two are a genuine loss. Preference-mutation and multi-horizon memory testing remain good design ideas — and F4's supersession test is independently motivated by Hermes's own `replace`/`remove` tool — but the quantitative backing did not survive and must not be cited.

---

## Caveats

**Scope mismatch is the dominant weakness.** The question asked for use cases grounded in actual user behavior of *persistent agents*. No such telemetry survived. What exists is consumer chatbot telemetry (a different product category, with the vendor's own generalization disclaimer) and Hermes's shipped feature surface (evidence of what was built, not what is used). Every weighting rests on an unvalidated transfer.

**Single-owner unit-of-analysis problem.** Every percentage here is a population mean over millions of users; swift-claw serves one owner. Treat these as priors for allocating test budget, not as targets.

**OpenClaw is absent.** Despite being named in the question, not one surviving claim cites it. Any inference that OpenClaw users behave like Hermes users is unsupported here.

**The Asking/Doing evidence contradicts itself.** The same paper yields 49% Asking overall but 56% Doing for work-related messages. For an always-on task-executing agent the work-related split is arguably more relevant. "Decision support is the plurality" is not settled for swift-claw's workload.

**Time sensitivity.** OpenAI data ends June 2025 (~13 months stale); the Anthropic study is ~12.5 months old. HORIZON is an unrefereed v1 preprint ~3 months old, and the cliff shape rests on it alone. Hermes docs and code are current on main but a fast-moving target — verify against main before implementing.

**Softenings to carry.** "Irreversible" (finding 6) should read "frequently unrecoverable without explicit repair mechanisms." "Fully self-contained" (finding 2) overstates the docs — attached skills, `context_from`, pre-run scripts, and `AGENTS.md` injection are sanctioned context paths. "Contains `[SILENT]`" is looser than the implementation, which requires an isolated marker. The τ-bench/τ²-bench naming is imprecise.

**Source-attribution defect.** Two claims cited `hermesagent.org.cn` as primary; it is an unofficial mirror. Upstream NousResearch docs and source corroborate verbatim in both cases — fixable attribution, not a factual problem, but cite upstream.

**Split votes (2-1)** on the Asking/Doing split, the recovery prescription, and the affective-prevalence transfer. All three were downgraded to medium, and all three fail on the same axis: the descriptive fact is solid, the design inference outruns the source.

---

## Open questions

1. **What do persistent-agent users actually do day-to-day?** No telemetry for Hermes, OpenClaw, or any always-on Telegram agent survived verification, so the entire use-case weighting rests on transferring consumer-chatbot statistics to a different product category. Instrumenting swift-claw itself — even N=1, even just the author — would produce the behavioral data this field is currently guessing at.
2. **Which side of the Asking/Doing contradiction governs swift-claw?** Consumer usage is 49% Asking; work-related is 56% Doing. An always-on agent with tool access may look far more like the work distribution — or may be dominated by scheduled unattended jobs that fit neither bucket. Getting this wrong misallocates the whole suite.
3. **Is the compositional-depth cliff a real phase transition or a linear-axis artifact** of smooth exponential decay (METR/Sinha)? This decides whether swift-claw sweeps *s* to find a threshold and hard-caps task depth below it, or simply reports a smooth degradation curve with no special cutoff.
4. **Is there sound replacement evidence** for preference-mutation failure rates and multi-month memory decay — or should swift-claw measure these itself, as the suite's original contribution rather than someone else's citation?
5. **Does the 60s-tick + isolated-session + `[SILENT]` architecture actually reduce notification-fatigue abandonment,** or is that a plausible-sounding vendor rationale? The mitigation is verified as shipped code; its efficacy against the abandonment it supposedly addresses is unmeasured in every source here.

---

## Sources

Primary (Hermes):
- https://hermes-agent.nousresearch.com/docs/user-guide/features/cron
- https://hermes-agent.nousresearch.com/docs/user-guide/features/overview
- https://hermes-agent.nousresearch.com/docs/user-guide/features/memory
- https://hermes-agent.nousresearch.com/docs/developer-guide/cron-internals
- https://github.com/NousResearch/hermes-agent (`cron/scheduler.py`, `website/docs/**`)
- https://deepwiki.com/NousResearch/hermes-agent/10.3 (code-derived, secondary)

Primary (usage telemetry):
- https://cdn.openai.com/pdf/a253471f-8260-40c6-a2cc-aa93fe9f142e/economic-research-chatgpt-usage-paper.pdf — NBER w34255, "How People Use ChatGPT", 2025-09-15
- https://www.anthropic.com/news/how-people-use-claude-for-support-advice-and-companionship — 2025-06-27
- https://arxiv.org/html/2412.13678v1 — Clio (all extracted claims refuted 0-3; listed for the record)

Primary (eval methodology / long-horizon):
- https://github.com/sierra-research/tau2-bench, https://arxiv.org/abs/2506.07982
- https://github.com/amazon-agi/tau2-bench-verified
- https://arxiv.org/html/2604.11978v1 — HORIZON (unrefereed v1)
- https://arxiv.org/abs/2509.25370 — AgentDebug
- https://arxiv.org/abs/2601.22311, https://arxiv.org/abs/2605.11225 — PIVOT
- https://arxiv.org/abs/2509.09677 — Sinha et al.
- https://metr.org/time-horizons
- https://arxiv.org/html/2604.20006v1 — personalized memory (both extracted claims refuted 0-3)

Practitioner / secondary:
- https://velvetshark.com/50-days-with-openclaw
- https://github.com/openclaw/openclaw/issues/64983
- https://github.com/VoltAgent/awesome-openclaw-skills
- https://news.ycombinator.com/item?id=47147183
