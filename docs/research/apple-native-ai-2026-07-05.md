# Apple On-Device AI × swift-claw — Integration Research (2026-07-05)

**Feasibility + integration-design layer.** Investigates what Apple's ecosystem provides for local/native LLM, vision, OCR, and embeddings, and how to fold it into swift-claw (a pure-Swift, macOS-primary, launchd-oriented, single-owner Telegram daemon) **without** breaking provider-portability, the Linux build, or the exfiltration gate. Apple-native AI must stay optional and isolated behind protocols.

> **Verification key.** Every material claim carries a status: **✅ STABLE** (in Apple's public docs for the shipping macOS 26 / iOS 26 SDK) · **🟢 2°** (corroborated by reputable non-Apple sources — working OSS, tech press) · **🟠 BETA** (real, but macOS 27 / WWDC26 only — *not on the shipping OS the daemon targets*) · **🟣 SPIKE** (web cannot resolve; needs a hands-on SDK experiment) · **🔴 REFUTED** (contradicted by primary sources). Temporal frame: **July 2026** — macOS 26 "Tahoe" is shipping; macOS 27 is beta.

> **How this was produced.** Three orchestrated research passes, cross-checked against each other and against swift-claw's own source: (1) local WWDC 2026 note mining + a `file:line` map of the provider/tool/taint seams; (2) a web deep-research pass (fan-out search → fetch → 3-vote adversarial verification, 25 sources / 123 claims); (3) a targeted second pass verifying beta claims against Apple's `/tutorials/data/…json` symbol API with 404 negative controls — which caught two first-pass hallucinations (`fm token-count` refuted; `fm serve` unconfirmed). Availability numbers were read from Apple's backing JSON endpoints because the rendered docs are JS-only.

---

## 1. Executive summary

Apple's on-device stack is genuinely useful and callable from plain Swift on the shipping OS — but the on-device **LLM** is a small "summarize / extract / classify" workhorse, not a frontier reasoner, and it is served by a **per-user** system service. That one fact reshapes the whole integration.

**What is realistically possible today (shipping macOS 26):**

- **On-device LLM** — `FoundationModels` gives a ~3B-parameter model with a **4,096-token** context window, guided/structured output (`@Generable`), tool calling, streaming, and safety guardrails. Callable from a plain SwiftPM binary with **no entitlement and no `.app` bundle**. ✅ STABLE
- **Vision OCR / documents / barcodes** — `RecognizeTextRequest`, `RecognizeDocumentsRequest` (tables, QR, data-detectors), `DetectBarcodesRequest`. On-device, offline, headless, **no Apple-Intelligence dependency**. ✅ STABLE
- **On-device embeddings & NLP** — `NLContextualEmbedding` (27 languages), `NLEmbedding`, `NLTagger`. Zero-egress, no entitlement — a natural local memory/RAG primitive. ✅ STABLE

**What is *not* possible or not confirmed:**

- **A full cloud-grade LLM replacement.** 4,096 tokens can't hold swift-claw's system prompt + tool schemas + assembled context + reply. The on-device model is a helper, not the agent's main brain. ✅ (confirmed limit)
- **Running from a true `LaunchDaemon` with no logged-in user.** The model runs in a *per-user* XPC service (`IntelligencePlatformComputeService`) behind a per-user "Apple Intelligence" toggle; every working headless example runs inside a login session. **This is the one load-bearing unknown.** 🟣 SPIKE
- **The WWDC26 provider protocol, Core AI, PCC, image input.** All real, all **macOS 27 beta only** — not adoptable on the OS the daemon targets today. 🟠 BETA

**The decision that gates everything.** swift-claw's `CLAUDE.md` calls itself a *launchd daemon*. On-device FoundationModels is delivered by a per-user service — so it most plausibly requires a **LaunchAgent under an auto-login account, not a system LaunchDaemon**. This is the same class of constraint already behind the project's "a launchd daemon can't use the Keychain" rule. A ~1-hour SDK spike settles it and should run before any Apple-AI code is written.

**Best recommended path.** Do not chase a provider replacement. Add a small, isolated `ClawAppleAI` module behind a narrow internal protocol and land two read-only slices in order:

1. **Local summarize / classify** for memory consolidation and intent routing (internal, off the hot path, tolerant of the 4K window) — a real privacy win: private memory is processed *on-device and never sent to the cloud provider*.
2. **An `image_ocr` Vision tool** so the owner can finally send a photo and get its text — Vision is the lowest-risk Apple surface and drops straight into the existing `Tool` + taint seam with *zero* policy-gate changes.

Everything stays behind `#if canImport(FoundationModels)` + a runtime capability check, so the Linux CI gate stays green and swift-claw remains provider-portable.

---

## 2. Verified Apple capability matrix

Grouped by what swift-claw would actually call. "Daemon/CLI" is the column that matters most: a headless CLI *in a login session* is proven for the whole first group; a true no-session `LaunchDaemon` is the open question marked throughout.

### On-device LLM — FoundationModels

| Capability | Framework / API | OS availability | Daemon / CLI | Streaming | Structured / tools | Privacy | Key limitation |
|---|---|---|---|---|---|---|---|
| On-device text model ✅ | `SystemLanguageModel` · `LanguageModelSession` | macOS 26.0+ / iOS 26.0+ | CLI in session ✓ · daemon 🟣 | `streamResponse` (cumulative snapshots) | `@Generable`/`@Guide` + `Tool` (runs tools *itself*) | On-device, offline, no key | 4,096-token window; ~3B params; summarize-grade |
| Availability gate ✅ | `SystemLanguageModel.default.availability` | macOS 26.0+ | per-user check | — | — | — | `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)` — per-user toggle |
| Token accounting ✅ | `contextSize` · `tokenCount(for:)` | macOS 26.4+ | CLI in session ✓ | — | — | On-device | window rises to **8,192** on macOS 27 / newer devices only |
| Image input (multimodal) 🟠 | `Attachment(image)` in `Prompt` | macOS 27 beta | — | Yes | Yes | On-device | ~200 tokens/image; not on shipping 26 |
| Private Cloud Compute model 🟠 | `PrivateCloudComputeLanguageModel` | macOS 27 beta | app-context; entitlement | Yes | Yes + reasoning (`.light/.moderate/.deep`) | Stateless PCC; iCloud-metered | 32K ctx; needs entitlement + <2M-download app — *out of reach for a personal daemon* |
| Swappable provider protocol 🟠 | `LanguageModel` · `LanguageModelExecutor` | macOS 27 beta (introducedAt 27.0) | open-sourced; Linux "soon" | streaming-first channel | caps: toolCalling/guidedGeneration/reasoning | depends on backing model | not on shipping 26 — but `LanguageModelSession.init(model:)` seam itself *is* 26.0 |

### Vision — image understanding & OCR

| Capability | Framework / API | OS availability | Daemon / CLI | Structured / tools | Privacy | Key limitation |
|---|---|---|---|---|---|---|
| Text recognition (OCR) ✅ | `RecognizeTextRequest` · `VNRecognizeTextRequest` | macOS 15 / 10.15+ | Headless ✓ (CLIs proven) | typed observations | On-device, offline | no Apple-Intelligence dependency |
| Document structure ✅ | `RecognizeDocumentsRequest` · `DocumentObservation` | macOS 26.0+ | Headless ✓ | tables, lists, QR, `detectedData` | On-device | 26 languages; word-level not zh/ja/ko/th |
| Barcode / QR ✅ | `DetectBarcodesRequest` · `VNDetectBarcodesRequest` | macOS 15 / 10.13+ | Headless ✓ | typed observations | On-device | macOS-capable (not iOS-only) |
| Live camera scanner 🔴 | `DataScannerViewController` | iOS 16 / Catalyst only | ✗ no macOS/daemon | — | — | **Unusable** — needs a foreground camera app |

### On-device language & embeddings — NaturalLanguage

| Capability | Framework / API | OS availability | Daemon / CLI | Privacy | Key limitation |
|---|---|---|---|---|---|
| Contextual embeddings ✅ | `NLContextualEmbedding` | macOS 14.0+ | Headless ✓ · asset dl 🟣 | On-device, zero-egress | 27 langs; model assets download on first use |
| Static embeddings + NLP ✅ | `NLEmbedding` · `NLTagger` · `NLLanguageRecognizer` | macOS 10.14–11+ | Headless ✓ (no assets) | On-device, zero-egress | sentence embedding ~7 languages only |

### Custom / local models — Core AI & MLX

| Capability | Framework / API | OS availability | Daemon / CLI | Notes |
|---|---|---|---|---|
| Bring-your-own model runtime 🟠 | `CoreAI` · `AIModel` · `CoreAILanguageModel` | macOS 27 beta (27.0) | Python + CLI headless; Swift? | Real (Apple docs `developer.apple.com/documentation/coreai` + repos `apple/coreai-torch`, `apple/coreai-models`) but 27-only; plugs into `LanguageModelSession` |
| Local LLM server 🟢 | `mlx-lm` · `mlx_lm.server` · `mlx-swift` | any (open-source) | Headless ✓ (persistent server) | OpenAI-compatible `/v1/chat` on :8080; "basic security only — not for production"; `mlx-swift` is the embeddable in-process path |

---

## 3. Feasibility for swift-claw

Rated for the actual runtime: a macOS-primary, long-lived, single-owner Telegram daemon with an OpenAI-compatible `LLMProvider` and a strict taint/exfil model.

| Integration idea | Verdict | Why |
|---|---|---|
| **A. Full on-device LLM provider replacement** | ❌ not recommended | 4,096-token window can't fit instructions + tool schemas + assembled context + reply. Tuned for summarize/extract/classify, not multi-step reasoning. Also inherits the daemon-session risk on the hot path. |
| **B. On-device fallback provider** | 🟢 later, low priority | Viable as *offline degradation* only. Needs a `FallbackRouterProvider` decorator + real impedance work (session-per-call, snapshot→delta streaming, tool-execution ownership). Modest value for a home daemon; defer. |
| **C. Local summarizer / classifier** *(recommended first slice)* | ✅ strong fit | Off the hot path (memory consolidation, intent routing) → 4K window + latency + throttling are non-issues. No Telegram plumbing needed. Direct privacy win: private memory summarized on-device, never egressed. Exercises the daemon path at low stakes. |
| **C-variant. Memory extraction / consolidation** | ✅ strong fit | Exactly what Apple built the on-device model for. Complement with `NLContextualEmbedding` for local semantic recall. Caveat: writing model-derived items to durable memory needs a new provenance value + confirm-gated `/remember`. |
| **D. OCR / document / image tools** *(recommended second slice)* | ✅ strong fit | Vision is the lowest-risk Apple surface (no Apple-Intelligence dependency, long-shipping, headless-proven). Drops into the existing `Tool` + taint seam with zero gate changes. Gated only on building Telegram attachment ingestion. |
| **E. Companion app / XPC bridge** | 🟣 only if the spike fails | If the spike shows FoundationModels truly needs a GUI session, a menu-bar helper (or auto-login LaunchAgent) that owns the session and vends results over local IPC is the escape hatch. Adds a process to supervise; avoid unless forced. |
| **F. Multimodal Telegram attachments** | 🟢 hybrid, later | `ChatMessage.content` is String-only — no wire path to a *remote* vision model. Image→text must happen on-device (Option D) and enter context as fenced text. A remote-vision fallback would require extending the provider contract; not worth it for v1. |

---

## 4. Architecture proposal

Honors two hard constraints from `ARCHITECTURE.md`: all Apple-only code stays out of `ClawCore` (Linux CI gate, Inc-6) and behind `#if canImport`; and the provider must surface proposed tool calls as *data*, never execute them (that would bypass the `ToolPolicyGate`). The spec already reserves a "native adapter" seam (§8/§18) — this fills it.

### New module: `ClawAppleAI`

macOS-only SwiftPM target depending only on `ClawCore`. Holds every `import FoundationModels/Vision/NaturalLanguage`. Nothing here is referenced unconditionally by the core graph.

- **`NativeAICapabilityDetector`** — runtime probe wrapping `SystemLanguageModel.default.availability` + Vision/NL asset status → a `Sendable` capability set. Composition root uses it to decide what to register.
- **`LocalTextModel`** — **narrow internal protocol** (not `LLMProvider`): `summarize` / `classify`. Apple conformer + a Linux "unavailable" default.
- **`AppleFoundationTextModel`** — `LocalTextModel` via `LanguageModelSession` + `@Generable`. Actor-isolated (the session is single-request-at-a-time).
- **`VisionProcessingService`** — wraps `RecognizeTextRequest` / `RecognizeDocumentsRequest` / `DetectBarcodesRequest`; takes a staged file path, returns redacted+capped text.
- **Tools** — `LocalSummarizeTool`, `LocalClassifyTool`, `ImageOCRTool` conform to the *existing* `Tool` protocol; register at `RunCommand.makeToolDispatcher`.

### The narrow local-model seam (recommended first)

```swift
// ClawCore — protocol only, no Apple imports (keeps Linux green)
public protocol LocalTextModel: Sendable {
  var isAvailable: Bool { get async }
  func summarize(_ text: String, instructions: String) async throws -> String
  func classify(_ text: String, into labels: [String]) async throws -> String
}

// ClawAppleAI — macOS-only conformer, isolated behind canImport
#if canImport(FoundationModels)
import FoundationModels
actor AppleFoundationTextModel: LocalTextModel {
  var isAvailable: Bool {
    get async { if case .available = SystemLanguageModel.default.availability { true } else { false } }
  }
  func summarize(_ text: String, instructions: String) async throws -> String {
    let session = LanguageModelSession(instructions: instructions)   // ephemeral, no shared state
    return try await session.respond(to: text).content              // guardrails on in + out
  }
}
#endif
```

### A read-only Vision tool (recommended second) — fits the existing seam untouched

```swift
// Conforms to the SAME Tool protocol as file_read / web_fetch.
struct ImageOCRTool: Tool {
  let definition = ToolDefinition(
    name: "image_ocr",
    description: "Extract text from a staged image the owner sent over Telegram.",
    parameters: /* JSON-Schema: { path: string } — a workspace-scoped path, not bytes */)
  let timeout: Duration = .seconds(20)

  func execute(arguments: JSONValue) async -> ToolPayload {
    let text = (try? await vision.recognizeText(atStagedPath: path)) ?? ""
    return ToolPayload(
      content: ToolOutputCap.cap(SecretRedactor.redact(text)),
      status: .ok,
      ingestedUntrusted: true,   // ← attacker-controllable image → taints the session
      readPrivateData: false)    // ← auto-fenced in <claw-untrusted> by AgentRuntime
  }
}
```

Because `egressTools = {web_fetch, web_search}` (`ToolPolicyGate.swift:7`), a non-egressing tool short-circuits to `.allow` — **no `ToolPolicyGate` change is needed**. Its `ingestedUntrusted: true` flag automatically arms the downstream `web_fetch` trifecta gate. Registration is one line appended to the `tools` array at `RunCommand.swift:259`.

### Wiring, config & portability

- **Composition root** — `RunCommand.makeAgent` (`RunCommand.swift:289`) asks `NativeAICapabilityDetector`; if available, injects the local model into the memory/router services and appends the tools. If not, nothing is registered — the daemon behaves exactly as today.
- **Config discriminator** — add `CLAW_APPLE_AI_ENABLED` (and, if/when Option B lands, `CLAW_LLM_PROVIDER=openai|apple|router` — none exists today; provider selection is currently base-URL-only in `LLMConfig`/`AppConfig.parseLLMConfig`).
- **Cost** — a free local tool/provider must report `costFromProvider = 0`, else `CostResolver` floors it at `$0.000001` (`LLM.swift:298`) and debits the USD breakers for a $0 call.
- **Attachment ingestion (prereq for Option D)** — add `getFile` to `TelegramClient`; capture `file_id` in the wire model (today `TPresence` discards it, `WireModels.swift:27`); download → stage into a workspace scratch path under the §13 canonicalize/scope checks → pass the *path* to the tool (there is no binary channel on `Tool.execute`).

### If you ever adopt the beta provider protocol

An `AppleFoundationModelsProvider: LLMProvider` (`LLM.swift:110`) is a valid future once macOS 27 ships. Three impedance points:

1. **Tool-execution ownership** — `LanguageModelSession` executes registered `Tool`s itself; you must run it *tool-less* and keep tool dispatch in `AgentRuntime` (behind the `ToolPolicyGate`), or build a suspend/capture shim. Letting the framework auto-run tools bypasses the security gate.
2. **Streaming shape** — FoundationModels streams *cumulative snapshots* but `StreamEvent.delta` is *incremental* (`consumeStream` appends) — the adapter must diff snapshot[n] vs snapshot[n-1].
3. **Statelessness** — `LLMProvider` is stateless per call (full `messages` array each time) while a `LanguageModelSession` accumulates a `Transcript` — create an ephemeral session per call seeded from `request.messages` (system→instructions, user/assistant/tool→transcript entries).

---

## 5. Security-model changes

The good news: swift-claw's existing taint model already has the exact hooks. The subtle news: "local" changes the *risk*, not the *code path* — and prompt injection does not go away just because the model is on-device.

### Where Apple-AI outputs sit in the trust hierarchy

- **Treat every Apple-AI output as an untrusted tool observation.** OCR of an owner-supplied image is attacker-controllable text; a local summary of untrusted input inherits that taint (garbage-in). So all three tools set `ingestedUntrusted: true` → auto-fenced in `<claw-untrusted nonce=…>` (`ContextContracts.swift:170`) → `session.tainted = 1` (`RunStoreGRDB.swift:409`). This is identical to how `file_read` and `web_fetch` already behave. **No new plumbing.**
- **The private-data leg.** Today `readPrivateData` is hardwired to `file_read` of `MEMORY.md/USER.md` (`FileReadTool.swift:78`). An OCR of the owner's own screenshot is private-but-inbound; leaving `readPrivateData: false` for v1 is correct — it still taints, it just doesn't on its own arm the `web_fetch` approval unless durable memory is also in context.

### The genuine privacy win — and its limit

**Real upside.** The provider endpoint is itself an **egress sink** (§12): today the full assembled context — including private `MEMORY.md`/`USER.md` — is shipped to the configured cloud provider with no trifecta approval (it is "pinned trusted egress", protected only by base-URL pinning + the redactor). Running *memory consolidation and intent routing on-device* means that private text is summarized/classified **without ever leaving the machine**. That shrinks the "external communication" leg of the lethal trifecta for a whole class of internal work.

**But do not auto-relax the gate.** In current code the trifecta gate keys on `tainted && privateData` for `web_fetch` — *independent of whether the LLM is local or remote*. A local model does not, and should not automatically, relax any `web_fetch` approval: `web_fetch` is still egress regardless of the model's locality. If you ever want "on-device brain ⇒ lighter approvals," make it a deliberate config decision threaded through `ToolDispatchContext` — not an implicit consequence.

### Prompt injection still applies

An on-device model is exactly as injectable as a cloud one — "local" ≠ "safe." Apple's own WWDC26 security session (§347) frames the danger with Simon Willison's **Lethal Trifecta** and states plainly that indirect prompt injection is an *unsolved* problem, recommending **deterministic** mitigations over probabilistic ones. swift-claw's in-code policy gates are already aligned with that philosophy; keep enforcement in code, never in the prompt. Apple's new `.historyTransform` spotlighting/`redactPII` and `.onToolCall` gating (beta) are conceptual cousins of swift-claw's fence + gate — validation that the architecture is on the right track, not something to adopt on the shipping OS.

### Memory provenance

If a local summarizer writes to durable memory, note that `MemorySource` has only `.owner` today (`Memory.swift:29`), and §9.3 forbids folding untrusted tool results into the trusted summary. A model/tool-authored memory item needs a *new provenance case* and must route through the confirm-gated `/remember` flow. Don't let the local model silently write memory.

---

## 6. Implementation roadmap

Staged so the one deployment unknown is resolved before any real code, and so each slice is independently shippable and reversible.

- **Stage 0 — Research validation spike (½–1 day). 🟣** Run the 3-condition experiment: a tiny signed SwiftPM binary printing `SystemLanguageModel.default.availability` + one `respond(to:)`, installed as **(i)** a `LaunchDaemon` with no console user, **(ii)** over SSH in a login session, **(iii)** a `LaunchAgent`. Repeat for a Vision request and an `NLContextualEmbedding` asset download. *Output:* go/no-go + the deployment shape (system daemon vs auto-login LaunchAgent). Verify no-console-user via `stat -f%Su /dev/console == root` and empty `who`. Expected failure mode if it fails: `.unavailable(.appleIntelligenceNotEnabled)` or an XPC "connection invalid / service not found".
- **Stage 1 — Minimal prototype, behind a flag.** Create `ClawAppleAI` + `NativeAICapabilityDetector` + `AppleFoundationTextModel: LocalTextModel`, unit-tested against a stub conformer. A throwaway CLI subcommand runs one summarize end-to-end on the daemon host. Nothing wired into the live turn loop yet.
- **Stage 2 — First production slice (Option C).** `LocalSummarizeTool` / memory-consolidation using the local model, gated by `CLAW_APPLE_AI_ENABLED` (default off). Correct taint, confirmed `$0` cost, availability fallback to no-op. *Tests:* taint propagation, unavailable-path fallback, Linux build stays green.
- **Stage 3 — Second slice (Option D).** Telegram `getFile` + download + workspace staging pipeline, then `ImageOCRTool` (+ optional document/barcode variants). The owner can send a photo and get its text back — fenced and tainted like any untrusted read.
- **Rollback & reversibility.** Capability detector returns unavailable → tools simply aren't registered and the daemon runs exactly as before. `#if canImport(FoundationModels)` keeps non-Apple / Linux builds compiling. Flag off by default; each slice is a clean revert.
- **Later — track, don't build.** When macOS 27 *ships* (not beta): re-evaluate the `LanguageModel`/`LanguageModelExecutor` provider protocol, image input, Core AI custom models, and (if an entitlement path opens) PCC. Optional `AppleFoundationModelsProvider` fallback + `FallbackRouterProvider`.

---

## 7. Risks & open questions

### Confirmed limitations ✅

- **4,096-token on-device window** — disqualifies a full provider role; fine for off-hot-path helpers.
- **Summarize/extract/classify-grade model** (~3B, 2-bit) — not a reasoner; no reasoning on-device (reasoning is PCC-only, beta).
- **Hard prerequisites** — Apple Silicon, Apple-Intelligence-eligible, *enabled in Settings* (per-user), supported region, model asset downloaded.
- **Session is single-request-at-a-time** — must be actor-isolated in a concurrent daemon.
- **`DataScannerViewController` unusable**; **`ChatMessage` is text-only** so remote multimodal is a non-starter — vision must be on-device.

### Unknowns requiring an SDK spike 🟣

- **The big one:** does FoundationModels work from a true `LaunchDaemon` with no login session? Strong prior: *no* — per-user XPC service (`IntelligencePlatformComputeService`) + per-user state under `~/Library/IntelligencePlatform/`. Likely answer: run as a LaunchAgent under auto-login.
- `NLContextualEmbedding` / newer Vision model-asset download inside a daemon (mitigate by pre-seeding assets from a login session, then read-only in the daemon).
- Exact beta symbol spellings if you prototype on 27: `CoreAILanguageModel` module, `xcrun coreai-build` flags, whether `fm serve` exists (unconfirmed — secondary blogs only), `DocumentObservation` `detectedData` property name.

### App Store / signing / entitlement 🟢

- **No entitlement to call the base model** — a plain SwiftPM CLI works (proven by `scouzi1966/maclocal-api`, `presswizards/apfel-Apple-Native-LLM`). Only Apple-Silicon *ad-hoc* code signing (an OS-wide rule) applies. The `com.apple.developer.foundation-model-adapter` entitlement is for *custom adapters only*, not base-model use.
- **PCC is effectively out of reach** for a personal daemon: it needs an entitlement + a <2M-download App-Store app context. Don't design around it.

### Daemon / background constraints

- Background FoundationModels work is **throttled under system load** → catch the retriable rate-limited error and retry. Foreground is unlimited.
- The on-device model is **unpinned** — it updates with the OS. A long-lived daemon may see output drift across point releases (e.g. 26.0–26.3 vs 26.4 model revisions); snapshot prompts/outputs in tests.

### Portability

- Everything Apple is macOS-only / Apple-Silicon-only → must stay behind protocols + `#if canImport`; the Inc-6 Linux CI gate must stay green. On Linux / Intel, all of it falls back to the remote provider automatically.

### Privacy / security

- Apple-AI outputs are **untrusted** (taint). Prompt injection persists on-device. Local processing *reduces* egress but must not *auto-relax* the exfil gate. Model-authored memory needs new provenance + confirm-gating.

---

## 8. Final recommendation

**One preferred path.** Run the ½–1 day deployment spike first. Then add a small, isolated `ClawAppleAI` module behind a narrow `LocalTextModel` protocol and ship, in order: **(1)** on-device *summarize / classify* for memory consolidation and intent routing (Option C), then **(2)** an `image_ocr` Vision read-only tool once Telegram attachment ingestion exists (Option D). **Do not** pursue a full on-device LLM provider replacement (4,096-token window). Treat the WWDC26 provider protocol, Core AI, and PCC as tracked, prototype-on-beta futures — not shipping work.

**Why this and not something bolder.** It's the intersection of high value, low risk, and architectural fit. Option C banks the one thing on-device AI is uniquely good for — keeping private data private — by summarizing the owner's memory *on the machine* instead of shipping it to a cloud endpoint that §12 already classifies as an exfil sink. It needs no Telegram plumbing, sits off the hot path where the 4K window and throttling don't bite, and validates the daemon path at low stakes. Option D then delivers a visible new capability (send a photo → get its text) through Vision, the safest Apple surface, landing in the existing `Tool` + taint seam with *zero* policy-gate changes.

Both slices keep swift-claw honest to its own rules: Apple code stays behind `#if canImport` and a runtime check, the OpenAI-compatible provider remains the primary brain, and the Linux build stays green. You gain a real privacy dividend and a genuinely new user capability without betting the architecture on a 4,096-token model or a beta API — and you find out, cheaply and early, whether the whole thing must run as a LaunchAgent rather than the LaunchDaemon the project currently assumes.

---

## Appendix — sources

Availability facts were read from Apple's backing JSON endpoints (`developer.apple.com/tutorials/data/documentation/…json`) because the rendered docs are JS-only. Anything the web could not settle is marked 🟣 SPIKE rather than asserted.

**Apple primary**
- Docs — `FoundationModels`, `SystemLanguageModel`, `LanguageModelSession`, `SystemLanguageModel.Availability`
- TN3193 — *Managing the on-device model's context window* (4,096)
- Docs — `CoreAI`, `PrivateCloudComputeLanguageModel`, `LanguageModel` / `LanguageModelExecutor`, `LanguageModelCapabilities` (all introducedAt 27.0, beta)
- Docs — `RecognizeTextRequest`, `RecognizeDocumentsRequest`, `VNRecognizeTextRequest`, `DetectBarcodesRequest`, `VNDetectBarcodesRequest`, `DataScannerViewController`
- Docs — `NLContextualEmbedding`, `NLEmbedding`, `NLTagger`, `NLLanguageRecognizer`
- WWDC25 §272 (documents), §286, §301; WWDC26 §241, §242, §324, §326, §334, §339, §347
- Adapter entitlement page (`com.apple.developer.foundation-model-adapter`)

**Apple / partner repos & packages**
- `github.com/apple/coreai-models`, `apple/coreai-torch`, `apple/coreai-optimization`, `apple/foundation-models-utilities`
- `github.com/apple/python-apple-fm-sdk` · PyPI `apple-fm-sdk` v0.2.1 (macOS 26; the native `fm` CLI is macOS 27 beta only)
- `github.com/anthropics/ClaudeForFoundationModels` (v0.1.0, OS-27 beta) · Firebase Gemini `wwdc26-preview`

**Reputable secondary / OSS**
- `huggingface/AnyLanguageModel` (Apache-2.0) — unified session API over Apple FM + OpenAI + Anthropic + Gemini + Ollama + MLX + llama.cpp (best study/adopt candidate)
- `scouzi1966/maclocal-api` (afm, MIT) — headless OpenAI-compatible server over FoundationModels + Vision OCR endpoint; proves no-entitlement/no-app-bundle CLI
- `presswizards/apfel-Apple-Native-LLM`, `1amageek/OpenFoundationModels` (API-shape reference; routes *away* from Apple's model)
- `ml-explore/mlx`, `mlx-lm`, `mlx-swift`, `mlx-swift-lm`
- `zhixian.io` — the `IntelligencePlatformComputeService` per-user XPC architecture

**swift-claw source (integration seams)**
- `docs/ARCHITECTURE.md` §5 (concurrency), §8/§18 (reserved native-adapter seam), §12 (exfil/egress), §17 (Linux gate), §9.3 (memory compaction)
- `Sources/ClawCore/LLM/LLM.swift` (`LLMProvider`:110, domain types:8–101, `ProviderError`:127, `CostResolver`:298)
- `Sources/ClawCore/Domain/Tools/ToolContracts.swift` (`Tool`:206, `ToolPayload`:147), `ToolDispatching.swift`
- `Sources/ClawTools/Policy/ToolPolicyGate.swift:7`, `ExfilArgGuard.swift`, `Tools/FileReadTool.swift`, `Tools/WebFetchTool.swift`
- `Sources/clawd/Subcommands/RunCommand.swift` (`makeAgent`:289, `makeToolDispatcher`:259)
- `Sources/ClawTelegram/Wire/WireModels.swift:27`, `Sources/ClawCore/Domain/Bot/IncomingMessage.swift`, `Sources/ClawCore/Domain/Memory/Memory.swift:29`
