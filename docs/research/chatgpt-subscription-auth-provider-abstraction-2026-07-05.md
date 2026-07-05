# Using a ChatGPT (or Claude) Subscription from a Third-Party App — and the Provider Abstraction swift-claw Should Build

*Prepared for Ivan (swift-claw, single-owner personal AI assistant in pure Swift 6, Telegram-controlled, launchd daemon, already defines an `LLMProvider` protocol over an OpenAI-compatible Chat Completions contract). Question: can a third-party app let the owner sign in with a ChatGPT/Claude subscription instead of API keys — officially or otherwise — and what pluggable provider abstraction keeps the agent loop independent of the answer?*

> **Verification key.** Parts 1–3 (the auth landscape, per-project reality, risk assessment) are drawn from two adversarially-verified deep-research passes (204 subagents total; each claim killed unless ≥2/3 independent verifiers confirmed it against primary sources — OpenAI/Anthropic docs & ToS pages, and the projects' own repos), plus targeted follow-up. **Parts 4–5 (the Swift provider abstraction and the recommendation) are DESIGN SYNTHESIS** — engineering judgment grounded in those facts, not fact-checked claims; they carry lower certainty and are marked ⚠️ where they extend past verified ground. "Official" vs "reverse-engineered" is flagged throughout. Date: 2026-07-05.
>
> **Sourcing caveats.** (a) Several OpenAI/Anthropic policy pages 403-block bots; their wording was cross-confirmed via multiple independent sources rather than fetched first-party. (b) Fast-moving area — vendor policies, token lifetimes, private endpoints, and OAuth `client_id`s change; reverse-engineered tools break on rotation. Re-check before relying on any subscription route. (c) Not individually source-verified this pass: the deeper internal provider layers of OpenWebUI/LibreChat/Continue (their API-key-only stance is well-supported by their public docs, cited inline); "Hermes" as a subscription-auth project could not be pinned down.

---

## TL;DR

**Neither OpenAI nor Anthropic offers any official mechanism for an arbitrary third-party app to make model calls billed against a user's consumer subscription.** Both support subscription sign-in, but only inside clients they ship or explicitly partner with.

- **OpenAI** — "Sign in with ChatGPT" is a real, documented OAuth flow, but scoped to *Codex* clients: OpenAI's own app/CLI/IDE/web, plus **partner** embeddings (JetBrains, Xcode). Everything else that reaches ChatGPT-subscription inference from outside is reverse-engineering — reusing the Codex CLI's first-party OAuth `client_id` (`app_EMoamEEZ73f0CkXaXp7hrann`) and/or the local `~/.codex/auth.json` token, hitting the private `chatgpt.com/backend-api/codex` endpoint. Simon Willison, who built one, calls it a *"semi-official Codex **backdoor** API."*
- **Anthropic** — Claude Code lets individuals sign in with Claude Pro/Max and can mint a one-year inference-scoped `CLAUDE_CODE_OAUTH_TOKEN`. But **Feb 2026 Anthropic added a ToS clause banning subscription OAuth tokens in third-party tools, enforced server-side since ~Jan 2026** — the ban explicitly named **OpenClaw** and swept up OpenCode, Cline, and Anthropic's own Agent SDK.
- **For swift-claw** — a single-owner, headless, launchd-daemon assistant that is *itself OpenClaw-inspired* — the subscription-borrowing route is the exact pattern Anthropic just banned and OpenAI's terms prohibit. **Build on API keys over the existing OpenAI-compatible contract first**, refactor `LLMProvider` so authentication is a separate pluggable seam, and quarantine any subscription route behind an explicitly-unofficial, opt-in provider (or a subprocess bridge to the official CLI).

---

## Part 1 — Is there an official mechanism?

### 1a. OpenAI

| Mechanism | What it actually is | Usable by a 3rd-party app for subscription inference? |
|---|---|---|
| **"Sign in with ChatGPT" (Codex)** | Official OAuth authorization-code + PKCE browser flow (localhost callback), returns an access token cached at `~/.codex/auth.json`, auto-refreshed before expiry. Included in Free/Plus/Pro/Business/Edu/Enterprise plans with per-plan message limits. | **Only inside Codex clients** — OpenAI's own app/CLI/IDE/web, and **partner** integrations OpenAI co-builds. Not a general 3rd-party grant. |
| **Codex-in-JetBrains / Xcode** | *Official partnership* — "OpenAI Codex is now natively integrated into JetBrains AI chat," built by named OpenAI + JetBrains engineers; offers ChatGPT-account sign-in, API key, or JetBrains AI sub. | Yes — the exception that proves the rule: subscription sign-in in a non-OpenAI product exists **where OpenAI explicitly partners**, not as an open flow. |
| **Apps SDK OAuth** | Runs the **opposite** direction: ChatGPT acts as the OAuth 2.1 *client* (auth-code + PKCE/S256) against **the developer's** authorization server, to call the developer's MCP backend. | **No.** Delegates identity *into* your backend; does not let you pull subscription inference *out*. |
| **"Sign in with ChatGPT" SSO** | Identity/SSO only. | **No** — grants no model access. |
| **The "Codex backdoor"** | Reverse-engineered: reuse Codex's public `client_id` and/or read `~/.codex/auth.json`, POST to `https://chatgpt.com/backend-api/codex` with `Authorization: Bearer` + optional `ChatGPT-Account-ID`. Not `api.openai.com`. | **Unofficial.** Works today; violates the terms (Part 3). |
| **Official 3rd-party "bring your plan"** | A Feb 2026 feature request ("Sign in with ChatGPT for third-party apps") exists but is **unfulfilled / "under consideration,"** staff-unconfirmed. | **Does not exist.** |

Romain Huet (OpenAI) tweeted they want people to use "Codex, and their ChatGPT subscription, wherever they like… JetBrains, Xcode, OpenCode, Pi, and now Claude Code." Read carefully: stated tolerance for **Codex** reaching those surfaces — some official (JetBrains), some via the backdoor — not a documented contract you can build on.

**Sources:** [developers.openai.com/codex/auth](https://developers.openai.com/codex/auth) · [Help Center: Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) · [codex/pricing](https://developers.openai.com/codex/pricing) · [apps-sdk/build/auth](https://developers.openai.com/apps-sdk/build/auth) · [JetBrains: Codex in JetBrains IDEs](https://blog.jetbrains.com/ai/2026/01/codex-in-jetbrains-ides/) · [Simon Willison: a pelican for GPT-5.5 via the semi-official Codex backdoor API](https://simonwillison.net/2026/Apr/23/gpt-5-5/)

### 1b. Anthropic

- **Claude Code subscription sign-in is official and first-party:** individuals log in with a Claude.ai account (browser OAuth + local callback, paste-in code fallback); "Subscription OAuth credentials from `/login`" are the default for Pro/Max/Team/Enterprise. `claude setup-token` mints a **one-year OAuth token, scoped to inference only**, exported as `CLAUDE_CODE_OAUTH_TOKEN`.
- **But Anthropic closed the door on third-party reuse.** A Feb 19 2026 ToS "Authentication and credential use" section bans Free/Pro/Max OAuth tokens in third-party tools, enforced server-side since ~Jan 2026. Coverage: *"Anthropic blocked third-party tools like OpenClaw from using Claude through subscription credentials,"* actively blocking session-token sharing and credential relay; the ban list includes **OpenClaw, OpenCode, Cline, and Anthropic's own Agent SDK.**

The `CLAUDE_CODE_OAUTH_TOKEN` route is technically usable from a script, but using it *outside Claude Code* is exactly what the new clause prohibits, and enforcement is live. Whether an inference-scoped token survives detection for a single-owner daemon is an **open question** — but it's building on sand.

**Sources:** [code.claude.com/docs/en/authentication](https://code.claude.com/docs/en/authentication) · [support.anthropic.com: Use Claude Code with your Pro or Max plan](https://support.anthropic.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan) · [Natural 20: Anthropic banned OpenClaw — the OAuth lockdown](https://natural20.com/coverage/anthropic-banned-openclaw-oauth-claude-code-third-party) · [MindStudio: the OpenAI/Anthropic subscription change](https://www.mindstudio.ai/blog/openai-codex-anthropic-subscription-change) · [DEV: Roo Code and the Claude Max ban](https://dev.to/robinbanner/roo-code-and-the-claude-max-ban-what-actually-happened-and-how-to-fix-it-5ck4)

---

## Part 2 — How existing projects actually authenticate

The consistent pattern: **almost everything is API-key-based.** The handful that reach a subscription do it either through OpenAI's official Codex OAuth (OpenAI only) or by **shelling out to the vendor's official CLI as a subprocess** (so the sanctioned client, not the third-party app, holds the token).

| Project | Provider auth | ChatGPT sub? | Claude sub? | How / notes |
|---|---|---|---|---|
| **swift-claw** (you) | API key over OpenAI-compatible Chat Completions | — | — | Current baseline |
| **Aider** ([repo](https://github.com/Aider-AI/aider)) | **API key only** (env / `.env` / `.aider.conf.yml`); optional OpenRouter OAuth that just *mints an API key* | No | No | [api-keys docs](https://aider.chat/docs/config/api-keys.html) |
| **simonw/llm** ([repo](https://github.com/simonw/llm)) | **API key only** (`needs_key`/`key_env_var`, `keys.json`) | No (core) | No | Subscription only via the separate reverse-eng [llm-openai-via-codex](https://github.com/simonw/llm-openai-via-codex) plugin |
| **OpenWebUI** ([repo](https://github.com/open-webui/open-webui)) | **API key / OpenAI-compatible base URL**; app login (Bearer/OIDC) is separate from provider auth | No | No | [OpenAI-compatible docs](https://docs.openwebui.com/getting-started/quick-start/connect-a-provider/starting-with-openai-compatible/) |
| **LibreChat** ([repo](https://github.com/danny-avila/LibreChat)) | **API keys** in `.env` + custom OpenAI-compatible endpoints; OAuth/OIDC is for *user login*, not provider access | No | No | [custom endpoints](https://www.librechat.ai/docs/quick_start/custom_endpoints) |
| **Continue** ([repo](https://github.com/continuedev/continue)) | **API key per provider** in `config.yaml` via `${{ secrets.X }}` / `.env`; custom headers/mTLS | No | No | [model providers](https://docs.continue.dev/customize/model-providers/overview) |
| **Cline** ([repo](https://github.com/cline/cline)) | API keys **plus** a "Claude Code" provider that **shells out to the local `claude` CLI**, and OpenAI Codex OAuth | Via Codex OAuth | **Via official `claude` CLI subprocess** (set the CLI path) | [Claude Code provider](https://docs.cline.bot/provider-config/claude-code) · [Codex OAuth blog](https://cline.bot/blog/introducing-openai-codex-oauth) · [Claude Max blog](https://cline.bot/blog/how-to-use-your-claude-max-subscription-in-cline) |
| **Roo Code** ([repo](https://github.com/RooCodeInc/Roo-Code)) | API keys; same subprocess-to-official-CLI bridge after the Max ban | via Codex | via official CLI bridge | [issue #4799](https://github.com/RooCodeInc/Roo-Code/issues/4799) |
| **OpenHands** ([repo](https://github.com/OpenHands/software-agent-sdk)) | API keys **plus** `LLM.subscription_login()` — OAuth PKCE to OpenAI Codex, cached at `~/.openhands/auth/`, auto-refresh | **Yes — official Codex OAuth** (OpenAI is the *only* sub provider so far) | Not yet | [LLM subscriptions](https://docs.openhands.dev/sdk/guides/llm-subscriptions) · GUI/CLI sign-in still in-flight ([#12410](https://github.com/OpenHands/OpenHands/issues/12410), [CLI #261](https://github.com/OpenHands/OpenHands-CLI/issues/261)) |
| **OpenCode** ([repo](https://github.com/sst/opencode)) | `/connect` device/OAuth for ChatGPT Plus/Pro, GitHub Copilot, GitLab Duo, "zero setup"; API key fallback | **Yes — official Codex OAuth** | **Not native** — only via unofficial [opencode-with-claude](https://github.com/ianjwhite99/opencode-with-claude) + [Meridian](https://github.com/rynfar/meridian) proxy | Built on Vercel AI SDK + Models.dev (75+ providers). [providers](https://opencode.ai/docs/providers/) |
| **Claude Code** ([docs](https://code.claude.com/docs/en/authentication)) | First-party subscription OAuth / `setup-token` / API key | — | **Yes (first-party)** | Its `setup-token` is inference-scoped but ToS-restricted to Claude Code |
| **Codex CLI** ([repo](https://github.com/openai/codex)) | First-party ChatGPT OAuth / API key | **Yes (first-party)** | — | The `client_id` + `auth.json` everyone else piggybacks on |

**Pure reverse-engineered subscription tools** (all self-labeled unofficial; reuse Codex creds → `chatgpt.com/backend-api/codex`): [simonw/llm-openai-via-codex](https://github.com/simonw/llm-openai-via-codex) · [EvanZhouDev/openai-oauth](https://github.com/EvanZhouDev/openai-oauth) · [numman-ali/opencode-openai-codex-auth](https://github.com/numman-ali/opencode-openai-codex-auth) · [raine/claude-code-proxy](https://github.com/raine/claude-code-proxy) · [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (wraps Codex/Claude Code/Gemini/Grok CLIs and re-exposes them as OpenAI-compatible endpoints).

> **The one pattern worth stealing:** Cline and Roo Code reach Claude Max by **invoking the official `claude` binary as a subprocess** and pointing at its path — the third-party app never touches the OAuth token; the sanctioned client makes the request. Post-ban, this is the surviving (though still gray, and in the ban's blast radius) way to use a Claude subscription from another tool.

---

## Part 3 — Risk assessment per approach

| Approach | Legal / ToS | Security | Privacy | Reliability | Maintenance | Verdict |
|---|---|---|---|---|---|---|
| **API key** (OpenAI-compat, incl. Anthropic/local via OpenAI shape) | ✅ Fully sanctioned | ✅ One secret, revocable, scopeable | ✅ Vendor DPA applies | ✅ Documented, stable | ✅ Low | **Build on this** |
| **Local model** (Ollama/MLX/llama.cpp over OpenAI-compat) | ✅ N/A | ✅ Nothing leaves the box | ✅ Best | ⚠️ Your hardware | ✅ Low | **Great complement** |
| **Official first-party subscription OAuth** (Codex sign-in) *as OpenHands/OpenCode use it* | ✅ For those clients; **not a grant to you** | ✅ Std OAuth | ✅ | ⚠️ First-party-only in practice; **headless daemon can't do the browser step at runtime** | ⚠️ Vendors can scope it to their clients | Not available to you as a general flow |
| **Anthropic `CLAUDE_CODE_OAUTH_TOKEN`** outside Claude Code | ❌ **Feb 2026 clause bans 3rd-party use; enforced** | ✅ Token scoped to inference | ⚠️ | ❌ Server-side blocks; ~weekly expiry | ❌ Breaks on rotation | **Avoid** — swift-claw is exactly the OpenClaw-class tool that got banned |
| **Official-CLI subprocess bridge** (drive `codex`/`claude` as a child process) | ⚠️ Gray; official client makes the call, but named in the ban's blast radius | ⚠️ Token lives in the CLI's store, not yours | ⚠️ | ⚠️ Depends on CLI staying installed/logged-in; heavy for a daemon | ⚠️ CLI upgrades change flags | Least-bad subscription route **if** the owner insists |
| **Reverse-eng ChatGPT backdoor** (`backend-api/codex`, borrowed `client_id`) | ❌ Violates Services Agreement (d) reverse-engineer, (f) unpermitted extraction, (h) bypass rate limits/protections; and consumer Terms (no programmatic Output extraction) | ❌ Long-lived token in your store; account-wide blast radius | ❌ Traffic to undocumented endpoint | ❌ Authors warn of rate-limit/**suspension/termination** | ❌ Breaks whenever OpenAI rotates client/endpoint | **Avoid** |
| **Browser cookies / session-token relay** | ❌ Account-sharing prohibitions; Anthropic explicitly blocks this | ❌ Full-account credential exposure | ❌ | ❌ Rotates constantly | ❌ Fragile | **Avoid** |

**ToS sources:** OpenAI [Services Agreement](https://openai.com/policies/services-agreement/) (Restrictions (d)/(f)/(h)) · [consumer Terms of Use](https://openai.com/policies/row-terms-of-use/) ("may not share your account credentials… responsible for all activities"; no programmatic Output extraction) · [Account Sharing Policy](https://help.openai.com/en/articles/10471989-openai-account-sharing-policy) · Anthropic authentication clause per [code.claude.com/…/authentication](https://code.claude.com/docs/en/authentication) and the ban coverage above.

**Two precision notes the verifiers forced (don't overstate the case):** OpenAI's clause **(g)** about *buying/selling/transferring API keys* is a **loose fit** for subscription-token reuse (a sub token isn't an API key); the load-bearing prohibitions are reverse-engineering, unpermitted extraction, and rate-limit/protection bypass. And the account-sharing ban lives in the **consumer Terms**, not the API Services Agreement.

---

## Part 4 — The extensible provider abstraction ⚠️ (design synthesis)

The design goal is right: **the agent loop must depend on an interface, never on how auth works.** Mature multi-provider systems all converge on the same move — *implement a small interface and register it; never edit core routing*:

- **LiteLLM:** subclass `CustomLLM(BaseLLM)`, implement `completion/acompletion/streaming/astreaming`, register a `{provider, handler}` entry in `custom_provider_map` — consulted *after* built-ins, zero core edits. ([docs](https://docs.litellm.ai/docs/providers/custom_llm_server))
- **Vercel AI SDK:** a `ProviderV4` factory (`languageModel()/embeddingModel()/imageModel()`) whose language model implements two execution methods — `doGenerate` (buffered) and `doStream` (a stream of parts). ([custom providers](https://ai-sdk.dev/providers/community-providers/custom-providers))
- **LangChain:** a fixed output envelope — `AIMessage → ChatGeneration → ChatResult`. ([custom chat model](https://python.langchain.com/docs/how_to/custom_chat_model/))
- **simonw/llm:** `KeyModel`/`AsyncKeyModel` base classes with an abstract `execute()`, contributed through a `register_models` hook, each model annotated with **capability flags** (`vision`, `supports_tools`, `supports_schema`). ([openai_models.py](https://github.com/simonw/llm/blob/main/llm/default_plugins/openai_models.py))

The lesson for swift-claw: split the current single `LLMProvider` into **four orthogonal seams** so "how you get a token" and "how you make a request" vary independently.

```swift
// ── Seam 1: Identity + capabilities (static, Sendable value type) ─────────────
public struct ProviderDescriptor: Sendable, Hashable {
  public let id: ProviderID                 // typed, not a magic string
  public let displayName: String
  public let capabilities: ProviderCapabilities
}

public enum ProviderID: Sendable, Hashable {
  case openAI, anthropic, local
  case openAICompatible(String)             // "groq", "together", …
  case chatGPTSubscription                  // quarantined, opt-in, unofficial
}

public struct ProviderCapabilities: Sendable, Hashable {
  public let streaming: Bool
  public let toolCalling: Bool
  public let vision: Bool
  public let systemPrompt: Bool
  public let maxContextTokens: Int?
}

// ── Seam 2: Authentication — produce the credential to attach to a request ────
public protocol CredentialSource: Sendable {
  func currentCredential() async throws -> Credential   // refreshes if needed
  func invalidate() async                               // called on 401
}

public enum Credential: Sendable, Equatable {
  case none                                             // local models
  case bearer(String)                                  // API key OR OAuth access token
  case header(name: String, value: String)             // e.g. ChatGPT-Account-ID
  case composite([Credential])
}

// ── Seam 3: Secure token/session storage (over swift-claw's existing SecretStore) ─
public protocol CredentialStore: Sendable {
  func load(_ key: CredentialKey) async throws -> StoredCredential?
  func save(_ credential: StoredCredential, for key: CredentialKey) async throws
  func delete(_ key: CredentialKey) async throws
}
public struct StoredCredential: Sendable, Codable {
  public var accessToken: String
  public var refreshToken: String?
  public var expiresAt: Date?
  public var extraHeaders: [String: String]            // e.g. ChatGPT-Account-ID
}

// ── Seam 4: Request execution — existing LLMProvider, now credential-agnostic ─
public protocol LLMProvider: Sendable {
  var descriptor: ProviderDescriptor { get }
  func models() async throws -> [ModelInfo]                            // discovery
  func complete(_ request: ChatRequest) async throws -> ChatResponse   // buffered
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error>
}
```

The **agent loop resolves an `LLMProvider` from a `ProviderRegistry` and calls it** — it never sees `Credential`, `CredentialSource`, or refresh logic. That is the dependency inversion: concrete providers depend on the abstraction, the loop depends on the abstraction, neither depends on the other.

An OpenAI-compatible provider composes seams 2+4 and doesn't care whether the bearer is an API key or a refreshing OAuth token:

```swift
public struct OpenAICompatibleProvider: LLMProvider {
  public let descriptor: ProviderDescriptor
  let baseURL: URL
  let credentials: any CredentialSource      // ← the only auth dependency
  let http: HTTPClient

  public func complete(_ request: ChatRequest) async throws -> ChatResponse {
    var attempt = 0
    while true {
      let cred = try await credentials.currentCredential()
      do { return try await send(request, cred) }
      catch LLMError.unauthorized where attempt == 0 {   // one refresh retry
        await credentials.invalidate(); attempt += 1
      }
    }
  }
}
```

Refresh needs the **single-flight actor** pattern (N concurrent callers collapse to one refresh) — the same "stored `Task` per lane" idiom swift-claw already uses for its per-session turn queue (ARCHITECTURE.md §5; [Donny Wals on async token refresh](https://www.donnywals.com/building-a-token-refresh-flow-with-async-await-and-swift-concurrency/)):

```swift
public actor RefreshingOAuthCredentialSource: CredentialSource {
  private let store: CredentialStore
  private let key: CredentialKey
  private let refresh: @Sendable (StoredCredential) async throws -> StoredCredential
  private var inFlight: Task<StoredCredential, Error>?

  public func currentCredential() async throws -> Credential {
    let current = try await store.load(key)
    if let cred = current, !cred.isExpiring { return cred.asCredential }
    return try await runRefresh(current).asCredential
  }

  private func runRefresh(_ current: StoredCredential?) async throws -> StoredCredential {
    if let task = inFlight { return try await task.value }        // coalesce
    let task = Task { [store, key, refresh] () throws -> StoredCredential in
      guard let current else { throw LLMError.reauthRequired }
      let fresh = try await refresh(current)                      // provider-specific
      try await store.save(fresh, for: key)
      return fresh
    }
    inFlight = task
    defer { inFlight = nil }
    return try await task.value
  }
}
```

**Every backend named falls out as a composition, with no agent-loop change:**

| Backend | `CredentialSource` | `LLMProvider` |
|---|---|---|
| API-key OpenAI / Anthropic / OpenAI-compat | `StaticCredentialSource(.bearer(key))` | `OpenAICompatibleProvider` (base URL swap) |
| Local model (Ollama/MLX) | `StaticCredentialSource(.none)` | `OpenAICompatibleProvider` → localhost |
| Anthropic subscription (`CLAUDE_CODE_OAUTH_TOKEN`) | `StaticCredentialSource(.bearer(token))` | Anthropic provider *(flag ToS)* |
| ChatGPT subscription (reverse-eng) | `RefreshingOAuthCredentialSource` (Codex OAuth + `ChatGPT-Account-ID`) | provider → `chatgpt.com/backend-api/codex` *(quarantined, opt-in)* |
| Official-CLI bridge | `StaticCredentialSource(.none)` | `SubprocessProvider` shelling to `codex`/`claude` |

**Testability & storage, matching swift-claw's conventions:**
- The agent loop takes `any LLMProvider`; unit tests inject a `MockLLMProvider` (canned `complete`/`stream`) — no network, no auth. Refresh logic tests inject a `MockCredentialStore` + a stub `refresh` closure.
- `CredentialStore` is implemented **over the existing `SecretStore` (sops+age)** — not the Keychain, which the launchd daemon can't reach anyway (per CLAUDE.md). Tokens, refresh tokens, and `ChatGPT-Account-ID` live there as `StoredCredential`.
- Everything stays `Sendable`: `ProviderDescriptor`/`Credential`/`StoredCredential`/`ChatRequest` are value types; the only mutable state (in-flight refresh) is confined to the `actor`.

Swift-native prior art for the request/stream layer: [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI/) (its `Configuration` has a `.relaxed` mode precisely for OpenAI-compatible third parties) and [m1guelpf/swift-openai-responses](https://github.com/m1guelpf/swift-openai-responses) (typed streaming client). Both are API-key-only — neither models the auth seam, which is the part swift-claw would add.

---

## Part 5 — Recommendation ⚠️ (design synthesis)

**Build first (the whole "v1"):**
1. Refactor the current `LLMProvider` into the four seams above. Small, mechanical change; the only structural work that matters — do it before adding any second backend.
2. Ship **API-key providers** over the existing OpenAI-compatible contract: OpenAI, any OpenAI-compatible aggregator (OpenRouter/Groq/Together), and **local** (Ollama/MLX) as the same provider with a different base URL. Anthropic via its native API is one more `LLMProvider` conformer.
3. Implement `CredentialStore` over `SecretStore`. Even for static API keys, this gives the seam that OAuth refresh plugs into later for free.

**Defer, behind a feature flag, only if the owner explicitly wants it:**
4. A `RefreshingOAuthCredentialSource` + subscription provider, or a `SubprocessProvider` CLI bridge. Because it's just a composition, it can be added later **without touching the agent loop or the v1 providers** — the entire payoff of doing the abstraction first.

**Avoid:**
- The **reverse-engineered ChatGPT backdoor** (`backend-api/codex` + borrowed `client_id`) — violates OpenAI's terms; the authors themselves warn of suspension/termination.
- **Reusing Claude Pro/Max OAuth tokens** (`CLAUDE_CODE_OAUTH_TOKEN`, session relay) from swift-claw — Anthropic added a ToS clause against exactly this in Feb 2026 and enforces it server-side; **an OpenClaw-class assistant is the named target.** For an always-on daemon you want a *stable and sanctioned* credential, which points back to API keys.
- **Browser cookies / session tokens** — most fragile, highest blast radius, explicitly blocked.

**Why this shape fits swift-claw specifically:** it's headless (launchd) — can't run an interactive browser OAuth at runtime, so a refresh-token-only lifecycle is the *most* it could support even in the deferred case, and that's exactly what the `CredentialSource`/`CredentialStore` split accommodates. It's single-owner — so an API key is trivially the owner's own key, no delegation problem to solve. And it already speaks OpenAI-compatible Chat Completions — so API-key OpenAI/local/aggregator backends are *nearly free* to add once the seams exist.

---

## Open questions

- Whether an inference-scoped `CLAUDE_CODE_OAUTH_TOKEN` evades Anthropic's detection for a personal daemon (don't bet on it).
- Whether OpenAI ever ships the requested official third-party "bring your plan" flow (would change the recommendation if it lands).
- Whether OpenAI's Codex "Sign in with ChatGPT" is even operable for a headless launchd daemon that can't open an interactive browser at runtime (OpenAI's own guidance is to use API keys for headless/CI automation).
- Exact internal provider layers of OpenWebUI/LibreChat/Continue, and the identity of "Hermes" as a subscription-auth project — not source-verified this pass.

---

## Reference index

**OpenAI (primary):** [codex/auth](https://developers.openai.com/codex/auth) · [Help: Codex + ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) · [codex/pricing](https://developers.openai.com/codex/pricing) · [apps-sdk/build/auth](https://developers.openai.com/apps-sdk/build/auth) · [Services Agreement](https://openai.com/policies/services-agreement/) · [Consumer Terms of Use](https://openai.com/policies/row-terms-of-use/) · [Account Sharing Policy](https://help.openai.com/en/articles/10471989-openai-account-sharing-policy) · [openai/codex](https://github.com/openai/codex)

**Anthropic (primary):** [Claude Code authentication](https://code.claude.com/docs/en/authentication) · [Use Claude Code with Pro/Max](https://support.anthropic.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan)

**Ban / subscription-change coverage:** [Natural 20](https://natural20.com/coverage/anthropic-banned-openclaw-oauth-claude-code-third-party) · [MindStudio](https://www.mindstudio.ai/blog/openai-codex-anthropic-subscription-change) · [DEV: Roo Code + Claude Max ban](https://dev.to/robinbanner/roo-code-and-the-claude-max-ban-what-actually-happened-and-how-to-fix-it-5ck4) · [Simon Willison: GPT-5.5 / Codex backdoor](https://simonwillison.net/2026/Apr/23/gpt-5-5/) · [JetBrains × Codex](https://blog.jetbrains.com/ai/2026/01/codex-in-jetbrains-ides/)

**Projects (auth reality):** [Aider](https://github.com/Aider-AI/aider) · [simonw/llm](https://github.com/simonw/llm) · [OpenWebUI](https://github.com/open-webui/open-webui) · [LibreChat](https://github.com/danny-avila/LibreChat) · [Continue](https://github.com/continuedev/continue) · [Cline](https://github.com/cline/cline) · [Roo Code](https://github.com/RooCodeInc/Roo-Code) · [OpenHands SDK](https://github.com/OpenHands/software-agent-sdk) · [OpenCode](https://github.com/sst/opencode)

**Reverse-engineered subscription tools:** [llm-openai-via-codex](https://github.com/simonw/llm-openai-via-codex) · [openai-oauth](https://github.com/EvanZhouDev/openai-oauth) · [opencode-openai-codex-auth](https://github.com/numman-ali/opencode-openai-codex-auth) · [claude-code-proxy](https://github.com/raine/claude-code-proxy) · [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) · [opencode-with-claude](https://github.com/ianjwhite99/opencode-with-claude) · [Meridian](https://github.com/rynfar/meridian)

**Provider-abstraction prior art:** [LiteLLM custom provider](https://docs.litellm.ai/docs/providers/custom_llm_server) · [Vercel AI SDK custom providers](https://ai-sdk.dev/providers/community-providers/custom-providers) · [LangChain custom chat model](https://python.langchain.com/docs/how_to/custom_chat_model/) · [simonw/llm openai_models.py](https://github.com/simonw/llm/blob/main/llm/default_plugins/openai_models.py) · [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI/) · [m1guelpf/swift-openai-responses](https://github.com/m1guelpf/swift-openai-responses) · [Donny Wals: async token refresh](https://www.donnywals.com/building-a-token-refresh-flow-with-async-await-and-swift-concurrency/)
