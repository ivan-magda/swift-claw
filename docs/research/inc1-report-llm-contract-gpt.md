I'll answer as a world-famous AI Systems Architect PhD in Large Language Models with a Turing Award in Natural Language Processing

**TL;DR**: We detail a unified OpenAI-style chat/completions request/response spec.  In the request we include fields like `model`, `messages` (roles `system/user/assistant`), `max_tokens`/`max_completion_tokens`, `temperature`, `top_p`, `stop`, `stream:false`, `seed`, and any formatting hints; many of these (model, messages, temperature, top_p, stop, n, stream, user, logit_bias, presence_penalty, frequency_penalty) are common or easily mapped among providers.  Provider‐specific params (e.g. OpenRouter’s `providers`, `parallel_tool_calls`, or Groq’s `reasoning_effort`) are omitted for portability.  Auth is usually `Authorization: Bearer <API_KEY>` (OpenAI, Groq, LiteLLM) or local/no-auth (Ollama); OpenRouter also allows optional `HTTP-Referer`/`X-Title` headers for app metadata.  For O‑series (reasoning) models, use `max_completion_tokens` (not `max_tokens`) and omit unsupported sampling params (`temperature`, `top_p`) to avoid errors. 

**Portable Request JSON (Blocking Chat Completions)**: Each provider’s POST JSON can follow the OpenAI schema, with these *portable fields* (missing or unsupported params are simply omitted or ignored by that provider):

- **`model`** (string, *required*): model identifier (e.g. `"gpt-4o"`, `"gemma4"`, `"claude-3"`, or a LiteLLM key). Required by all providers.  
- **`messages`** (array of `{role, content}` objects, *required*): conversation history. Roles are typically `"system"`, `"user"`, or `"assistant"`. (Some systems also support a `"developer"` role or tool-call messages, but in practice the client can treat all non-user messages as system/assistant.) For example:  
  ```json
  "messages": [
    {"role":"system","content":"You are a helpful assistant."},
    {"role":"user","content":"Hello!"}
  ]
  ```  
  (OpenAI, Groq, LiteLLM use this same format; Ollama’s `/api/chat` uses a similar `messages` array.)  
- **`temperature`** (number, default 1): sampling temperature (0–2 for OpenAI/Groq). Not supported on some reasoning models (O-series); sending it to those yields a 400 error. For Anthropic Opus 4.7+, **don’t send** `temperature` or `top_p` at all (non-default values trigger errors).  
- **`top_p`** (number, default 1): nucleus sampling (0–1). Same caveat as `temperature`.  
- **`stop`** (string or array of strings): stop sequences (up to 4). Not supported with certain reasoning models, so omit for those. Example: `"stop": ["\nHuman:", "\nAI:"]`.  
- **`max_tokens`** vs **`max_completion_tokens`**: Many providers (OpenAI, Groq, OpenRouter) accept **`max_tokens`** as total output length cap. However, OpenAI’s new reasoning models *require* `max_completion_tokens` instead and `max_tokens` is deprecated. To be safe, use `max_completion_tokens` for long-output or reasoning models, or send both (they are synonymous in older models).  
- **`stream`** (boolean): set `false` (non-streaming). (Default is false in most APIs.)  
- **`seed`** (integer, optional): deterministic sampling seed. Supported by Groq/OpenAI for determinism; ignored by others.  
- **`response_format`** (object, optional): format hints (e.g. `{ "type": "json_object" }` for JSON output, or a JSON Schema). Supported by OpenAI/Groq for structured output. Others typically ignore it.  
- **`presence_penalty`, `frequency_penalty`** (number): common to OpenAI/Groq (range -2..2); many models ignore them.  
- **`logit_bias`** (object): maps token IDs to bias scores (OpenAI/Groq).  
- **`n`** (int, default 1): number of completion choices (only 1 supported by most chat endpoints).  
- **`user`** (string): optional end-user ID (for monitoring). Supported by OpenAI/Groq, ignored elsewhere.  
- **Provider-specific fields (to avoid unless needed)**: e.g. OpenRouter’s `providers`, `cache_control`, `metadata`; Groq’s `reasoning_effort`/`include_reasoning`; function-calling fields (`functions`, `tools`, `tool_choice`, `function_call`) etc. We recommend omitting these for portability.  

**Auth & Headers**:  
- **OpenAI/Groq/LiteLLM**: add `Authorization: Bearer <API_KEY>`.  Content-Type `application/json`.  
- **OpenRouter**: same Bearer auth, *and* optional app headers: `HTTP-Referer: <your_app_URL>` and `X-Title: <app_name>` (for rankings on openrouter.ai).  You may also send `X-OpenRouter-Metadata: enabled` to receive routing logs.  
- **Ollama/LM Studio (local)**: no auth by default (calls to `http://localhost:11434/api/chat` in examples).  
- **Anthropic (native)**: *natively* uses the `/v1/messages` API with header `x-api-key: <KEY>` and e.g. `anthropic-version: 2023-06-01`.  (There is currently **no** official OpenAI `/v1/chat/completions` endpoint for Anthropic; if using an “OpenAI-compatible Anthropic” proxy, follow that proxy’s auth.)  
- **LiteLLM proxy**: also uses `Authorization: Bearer <key>` (its own API key or virtual key); it then translates to the target provider internally.  

## 2. Response JSON (Chat Completion)  
All providers return a JSON with a similar structure. Key fields to parse:

- **`id`** (string): completion ID.  
- **`object`**: usually `"chat.completion"`.  
- **`created`**: timestamp (Unix seconds) of creation.  
- **`model`**: string of model used.  
- **`choices`** (array): list of generated completions (length = `n`). Usually one element. Each choice has:  
  - **`message`**: object with at least `role` and `content`. For normal outputs, `role` is `"assistant"` and `content` is the generated text. (If the assistant calls a function, the response might instead include a `"function_call"` object – treat that as content.)  Note: for Ollama, the response has `message.content` as above; it also includes `message.thinking` (hidden reasoning) if `think=true`, and `done_reason` separately. These fields are provider-specific.  
  - **`finish_reason`** (string or null): why generation stopped. Common values (OpenAI/Groq): 
    - `"stop"` – hit a stop sequence or natural end; 
    - `"length"` – hit max tokens limit; 
    - `"function_call"` or `"tool_calls"` – model decided to call a function (varies by API); 
    - `"content_filter"` – content omitted by policy (Azure/AWS Claude returns this); 
    - `null` – not finished (should not happen in non-streaming).  
  - **`index`**: choice index (0 if only one).  
  - **`logprobs`**: usually `null` unless requested.  
- **`usage`**: object with token counts. OpenAI/Groq style:  
  ```json
  "usage": {
    "prompt_tokens": <int>,
    "completion_tokens": <int>,
    "total_tokens": <int>,
    "prompt_tokens_details": { "cached_tokens": <int>, "audio_tokens": <int> }  // optional
  }
  ```  
  - `prompt_tokens`, `completion_tokens`, `total_tokens`: as named. Groq also adds timing fields (`queue_time`, `prompt_time`, `completion_time`) in its usage.  
  - `prompt_tokens_details` (object): breakdown of prompt tokens (OpenAI provides `cached_tokens` if prompt was cached).  
  - **Cross-provider differences**: 
    - OpenRouter and LiteLLM proxy return an OpenAI‐compatible usage (as above). 
    - Groq includes the same token counts plus its time metrics. 
    - **Ollama/LM Studio** returns no `usage` object. Instead, it includes metrics like `prompt_eval_count` (token count in prompt) and timing info in the response. Clients should treat missing `usage` as “unknown” or rely on prompt token count if needed. 
    - Some models (especially reasoning models) may have “hidden” tokens not counted in these totals (raw “thinking” tokens in Claude/Gemini that aren’t exposed); clients generally use the provided counts.  
- **Content null cases**: `choices[i].message.content` may be `null` if the model’s output is a function/tool call (the function name/arguments might be elsewhere) or if streaming (in a partial delta, but in non-streaming it should be final text).  
- **`id`/`model`/`created` presence**: All providers include `id` and `model` (Groq example). Some (like Ollama) use different names (`model` is still present, but no `id` or usage). Fallback: if `model` missing, assume request’s model; if `id` missing, generate one client-side if needed.  

## 3. Error Handling (Status → Action)  

| HTTP Status | Meaning/Example (Cross-Provider)                                                                | Action       |
|-------------|-----------------------------------------------------------------------------------------------|--------------|
| **400**     | *Bad Request* – e.g. malformed JSON, missing required field, or context-length (prompt) too long.  Also includes parameter errors (e.g. unsupported param for model).  Example: OpenAI returns 400 for invalid params; Anthropic Opus gives 400 if you send `temperature`. | Terminal – fix request. |
| **401/403** | *Authentication/Authorization* error: invalid or missing API key (401) or insufficient permissions/blocked by policy (403).  Eg. wrong Bearer token, or OpenRouter “insufficient credits”/“guardrail block”. | Terminal – do not retry. |
| **404**     | *Not Found* – usually model or endpoint not found. E.g. calling Anthropic’s /v1/chat/completions (which doesn’t exist) returns 404, or unknown model name. | Terminal – fix model/base URL. |
| **408**     | *Request Timeout* – server timed out. (OpenRouter lists 408 for timeout.) | Retryable (backoff). |
| **429**     | *Too Many Requests* – rate limit or quota exceeded.  Providers usually set a `Retry-After` header (seconds to wait) on 429, and/or include `X-RateLimit-*` headers (OpenAI/Groq). | **Retryable** – obey `Retry-After` (if given), else exponential backoff + jitter. |
| **502/503** | *Bad Gateway/Service Unavailable* – upstream provider error or no capacity. Example: OpenRouter 502 if model down, 503 if no provider route. Also applicable to Groq: their docs say “retry-after” on 503 after overload. | **Retryable** – wait and retry with backoff. |
| **5xx (other)** | *Server Error* – transient server failure. | **Retryable** – backoff. |
  
Most APIs return an error JSON in a structured form. For example:
- **OpenAI/Groq/LiteLLM**: `{"error":{"message":"...","type":"...","param":...,"code":"..."}}` (OpenAI docs use this shape).  
- **OpenRouter**: `{"error":{"code":<HTTP code>,"message":"...","metadata":{...}}}`. The HTTP status equals `error.code`. Its `metadata` may include details (e.g. guardrail patterns).  
- **Others** (e.g. Ollama): not well-documented; likely plain text or simple JSON. If the body cannot be parsed, report it as a generic error.  

**Retry Tags**: In the table above, 429 and 5xx are retryable; 400/401/403/404 are terminal (no retry).  

**Rate-limit headers**:  
- **OpenAI** provides rate-limit info via `X-RateLimit-*` headers (requests/tokens remaining, reset times), and on 429 may send `Retry-After` (not shown in docs, but commonly used).  
- **Groq** includes `retry-after` (seconds) on 429, plus `X-RateLimit-*` headers (RPD/TPM).  
- **OpenRouter** includes `Retry-After` on 429/503; no custom ratelimit headers beyond standard HTTP.  
- **LiteLLM proxy** will pass through or emulate these headers depending on the backend provider.  
- **Ollama/local** has no rate limits for local, and no special headers.  

## 4. Retry Policy  
Retry on 429/408/5xx/502/503 with exponential backoff and full jitter. For example:  
- Initial delay ~1 second, double each retry (2s, 4s, 8s, …) plus randomization.  
- Honor any `Retry-After` header: if present, wait at least that long.  
- Cap retries (e.g. 5–8 attempts).  
- If using Swift concurrency, handle async sleeps and cancellation.  

**Example strategy**: for 429 or 5xx, do up to 6 tries: wait `random(0..min(ceil(2^attempt), 60))` seconds before each retry.  Stop early if success.  Always respect `Retry-After` if returned.  

## 5. Practical Gotchas (Self-hosted/Pure-Swift)  
- **Timeouts**: Local LLM servers (like Ollama/LM Studio) can be slow to start or answer. Use longer connect/read timeouts (several seconds+) for local endpoints.  Likewise, big models may take time before first token.  
- **Gzip**: Some servers compress responses. Ensure your HTTP client handles `Content-Encoding: gzip`. (OpenAI/Groq support gzip; ensure to set `Accept-Encoding` and decode.)  
- **Large responses**: LLM outputs can be very large. Some HTTP libs impose body size limits. Increase buffer limits or stream the body if supported to avoid truncation.  
- **Idempotency**: Chat completions are **not** idempotent (no idempotency-key is supported). Retries may generate different completions or duplicate outputs, since each API call invokes a fresh inference. Design your application accordingly.  
- **Streaming vs Blocking**: We use `stream:false` here. Ensure the server supports non-stream mode. (Ollama’s API is streaming by default, but setting `"stream":false` will return full JSON once done.)  
- **Role differences**: Some models (e.g. OpenAI’s O-series) use `"developer"` role or treat system messages specially. For portability, send system prompts as `"system"`. If a provider requires a single initial system message (Anthropic does), the client may need to prepend user/system roles accordingly.  
- **Field defaults**: If you send a field that a provider doesn’t support, it will usually ignore it (e.g. Anthropic ignores unknown fields) or error (as noted for Opus 4.7). To be safe, only include common fields.  
- **Provider-specific endpoints**: Ensure the correct base path: OpenAI/Groq use `.../v1/chat/completions`, OpenRouter uses `/api/v1/chat/completions`, Ollama uses `/api/chat`, Anthropic uses `/v1/messages`. The client’s `base_url` must match the provider.  
- **Character Encoding**: Always send/expect UTF-8. Some local LLMs might not support unusual characters well.  

**References:** Official API docs for each provider (OpenAI, Groq, OpenRouter, Ollama, Anthropic/Claude notes) were used to compile this spec. Fields marked *deprecated* or *reasoning-only* are noted. 

