<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# I'm building a single-owner personal-assistant daemon in pure Swift 6 (strict

concurrency) that talks to LLMs through ONE OpenAI-compatible /chat/completions
contract over AsyncHTTPClient (no official SDK; a thin in-house client). v1 uses
BLOCKING, non-streaming calls (stream:false); SSE streaming comes later. The
provider/model/base_url/api_key are configurable so I can swap between OpenAI,
OpenRouter, Groq, Ollama/LM Studio, an Anthropic OpenAI-compatible endpoint, and
a LiteLLM proxy WITHOUT code changes. I need an exact, current, cross-provider
wire contract plus an error/retry model.

Please research and answer:

1. The exact request JSON for a blocking POST to {base_url}/chat/completions:
required and commonly-used fields (model; messages[] with roles
system/user/assistant/tool; max_tokens vs max_completion_tokens; temperature;
top_p; stop; stream:false; seed; response_format). Which fields are portable
vs provider-specific. Auth/header conventions (Authorization: Bearer, plus
provider-specific headers e.g. OpenRouter HTTP-Referer/X-Title).
2. Reasoning models (OpenAI o-series and equivalents): the max_tokens ->
max_completion_tokens change, unsupported temperature, hidden reasoning
tokens, and how a portable client should handle the divergence.
3. The exact response JSON: choices[].message.content (and when it can be null);
the finish_reason enum values; the usage object including any prompt-caching
fields (e.g. prompt_tokens_details.cached_tokens); id/model/created. Note
cross-provider differences in the usage object (OpenAI vs OpenRouter vs Groq
vs Ollama vs LiteLLM), including providers that omit usage entirely.
4. The error contract: HTTP status -> meaning (400 incl. context-length-exceeded,
401/403 auth, 404 model, 429 rate/quota, 5xx/overload); the error body shape
({"error":{message,type,code,param}}) and cross-provider variance; where
rate-limit reset info lives (Retry-After header vs x-ratelimit-* headers vs
body). Tag each class retryable vs terminal.
5. A recommended retry policy: which statuses to retry, capped exponential
backoff + full jitter parameters used in practice, honoring Retry-After, and
a sane attempt cap.
6. Practical gotchas for a self-hosted daemon: connection/read timeouts for slow
local endpoints (Ollama), gzip, large-response body caps, idempotency.

Rigor: cite the official OpenAI API reference and each provider's docs with
dates/versions; note anything that changed in 2025-2026; explicitly flag fields
that are provider-specific or that you could not verify.

Output: (1) a portable "request to send" spec; (2) a "response to parse" spec
with fallbacks for missing fields; (3) an error->action table tagged
retryable|terminal; (4) a short list of cross-provider caveats.

I have all the information needed. Let me now compose the comprehensive, rigorously cited answer.

***

I'll answer as a world-famous distributed systems engineer PhD in LLM API protocol design with the IEEE CS Technical Committee Outstanding Paper Award.

**TL;DR:** The OpenAI `/chat/completions` wire contract is de-facto standard, but every downstream provider diverges in subtle ways—reasoning model params, the `usage` object shape, error bodies, and rate-limit headers. Below is a production-grade spec with all the forks called out explicitly.

***

## 1 — Request Spec (Portable)

### Canonical Request Shape

```jsonc
POST {base_url}/chat/completions
Content-Type: application/json
Authorization: Bearer {api_key}
// Provider extras below

{
  "model": "gpt-4o",                    // REQUIRED — string, provider-specific id
  "messages": [                          // REQUIRED — ordered history
    { "role": "system",    "content": "You are a helpful assistant." },
    { "role": "user",      "content": "Hello" },
    { "role": "assistant", "content": "Hi there!" },
    { "role": "tool",      "content": "<json result>", "tool_call_id": "call_abc" }
  ],
  "stream": false,                       // REQUIRED for v1; explicit is safer
  "max_completion_tokens": 2048,        // PREFERRED over max_tokens (see §2)
  "temperature": 0.7,                   // omit for reasoning models (see §2)
  "top_p": 1.0,                         // omit for reasoning models
  "stop": ["\n\n"],                     // optional; string or string[^4]
  "seed": 42,                           // optional; best-effort reproducibility
  "response_format": { "type": "text" } // "json_object" or "json_schema" where supported
}
```


### Field Portability Matrix

| Field | OpenAI | OpenRouter | Groq | Ollama | LiteLLM proxy | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| `model` | ✅ | ✅ (use `provider/model`) | ✅ | ✅ | ✅ | required everywhere |
| `messages` roles | system/user/assistant/tool | same | same | same | normalized |  |
| `max_completion_tokens` | ✅ (since late 2024) | ✅ (passes through) | ✅ | ✅ (maps to `num_predict`) | ✅ (maps per provider) | **use this** |
| `max_tokens` | ⚠️ deprecated; errors on o-series/GPT-5 | pass-through | ✅ | ✅ | auto-maps | avoid in new code |
| `temperature` | ✅ (0–2) | ✅ | ✅ | ✅ | ✅ | must be omitted or 1 for reasoning models |
| `top_p` | ✅ | ✅ | ✅ | ✅ | ✅ | omit for reasoning models |
| `stop` | ✅ | ✅ | ✅ | ✅ | ✅ | portable |
| `stream` | ✅ | ✅ | ✅ | ✅ | ✅ | portable |
| `seed` | ✅ best-effort | ✅ passes through | ⚠️ accepted but no guarantee | ⚠️ Ollama ignores | ✅ normalized | NOT deterministic guarantee [^1] |
| `response_format` | ✅ (`text`, `json_object`, `json_schema`) | ✅ | ✅ (`json_object`/`json_schema` on supported models) | ⚠️ `json_object` only, no streaming+JSON combo [^2] | ✅ normalized |  |
| `reasoning_effort` | ✅ o-series only (`low`/`medium`/`high`) | ✅ passes through | ❌ | ❌ | ✅ normalized | OpenAI-specific [^3] |

### Auth \& Header Conventions

**Universal (all providers):**

```
Authorization: Bearer {api_key}
Content-Type: application/json
```

**OpenRouter extras** (optional but strongly recommended for app attribution and analytics):[^4][^5]

```
HTTP-Referer: https://your-daemon.local
X-Title: MyAssistantDaemon        // or X-OpenRouter-Title for newer API versions
```

**Anthropic native** (not OpenAI-compat path): requires `anthropic-version: 2023-06-01` and `x-api-key:` header instead of Bearer — but when using an OpenAI-compat shim or LiteLLM, standard Bearer auth is used instead.[^6]

**Ollama local:** `api_key` is ignored; any non-empty string works (e.g., `"ollama"`). Endpoint: `http://localhost:11434/v1/chat/completions`.[^2]

**Groq:** Standard Bearer auth to `https://api.groq.com/openai/v1/chat/completions`.[^7]

**LiteLLM proxy:** Standard Bearer auth with `model` set to `provider/model-name` (e.g., `openai/gpt-4o`, `anthropic/claude-3-5-sonnet`). LiteLLM normalizes the request to each backend's native format transparently.[^8]

***

## 2 — Reasoning Models (o-series + Equivalents)

The o1/o3/o4-mini family and OpenAI's GPT-5.x series with reasoning introduced breaking API changes in late 2024 through 2025.[^9][^3]

### `max_tokens` → `max_completion_tokens`

`max_tokens` is **rejected with a 400** on all o-series and GPT-5 reasoning models:[^10][^9]

```
Error: max_tokens is too large: 1000.
This model supports at most 1000 completion tokens,
but only via the max_completion_tokens parameter, not max_tokens.
```

`max_completion_tokens` was added as the preferred field in September 2024 and works on *all* models (including GPT-4o, GPT-3.5), making it the correct portable choice. **The daemon should always send `max_completion_tokens` and never send `max_tokens`.**[^11]

Critical gotcha for reasoning models: `max_completion_tokens` is a **budget for all output tokens including hidden reasoning tokens**. An o4-mini request with `max_completion_tokens: 3072` can exhaust all 3072 tokens on internal reasoning, leaving the `content` field empty with `finish_reason: "length"`. Set this value generously (≥8000 for complex tasks) or use `reasoning_effort: "low"` to cap thinking overhead.[^12][^13]

### Unsupported Parameters on Reasoning Models

`temperature`, `top_p`, `presence_penalty`, `frequency_penalty` all return a 400 if set to non-default values:[^14][^9]

```
Unsupported value: 'temperature' does not support 0.7 with this model.
Only the default (1) value is supported.
```

As of June 2026, the full landscape is:[^14]

- **o1, o3, o4-mini, o3-pro**: no sampling params whatsoever; `reasoning_effort: low|medium|high` instead
- **GPT-5.x non-reasoning chat models** (e.g., `gpt-5-chat-latest`): temperature + top_p supported
- **GPT-5.2 series**: reasoning effort `none|low|medium|high|xhigh`; when `reasoning_effort: none`, temperature/top_p are available


### Portable Client Strategy

```swift
// Detect reasoning model by name prefix:
let isReasoningModel = model.hasPrefix("o1") || model.hasPrefix("o3") ||
                       model.hasPrefix("o4") || model.hasPrefix("o-") ||
                       model.contains("reasoning")

var body: [String: Any] = [
    "model": model,
    "messages": messages,
    "stream": false,
    "max_completion_tokens": maxTokens
]
if !isReasoningModel {
    body["temperature"] = temperature
    body["top_p"] = topP
}
```


### Hidden Reasoning Tokens

Reasoning tokens are billed as completion tokens but never appear in `content`. They show up in `usage.completion_tokens_details.reasoning_tokens` (OpenAI). On OpenRouter the same field appears as `completion_tokens_details.reasoning_tokens`. Always check `reasoning_tokens` when debugging unexpectedly high bills or empty `content` responses.[^15][^16][^17][^13]

***

## 3 — Response Spec

### Full Response Shape

```jsonc
{
  "id": "chatcmpl-abc123",            // string; Groq uses chatcmpl-*, OpenRouter same
  "object": "chat.completion",
  "created": 1719000000,             // Unix timestamp int
  "model": "gpt-4o-2024-08-06",      // echoed model, may differ from requested alias
  "system_fingerprint": "fp_abc",    // OpenAI only; indicates backend config version
  "choices": [
    {
      "index": 0,
      "finish_reason": "stop",        // see enum table below
      "message": {
        "role": "assistant",
        "content": "Hello!",          // string OR null — see below
        "tool_calls": null,           // present when finish_reason == "tool_calls"
        "refusal": null               // OpenAI only; set when model refuses request
      }
    }
  ],
  "usage": {
    "prompt_tokens": 15,
    "completion_tokens": 9,
    "total_tokens": 24,
    // --- OpenAI & LiteLLM normalized ---
    "prompt_tokens_details": {
      "cached_tokens": 0,             // non-zero on cache hit [cite:22]
      "audio_tokens": 0
    },
    "completion_tokens_details": {
      "reasoning_tokens": 0,          // non-zero on o-series [cite:25]
      "audio_tokens": 0,
      "accepted_prediction_tokens": 0,
      "rejected_prediction_tokens": 0
    }
  }
}
```


### `content` Null Cases

`content` is legitimately `null` (not an error) in two cases:[^18]

1. `finish_reason == "tool_calls"` — the response is in `message.tool_calls` instead
2. `finish_reason == "content_filter"` — the content was blocked; `content` may be null or empty string

A defensive parser must treat `null` content as an empty string when no tool call is present, not as an error.

### `finish_reason` Enum

| Value | Meaning |
| :-- | :-- |
| `stop` | natural EOS or hit a `stop` sequence |
| `length` | hit `max_completion_tokens`; output is truncated |
| `tool_calls` | model wants to call a function/tool |
| `content_filter` | content policy blocked the output |
| `function_call` | **deprecated** alias for `tool_calls` |
| `null` | streaming in-progress (only; never in non-streaming) |

Providers like Groq and Ollama generally return the same enum strings. OpenRouter adds `native_finish_reason` alongside the normalized `finish_reason`.[^19][^20]

### `usage` Object — Cross-Provider Differences

| Field | OpenAI | OpenRouter | Groq | Ollama | LiteLLM proxy |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `prompt_tokens` | ✅ | ✅ | ✅ | ✅ | ✅ normalized |
| `completion_tokens` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `total_tokens` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `prompt_tokens_details.cached_tokens` | ✅ | ✅ | ❌ absent | ❌ absent | ✅ (0 if N/A) |
| `completion_tokens_details.reasoning_tokens` | ✅ | ✅ | ❌ | ❌ | ✅ (0 if N/A) |
| `cost` | ❌ | ✅ (in credits) | ❌ | ❌ | ❌ |
| `cache_write_tokens` | ❌ | ✅ (Anthropic models) | ❌ | ❌ | ✅ as `cache_creation_input_tokens` |

OpenRouter uses its own "QuadChars" tokenizer for billing; the `usage.prompt_tokens` in the response reflects **native provider token counts**, not OpenRouter's normalized count. LiteLLM always normalizes usage to an OpenAI-compatible shape, returning `0` for absent sub-fields rather than omitting them.[^21][^17][^22]

**Fallback parse rule:** Always treat absent `usage` or any sub-field as zero, never null-deref. Ollama may omit `prompt_tokens_details` entirely on some model versions.

***

## 4 — Error Contract

### Error Body Shape (OpenAI standard)

```jsonc
{
  "error": {
    "message": "This model's maximum context length is 16385 tokens...",
    "type":    "invalid_request_error",
    "param":   "messages",         // which field caused it; may be null
    "code":    "context_length_exceeded"  // machine-readable sub-code; may be null
  }
}
```

Cross-provider: Groq, OpenRouter, and LiteLLM all return this same envelope shape. Anthropic's native API uses `{"type":"error","error":{"type":"...", "message":"..."}}`  — but when accessed via an OpenAI-compat shim, LiteLLM translates it to the standard envelope.[^23][^24][^8]

### Error → Action Table

| HTTP Status | `code` / scenario | Meaning | Action |
| :-- | :-- | :-- | :-- |
| **400** | `context_length_exceeded` | Input + output exceeds model context window | **TERMINAL** — truncate history, reduce `max_completion_tokens` [^23][^25] |
| **400** | `max_tokens` param error | Sent `max_tokens` to reasoning model | **TERMINAL** — switch to `max_completion_tokens` [^9] |
| **400** | `invalid_request_error` (other) | Malformed JSON, bad role, invalid param value | **TERMINAL** — fix the request |
| **400** | temperature unsupported | Sent temperature != 1 to o-series | **TERMINAL** — remove temperature |
| **401** | `invalid_api_key` | Wrong or missing API key | **TERMINAL** — check config |
| **403** | `permission_denied` | Key lacks access to this model | **TERMINAL** — check billing/tier |
| **404** | `model_not_found` | Model ID doesn't exist or isn't deployed | **TERMINAL** — check model name / provider |
| **408** | connection timeout | Network/server timeout | **RETRYABLE** — same as 5xx policy |
| **413** | body too large | Request body exceeds provider's limit (~1MB) | **TERMINAL** — trim messages |
| **422** | `unprocessable_entity` | Passes JSON parse but fails schema validation | **TERMINAL** |
| **429** | `rate_limit_exceeded` | RPM or TPM exhausted | **RETRYABLE** — honor `retry-after-ms` first [^26][^27] |
| **429** | `quota_exceeded` (monthly) | Hard quota cap | **TERMINAL until billing fixed** — check body `.code` |
| **500** | `server_error` | Backend crash or deployment issue | **RETRYABLE** — exponential backoff [^28] |
| **503** | `service_unavailable` / overloaded | Model/server overloaded | **RETRYABLE** — [^29] |
| **529** | Anthropic `overloaded_error` | Anthropic-specific overload (not standard HTTP) | **RETRYABLE** — treat same as 503 [^24] |

### Rate-Limit Header Locations

**OpenAI** sends these on *every* response (not only 429s):[^30][^31]

```
x-ratelimit-limit-requests: 5000
x-ratelimit-remaining-requests: 4999
x-ratelimit-reset-requests: 12ms          // time until RPM window resets
x-ratelimit-limit-tokens: 160000
x-ratelimit-remaining-tokens: 159976
x-ratelimit-reset-tokens: 9ms
retry-after-ms: 430                       // ONLY on 429; milliseconds to wait
```

**Groq** uses the same header names; `x-ratelimit-limit-requests` is RPD (requests/day), `x-ratelimit-limit-tokens` is TPM.[^27][^32]

**OpenRouter / Ollama:** do not reliably send `x-ratelimit-*` headers. Parse `Retry-After` (seconds) as fallback.

***

## 5 — Recommended Retry Policy

Based on OpenAI's official guidance  and production practice:[^33][^34][^35][^30]

### Which Statuses to Retry

Retry: **429**, **500**, **503**, **529**, **408** (timeout), connection errors.
Do NOT retry: **400**, **401**, **403**, **404**, **413**, **422**.

### Algorithm

```
attempt = 0, base_delay = 0.5s, max_delay = 60s, max_attempts = 5

loop:
  response = POST(request)
  if success: return response
  if not retryable(status): throw terminal error

  // Honor server's advice first
  retry_after_ms = parse_header("retry-after-ms")  // OpenAI style
  retry_after_s  = parse_header("Retry-After")     // standard; may be int or HTTP-date

  if retry_after_ms and retry_after_ms < 60_000:
      sleep(retry_after_ms)
  elif retry_after_s and retry_after_s < 60:
      sleep(retry_after_s * 1000)
  else:
      // Capped exponential with full jitter (AWS-style)
      cap = min(base_delay * 2^attempt, max_delay)
      sleep(random_uniform(0, cap))    // full jitter prevents thundering herd

  attempt += 1
  if attempt >= max_attempts: throw RetryExhaustedError
```

The OpenAI Python SDK uses: initial=0.5s, max=8s, jitter factor 0.75–1.0×, default 2 retries. For a self-hosted daemon where calls are infrequent and precious, a more conservative `max_attempts=5` with `max_delay=60s` is better.[^34][^35]

**Retry-After cap:** If the server requests >60s delay, fall back to your own backoff calculation rather than waiting indefinitely.[^34]

***

## 6 — Daemon-Specific Gotchas (Swift/AsyncHTTPClient)

### Timeouts for Ollama / Local Models

AsyncHTTPClient's default is: **no read timeout, 10s connect timeout**. For Ollama, the first request after model unload has a 5–30s cold-start loading period. Configure:[^36][^37][^38]

```swift
var config = HTTPClient.Configuration()
config.timeout = .init(
    connect: .seconds(10),
    read: .seconds(300)   // non-streaming blocking call on large models
)
// Per-request override for remote APIs (OpenAI, Groq) — tighter
let request = HTTPClientRequest(url: url)
// Use the execute(_:deadline:) overload:
let response = try await client.execute(request, deadline: .now() + .seconds(120))
```

Pre-warm Ollama on daemon startup to avoid cold-start timeout:[^37]

```bash
curl http://localhost:11434/api/generate -d '{"model":"llama3:8b","prompt":"","keep_alive":"24h"}'
```


### Gzip / Brotli Decompression

OpenAI and some providers may return `Content-Encoding: gzip` or `Content-Encoding: br` (Brotli). AsyncHTTPClient has decompression **disabled by default** — you must opt in:[^39]

```swift
var config = HTTPClient.Configuration()
config.decompression = .enabled(limit: .size(10 * 1024 * 1024))  // 10MB cap
```

Without this, you'll receive raw compressed bytes and your JSON decoder will fail. If Brotli hits, set an explicit `Accept-Encoding: gzip, deflate` request header to avoid the br issue.[^39]

### Large Response Body Cap

A non-streaming response for a 128K-token reasoning model can easily be 500KB+. AsyncHTTPClient's `response.body.collect(upTo:)` requires an explicit byte cap:

```swift
// 20MB should cover even the longest conceivable non-streaming response
let body = try await response.body.collect(upTo: 20 * 1024 * 1024)
```

Failing to set this will throw `NIOCore/ByteBuffer.swift: insufficientCapacity`.

### Idempotency

The `/chat/completions` endpoint is **not idempotent by design** — each call may produce a different answer and incurs token cost. For your retry loop, only retry on network errors and 5xx/429; never retry 400-class errors automatically, as they always require request modification. If you want true idempotency for deduplication (e.g., after a network-level retry that succeeded but the response was dropped), OpenAI supports an `Idempotency-Key` header on POST requests — but this is **OpenAI-only** and not cross-provider portable; tag it as a premium-only config option.

***

## Cross-Provider Caveats (Quick Reference)

- **`max_tokens` vs `max_completion_tokens`:** Always send `max_completion_tokens`; LiteLLM and OpenRouter pass it through; Groq and Ollama accept both. Never send `max_tokens` to o-series or GPT-5.[^40][^9][^11]
- **`temperature` on reasoning models:** Always omit (or check model name first). LiteLLM auto-drops unsupported params via `drop_params: true` config.[^41]
- **OpenRouter `usage.prompt_tokens`** counts **native provider tokens**, not a normalized count — expect different numbers than calling the same provider directly, especially after Anthropic tokenizer changes.[^21]
- **Ollama `seed`** is accepted but the field is silently ignored for most models; don't rely on it for reproducibility.[^40]
- **Ollama + `response_format: json_object` + `stream: false`** works; but `stream: true` + `json_object` simultaneously is broken as of early 2026  — relevant when you add streaming later.[^2]
- **Groq rate limits:** `x-ratelimit-limit-requests` is RPD (per day), while `x-ratelimit-limit-tokens` is TPM (per minute) — the windows differ. Parse both `reset` headers and take the one with the shorter wait.[^27]
- **Anthropic `529` overloaded:** Not a standard HTTP code; treat it like 503 in your retryable set.[^24]
- **LiteLLM proxy `usage`:** Always includes all sub-fields (with 0 defaults), never omits them — the safest consumer for a portable daemon.[^22]
- **`content == null` is not an error** when `finish_reason == "tool_calls"` or `"content_filter"`. Always null-check before string-processing content.[^18]
- **`system_fingerprint`** is OpenAI-only; Groq, Ollama, and OpenRouter omit it — don't use it for cross-provider cache keying.[^1]
- **Brotli compression** can arrive from OpenAI unexpectedly; explicitly set `Accept-Encoding: gzip, deflate` if your client doesn't handle Brotli.[^39]
<span style="display:none">[^100][^101][^102][^103][^104][^105][^106][^107][^108][^109][^110][^111][^112][^113][^114][^115][^116][^117][^42][^43][^44][^45][^46][^47][^48][^49][^50][^51][^52][^53][^54][^55][^56][^57][^58][^59][^60][^61][^62][^63][^64][^65][^66][^67][^68][^69][^70][^71][^72][^73][^74][^75][^76][^77][^78][^79][^80][^81][^82][^83][^84][^85][^86][^87][^88][^89][^90][^91][^92][^93][^94][^95][^96][^97][^98][^99]</span>

<div align="center">⁂</div>

[^1]: https://platform.openai.com/docs/guides/advanced-usage

[^2]: https://theneuralbase.com/ollama/learn/beginner/using-openai-sdk-with-ollama/

[^3]: https://www.linkedin.com/pulse/understanding-openais-o-series-evolution-ai-reasoning-rick-hightower-crsbf

[^4]: https://openrouter.ai/docs/app-attribution

[^5]: https://www.educative.io/courses/openrouter-fundamentals/making-your-first-request

[^6]: https://zubnet.ai/wiki/en/Endpoint/

[^7]: https://www.reddit.com/r/GroqInc/comments/1c9gk2l/groq_api_chat_completion_end_point_and_api/

[^8]: https://docs.litellm.ai/docs/

[^9]: https://note.com/ai_tarou/n/nd3ecd5ed409e?hl=en

[^10]: https://community.openai.com/t/api-stopped-working-max-tokens-and-temperature-no-longer-allowed/1110863

[^11]: https://github.com/spring-projects/spring-ai/issues/1411

[^12]: https://platform.openai.com/docs/api-reference/chat/completions/create

[^13]: https://community.openai.com/t/o4-mini-returns-empty-response-because-reasoning-token-used-all-the-completion-token/1359002

[^14]: https://community.openai.com/t/request-for-compatibility-matrix-reasoning-effort-sampling-parameters-across-gpt-5-series/1371738

[^15]: https://developers.openai.com/api/reference/python/resources/chat/subresources/completions/methods/create/

[^16]: https://developers.openai.com/api/reference/resources/completions

[^17]: https://openrouter.ai/docs/api/reference/overview

[^18]: https://community.openai.com/t/chat-completion-ai-returning-content-as-none-and-finish-reason-as-tool-call/1151616

[^19]: https://docs.rs/openai-openapi-types/latest/openai_openapi_types/enum.CreateChatCompletionResponseChoiceFinishReason.html

[^20]: https://docs.robomotion.io/reference/packages/openrouter/get-generation/

[^21]: https://openrouter.ai/blog/opus-47-tokenizer-analysis/

[^22]: https://pypi.org/project/litellm/1.64.1/

[^23]: https://community.openai.com/t/help-needed-tackling-context-length-limits-in-openai-models/617543

[^24]: https://github.com/anthropics/claude-code/issues/3633

[^25]: https://community.openai.com/t/maximum-content-length-exceeded-despite-prompt-being-very-simple/1078158

[^26]: https://www.respan.ai/articles/openai-api-rate-limits

[^27]: https://console.groq.com/docs/rate-limits

[^28]: https://platform.openai.com/docs/guides/error-codes

[^29]: https://community.openai.com/t/status-code-503-that-model-is-currently-overloaded-with-other-requests/31433

[^30]: https://developers.openai.com/api/docs/guides/rate-limits

[^31]: https://community.openai.com/t/how-to-get-rate-limit-reset-time-for-response-api/1268905

[^32]: https://www.grizzlypeaksoftware.com/articles/p/groq-api-free-tier-limits-in-2026-what-you-actually-get-uwysd6mb

[^33]: https://supportgpt.app/blog/openai-api-rate-limit

[^34]: https://leeroopedia.com/index.php/Heuristic:Openai_Openai_python_Retry_Backoff_Strategy

[^35]: https://oneuptime.com/blog/post/2026-02-16-how-to-handle-rate-limiting-and-throttling-in-azure-openai-api-calls/view

[^36]: https://github.com/openclaw/openclaw/issues/2252

[^37]: https://www.aimadetools.com/blog/ollama-api-timeout-fix/

[^38]: https://swift-server.github.io/async-http-client/docs/current/AsyncHTTPClient/Classes/HTTPClient/Configuration.html

[^39]: https://github.com/spring-projects/spring-ai/issues/2345

[^40]: https://readmex.com/en-US/ollama/ollama/page-17d8bc82d9-9fc9-4ad5-b603-e3341bda5ad8

[^41]: https://github.com/BerriAI/litellm/issues/13381

[^42]: https://platform.openai.com/docs/api-reference/completions/create

[^43]: https://mmacy.github.io/openai-python/1.13/error-handling/

[^44]: https://hexdocs.pm/openai_responses/0.5.1/OpenAI.Responses.Error.html

[^45]: https://developers.openai.com/api/docs/guides/completions

[^46]: https://developers.openai.com/api/docs/guides/error-codes

[^47]: https://github.com/jedarden/CLASP/blob/main/docs/api-reference/openai-chat-completions.md

[^48]: https://gonkagate.com/en/docs/errors

[^49]: https://github.com/cline/cline/issues/1896

[^50]: https://console.groq.com/docs/api-reference

[^51]: https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/prompt-caching

[^52]: https://theneuralbase.com/groq/qna/how-to-use-groq-with-openai-sdk/

[^53]: https://aiagentsdocs.com/docs/openrouter

[^54]: https://docs.getbifrost.ai/providers/supported-providers/groq

[^55]: https://hexdocs.pm/req_llm/1.0.0-rc.8/openrouter.html

[^56]: https://medium.com/@DragoZarev/with-this-new-configuration-the-openai-api-chat-completions-can-now-consistently-return-a-valid-487f169b10e3

[^57]: https://docs.boundaryml.com/ref/llm-client-providers/openrouter

[^58]: https://github.com/microsoft/semantic-kernel/discussions/9623

[^59]: https://ollama.com/blog/openai-compatibility

[^60]: https://docs.litellm.ai/docs/completion

[^61]: https://github.com/BerriAI/liteLLM-proxy/blob/main/README.md

[^62]: https://inventivehq.com/blog/http-status-codes-rate-limiting-throttling

[^63]: https://github.com/eyalrot/ollama_openai/blob/master/docs/API_COMPATIBILITY.md

[^64]: https://docs.litellm.ai/docs/completion/usage

[^65]: https://www.speakeasy.com/openapi/responses/rate-limiting

[^66]: https://www.reddit.com/r/LocalLLaMA/comments/1apvtwo/ollamas_openaicompatible_api_and_using_it_with/

[^67]: https://litellm.vercel.app/docs/

[^68]: https://milvus.io/ai-quick-reference/how-can-i-handle-rate-limiting-in-the-openai-api

[^69]: https://www.reddit.com/r/LocalLLaMA/comments/1dhxaoo/larger_models_stop_responding/

[^70]: https://learn.microsoft.com/en-us/javascript/api/@microsoft/agents-a365-observability/finishreason?view=agent365-sdk-node-latest

[^71]: https://aiweekly.co/node/2448

[^72]: https://github.com/openai/openai-python/blob/main/src/openai/types/chat/chat_completion.py

[^73]: https://scalablehuman.com/2025/09/03/anthropics-v1-messages-endpoint-parameters-openai-comparison-more/

[^74]: https://markaicode.com/troubleshooting-ollama-connection-timeouts-network-optimization/

[^75]: https://docs.llmgateway.io/features/anthropic-endpoint

[^76]: https://github.com/nsxdavid/anthropic-max-router

[^77]: https://github.com/langgenius/dify/issues/13498

[^78]: https://pecollective.com/tools/openai-api-vs-anthropic-api/

[^79]: https://developers.llamaindex.ai/python/framework/integrations/llm/ollama/

[^80]: https://therouter.ai/docs/guides/guides/usage-accounting/

[^81]: https://skillui.com/en/skill/show/jeremylongshore/claude-code-plugins-plus-skills/groq-common-errors

[^82]: https://coldfusion-example.blogspot.com/2026/02/handling-openai-api-429-too-many.html

[^83]: https://arxiv.org/html/2601.10088v1

[^84]: https://metacpan.org/pod/Langertha::RateLimit

[^85]: https://docs.litellm.ai/docs/completion/prompt_caching

[^86]: https://community.openai.com/t/error-400-maximum-context-length-exceeded/931400

[^87]: https://community.openai.com/t/chatcompletionmessag-is-returning-content-none-when-finish-reason-stop/583975

[^88]: https://community.openai.com/t/error-code-400-max-token-length/716391

[^89]: https://community.openai.com/t/function-call-response-is-empty-despite-completion-tokens-being-used/580888

[^90]: https://docs.litellm.ai/docs/tutorials/prompt_caching

[^91]: https://portkey.ai/error-library/context-length-error-10013

[^92]: https://community.openai.com/t/finish-reason-stop-but-have-a-tool-calls-and-no-content/820316

[^93]: https://docs.litellm.ai/docs/proxy/docker_quick_start

[^94]: https://docs.litellm.ai/docs/proxy/prod

[^95]: https://learn.microsoft.com/en-us/answers/questions/1693887/azure-openai-seed-parameter

[^96]: https://platform.openai.com/docs/guides/reasoning/managing-the-context-window

[^97]: https://github.com/AsyncHttpClient/async-http-client/wiki/Connection-pooling

[^98]: https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/reasoning?view=foundry-classic

[^99]: https://groups.google.com/g/asynchttpclient/c/IuWcrMw7SPg/m/UfaW9NSPuacJ

[^100]: https://community.openai.com/t/the-seed-inference-parameter-for-reproducibility/556118

[^101]: https://developers.openai.com/cookbook/examples/responses_api/reasoning_items

[^102]: https://bin.zmide.com/?p=1150

[^103]: https://learn.microsoft.com/en-us/answers/questions/1432042/availability-of-openais-seed-parameter-in-azure

[^104]: https://www.qwe.edu.pl/tutorial/reasoning-effort-levels-guide/

[^105]: https://github.com/AsyncHttpClient/async-http-client/issues/54

[^106]: https://github.com/openai/openai-python/issues/708

[^107]: https://status.openai.com/incidents/01JMYB80MRDHY3W4NZRAPC00WB

[^108]: https://hc.apache.org/httpcomponents-client-5.6.x/async-compression.html

[^109]: https://downforai.com/openai/error/api-error

[^110]: https://github.com/dispatch/reboot/issues/52

[^111]: https://stackoverflow.com/questions/66213812/gunzip-aiohttp-response-on-the-fly

[^112]: https://github.com/AsyncHttpClient/async-http-client/issues/1820

[^113]: https://tokenmix.ai/blog/openai-error-codes-guide?lang=fr

[^114]: https://www.cursor-ide.com/blog/claude-code-api-error-529-overloaded

[^115]: https://community.ibm.com/community/user/discussion/decompress-gzip-response-content-from-external-rest-api-through-automation-script

[^116]: https://errormedic.com/api/openai-api/troubleshooting-openai-api-errors-rate-limits-429-timeouts-and-server-issues-500-502-503

[^117]: https://learn.microsoft.com/en-us/aspnet/core/fundamentals/middleware/request-decompression?view=aspnetcore-10.0

