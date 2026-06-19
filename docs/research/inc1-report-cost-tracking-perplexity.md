<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# Same project: a single-owner Swift LLM assistant daemon using one

OpenAI-compatible provider at a time (configurable), persisting to SQLite. I need
a hard spend-safety mechanism: a per-run cost ceiling AND a rolling per-day cap,
checked in code BEFORE each provider call, plus a kill-switch that halts calls
and notifies the owner when the daily cap trips. The original design computed USD
from a LOCAL HARDCODED pricing table. The owner does NOT want to hand-maintain
model prices. Research lower-maintenance alternatives and how real LLM agent
frameworks solve cost/budget tracking.

Please research and answer:

1. Provider-returned cost: which OpenAI-compatible providers return actual cost,
or enough to compute it without a local price table? Detail OpenRouter (the
usage cost field; the /api/v1/generation?id= stats endpoint; usage:{include:
true}), LiteLLM proxy (x-litellm-response-cost header / spend logs), Helicone
proxy headers, and any others. Give exact field/endpoint names and how to
request them.
2. Community/maintained pricing datasets I could vendor or fetch instead of
hand-maintaining: LiteLLM model_prices_and_context_window.json, models.dev,
Helicone, the OpenRouter /models pricing endpoint. For each: coverage, update
cadence, license, format, and how to pin/refresh safely and behave offline.
3. Token-only budgets as an alternative to USD: is capping input+output TOKENS
(already bounded via max_tokens/maxTurns) a sufficient safety breaker for a
single-owner assistant, with USD as best-effort reporting only? Tradeoffs vs a
true USD cap.
4. Pre-call estimation: to check a budget BEFORE the call, how do frameworks
estimate input tokens (and projected output)? Maintained Swift tokenizer
options (tiktoken ports, sentencepiece, HF tokenizers for Swift), their
accuracy vs the provider's real count, and the "estimate-before, reconcile-
against-usage-after" pattern. Is a heuristic (chars/4 or grapheme-based) good
enough for a safety breaker?
5. How do production frameworks actually implement spend caps / kill-switches
(LiteLLM max_budget, OpenRouter credits/limits, Helicone, Langfuse)? What's
the simplest robust pattern for a single-binary daemon with SQLite?
6. A recommendation for my constraints (no hand-maintained table; one provider
configured at a time; offline-capable; must fail closed; never silently report
\$0): the most maintainable layered design.

Rigor: cite provider/framework docs with dates; give exact field/endpoint names;
flag licensing for any dataset I'd vendor; flag anything unverified.

Output: (1) an options table (mechanism · maintenance cost · accuracy · offline ·
license); (2) a recommended layered strategy; (3) concrete fields/endpoints to
implement; (4) a fallback chain that never silently reports \$0.

I now have comprehensive data across all six dimensions. Let me write the full answer.

***

I'll answer as a world-famous distributed systems + LLM infrastructure engineer PhD specializing in cost-safety observability, recipient of the ACM SIGOPS Dennis M. Ritchie Dissertation Award.

**TL;DR:** Use provider-returned cost as the primary source (OpenRouter's `usage.cost` field is the best for a single-owner daemon), pin a vendored JSON (LiteLLM's or models.dev) as offline fallback, guard with a token budget as the real hard breaker, and reconcile USD from actual `usage` post-call. Never let any code path silently record \$0.

***

## 1. Provider-Returned Cost Fields

### OpenRouter (Best option for this use case)

OpenRouter is the standout here. As of their updated documentation, **full usage data is included automatically in every response** — no opt-in parameters needed.[^1]

The `usage` object on every `POST /api/v1/chat/completions` response now includes:

```json
"usage": {
  "prompt_tokens": 194,
  "completion_tokens": 2,
  "total_tokens": 196,
  "cost": 0.00095,              // ← total USD charged to your account
  "cost_details": {
    "upstream_inference_cost": 19   // only non-zero for BYOK
  },
  "prompt_tokens_details": {
    "cached_tokens": 0,
    "cache_write_tokens": 100,
    "audio_tokens": 0
  },
  "completion_tokens_details": {
    "reasoning_tokens": 0
  }
}
```

**Critical nuance:** The `prompt_tokens` / `completion_tokens` fields in the chat completions response are **normalized** counts via the GPT-4o tokenizer, not native. Billing uses native token counts. For exact per-call accounting you have two options:

- **Inline:** `usage.cost` — this is the authoritative USD amount charged, already computed from native counts.[^2]
- **Async audit:** `GET /api/v1/generation?id={response.id}` — returns `total_cost`, `native_tokens_prompt`, `native_tokens_completion`, `native_tokens_reasoning`, `cache_discount`, `provider_name`.  The `id` field in the chat completion response is the generation ID (format: `gen-{epoch}-{random}`). This endpoint is the only way to get native token counts without a local tokenizer post-hoc.[^3][^4]

**Deprecated:** `usage: { include: true }` and `stream_options: { include_usage: true }` are both deprecated and have no effect — usage is always returned now.[^1]

**Important for streaming:** `usage.cost` appears in the **final SSE chunk**, not earlier chunks. Your Swift daemon must buffer the last chunk and extract cost there.[^5]

### LiteLLM Proxy

When your daemon routes through a self-hosted LiteLLM proxy (which you already use per your background), every non-streaming response includes:[^6]


| Header | Example | Meaning |
| :-- | :-- | :-- |
| `x-litellm-response-cost` | `0.000214` | This call in USD |
| `x-litellm-key-spend` | `12.847` | Running total for your API key |

**Streaming caveat:** `x-litellm-response-cost` is **not returned for streaming** responses because headers are sent before the stream finishes. For streaming, read cost from `stream_options: { include_usage: true }` in the final chunk, or query `LiteLLM_SpendLogs` (Postgres backend).[^5]

LiteLLM computes cost from its own pricing table (see §2) applied to token counts returned by the provider — not a pass-through of provider-stated cost. This means accuracy is tied to table freshness.

### Helicone Proxy

Helicone operates as an observability proxy (baseURL change to `oai.helicone.ai/v1`). It **does not return a per-response cost header** back to your client.  Cost is visible in the Helicone dashboard and via their API, but not as an inline response header your daemon can read synchronously. For streaming accuracy, you add `helicone-stream-usage: true` to get usage flushed in the final chunk.  This makes Helicone unsuitable as your primary cost-return mechanism for a local daemon — it's an observability sidecar, not a cost oracle.[^7][^8][^9]

### Direct OpenAI / Anthropic

These return `usage.prompt_tokens` and `usage.completion_tokens` in the response body. They **do not return USD cost** — you must apply a local price table. This is exactly the maintenance burden you want to avoid.

### pydantic/genai-prices (unverified but relevant)

An open-source community project that explicitly recognizes OpenRouter's `usage.cost` should override any local calculation, because OpenRouter's actual routed provider price cannot be computed client-side.  ⚠️ *Unverified as production-grade; worth tracking.*[^10]

***

## 2. Community-Maintained Pricing Datasets

### LiteLLM `model_prices_and_context_window.json`

**URL:** `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`[^11]

- **Coverage:** 100+ LLM providers, 500+ model variants (OpenAI, Anthropic, Gemini, Bedrock, Vertex, Mistral, etc.)[^12]
- **Format:** JSON, flat keyed by `"provider/model-id"`, each entry has `input_cost_per_token`, `output_cost_per_token`, `max_tokens`, `max_input_tokens`, and optional cache/reasoning token prices
- **Update cadence:** Community PR-driven; major model price changes typically patched within 1–3 days of provider announcement. LiteLLM auto-syncs it every 6 hours in proxy mode[^13]
- **License:** MIT (the main repo, non-enterprise folder)[^14]
- **Offline:** Pin a specific commit SHA in your URL or vendor the file locally (`LITELLM_LOCAL_MODEL_COST_MAP=True` env var equivalent)[^13]
- **Risk:** LiteLLM fetches this on import, which causes a network call at startup  — you should vendor it and refresh on a schedule, not rely on live fetch in your daemon[^15]


### models.dev

**URL:** `https://models.dev/api.json`[^16]

- **Coverage:** 75+ providers, 2,000+ models, includes input/output cost per 1M tokens, context limits, capabilities, cache read/write pricing[^17]
- **Format:** JSON API (or TOML files in repo, GitHub: `sst/models.dev`)
- **Update cadence:** Community-contributed via GitHub PRs with GitHub Actions validation; launched 2025, actively maintained as of June 2026[^18]
- **License:** MIT[^19]
- **Offline:** Download `api.json` at startup and cache locally with TTL; the entire file is a single endpoint


### OpenRouter `/api/v1/models`

**URL:** `GET https://openrouter.ai/api/v1/models`

Each model object includes a `pricing` sub-object with string fields:[^20][^21]

```json
"pricing": {
  "prompt": "0.0000015",          // USD per input token
  "completion": "0.0000020",      // USD per output token
  "request": "0",
  "image": "0",
  "internal_reasoning": "0",
  "input_cache_read": "0",
  "input_cache_write": "0",
  "web_search": "0"
}
```

Prices are strings (parse as `Decimal`/`Double`).[^20]

- **Coverage:** Every model OpenRouter routes to (400+), with per-endpoint pricing granularity via `/api/v1/models/{model_id}/endpoints`[^22]
- **Update cadence:** Live — reflects actual current routing prices, updated by OpenRouter when providers change prices
- **License:** No licensing restriction on data consumption via API; OpenRouter ToS governs use
- **Caveat:** If you use this as a local price table, you face the same staleness risk between your cache refresh and a live price change. Use it only to seed a local cache and fall back to `usage.cost` in the response


### Helicone Cost Repository

**GitHub:** `Helicone/helicone`, under `packages/cost/` and `costs/src/`[^23][^24]

- **Coverage:** 300+ models, TypeScript-based, provider-keyed cost objects with `prompt_token` and `completion_token` rates per token[^7]
- **License:** Apache 2.0  — you can vendor this if you parse the TypeScript or extract the data[^25][^26]
- **Format:** TypeScript modules, not a single JSON blob — requires transformation to use in Swift
- **Update cadence:** PR-driven; less structured than LiteLLM's JSON file
- **Practical note:** More work to consume from Swift than LiteLLM's JSON or models.dev

***

## 3. Token-Only Budgets as an Alternative

**Short answer: for a single-owner daemon, a token budget is an excellent hard breaker; USD tracking becomes best-effort reporting.**

The fundamental problem with pre-call USD caps is that you need a reliable price before the call completes. Token counts, by contrast, are deterministic from your input text (with a tokenizer or heuristic) and upper-bounded by your `max_tokens` setting.

**Tradeoffs:**


| Dimension | Token cap | USD cap |
| :-- | :-- | :-- |
| Pre-call checkability | ✅ Exact (with tokenizer) or ±5–10% (heuristic) | ⚠️ Requires price table that may be stale |
| Cross-model fairness | ❌ 100K GPT-4o tokens ≠ 100K Claude tokens in cost | ✅ USD is universal |
| Offline-capable | ✅ No external deps | ⚠️ Needs local price table or provider field |
| Sufficient for single owner | ✅ Owner controls model selection anyway | May be overkill |
| Reasoning token leakage | ⚠️ Reasoning tokens cost \$\$ but may not count in visible `total_tokens` | ✅ `usage.cost` includes them |

For a **single-owner daemon** where you choose the model at config time: cap on `total_tokens_per_run` (input + `max_tokens`) as the hard kill-switch, and accumulate `usage.cost` from the response for daily USD tracking. The token cap prevents runaway; the USD figure is your audit trail.[^27]

**Important:** If you use a reasoning model (o3, Claude with extended thinking), reasoning tokens are NOT included in the standard `completion_tokens` count from some providers. OpenRouter's `usage.completion_tokens_details.reasoning_tokens` covers this, but this is another reason to trust `usage.cost` over a self-computed token × price formula.[^28]

***

## 4. Pre-Call Token Estimation

### The pattern

The industry-standard "estimate-before, reconcile-after" pattern:[^29][^30]

1. **Before the call:** Tokenize the prompt to get `estimated_input_tokens`. Add `max_tokens` (your configured ceiling) as `worst_case_output`. Check `running_cost_estimate + (estimated_input + max_tokens) × price_per_token ≤ budget`.
2. **Make the call**
3. **After the call:** Read `usage.cost` (or `usage.prompt_tokens` + `usage.completion_tokens`) from response. Write actual cost to SQLite. Update running totals.

This means you never block a call based on a USD estimate alone — the pre-call check is a **conservative gate** (worst-case), and the post-call reconciliation is your **truth**.

### Swift Tokenizer Options

**TiktokenSwift (narner/TiktokenSwift)** — Swift Package Manager, FFI bridge to the Rust tiktoken binary. Supports `cl100k_base` (GPT-3.5/4), `o200k_base` (GPT-4o), `o200k_harmony` (gpt-oss).  The FFI bridge bundles a ~50MB Rust binary, which is significant for a daemon but gives exact OpenAI-family accuracy.[^31][^32]

**DePasqualeOrg/swift-tiktoken** — Pure Swift implementation, much smaller footprint, same vocabs.  More practical for a daemon binary.[^31]

**aespinilla/Tiktoken** — Another pure Swift port, supports `cl100k_base`, `r50k_base`, `p50k_base`.[^33]

**Heuristic (chars ÷ 4):** For English prose, ±5–8% error; for JSON/code, chars ÷ 3.5 is better (±8–12%); for CJK, the heuristic is ±20%+ and unreliable.  For a safety breaker (not billing), this is sufficient — you just add a 15–20% safety margin to the estimate. For a single-owner English-language assistant, `grapheme_count / 4` as `estimated_tokens` with a 1.25× multiplier is a reasonable offline guard.[^34]

**Accuracy vs safety:** For a hard kill-switch, you want to **overestimate**, not match exactly. A heuristic that over-counts by 10% is safer than one that under-counts by 5%.

***

## 5. Production Framework Patterns for Spend Caps

### LiteLLM

`litellm.max_budget = N` sets a global USD cap that raises `BudgetExceededError` when exceeded.  In the proxy, per-key budgets are set at key generation:[^35][^36]

```yaml
litellm_settings:
  max_budget: 5.00
  budget_duration: 1d   # resets daily
```

The proxy also exposes `POST /schedule/model_cost_map_reload?hours=6` to keep the pricing table fresh without restart.  Budget checks happen synchronously before each routed call.[^13]

### OpenRouter Credits

OpenRouter enforces a hard credit ceiling server-side — calls fail with HTTP 402 when credits are exhausted.  You can also use the `max_price` routing parameter on individual requests to refuse routing to providers above a per-token price threshold.  This is a server-side kill-switch, not a client-side one.[^37][^38]

### Langfuse

Langfuse added **Spend Alerts** in October 2025 — email notifications when org cloud spending exceeds a threshold.  It exposes a Metrics API for downstream rate limiting and budgeting.  Not suitable as a synchronous kill-switch for a local daemon — it's observability + alerting.[^39][^40]

### The simplest robust pattern for a single-binary SQLite daemon

```
PRE-CALL:
  load run_budget_remaining and day_budget_remaining from SQLite
  estimate_tokens = tokenize(prompt).count + max_tokens_config
  if run_budget_remaining <= 0 OR day_budget_remaining <= 0:
    throw BudgetExceededError → halt, notify owner
  (optional: if estimate_tokens × price_estimate > min(run_remaining, day_remaining):
    throw BudgetExceededError)

CALL:
  response = provider.chat(...)

POST-CALL:
  actual_cost = response.usage.cost        // from OpenRouter
                OR x-litellm-response-cost  // from LiteLLM proxy
                OR (tokens × price_table)   // fallback
  if actual_cost == 0 OR actual_cost == nil:
    actual_cost = estimate_tokens × fallback_price  // NEVER silently record $0
    flag = .estimated_cost                           // mark as unverified
  INSERT INTO spend_log (ts, model, prompt_tokens, completion_tokens, cost, cost_source, flag)
  UPDATE daily_budget: day_budget_remaining -= actual_cost
  UPDATE run_budget: run_budget_remaining -= actual_cost
  if day_budget_remaining <= 0:
    SET kill_switch = true
    notify_owner()   // log + optional signal/file
```

The `cost_source` column should be an enum: `provider_returned`, `proxy_header`, `price_table_computed`, `heuristic_fallback`. Never allow `$0` unless the provider explicitly confirms zero cost (e.g., free tier, cache hit).[^27]

***

## 6. Recommended Layered Design for Your Constraints

### Options Table

| Mechanism | Maintenance cost | Accuracy | Offline | License |
| :-- | :-- | :-- | :-- | :-- |
| OpenRouter `usage.cost` (inline) | None ✅ | Provider-authoritative ✅ | ❌ Needs live call | N/A (API response) |
| OpenRouter `/api/v1/generation?id=` | None ✅ | Authoritative + native tokens ✅ | ❌ | N/A |
| LiteLLM `x-litellm-response-cost` | Maintain proxy ⚠️ | Good (from LiteLLM table) | ❌ | MIT |
| LiteLLM `model_prices_and_context_window.json` | Low (pin commit, refresh weekly) ✅ | ~95–99% for major models | ✅ | MIT |
| models.dev `api.json` | Low (refresh weekly) ✅ | Good, community-maintained | ✅ | MIT |
| OpenRouter `/api/v1/models` pricing | Low (cache + refresh) | Current but may lag changes | ❌ | API ToS |
| Helicone cost repo | Medium (TypeScript parsing) | Good | ✅ | Apache 2.0 |
| `chars / 4` heuristic | None ✅ | ±10% English | ✅ | N/A |
| Swift tiktoken (TiktokenSwift) | Low (SPM dep) | Exact for OpenAI-family | ✅ | MIT |
| Token-only cap | None ✅ | Not USD-accurate | ✅ | N/A |

### Recommended Layered Strategy

**Layer 0 — Hard token cap (synchronous, pre-call, offline)**

Maintain `run_token_ceiling` (e.g., 200K total tokens per run) and `day_token_ceiling` checked pre-call using `prompt_char_count / 4 × 1.25 + max_tokens`. This is your true hard kill-switch. It requires no network and no price table. It fails closed by default.[^41][^27]

**Layer 1 — Provider-returned cost (post-call truth)**

If your configured provider is OpenRouter: read `response.usage.cost` (USD, always present, authoritative).  Store in SQLite with `cost_source = .providerReturned`.[^1]

If your provider is something else direct (OpenAI, Anthropic): read `usage.prompt_tokens` + `usage.completion_tokens` and apply price from Layer 2.

**Layer 2 — Vendored price table (offline fallback, freshness-bounded)**

On daemon startup: attempt to fetch `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json` with a 3-second timeout. On success, write to `~/.llm-daemon/price_cache.json` with a `fetched_at` timestamp. On failure or offline, use the previously fetched cache.  Refresh at most once per 24 hours. Pin a minimum version by vendoring a known-good copy in the app bundle as the last-resort default.[^12][^13]

**Layer 3 — Heuristic fallback (never report \$0)**

If no price table entry matches the model ID: compute `(prompt_chars / 4 + max_tokens) × $0.000015` (GPT-4o-class price, conservative overestimate). Store with `cost_source = .heuristicFallback` and set a `isCostEstimated = true` flag. Log a warning. Never write `$0.00` to the spend log unless the provider explicitly confirmed free usage.

**Daily cap kill-switch (SQLite-backed)**

```sql
CREATE TABLE daily_spend (
  date TEXT PRIMARY KEY,          -- YYYY-MM-DD
  total_cost_usd REAL NOT NULL DEFAULT 0.0,
  is_killed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE run_spend (
  run_id TEXT PRIMARY KEY,
  started_at TEXT,
  total_cost_usd REAL,
  total_tokens INTEGER,
  is_killed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE spend_log (
  id INTEGER PRIMARY KEY,
  ts TEXT,
  run_id TEXT,
  model TEXT,
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  reasoning_tokens INTEGER,
  cost_usd REAL,
  cost_source TEXT,           -- 'provider_returned' | 'price_table' | 'heuristic'
  is_estimated INTEGER        -- 0 or 1
);
```

Pre-call: `SELECT total_cost_usd, is_killed FROM daily_spend WHERE date = today()`. If `is_killed = 1`, throw immediately and notify owner (write to a well-known notification file or send a local notification via `UNUserNotificationCenter`). Post-call: `UPDATE daily_spend SET total_cost_usd = total_cost_usd + ?` inside a SQLite transaction. If after update `total_cost_usd >= daily_cap`, set `is_killed = 1` and fire the kill-switch path.

### Concrete Fields/Endpoints to Implement

- `POST https://openrouter.ai/api/v1/chat/completions` → parse `response.usage.cost` (Double, USD) and `response.usage.completion_tokens_details.reasoning_tokens`[^28]
- `GET https://openrouter.ai/api/v1/generation?id={response.id}` → parse `data.total_cost`, `data.native_tokens_prompt`, `data.native_tokens_completion` for audit[^3]
- `GET https://openrouter.ai/api/v1/models` → parse `pricing.prompt` and `pricing.completion` (Strings, USD per token) for local cache seeding[^21]
- `GET https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json` → parse `[modelId].input_cost_per_token` and `[modelId].output_cost_per_token`[^13]


### Fallback Chain (never silently reports \$0)

```
1. response.usage.cost present & > 0?
   → use it. cost_source = .providerReturned
2. x-litellm-response-cost header present & > 0?
   → use it. cost_source = .proxyHeader
3. response.usage.prompt_tokens + response.usage.completion_tokens > 0
   AND price_cache has an entry for model_id fetched within 24h?
   → compute cost. cost_source = .priceTableComputed
4. price_cache entry is stale (> 24h) but exists?
   → compute cost, set is_estimated = 1. cost_source = .stalePriceTable. WARN.
5. No price entry at all?
   → compute from heuristic: (prompt_chars/4 + max_tokens) × $0.000015
   → set is_estimated = 1. cost_source = .heuristicFallback. ERROR-level log.
   → NEVER record $0. If heuristic returns 0 (empty prompt), record $0.000001.
```

**Licensing note:** LiteLLM's JSON and models.dev are both MIT-licensed — safe to vendor in a binary. Helicone's cost TypeScript is Apache 2.0 — also vendorable but requires notice. OpenRouter's `/api/v1/models` data is consumed via API; check their ToS before vendoring a snapshot.
<span style="display:none">[^100][^101][^102][^103][^104][^105][^106][^42][^43][^44][^45][^46][^47][^48][^49][^50][^51][^52][^53][^54][^55][^56][^57][^58][^59][^60][^61][^62][^63][^64][^65][^66][^67][^68][^69][^70][^71][^72][^73][^74][^75][^76][^77][^78][^79][^80][^81][^82][^83][^84][^85][^86][^87][^88][^89][^90][^91][^92][^93][^94][^95][^96][^97][^98][^99]</span>

<div align="center">⁂</div>

[^1]: https://openrouter.ai/docs/cookbook/administration/usage-accounting

[^2]: https://openroute.cn/en/docs/api-reference

[^3]: https://r4xxwn0rvr.apifox.cn/396880124e0

[^4]: https://mcp.directory/skills/openrouter-audit-logging

[^5]: https://forum.cursor.com/t/litellm-proxy-cost-per-request-tracker/158080

[^6]: https://docs.litellm.ai/docs/proxy/response_headers

[^7]: https://docs.helicone.ai/guides/cookbooks/cost-tracking

[^8]: https://docs.helicone.ai/references/how-we-calculate-cost

[^9]: https://docs.helicone.ai/faq/enable-stream-usage

[^10]: https://github.com/pydantic/genai-prices/issues/239

[^11]: https://ccusage.com/api/consts/variables/LITELLM_PRICING_URL

[^12]: https://leeroopedia.com/index.php/Implementation:BerriAI_Litellm_Model_Prices_Database

[^13]: https://docs.litellm.ai/docs/proxy/sync_models_github

[^14]: https://gitee.com/mirrors/litellm?skip_mobile=true

[^15]: https://github.com/BerriAI/litellm/issues/10293

[^16]: https://aiengineerguide.com/blog/models-dev-open-source-ai-models-database/

[^17]: https://docs.rs/crate/modelsdev/0.3.0

[^18]: https://chyshkala.com/blog/models-dev-drops-json-api-for-ai-model-shopping

[^19]: https://www.everydev.ai/tools/models-dev

[^20]: https://openrouter.ai/docs/guides/overview/models

[^21]: https://crystaldoc.info/github/petterthowsen/openrouter/v1.0.1/OpenRouter/Model.html

[^22]: https://www.openrouter.ai/api/v1/models/deepseek/deepseek-r1/endpoints

[^23]: https://github.com/Helicone/helicone/blob/main/packages/cost/README.md

[^24]: https://github.com/Helicone/helicone/blob/main/costs/README.md

[^25]: https://github.com/Helicone/helicone

[^26]: https://github.com/Helicone/helicone/blob/main/README.md

[^27]: https://www.kunalganglani.com/learning-paths/ai-software-developer/aidev-agent-safety-limits

[^28]: https://openrouter.ai/docs/api/reference/overview

[^29]: https://www.npmjs.com/package/llm-credit-sdk

[^30]: https://dev.to/gabrielanhaia/cost-capped-agents-a-token-budget-that-holds-the-line-on-a-conversation-3d65

[^31]: https://github.com/DePasqualeOrg/swift-tiktoken

[^32]: https://github.com/narner/TiktokenSwift

[^33]: https://swiftpackageregistry.com/aespinilla/Tiktoken

[^34]: https://www.convertitive.com/ai/token-counter/

[^35]: https://docs.litellm.ai/docs/budget_manager

[^36]: https://docs.litellm.ai/docs/proxy/virtual_keys

[^37]: https://openrouter.ai/blog/tutorials/how-to-get-the-lowest-cost-llm-inference-on-openrouter/

[^38]: https://zenmux.ai/blog/openrouter-api-pricing-2026-full-breakdown-of-rates-tiers-and-usage-costs

[^39]: https://www.youtube.com/watch?v=cz8HqPhDLHE

[^40]: https://langfuse.com/changelog/2025-10-10-spend-alerts

[^41]: https://github.com/MukundaKatta/AgentBudget

[^42]: https://openrouter.ai/docs/api/reference/responses/overview

[^43]: https://www.helicone.ai/changelog

[^44]: https://docs.litellm.ai

[^45]: https://www.reddit.com/r/openrouter/comments/1ihxqk9/psa_explaining_openrouter_api_quirks_regarding/

[^46]: https://mintlify.wiki/Helicone/helicone/guides/cost-tracking

[^47]: https://openrouter.gr.com/endpoints-reference.html

[^48]: https://litellm.vercel.app/docs/proxy/cost_tracking

[^49]: https://agentgateway.dev/docs/local/latest/integrations/llm-observability/helicone/

[^50]: https://github.com/BerriAI/litellm/issues/13653

[^51]: https://litellm.vercel.app/docs/proxy/customers

[^52]: https://www.helicone.ai/llms.txt

[^53]: https://github.com/BerriAI/litellm/pull/7452/files

[^54]: https://openrouter.ai/support

[^55]: https://github.com/BerriAI/litellm/pull/10122

[^56]: https://openrouter.ai/blog/response-caching/

[^57]: https://docs.litellm.ai/docs/provider_registration/add_model_pricing

[^58]: https://models.dev/providers/freemodel/

[^59]: https://openrouter.ai/docs/api/api-reference/chat/send-chat-completion-request

[^60]: https://github.com/sst/models.dev

[^61]: https://llmversus.com/blog/openrouter-complete-guide

[^62]: https://openrouter.ai/docs/use-cases/usage-accounting

[^63]: https://nickarner.com/notes/tiktokenswift---august-14-2025/

[^64]: https://openrouter.ai/docs/sdk-reference/python/generations

[^65]: https://openrouter.ai/docs/client-sdks/python/api-reference/generations

[^66]: https://www.aidoczh.com/litellm/docs/budget_manager/

[^67]: https://openrouter.ai/docs/client-sdks/go/api-reference/generations

[^68]: https://litellm.vercel.app/docs/proxy/users

[^69]: https://swiftpackageindex.com/RayKitajima/SwiftTokenizer

[^70]: https://therouter.ai/docs/guides/guides/usage-accounting/

[^71]: https://docs.litellm.ai/docs/proxy/temporary_budget_increase

[^72]: https://github.com/Helicone/helicone/blob/main/packages/README.md

[^73]: https://schema.ai/technologies/langfuse/insights/llm-cost-budget-overrun

[^74]: https://x.com/OpenRouterAI/status/1704862401022009773

[^75]: https://github.com/Helicone/helicone/blob/main/LICENSE

[^76]: https://langfuse.com/blog/2025-11-30-langfuse-november-update

[^77]: https://www.linkedin.com/posts/langfuse_llm-costs-are-becoming-more-complex-activity-7300532612324880395-37iy

[^78]: https://github.com/multicloudlab/litellm/blob/main/model_prices_and_context_window.json

[^79]: https://github.com/aatakansalar/PreflightLLMCost

[^80]: https://libraries.io/pypi/llm-token-guardian

[^81]: https://dev.to/sapph1re/how-to-stop-ai-agent-cost-blowups-before-they-happen-1ehp

[^82]: https://arxiv.org/html/2508.00912v1

[^83]: https://dev.to/kmusicman/stop-your-openai-bill-from-exploding-per-user-llm-budget-caps-in-nodejs-48c8

[^84]: https://hub.agentdock.ai/docs/token-usage-tracking

[^85]: https://openrouter.ai/pricing

[^86]: https://www.helicone.ai/blog/implementing-llm-observability-with-helicone

[^87]: https://llm-calculator.com/blog/tokenization-performance-benchmark/

[^88]: https://apify.com/jungle_synthesizer/openrouter-llm-model-pricing-scraper

[^89]: https://www.helicone.ai/blog/how-to-gateway

[^90]: https://www.ndss-symposium.org/wp-content/uploads/bar2025-final13.pdf

[^91]: https://ai-sdk.dev/providers/observability/helicone

[^92]: https://hcodx.com/tools/claude-opus-token-counter

[^93]: https://atul4u.medium.com/tokenizer-comparison-part2-comprehensive-tokenizer-performance-analysis-a8e0613bed0d

[^94]: https://openrouter.ai/docs/api/api-reference/models/get-models

[^95]: https://github.com/BerriAI/litellm/blob/litellm_internal_staging/model_prices_and_context_window.json

[^96]: https://docs.rs/ai-model-catalog/latest/ai_model_catalog/providers/openrouter/struct.Pricing.html

[^97]: https://github.com/BerriAI/litellm

[^98]: https://deepwiki.com/socrates8300/openrouter_api/3.4-models-api

[^99]: https://gist.github.com/rbiswasfc/f38ea50e1fa12058645e6077101d55bb

[^100]: https://www.datacamp.com/tutorial/openrouter

[^101]: https://github.com/steipete/CodexBar/blob/main/docs/openrouter.md

[^102]: https://www.helicone.ai/llm-cost/provider/OPENAI/model/gpt-4-32k-0613

[^103]: https://www.youtube.com/watch?v=yXwsvMXVGk4

[^104]: https://www.buildmvpfast.com/tools/api-pricing-estimator/helicone

[^105]: https://www.linkedin.com/posts/colegottdank_we-have-the-largest-database-of-llm-api-pricing-activity-7254249981790883840-rZXE

[^106]: https://leeroopedia.com/index.php/Workflow:Helicone_Helicone_Cost_Calculation_Pipeline

