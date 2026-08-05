# Model fallback: how OpenClaw and Hermes do it

**Read on 2026-08-05**, from source rather than docs.

- OpenClaw at `5b03ce77f5148a8d2b44a35a1123e111ba640c62`
- Hermes at `226e8de827a669e8ffa7035b27d70c19e44b1208`

Line references are to those commits. This is a reference study behind
[#75](https://github.com/ivan-magda/swift-claw/issues/75); it records what those two projects do,
not what swift-claw should do.

## 1. Both converged on the same shape

Neither project routes. Both keep an ordered list of candidates and walk it on failure.

| | Hermes | OpenClaw |
|---|---|---|
| Chain shape | ordered list, no weights or priorities | ordered list, no weights or priorities |
| Entry may change provider, base URL, API key | yes | yes |
| Typed error taxonomy drives it | `FailoverReason`, 23 members | `FailoverReason`, 9 members |
| Cost input to ordering | none | none |
| Spend cap on the fallback | none | none |
| Capability gating before switching | none | partial |
| Mid-stream splice | no | no |
| Return to primary | turn-scoped restore + cooldown | per-auth-profile cooldown + half-open probe |
| Owner told | yes, once per transition | yes, but verbose-gated |

The agreement is more interesting than the differences. Two independent codebases, one with a
credential-pool layer and one without, landed on: classify into a typed reason, decide retry versus
switch from that reason, walk an ordered list, arm a cooldown when leaving the primary, restore it
later.

## 2. Trigger classification

### Hermes

`agent/error_classifier.py` is a single centralized classifier, 1599 lines. `FailoverReason`
(`:24-73`) has 23 members. The classifier returns **four orthogonal hints**, not one verdict
(`:76-97`):

```python
@dataclass
class ClassifiedError:
    reason: FailoverReason
    status_code: Optional[int] = None
    retryable: bool = True
    should_compress: bool = False
    should_rotate_credential: bool = False
    should_fallback: bool = False
```

That separation is the design's load-bearing idea. A 429 can be retryable *and* fallback-eligible;
the loop decides which lever to pull first. A 400 can be non-retryable and still fallback-eligible.

The pipeline order (`:515-850`) puts provider-specific special cases **before** status
classification, so a 400 that is really a safety block is not downgraded to `format_error`.
Ambiguous wording gets disambiguated by pattern: `_USAGE_LIMIT_PATTERNS` plus
`_USAGE_LIMIT_TRANSIENT_SIGNALS` (`:173-186`) read "try again" / "resets at" / "window" as transient
`rate_limit`, and everything else as `billing`. The classifier also unwraps nested provider errors,
digging the real message out of OpenRouter's `metadata.raw` envelope (`:558-594`).

Deliberately **not** fallback-triggering: `context_overflow`, `payload_too_large`,
`long_context_tier`, `thinking_signature`, `image_too_large`, `multimodal_tool_content_unsupported`,
`llama_cpp_grammar_pattern`, `invalid_encrypted_content`, `provider_policy_blocked`,
`ssl_cert_verification`.

Two classifications are worth stealing outright. A 404 carrying a billing phrase becomes `billing`,
because Nous surfaces credit depletion as a 404. A generic 404 stays `unknown` and retryable rather
than `model_not_found`, so a misconfigured local llama.cpp URL does not trigger a wrong failover.

### OpenClaw

`src/agents/pi-embedded-helpers/types.ts:3`:

```ts
export type FailoverReason =
  | "auth" | "auth_permanent" | "format" | "rate_limit"
  | "billing" | "timeout" | "model_not_found" | "session_expired" | "unknown";
```

Status mapping in `errors.ts:254-294`; message mapping in `classifyFailoverReason` (`errors.ts:825-867`)
is an ordered cascade where the order is load-bearing. Image-dimension and image-size errors are
checked first and return `null`, so they never reach fallback.

**OpenClaw does not treat subscription exhaustion as its own class.** `"usage limit"`,
`"quota exceeded"`, `"exceeded your current quota"`, `"resource has been exhausted"` all land in the
`rateLimit` bucket (`failover-matches.ts:4-14`), so an exhausted Claude or Codex plan is handled as
transient throttling with a 1m/5m/25m/1h cooldown. The persistent split is drawn elsewhere:
`billing` and `auth_permanent` get a "disabled" window (5h doubling to a 24h cap,
`auth-profiles/usage.ts:413-427`) and short-circuit the whole provider:

```ts
// model-fallback.ts:412-428
const isPersistentIssue =
  inferredReason === "auth" || inferredReason === "auth_permanent" || inferredReason === "billing";
if (isPersistentIssue) {
  return { type: "skip", reason: inferredReason,
    error: `Provider ${candidate.provider} has ${inferredReason} issue (skipping all models)` };
}
```

Neither project reads `Retry-After` or `x-ratelimit-*` on the LLM path in OpenClaw's case; Hermes
does read `Retry-After` and caps it at 600s, with a comment naming the reason (`conversation_loop.py:4149-4165`):

> Cap at 10 minutes. Anthropic Tier 1 input-token buckets reset in ~171s, so a 120s cap caused us to
> retry before the actual reset window.

OpenClaw *does* fetch subscription usage windows with `resetAt` timestamps
(`infra/provider-usage.types.ts:1-5`) but consumes them only in `/status` and the session-status
tool. They never reach the router.

## 3. Retry versus fallback

Hermes decides eagerness from the reason (`conversation_loop.py:3171-3244`):

```python
is_rate_limited = classified.reason in {
    FailoverReason.rate_limit, FailoverReason.billing, FailoverReason.upstream_rate_limit,
}
_is_transport_failure = classified.reason in {FailoverReason.timeout, FailoverReason.overloaded}
_should_fallback = (
    is_rate_limited
    or (_is_transport_failure and retry_count >= 2)
)
```

Rate-limit and billing switch immediately. Timeout and overload retry twice first. Auth gets a
one-shot failover gated by `_retry.auth_failover_attempted` (`:3247-3273`).

Fallback also sits *below* credential rotation: a rate limit tries other keys in the pool first,
unless rotation cannot help (`conversation_loop.py:3204-3215`):

```python
def _pool_may_recover_from_rate_limit(pool) -> bool:
    if pool is None: return False
    if not pool.has_available(): return False
    return len(pool.entries()) > 1
```

Backoff is exponential with 50% jitter, seeded from `time_ns ^ counter` under a lock so concurrent
sessions decorrelate (`retry_utils.py:37-76`). There is **no overall turn deadline**; the bound is
`max_retries` per entry times chain length, and a successful activation resets `retry_count` to 0.

Hermes's own config comment tells fallback users to turn retries down
(`cli-config.yaml.example:703-708`):

> Lower this to 1 if you use fallback providers and want fast failover on flaky primaries (default 3).

OpenClaw has **no delay between candidates at all**. `runWithModelFallback` (`model-fallback.ts:475-574`)
has no sleep, no jitter, no deadline, and makes one attempt per candidate with a dedupe `Set`. Its
backoff lives entirely in the persisted per-auth-profile cooldown (`auth-profiles/usage.ts:269-275`):

```ts
export function calculateAuthProfileCooldownMs(errorCount: number): number {
  const normalized = Math.max(1, errorCount);
  return Math.min(60 * 60 * 1000, 60 * 1000 * 5 ** Math.min(normalized - 1, 3));
}
// 1 min, 5 min, 25 min, 1 h (cap). No jitter.
```

Its inner loop is bounded by a scaled iteration count (`run.ts:121-131`): `24 + profileCount * 8`,
clamped to `[32, 160]`, and exceeding it returns a terminal reply rather than looping.

## 4. Returning to the primary

Hermes restores the primary at the top of **every** turn (`agent_runtime_helpers.py:1138-1330`,
called from `turn_context.py:174`), restoring model, provider, base URL, API mode, client and
compressor limits, and resetting `_fallback_index`. One line gates it:

```python
if getattr(agent, "_rate_limited_until", 0) > time.monotonic():
    return False  # primary still in rate-limit cooldown, stay on fallback
```

The cooldown is 60s when leaving the primary on a rate limit, and
`_FALLBACK_EXHAUSTED_COOLDOWN_S = 5.0` when the chain exhausts on anything else. The second constant
was a fix for a cross-turn replay storm, where every turn re-marshaled an 80k-token context across
every provider (`chat_completion_helpers.py:1351-1367`).

OpenClaw persists health per auth profile in
`~/.openclaw/agents/<agentId>/agent/auth-profiles.json`, and calls the expiry path a circuit breaker
in as many words. `clearExpiredCooldowns` (`usage.ts:180-231`) clears expired windows *and* resets
`errorCount`, described as "half-open → closed" and credited with fixing profiles that appeared
stuck. Active windows are immutable: `keepActiveWindowOrRecompute` (`usage.ts:378-387`) stops retries
inside a window from extending recovery.

Its half-open probe is explicit (`model-fallback.ts:337-371`):

```ts
const MIN_PROBE_INTERVAL_MS = 30_000;      // per (agentDir, provider)
const PROBE_MARGIN_MS = 2 * 60 * 1000;     // probe when within 2 min of cooldown expiry
```

Profile ordering is round-robin, and `lastGood` is deliberately not prioritized: "that would defeat
round-robin" (`auth-profiles/order.ts:152`).

Neither project keeps per-model or per-provider health scores. OpenClaw's health state is per
*auth profile* only; a model with no auth profiles is never marked unhealthy. Hermes's only memo is
`_unavailable_fallback_keys`, a session-scoped set of entries whose client failed to construct.

## 5. Mid-stream failure

Neither project splices a fallback into a half-streamed turn.

Hermes keeps what was delivered. A stream that dies after emitting text turns that text into the
final response and shows `"↻ Stream interrupted — using delivered content as final response"`
(`conversation_loop.py:4854-4881`). A partial-stream stub is *continued on the same model* with a
system nudge (`:446-451`):

> [System: The previous response was cut off by a network error mid-stream. Continue exactly where
> you left off. Do not restart or repeat prior text. Finish the answer directly.]

The single exception is content-filter termination, which does switch providers and rolls partial
content back to the last clean assistant turn first (`:1866-1900`), so the new provider gets a
coherent continuation point.

OpenClaw restarts the whole turn on the next candidate with the same prompt and session file
(`run.ts:1235-1300`). Already-sent text is not retracted; the block-reply pipeline dedupes by payload
key so identical re-emitted blocks are suppressed (`block-reply-pipeline.ts:82-242`), and messaging
tool sends are deduped by normalized substring match (`messaging-dedupe.ts:19-46`). The failed
attempt is written into the transcript as a custom entry so the next model can see what happened
(`run/attempt.ts:1757-1768`).

OpenClaw's CLI path also rewrites the prompt on any fallback retry and drops images
(`commands/agent.ts:130-135`):

```ts
return "Continue where you left off. The previous model attempt failed or timed out.";
```

The chat path does not; it re-sends the body verbatim.

History rewriting on a model switch is substantial in OpenClaw and absent in Hermes.
`sanitizeSessionHistory` (`google.ts:410-492`) detects `modelChanged` and applies a per-provider
`TranscriptPolicy` (`transcript-policy.ts:78-135`): tool-call-ID re-encoding, thought-signature
stripping, thinking-block dropping, turn-ordering fixes, orphaned `tool_use`/`tool_result` repair.
`repairToolUseResultPairing` is forced on universally because "OpenAI rejects function_call_output
items whose call_id has no matching function_call".

## 6. Capability compatibility

This is Hermes's weakest area and OpenClaw's partial win.

Hermes adjusts a lot **at activation**: wire protocol re-derived per entry
(`codex_responses` / `anthropic_messages` / `bedrock_converse` / `chat_completions`), model slug
normalized, credential pool rebound to the new provider, prompt self-identity rewritten, and the
context compressor re-pointed at the fallback's real window
(`chat_completion_helpers.py:1499-1505`):

> Without this, compression decisions use the primary model's context window (e.g. 200K) instead of
> the fallback's (e.g. 32K), causing oversized sessions to overflow the fallback.

What it does **not** do: consult capability metadata before selecting. `ModelCapabilities` with
`supports_tools` and `supports_vision` exists (`models_dev.py:405-406, 458-503`) and is used by the
model picker and image routing, but `try_activate_fallback` never reads it. A model with no tool
support is activated blind. All adaptation is reactive, after the fallback itself errors: strip
`pattern`/`format` for llama.cpp, downgrade list-type tool content to text, strip images on
rejection, shrink oversized images.

OpenClaw screens two things before the request. `evaluateContextWindowGuard` (`run.ts:358-383`) warns
below a threshold and hard-blocks below a minimum, throwing a `FailoverError` so the chain advances.
Vision is gated by `params.model.input?.includes("image")` (`attempt.ts:781`), and non-vision models
get a separate `imageModel` chain instead of native image input. Thinking level auto-downgrades from
the provider's own error text, with a comment naming the exact scenario:

> This commonly happens during model fallback when switching from Anthropic (which supports thinking
> levels) to providers that don't.

Neither project down-converts tool *schemas* for a weaker fallback, and neither orders the chain by
capability.

## 7. Cost

Neither project considers cost when falling back. Hermes has `usage_pricing.py`; it is never
consulted by `try_activate_fallback`. OpenClaw's `model-fallback.ts` and `model-selection.ts` contain
zero references to `cost`, and a grep for `spendCap|maxCostUsd|budgetUsd|costLimit|dailyLimit`
returns nothing outside tests.

Both learned the money lesson reactively, and both wrote the reason down.

Hermes excludes 402 from the retryable set once pool rotation and fallback have both failed
(`conversation_loop.py:3731-3745`):

> Treating 402 as retryable from this point just burns more paid requests against a depleted balance
> with no recovery mechanism left — see #31273 (real-world: ~$40 in 48h on a 24/7 gateway).

Its docs also warn about a cost the code does not guard
(`website/docs/user-guide/features/fallback-providers.md:117`):

> When fallback fires, the new provider:model has no cached prefix… the next request re-reads the
> entire history at full input-token price instead of the ~75–90% discounted cached rate… a long
> session that bounces between providers can cost noticeably more than one that stays put.

OpenClaw's one cost-relevant decision runs the other way, on purpose. Explicit fallbacks are **not**
filtered by the model allowlist, "Fallbacks are explicit user intent; do not silently filter them by
the model allowlist" (`model-fallback.ts:325-327`), so a chain can reach a model the allowlist would
otherwise refuse.

## 8. Telling the owner

Hermes emits exactly one durable notice per activation, and buffers the routine retry chatter so it
is dropped on success (`chat_completion_helpers.py:1641-1656`):

```python
agent._pending_fallback_notice = (
    f"🔄 Switched to fallback model: {old_model} via {old_provider} "
    f"→ {fb_model} via {fb_provider}"
)
```

It also guards against lying. `_has_pending_fallback()` (`run_agent.py:4788-4800`) exists so
"trying fallback…" prints only when a chain entry actually remains, because otherwise "the session
looks like it's recovering when it's about to abort silently".

OpenClaw's chat notice is **verbose-gated** (`agent-runner.ts:618-629`), so a silent model switch is
its default UX. The state is persisted per session as `fallbackNoticeSelectedModel` /
`fallbackNoticeActiveModel` so the notice fires once per transition rather than every turn, and it
clears when the owner switches models explicitly. Structured `phase: "fallback"` and
`phase: "fallback_cleared"` lifecycle events carry `selectedProvider`, `activeProvider`,
`reasonSummary` and attempt summaries. `model-fallback.ts` itself logs nothing; it imports no logger.

## 9. Testing

Both test the classifier as pure tables and the chain with injected failures.

Hermes: `tests/agent/test_error_classifier.py` has 189 test functions and pins the exact enum member
set. `tests/run_agent/test_provider_fallback.py` covers chain init, index advancement, and skip
paths. `tests/run_agent/test_24996_fallback_exhaustion_cooldown.py` freezes `time.monotonic` inside
the module under test to assert exact cooldown arming. Several files are named for the issue they
regress.

OpenClaw: `src/agents/model-fallback.test.ts` (~55 cases) drives the real `runWithModelFallback` with
a `vi.fn()` stub, asserting `run.mock.calls[1]` is the expected `[provider, model]` pair. Its error
payloads are **documented real provider shapes with source links** (`:176-189`): OpenAI 429 text,
Anthropic `overloaded_error` JSON, HTTP-400 `insufficient_quota`, `model_cooldown`. The probe suite
freezes `Date.now` and clears a module-internal throttle map between tests.
`isbillingerrormessage.test.ts` includes false-positive guards such as "does not false-positive on
plain 'a 402' prose".

## 10. What neither project does

1. No cost-aware ordering, no spend cap, no budget guard on the fallback.
2. No capability-aware ordering; the chain is whatever order the owner wrote.
3. No mid-stream splice.
4. No weighted routing, latency scoring, or per-capability dispatch.
5. No per-model circuit breaker. OpenClaw's health is per auth profile; Hermes's is a
   couldn't-construct-a-client memo.
6. No overall deadline across the chain.
7. Context overflow is excluded from fallback in both, on the same reasoning: a different model may
   have a *smaller* window and fail worse.
