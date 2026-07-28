# Inbound image support — Telegram photo → LLM vision

Research report, 2026-07-28. Repo at `main` (30cf761).

Produced by 10 parallel research lanes (5 over the codebase, 4 over the web) plus an adversarial
completeness critic, then hand-verified on the load-bearing claims. Every `file:line` in this
document was opened. External claims cite a URL or are marked **UNVERIFIED**.

This report describes the decision space. It is not an implementation plan.

---

## 1. What happens today

### 1.1 Bare photo → "I can't read photos yet."

| Step | Code | Effect |
|---|---|---|
| decode | `Sources/ClawTelegram/Wire/WireModels.swift:66` — `let photo: [TPresence]?`, with `struct TPresence: Decodable {}` at `:28` | Telegram's `PhotoSize[]` decodes into **fieldless** structs. `file_id`, `file_unique_id`, `width`, `height`, `file_size` are destroyed at the wire boundary. Only the array's presence survives. |
| classify | `WireModels.swift:74` — `if photo != nil { return "photos" }` | The photo collapses to the string `"photos"`. |
| flatten | `WireModels.swift:83-93` (`toRawMessage()`) | `RawMessage` (`Sources/ClawCore/Domain/Bot/IncomingMessage.swift:65-92`) has no photo field — only `mediaKind: String?` and `voice: VoiceAttachment?`. Nothing downstream can reference the image. |
| normalize | `IncomingMessage.swift:145` | `.unsupported(kind: "photos")` |
| route | `Sources/ClawGateway/Routing/MessageRouter.swift:149-156`, text at `:112-114` | Allowed sender → the canned line. Non-allowlisted sender → `privateBotText` (`:151`): capabilities are never disclosed to strangers. |

The loss happens at *decode*, one layer earlier than a naive read of `toRawMessage()` suggests.

### 1.2 Captioned photo → "I don't see an attached image"

`IncomingMessage.normalize` is an ordered if-chain (`IncomingMessage.swift:138-146`):

```swift
if let text = message.text {          // :138
  content = .text(text)
} else if let caption = message.caption {
  content = .text(caption)            // :141  ← the photo is dropped here
} else if let voice = message.voice {
  content = .voice(voice)             // :143
} else if let mediaKind = message.mediaKind {
  content = .unsupported(kind: mediaKind)   // :145
}
```

The caption branch fires before any attachment branch, so a captioned photo becomes a plain text
message. The doc comment at `:124-128` states this as deliberate: *"A media caption counts as
text … written text always outranks the attachment."* The model receives only the caption and
correctly reports that it sees no image. The observed reply is honest; the normalizer is lossy.

Two live consequences of that branch, both security-relevant:

- **A photo caption is command-parsed.** `.text` goes through `Command.parse` at
  `MessageRouter.swift:164-169`, so a photo captioned `/stop` executes `/stop`.
- **A photo caption can resolve a parked confirmation.** `routePlain` offers plain text to
  `confirmations.resolve` *before* dispatching a turn (`MessageRouter.swift:310-320`). A photo
  captioned "yes" can today confirm a parked `/remember` write (`CommandHandlers.swift:152`), a
  `/memory delete` (`:263`), or a `/schedule` arm (`ScheduleHandlers.swift:78`).

Voice deliberately bypasses both paths (`MessageRouter.swift:191-198`).

### 1.3 This is spec-mandated, not an oversight

Three normative statements authorize today's behavior and must be **rewritten**, not merely
supplemented:

- `docs/ARCHITECTURE.md:226-229` §6.1 step (3b): *"Non-text intake: unsupported type → friendly
  'I can't read X yet'; media caption text IS processed; edited message → flagged isEdited and
  processed as a NEW turn."*
- `docs/ARCHITECTURE.md:432` §8: *"Image input (`image_url` content parts …) is on the near-term
  roadmap, not v1."* Also `:820`.
- `docs/PRD.md:46` (NG8) and `:111-116` (FR-G6).

Two pre-existing doc drifts sit in the same paragraphs and should be folded in: `docs/PRD.md:41`
and `:114` still claim voice notes are not transcribed (voice shipped), and
`docs/ARCHITECTURE.md:820` still lists shipped voice transcription under "Later/optional".

---

## 2. Codebase seams

### 2.1 Telegram wire → domain

| Seam | File:line | Change | Blast radius |
|---|---|---|---|
| `TMessage.photo` | `WireModels.swift:66` | `[TPresence]?` → `[TPhotoSize]?` with real fields, plus a `PhotoAttachment?` picker mirroring `TVoice.attachment` (`:40-50`) | 1 decode site; `mediaKind` (`:74`) unaffected |
| `TVoice` optionality doctrine | `WireModels.swift:30-33` | Every field optional **on purpose**, so a malformed payload degrades to presence-only rather than failing the whole `getUpdates` batch and stalling intake. `TPhotoSize` must follow it. | contract, not a call site |
| `RawMessage` | `IncomingMessage.swift:65-92` | add `photo:` defaulted like `voice:` (`:82`) | 0 |
| `Content` | `IncomingMessage.swift:95-99` | new case | every `switch`: `MessageRouter.swift:148-170` + tests |
| `normalize` | `IncomingMessage.swift:138-146` | attachment must survive a caption | breaks 2 locked-in tests: `Tests/ClawCoreTests/Domain/Bot/NormalizerTests.swift:48`, `:89` |
| download | protocol `Sources/ClawCore/Voice/VoiceContracts.swift:28-30`; impl `Sources/ClawTelegram/Client/TelegramClient.swift:160-206` | The implementation is **already media-agnostic**: `getFile` (15 s) → `isSafeFilePath` (`:196-205`) → bounded GET of `/file/bot<token>/<path>` (60 s) → every error through `sanitize` (`:186`, `:252-256`). Only two log strings say "voice". `CLAUDE.md` (reuse before you add) forbids a parallel `downloadPhotoFile` — rename and generalize. | 1 impl, 1 protocol, ~4 test files |

### 2.2 Routing

`MessageRouter.route` (`:129-171`) computes `accessControl.isAllowed` **once at `:146`, before**
the content switch at `:148` — content-agnostic by construction. A `routeImage` twin of `routeVoice`
(`:173-208`) inherits access gating for free if it preserves the ordering:

1. `guard isAllowed` (`:179-181`) — access outranks service availability, so a stranger never causes
   a byte to be fetched.
2. `guard let service` (`:183-189`) — a nil service yields the canned unsupported line. Fail-closed
   by construction.
3. download.
4. dispatch or reply.

**Preserve: `routeVoice` downloads before any update claim**, so cancellation mid-work leaves the
update unclaimed for redelivery — asserted at
`Tests/ClawGatewayTests/Routing/VoiceRoutingTests.swift:276-297`. `ReplySender.sendCanned` guards
`Task.isCancelled → .transientFailure` (`ReplySender.swift:73-92`) before `claimUpdate`.

### 2.3 The LLM contract — the hard part

| Seam | File:line | Today |
|---|---|---|
| `ChatMessage.content` | `Sources/ClawCore/LLM/LLM.swift:24` | plain `String` |
| Chat Completions wire | `Sources/ClawLLM/Provider/OpenAICompatibleProvider.swift:576` | `WireMessage.content: String?`; encode at `:157-200` |
| Responses wire | `Sources/ClawLLM/ChatGPT/ChatGPTResponsesRequestEncoder.swift:370-373` | `struct ChatGPTWireContent { let type: String; let text: String }` — `text` non-optional, no image variant; `.userText` hardcodes `input_text` at `:331-336` |
| Token preflight | `LLM.swift:251-285` | `ceil(ceil(graphemes/4) * 1.25)` over `message.content` + tool-call JSON |
| Persistence | `Sources/ClawCore/Persistence/Persistence.swift:172-195` (`StoredMessage.content: String`); `Sources/ClawData/Database/ClawDatabase+SchemaV9.swift:27` (`content TEXT NOT NULL`) | no attachment column or table |

**Blast radius of `content: String` → `[ContentPart]`: 147 `ChatMessage(` construction sites across
22 files** — 10 in `Sources/` (`ContextBuilder.swift:490,503,539,547,556,565`;
`AgentRuntime.swift:418,427`; `ScheduleDraftParser.swift:125,126`) and 137 across 19 test files —
plus **10 read sites of `.content` in `Sources/`, all inside the LLM layer**: `LLM.swift:256,398`,
`OpenAICompatibleProvider.swift:167,170`, `ChatGPTResponsesRequestEncoder.swift:111,155-156,183,192,202-203`.

Adding a *defaulted* field instead breaks zero sites — the memberwise init already defaults
`toolCalls`/`toolCallId`/`providerState` (`LLM.swift:29-41`).

**Untouched by design** (verified): `SSEParser`, `ChatGPTResponsesSSEParser` (decodes only
`output_text`), `ChatGPTResponsesAccumulator`, `LLMStreaming` (entirely response-side),
`ChatGPTPromptCacheKey` (digests instructions + tools only, so image bytes cause **no cache-key
churn**), `ChatGPTProviderStateCodec`, `ChatResponse`, `CostResolver`, `Prices.json`. The Chat
Completions route has **one** encode function serving both `complete` (`:57`) and `stream` (`:259`).

### 2.4 Budgets, policy, composition

- `LLMInputReservationPolicy` (`Sources/ClawCore/LLM/LLMAccounting.swift:36-52`) — `.textOnly` vs
  `.replayState(tokensPerByte:framingTokensPerState:aggregateByteCap:)`. **This is the existing seam
  for pricing non-text bytes into the preflight**, folded in unconditionally at
  `ProviderUsageAccountant.swift:133`. It currently inspects only `message.providerState`
  (`:80-81`).
- `docs/ARCHITECTURE.md:430-431` forbids `AgentRuntime`/`ScheduleDraftParser`/scheduler/gateway from
  branching on a provider ID or capability, and `:489` requires *"Capabilities are enforced at
  configuration, before network I/O — never silently degraded at runtime."* Precedent:
  `AppConfig.parseStructuredOutput` throws `ConfigError.structuredOutputUnsupportedOnRoute`
  (`AppConfig.swift:308-330`); pre-flight refusals live in `ChatGPTResponsesProvider.makePlan`
  (`:162-172`).
- Composition template: `DaemonBuilder+Intake.swift:53-85` — sweep staging → `guard
  config.<feature>.enabled` → build engine or log-and-nil → construct service. **Nil at any step
  yields the canned unsupported reply.**

### 2.5 Structural blockers found by the critic pass

Three facts that invalidate otherwise-attractive designs:

1. **There is no in-memory carrier from routing to the turn.** `TurnEnqueuer.enqueue` takes four
   `Int64`s and an optional `Logger` (`Sources/ClawGateway/Turn/TurnEnqueuer.swift:16-22`).
   `TurnRunner.run` re-derives everything from SQLite via `loadTurnInputs` (`:255-288`), and
   `ContextBuilder` rebuilds every `ChatMessage` from `StoredMessage` rows
   (`ContextBuilder.swift:539-565`). "Keep the bytes in memory for the live turn" therefore needs a
   **new component**: an attachment cache keyed by `messageId`, or bytes threaded through the lane
   closure. Boot reconciliation replays PENDING runs from the DB alone, so in-memory-only bytes are
   lost on a crash between `claimAndPersistInbound` and the turn.
2. **`loadTurnInputs` and `ContextBuilder.assemble` are synchronous** (`throws ->`, not `async`).
   Re-fetching an image by `file_id` at assembly time forces network I/O into a deliberately pure
   pipeline, or requires a new prefetch stage.
3. **A "turn" is up to 12 provider round-trips, each re-sending the image.**
   `AgentRuntime.swift:266` — `for roundTripIndex in 1...max(1, budget.maxTurns - priorRounds)` —
   with `RunBudget.default` `maxTurns: 12` (`RunBudget.swift:30`); `var wire` is appended to and
   re-sent every iteration (`:417`, `:426`). All per-turn cost figures must carry a round-trip
   multiplier.

### 2.6 Test doubles to reuse

`docs/TESTING.md:135` requires shared doubles live in `ClawTestSupport`.

`Sources/ClawTestSupport/RecordingHTTPExecutor.swift:51-111` — URL-keyed `HTTPExecuting` actor;
enforces the `.buffered` policy, records `selectedBodyCap`, and fails an over-cap success body
exactly as the real executor does (`:102-104`). Feature-local template:
`Tests/ClawGatewayTests/Support/VoiceDoubles.swift:8-86` — four doubles, one per seam.

**Binary payloads are already a solved problem.** `Tests/ClawTelegramTests/Client/VoiceDownloadTests.swift:23`
uses `Data([0x4F, 0x67, 0x67, 0x53])  // "OggS"` — a four-byte magic-number stub through
`RecordingHTTPExecutor`. A four-byte JPEG SOI stub is equally sufficient and its base64 is
deterministic, so the sanctioned assertion is fully deterministic. Real fixtures exist only for
`ClawAppleSpeechTests` (`Package.swift:163`); `ClawTelegramTests`/`ClawGatewayTests` declare no
`resources:`, so a real `.jpg` fixture would require a `Package.swift` edit.

`docs/TESTING.md:50` makes the key assertion legitimate: Telegram and the LLM are *unmanaged*
dependencies stubbed at their protocol seam, and *"asserting the request we send them is legitimate,
because that request is externally observable."* **Asserting that the outbound `ChatRequest` carries
an image part is a sanctioned test.**

**Blocker for album work:** `RecordingHTTPExecutor` is URL-keyed (`:52`, lookup at `:76`). Two
`getFile` calls for two `file_id`s POST to the *same* URL, so an album test cannot script distinct
responses at that seam. Extending the double (per-URL queue or body matching) is a prerequisite.

---

## 3. External constraints

### 3.1 Telegram (Bot API 10.2, docs fetched 2026-07-28)

| Fact | Detail |
|---|---|
| `Message.photo` | `Array of PhotoSize`; `PhotoSize = {file_id, file_unique_id, width, height, file_size?}`. `file_size` is emitted only when non-zero. |
| ordering | **No documented guarantee.** The reference server sorts ascending by *expected byte size*, tie-broken by w×h (`tdlib/td PhotoSize.cpp`). Do not index `[last]` on faith. |
| server resize boxes | s=100², m=320², x=800², y=1280², w=2560² |
| client encode | long side ≤1280 by default, ≤2560 with the high-quality toggle; JPEG quality 87, progressive (`tdesktop localimageloader.cpp`) |
| EXIF | Stripped **as a side effect** of the client re-encode, not as a documented guarantee. `ComputePhotoJpegBytes` passes original bytes through when the source is already JPEG at ≤4 bpp and was not downscaled ⇒ **EXIF can survive**. iOS/Android encoders UNVERIFIED. Image *documents* preserve EXIF entirely. |
| `getFile` cap | exactly **20 MiB** (`MAX_DOWNLOAD_FILE_SIZE = 20 << 20`). Over-cap ⇒ HTTP 400, `"Bad Request: file is too big"`. |
| link lifetime | *"guaranteed valid for at least 1 hour"*; no expiry timestamp; `file_path` is optional. Cache `file_id`, never `file_path`. |
| token in URL | `https://api.telegram.org/file/bot<token>/<file_path>` — leaking the URL leaks the bot. |
| albums | `media_group_id: String`, unique **inside a chat** ⇒ key any buffer by `(chat_id, media_group_id)`. N items arrive as **N separate Updates** (2–10). **No completeness signal and no item count exist anywhere in the API.** Caption is per-message; official clients put it on one item, but the API permits it on any or every item. |
| documents | `mime_type` and `file_name` are *"as defined by the sender"* — untrusted. `Message.animation` also sets `document`; `Message.live_photo` also sets `photo`, so a plain photo handler covers live photos free. |
| rate limits | Published limits (~1 msg/s per chat, ~30/s broadcast) govern **sending**. **No documented rate limit on `getFile` or on `GET /file/…` exists**; community figures appear nowhere official. Any method can still 429 with `retry_after`. |
| album debounce prior art | `aiogram-media-group` uses a fixed **1.0 s** from the first member. OpenClaw uses `MEDIA_GROUP_TIMEOUT_MS = 500` **with an open bug** (`openclaw/openclaw#1811`) that 500 ms drops members of 4+-photo albums under latency. Prefer a **sliding** window at 1000–1500 ms. |

Bot API 9.x/10.x changed nothing about `PhotoSize`/`Message.photo`/`Document`/`getFile`.

### 3.2 Wire shapes — there are three, not two

**Chat Completions** (`detail: "auto"|"low"|"high"`):

```json
{"role":"user","content":[
  {"type":"text","text":"what's in this image?"},
  {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,/9j/4AAQ…","detail":"low"}}
]}
```

**Responses** (`image_url` is a plain string; `file_id` supported):

```json
{"role":"user","content":[
  {"type":"input_text","text":"what is in this image?"},
  {"type":"input_image","image_url":"data:image/jpeg;base64,…","detail":"high"}
]}
```

**Native Anthropic Messages** — `docs/ARCHITECTURE.md:433` reserves the seam for this adapter, and
its block is neither of the above:

```json
{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"…"}}
```

with `{"type":"url","url":…}` and `{"type":"file","file_id":…}` source variants also supported. Any
content-part model must be validated against **three** encoders or it will need re-cutting.

The URL-source variant corroborates the security rule in §6: Anthropic will natively fetch a remote
image URL, so handing it a `…/file/bot<token>/…` URL really would exfiltrate the bot token.

### 3.3 Anthropic via the OpenAI-compat layer — the shipped default

`.env.example:30-31` ships `CLAW_LLM_BASE_URL=https://api.anthropic.com/v1` +
`CLAW_LLM_MODEL=claude-sonnet-4-6`, i.e. the Chat Completions adapter against Anthropic. Verified at
`platform.claude.com/docs/en/api/openai-sdk` (2026-07-28):

- `type == "image_url"`, sub-field `url`: **"Fully supported"**.
- Sub-field **`detail`: "Ignored"** → the `detail:"low"` cost lever **does not work** on the shipped
  default provider. The only lever there is client-side pixel selection.
- `type == "file"` and `type == "input_audio"`: Ignored. So the Anthropic **Files API** path
  (upload once, reference by `file_id`) is *not* reachable through the compat layer.
- `usage.prompt_tokens`: Fully supported. `usage.prompt_tokens_details`: **Always empty** — no cache
  telemetry on this route.
- *"Most unsupported fields are silently ignored rather than producing errors."* A genuine hazard:
  on this route a malformed image part may be dropped silently rather than rejected.

### 3.4 Vision limits and token cost (verified verbatim, `platform.claude.com/docs/en/build-with-claude/vision`)

> "Claude views images in patches instead of pixels. Each patch is a 28×28-pixel block of the image,
> referred to as a visual token. An image, therefore, costs `⌈width / 28⌉ × ⌈height / 28⌉` visual
> tokens."

| Resolution tier | Models | Max long edge | Max visual tokens |
|---|---|---|---|
| High-resolution | Claude 4.7 and later | 2576 px | 4784 |
| Standard | All other models | 1568 px | 1568 |

`claude-sonnet-4-6` is a 4.6-generation model ⇒ **standard tier, 1568 px / 1568 tokens**.

Also confirmed: formats JPEG/PNG/GIF/WebP, animations unsupported (first frame only); max **10 MB
base64** per image on the Claude API directly (5 MB on Bedrock/Vertex); max dimensions 8000×8000;
>20 images per request triggers a stricter per-image dimension limit (resize each to ≤2000 px);
*"Claude does not parse or receive any metadata from images passed to it"*; *"Image uploads are
ephemeral and not stored beyond the duration of the API request"*; *"Claude works best when images
come before text."*

**OpenAI:** PNG/JPEG/WEBP/non-animated GIF; up to 512 MB total payload and 1500 images per request;
**no per-image byte cap is published** (the widely repeated 20 MB figure is moderation-endpoint-only
— UNVERIFIED as a vision limit). Patch-based models use a `/32` grid with a per-family multiplier;
tile-based models use `base + tiles×tile` after fitting to 2048² and a 768 px short side.

### 3.5 Model capability matrix

| Family | Vision |
|---|---|
| All current Claude models | yes |
| `gpt-5.x`, `gpt-5`, `gpt-4.1`, `gpt-4o`, `o3`, `o4-mini`, codex variants | yes |
| `o1-mini`, `o3-mini`, `gpt-3.5-turbo`, `gpt-oss-120b` | **no** ("Input modalities: text") |
| arbitrary local OpenAI-compatible model | unknown |

**There is no offline oracle for vision capability.** `CLAW_LLM_MODEL` has no default and is
required (`AppConfig.swift:213-218`). `Prices.json` (2392 keys) carries only
`{inputUSDPerMTok, outputUSDPerMTok}` — no modality column. The ChatGPT model catalog parser reads
only `slug`/`priority`/`visibility`/`show_in_picker` (`ChatGPTModelCatalog.swift:166-177`).

The failure signal is also unbranchable: a non-vision OpenAI model returns HTTP 400 with
`"Invalid content type. image_url is only supported by certain models."`, `type:
"invalid_request_error"`, **`code: null`** (community-reported, UNVERIFIED against official docs).
Worse, Anthropic's compat layer *silently ignores* most unsupported fields, so on some routes the
failure mode is a **silent drop** — reproducing today's bug at higher cost.

---

## 4. The ChatGPT-subscription route

**Verified at source level:**

- swift-claw pins `https://chatgpt.com/backend-api/codex/responses` (`LLMRoute.swift:77`) and
  impersonates `originator: codex_cli_rs` (`ChatGPTResponsesProvider.swift:275`).
- The OpenAI Codex CLI — the client being impersonated — **sends images to that exact endpoint**.
  `codex-rs/protocol/src/models.rs`: `ContentItem::InputImage { image_url: String, detail:
  Option<ImageDetail> }` ⇒ `{"type":"input_image","image_url":"data:…","detail":"high"}` inside a
  normal `{"type":"message","role":"user"}` item. `DEFAULT_IMAGE_DETAIL = High`.
- Independent corroboration: `simonw/llm-openai-via-codex` posts `{"type":"input_image","image_url":
  url,"detail":"low"}` to the same base with only `Authorization` + `ChatGPT-Account-ID`, declares
  `attachment_types = {png, jpeg, webp, gif}`, and documents `-a file.jpg` working on a subscription.
- Codex's client-side guards (`image_preparation.rs`, effectively backend constraints): **remote
  http(s) image URLs are rejected** and replaced with a text placeholder; high/auto detail resized to
  max 2048 px / 2500 patches; patch size 32 px.
- The endpoint **fails loud** on a bad content-part discriminant: `400 invalid_request_error`. Bad
  image bytes ⇒ 400 naming `['image/jpeg','image/png','image/gif','image/webp']`.
- `store: false` (`ChatGPTResponsesRequestEncoder.swift:54`) and the body is re-encoded per attempt
  (`ChatGPTResponsesProvider.swift:190-215`) ⇒ **the full history re-uploads on every turn, every
  round-trip, and every retry.** `CanonicalJSON.encode` (`CanonicalJSON.swift:4-16`) copies the body
  ~3×, so a 400 KB base64 image costs ~1.2 MB of transient allocation per encode.
- The auth spec deliberately deferred images:
  `docs/superpowers/specs/2026-07-15-chatgpt-subscription-auth-design.md:1369` lists "images" as out
  of scope; `:729` pins the user shape as `input_text` only.

### 4.1 Live probe — RESOLVED (2026-07-28)

The endpoint was probed directly with a real subscription token. **`input_image` works.**

Method: five controlled requests to `https://chatgpt.com/backend-api/codex/responses`, model
`gpt-5.6-sol`, `originator: codex_cli_rs`, `detail` **omitted**, each paired with an identical
no-image control to separate "the model saw it" from "the model guessed".

| Probe | Image | Answer | `input_tokens` |
|---|---|---|---|
| D | 512×512, four quadrants (TL red, TR green, BL blue, BR yellow) | *"Top-left: red / Top-right: green / Bottom-left: blue / Bottom-right: yellow"* — **all four correct** | 333 |
| E | control, same prompt, no image part | *"Please upload the image so I can identify the colour of each quadrant."* | 25 |
| A | 64×64, left red / right blue | *"Blue fills the frame…"* — wrong | 29 |
| B | control, same prompt as A | *"No image is visible, so I can't identify colours or positions."* | 24 |
| C | 1×1 pure red | *"Mint"* — wrong | 19 |

Findings:

- **Images are accepted, tokenized, and billed.** A vs B is the cleanest measurement: identical
  prompts, +5 input tokens for a 64×64 image — exactly 2×2 = 4 patches on a 32 px grid plus one
  framing token. D vs E: +308 tokens for 512×512.
- **There is no silent drop.** Both controls make the model report the image's *absence* rather than
  invent one, so a wrong answer with an image present is not evidence of a dropped part.
- **A and C were bad tests, not bad results.** A 1×1 image is one patch and a 64×64 is four — the
  model was answering from almost no information. At a realistic size the answer is exact.
- **`detail` can be omitted safely.** Every probe omitted it and succeeded. This sidesteps the
  contested `"low"` value entirely and is the only setting all three wire shapes agree on.
- **The endpoint requires `stream: true`.** A non-streaming request returns
  `400 {"detail":"Stream must be set to true"}`. swift-claw already hardcodes `stream: true`
  (`ChatGPTResponsesRequestEncoder.swift:55`) for both `complete` and `stream`, so this is already
  satisfied.
- **The predicted entitlement error is real**, verbatim: `{"detail":"The 'gpt-5.1-codex' model is not
  supported when using Codex with a ChatGPT account."}` — and it fires *before* body validation, so
  a stale model slug masks any content-shape result. Probe with a slug the account can actually
  reach.

**The recommended preflight reservation is empirically conservative on this route**, which is what
it was chosen for: `⌈w/28⌉ × ⌈h/28⌉` predicts 361 tokens for 512×512 (observed 308) and 9 for 64×64
(observed 5). It over-estimates by ~17% at realistic sizes and never under-reserves.

**Still unknown:** the server-side byte/dimension ceiling for a data-URL `input_image`, and whether
the `models` endpoint exposes a modality flag.

---

## 5. Design forks

### Fork 1 — Content model

| Option | Trade-off |
|---|---|
| **A. `content: [ContentPart]`** | One canonical representation; text/image ordering is expressible, which both providers care about. Cost: 147 ctor sites. |
| **B. Keep `content: String`, add `images: [ImageAttachment] = []`** | Zero breakage. But two parallel channels for one concept — what `CLAUDE.md`'s reuse rule exists to prevent — and no way to express image-before-text ordering. |
| **C. A `MessageContent` value type wrapping parts, with a `String`-taking convenience init** | Canonical parts internally; `ChatMessage(role: .user, content: "hello")` still compiles. Breaks only the **10 read sites**, not the 147 ctor sites. |

**Recommendation: C.** It buys A's single representation at B's blast radius. The 10 read sites are
all in the LLM layer and all need rewriting anyway — they are precisely the encoders and the
estimator. Ship `MessageContent` with a `var text: String` accessor so `ContextBuilder`'s grapheme
arithmetic (`:249-257`, `:452-459`) keeps working unchanged.

**`MessageContent` must not be modeled as user-role-only.** `ToolResultPayload.content` and
`ToolObservation.content` are both `String` today (`ToolContracts.swift:196`, `:216-219`) and
observations render as fenced text into `ChatMessage(role: .tool, …)` (`AgentRuntime.swift:426-435`).
Slice 1 can forbid image parts on `.tool`, but the *type* must permit them — any future
`view_image(file_id)` tool needs it.

### Fork 2 — Storage

| Option | For | Against |
|---|---|---|
| **A. DB blob** | Reuses the `provider_state` recipe: additive `ALTER` on live-FTS `messages` is proven (v5, `ClawDatabase.swift:152-157`, with a blocking test). Free lifecycle via `ON DELETE CASCADE`; free atomicity via the fused `claimAndPersistInbound`; free `SQLITE_FULL → StoreError.diskFull` typing. | **Nothing ever deletes a message row** — the only `DELETE FROM` in `Sources/` targets `memory_items`. `ARCHITECTURE.md:387` claims a retention policy that does not exist in code. DB is unencrypted at rest (`:385`). |
| **B. Store `file_id`, re-fetch on replay** | Tiny row; Telegram is the store. | Blocked by §2.5(2): assembly is synchronous. Plus unknown `file_id` longevity and unknown `getFile` rate limits. |
| **C. Ephemeral — bytes live only in the turn they arrived** | Zero schema change, zero replay cost, zero FTS risk, zero unbounded growth. Matches Anthropic's own ephemeral-upload model. | "What was in that photo?" three turns later degrades — though the assistant's own reply is persisted and usually contains the description. Needs the new carrier from §2.5(1). |
| **D. Disk file + path in DB** | Mirrors voice staging. | Needs retention, quota, and DB↔file orphan reconciliation, none of which exist. Every on-disk media path today is stage → use → delete-in-`defer` plus a wipe-everything boot sweep. |

**Recommendation: C, with a durable `file_id` handle.** Persist `file_id` + dimensions + byte count
in a small nullable column alongside a human-readable placeholder in `content`; carry decoded bytes
in memory for the live turn only. This preserves fused-transaction crash safety (a retry can
re-resolve `file_id`), avoids DB growth entirely, and leaves a clean upgrade path to A.

**Whichever option wins, never put base64 in `messages.content`.** FTS5 indexes exactly that column
(`ClawDatabase.swift:146-150`), so base64 would tokenize into the index and resurface as BM25
"relevant prior conversation", and it would blow the grapheme fitter
(`ContextBuilder.swift:251-256`).

**Option C requires naming its carrier.** §2.5(1) — an attachment cache keyed by `messageId`,
populated in `routeImage` and read in `TurnRunner`, or bytes threaded through the lane closure.
This is a new seam and must be designed, not assumed.

### Fork 3 — Downscaling

| Option | Trade-off |
|---|---|
| **A. Forward Telegram's bytes verbatim** | Zero dependencies, zero decoder attack surface, Linux-clean. EXIF passes through if present. |
| **B. Decode + downscale + re-encode locally** | Guarantees a byte budget and strips EXIF. But no cross-platform codec exists in the dependency set; `ImageIO` is macOS-only, and the voice precedent's macOS-26 floor is exactly what an image feature should avoid, since vision runs provider-side. A decoder is new attack surface with **no sandbox** — the VM sandbox is `execute_code`-only. |
| **C. Select, don't resize** — pick the `PhotoSize` whose declared bytes and pixels fit the budget | **Telegram already downscaled server-side** into five boxes. Choosing among pre-rendered sizes is a free resize. Three lines, no dependency. |

**Recommendation: C.** Order-independent and `file_size`-nil-tolerant: filter to entries with
`file_size == nil || file_size <= budget`, take `max(by: w*h)`, and fall back to `max(by: w*h)` over
the whole array if the filter empties (letting the transport cap reject it). Image *documents* have
no ladder — a separate scope decision.

### Fork 4 — Capability gating

| Option | Trade-off |
|---|---|
| **A. `supportsVision` on `LLMProviderCapabilities`** | Fits the fail-closed-at-config precedent, but it is the **wrong axis**: both routes can carry images, and vision is a property of the model slug, not the route. Costs 4 edit sites for a flag that would be `true` on both. |
| **B. A config knob resolved at composition into an injected value** | Honest that no offline oracle exists. Satisfies `ARCHITECTURE.md:430-431` by injecting a value rather than branching on a capability. Mirrors `CLAW_VOICE_TRANSCRIPTION`. |
| **C. No gate — always send, map the provider's 400** | Burns a turn and a spend event per photo on a text-only model, the 400 has `code: null` so it can only be matched on message text, and Anthropic's compat layer may drop silently instead. |

**Recommendation: B, with C as the backstop.** `CLAW_IMAGE_INPUT` (bool, default **true**, mirroring
`VoiceConfig.swift:20-24`), resolved in `DaemonBuilder+Intake` into a service that is nil when off ⇒
the canned reply, fail-closed by construction. Plus a **distinct** degradation string for a provider
rejection, so the owner learns "your model can't see images" rather than getting silence.

### Fork 5 — Albums

| Option | Trade-off |
|---|---|
| **A. None — N photos = N turns** | Today's shape minus the canned reply. Zero invariant surgery. Observable defect: a 3-photo album yields 3 replies, and the album caption is divorced from the other images. |
| **B. Sliding debounce keyed `(chat_id, media_group_id)`, ~1500 ms, hard cap 10 items, flush as one turn** | Matches expectation. But **collides with the cursor invariant**: `ARCHITECTURE.md:239-244` requires claim+persist in one transaction with the cursor advancing last, and `claimAndPersistInbound` claims exactly **one** `update_id`. One turn spanning N updates needs multi-update claiming — real invariant surgery. Also blocked on the URL-keyed test double (§2.6). |
| **C. Batch replies only** | Halves the annoyance without fixing the caption/image divorce; adds outbox complexity. |

**Recommendation: A for the first slice, B as a designed follow-up.** Prefer sliding over fixed —
OpenClaw's filed bug is precisely a fixed 500 ms window dropping members under latency. Note
honestly that "3 photos → 3 replies" is the most likely user complaint about slice 1.

### Fork 6 — Caption + image merging

| Option | Trade-off |
|---|---|
| **A. `.photo(PhotoAttachment, caption: String?)`** | Minimal; mirrors `.voice`; caption travels with the image. Narrows the "text outranks attachment" rule to voice only — justified, because a transcript and a caption are two texts with no natural merge, whereas photo+caption is a natural pair. |
| **B. Restructure `Content` into `{ text: String?, attachments: [Attachment] }`** | The right long-run model; generalizes to documents and albums. Touches every `switch` on `Content`. |
| **C. Reorder the chain, attachments before caption** | Wrong — drops the caption instead of the photo. |

**Recommendation: A now, B when a second attachment kind lands.**

**Decided, not open:** a photo caption must be **neither** `Command.parse`d **nor** offered to a
parked confirmation. `ARCHITECTURE.md:230-239` already states the rationale normatively for voice —
*"machine-derived, possibly forwarded audio must not steer control paths"* — and the wire captures no
forward metadata for photos either. This is a **behavior change**: today `/stop` under a photo
executes, and "yes" under a photo can confirm a parked `/remember` write.

### Fork 7 — History replay and cost control

| Option | Trade-off |
|---|---|
| **A. Replay every image on every turn** | Max fidelity. Cost × turns × round-trips; on the ChatGPT route also × retries. |
| **B. Replay only in the turn it arrived; older turns degrade to a text placeholder** | Exactly what Codex's `image_preparation.rs` does. Bounded cost. Follow-ups rely on the assistant's own persisted description. |
| **C. Replay newest-first within an aggregate byte budget** | Reuses the documented `LLMReplayStateBounds` pattern (1 MiB/row, 4 MiB aggregate) with `ChatGPTProviderStateCodec.affordable` walking newest-first. |

**Recommendation: C, and it is what shipped in the spec.** B was recommended first, on the reasoning
that it falls out of ephemeral storage and keeps proactive runs free of image cost. That reasoning
was sound and the conclusion was still wrong: B answers a captioned photo but leaves the equally
common photo-then-question flow relying on the assistant's own description instead of the pixels. C
is the correction — newest-first within an aggregate byte budget, reusing the semantics of
`ChatGPTProviderStateCodec.affordable` rather than inventing a second selection algorithm.

The proactive-cost concern C reopens is real but small: a scheduled run assembles the same history,
so a cached image can ride along into an unattended turn. The byte budget bounds it, and the cache is
LRU, so a photo from hours earlier has usually aged out before a 3am job sees it.

**Regardless of choice, the preflight must learn about images.**
`TokenEstimator.estimateInputTokens` (`LLM.swift:251-285`) is grapheme-only, so an image estimates to
**zero** and sails past `budget.maxInputTokens` (100 000) and the per-run USD gate. The seam is
`LLMInputReservationPolicy` (`LLMAccounting.swift:36-52`), already folded in unconditionally at
`ProviderUsageAccountant.swift:133`. **Recommended universal over-estimate: `⌈w/28⌉ × ⌈h/28⌉` capped
at 4784** — Anthropic's exact published formula (§3.4), which strictly over-counts OpenAI's `/32`
grid, so one constant serves every route and errs toward refusing rather than overspending.

Post-call accounting already works: `UsageResolver.resolve` (`LLM.swift:392-400`) trusts
provider-reported usage, and image tokens fold into `prompt_tokens`/`input_tokens` on all routes.

**Proactive runs.** `RunOrigin.isProactive` (`ScheduledJob.swift:6-14`) gates a second, tighter USD
pool inside `BudgetGate.preflight` (`RunBudget.swift:129-135`). Scheduled and heartbeat fires reuse
the same session and the same history assembly, so under any durable-replay option an unattended 3am
job re-uploads stored images against that pool with no owner present. Option B avoids this by
construction — that is a reason to choose it, not an accident.

### Fork 8 — Fallback when the route can't do vision

A three-layer ladder, reusing existing copy machinery (`VoiceAttachment.mediaKindDescription` at
`IncomingMessage.swift:49` is the precedent for sharing the noun between wire and reply, so tests
assert a constant rather than a literal):

1. **Feature off or service nil** → the existing canned line, before any byte is fetched.
2. **Provider rejects the image** → a *distinct* owner-facing line naming the cause, mapped from the
   transport error, never silent. `ARCHITECTURE.md:24` principle 7 and `:760` forbid silence on
   unsupported input.
3. **Never** fall back to caption-only text with the image silently dropped. That is the current bug.

### Fork 9 — Typing indicator during download (new)

A `TypingIndicator` seam exists (`Sources/ClawCore/Transport/TypingIndicator.swift:4`, impl
`TelegramClient.swift:331`) but is pulsed only *inside* the turn (`StreamingTurnRuntime.swift:197`).
`routeVoice` awaits transcription with no pulse (`MessageRouter.swift:191`) — up to a 16 MiB download
plus a 120 s deadline of total silence — and `routeImage` inherits that.

**Recommendation: pulse typing around the fetch, best-effort and non-claiming.** A pulse before
`claimUpdate` must not disturb the deliberate download-before-claim ordering asserted at
`VoiceRoutingTests.swift:276-297`.

### Fork 10 — Edited messages (new)

`normalize` reads `raw.message ?? raw.editedMessage` (`IncomingMessage.swift:131`) and stamps
`isEdited` (`:156`); `ARCHITECTURE.md:227-228` says an edit is processed as a **new turn**. Telegram
delivers a caption edit on a photo as an `edited_message` **carrying the photo array again**, so
under fork 6A a one-character typo fix becomes a second `getFile`, a second download, and a second
vision call.

**Recommendation: dedupe by `file_unique_id`** — it is stable across `file_id` reissues and is
exactly what Telegram documents it for. Skipping attachments on `isEdited` is simpler but loses the
"I meant *this* about the photo" case.

---

## 6. Security

`docs/ARCHITECTURE.md:22` already names attachments: *"Messages, web pages, tool output, attachments
— and durable memory — are data."*

**Provenance and taint — the highest-leverage decision.** `ARCHITECTURE.md:617` taints on
machine-derived inbound text, reasoning that *"the wire captures no forward metadata, so the owner's
own note and forwarded third-party audio are indistinguishable."* The argument transfers **a
fortiori** to images: a forwarded screenshot is indistinguishable from an owner-shot photo, **and**
the injected text inside an image is never materialized in Swift — it is read inside the model, so no
Swift-side sanitizer can ever see it. `:620` is explicit that there is no reliable model-level fix.

Mechanically: `.untrusted` at `claimAndPersistInbound` sets `sessions.tainted` in the same fused
write (`SessionMessageStoreGRDB.swift:86-88`), arming `ToolPolicyGate`'s trifecta leg
(`ToolPolicyGate.swift:64-71`) so a later egress action routes to
`.requireApproval(reason: .exfilTrifecta)` (`:108-114`). **Persisting `.trusted` silently disarms
that gate for the whole session.**

**Recommendation: `.untrusted`, mandatory, no flag.** Accepted cost: image turns drop out of FTS
recall (`RetrieverGRDB.swift:34-37`, `AND m.provenance = 'trusted'`). The "persist the caption as a
separate `.trusted` row" workaround is a spec violation, not an option — `:617` requires the filter
precisely because *"resurfacing one into a later or detainted session would re-ingest
attacker-influenceable content without re-arming the taint flag."*

The image cannot itself be fenced — `<claw-untrusted nonce=…>` (`ContextBuilder.swift:18,554-563`)
is a text construct. **Emit a fenced text part adjacent to the image part** declaring that the
following image is untrusted data, so the labeling layer still holds.

**Approvals: images participate only via taint.** There is exactly one gate call site —
`ToolPolicyGate.evaluate` from `GatedToolDispatcher.dispatch` (`ToolPolicyGate.swift:391`) — whose
input is a model-proposed `ToolCall`. An approval binds `tool + canonicalArgsJSON + argsHash +
canonicalTarget` (`ToolApproval.swift:77-102`), a shape an inbound photo cannot fill.

**EXIF and GPS.** §12 has **no metadata clause** — this decision must be made explicitly. Facts:
Telegram's photo path strips EXIF as a side effect of the client re-encode, except the
already-JPEG-at-≤4-bpp passthrough branch; iOS/Android encoders UNVERIFIED; image **documents**
preserve EXIF entirely; Anthropic states it does not parse or receive image metadata; OpenAI makes no
such statement. §12 `:618` classifies the LLM endpoint as a real egress sink with *"no 'reply to
owner DM ⇒ exfil-free' exemption."*

**Byte caps.** Copy the two-stage pattern from `VoiceMessageService.swift:88-101`: the free
declared-metadata guard first (`PhotoSize.file_size` exists for exactly this, though it may be nil),
then the same ceiling handed to the transport as ground truth. `VoiceContracts.swift:11-14` documents
why both are needed: *"the ground-truth check behind the cheap declared-metadata guard, which a
forwarded voice note can forge."* Transport enforcement is `AsyncHTTPExecutor.collect`
(`Sources/ClawTelegram/Wire/HTTPExecuting.swift:139-167`), which stops mid-stream and throws
`oversizedBody(cap:)`. `HTTPResponseBodyPolicy` (`Sources/ClawCore/Transport/HTTPExecuting.swift:94-106`)
already states why over-cap success must **fail** rather than truncate: *"a payload handed back short
is indistinguishable from a complete one"* — decisive here, since a truncated JPEG must never reach a
vision model.

Binding cap stack: Telegram `getFile` 20 MiB > repo voice `maxDownloadBytes` 16 MiB > **Anthropic
10 MB base64 ≈ 7.5 MB raw**. Anthropic is the binding constraint for the shipped default config.

**Token in the download URL.** Three controls already hold and must be preserved: nothing wires a
config path to the base URL (`TelegramClient.swift:14` is `private let baseURL: String` and `:22` is
a **defaulted init parameter**, not a compile-time constant — only `CLAW_TELEGRAM_BOT_TOKEN` exists
in `EnvSecretStore.swift:8`, and `RunComposition.swift:61-65` passes the default);
`isSafeFilePath` treats the server-returned path as hostile (`:196-205`); and **downloads ride
`downloadHTTP = clients.tool.executor`** (`RunComposition.swift:67-71`), the `.protectedEgress`
profile with `redirectConfiguration = .disallow`. The plain `.telegram` profile **does** follow
redirects, so routing downloads through `.tool` is what stops a `Location:` header walking the token
onto an arbitrary host. `SSRFGuard` is correctly not involved — its only consumer is `WebFetchTool`,
which takes a model-chosen URL.

**The Telegram file URL must never be handed to an LLM as a remote `image_url`** — base64 only.
Codex rejects remote URLs anyway; Anthropic and OpenAI would happily fetch it.

**Logging.** `SecretRedactor.redact` is `String`-only (`SecretRedactor.swift:16-24`), so nothing
prevents `logger.error("… \(data)")` emitting megabytes. The convention lives in code:
`TurnDispatch.swift:51-60` — *"only the message SIZE is logged, never its text"* — mirrored by voice
as `duration=…s chars=…`. Image logging: `bytes=`, `mime=`, `WxH`, `count=`; never bytes, never
base64, never the download URL.

**Missing rate limiter.** `ARCHITECTURE.md:224-225` mandates step (3a): *"RateLimiter (per-user +
global token bucket; honor retry_after; fail CLOSED)."* A case-insensitive grep for
`ratelimit|token bucket` across `Sources/` and `Tests/` returns **zero hits**; only `BudgetGate`
backstops cost. Images make this materially worse than voice — an album fires up to 10 `getFile`s +
10 downloads + 10 vision inferences in one burst, against an endpoint with no documented rate limit.
A feature-local per-turn image cap is the cheap stopgap.

---

## 7. Cost model

A typical Telegram photo (Desktop default): **1280×960**, JPEG q87, ~150–400 KB. Base64 inflates
~33% ⇒ **~200–550 KB of wire body per image per request**.

**Visual tokens for one 1280×960 photo:**

| Route / model | Formula | Tokens |
|---|---|---|
| `claude-sonnet-4-6` (standard tier, shipped default) | `⌈1280/28⌉ × ⌈960/28⌉ = 46 × 35 = 1610`, over the 1568 cap ⇒ server downscales | ≈ **1,568** |
| Claude 4.7 and later (high-res tier) | 1610 < 4784, 1280 < 2576 px ⇒ no resize | **1,610** |
| `gpt-5.4`/`5.5` (patch `/32`) | `40 × 30 = 1200`; non-mini multiplier assumed 1.0, UNVERIFIED | **1,200** |
| `gpt-5-mini` / `gpt-5-nano` | ×1.62 / ×2.46 | 1,944 / 2,952 |
| `gpt-5` (tile, high detail) | 1024×768 ⇒ 4 tiles; `70 + 4×140` | 630 |
| `gpt-4o-mini` (tile, high) | `2833 + 4×5667` | **25,501** |

**Per user message, not per request.** One user message is a *run* of up to 12 provider round-trips
(`AgentRuntime.swift:266`, `RunBudget.swift:30`), each re-sending the whole wire array
(`:417`, `:426`). Using `Prices.json` (`claude-sonnet-4-6` = $3/MTok in):

| Scenario | Image tokens | Cost |
|---|---|---|
| 1 photo, 1 round-trip | 1,568 | $0.0047 |
| **1 photo, 1 run (12 round-trips)** | **18,816** | **$0.056** — 11% of `perRunUSD` from a single image before any tool output |
| 10-photo album, 1 round-trip | 15,680 | 15.7% of `maxInputTokens` in one shot |
| 10-photo album, full run | 188,160 | exceeds `maxInputTokens` (100 000) — the run degrades mid-way |
| 1 photo replayed across a 10-run session (fork 7A) | 188,160 | $0.56 |
| Same, fork 7B (replay-once) | 18,816 | $0.056 |

`RunBudget` defaults: `maxTurns` 12, `maxInputTokens` 100 000, `perRunUSD` $0.50, `perDayUSD` $10.00,
`dayTokenCeiling` 666,666.

Note `gpt-4o-mini`'s 25,501 tokens/image: a single album would exceed `maxInputTokens` outright,
which is exactly why the reservation must be wired into the preflight rather than discovered
post-hoc.

**Prompt caching.** On Anthropic, adding images invalidates the **messages tier only** — the tools
and system caches survive, so a photo does *not* invalidate the system/`USER.md`/`MEMORY.md` prefix.
Tail placement is still right, to avoid invalidating earlier turns. On OpenAI, cache hits require an
exact prefix match and *"applies to images and tools, which must be identical between requests."*
`ChatGPTPromptCacheKey` digests instructions + tools only, so image bytes cause **no cache-key
churn** on that route.

---

## 8. Minimal first slice

"A bare or captioned photo from the owner reaches a vision model and gets answered."

1. Real `TPhotoSize` (all fields optional, per the `TVoice` doctrine) + a `PhotoAttachment` picker
   that filters by declared bytes and takes max pixels; `RawMessage.photo`, defaulted.
2. `IncomingMessage.Content.photo(PhotoAttachment, caption: String?)`; narrow the "caption outranks
   attachment" rule to voice only; update the two locked-in normalizer tests.
3. Generalize `VoiceMediaFetching.downloadVoiceFile` into a media-agnostic `downloadFile` on a
   renamed seam — the implementation is already generic.
4. `ImageMessageService` as a `VoiceMessageService` twin: declared-size guard → download →
   **magic-byte sniff** (JPEG `FF D8 FF`, PNG `89 50 4E 47`, GIF `47 49 46 38`, WEBP `RIFF….WEBP`) →
   in-memory attachment. Typed `Failure` enum with per-case `ownerReplyText`.
5. `routeImage` twin of `routeVoice`: access → availability → download → dispatch as `.untrusted`,
   **before** any update claim; bypassing `Command.parse` and the confirmation resolver.
6. The attachment carrier from §2.5(1): an LRU cache bounded by count and bytes, keyed by the
   persisted **row id** (`SessionMessageStoreGRDB.swift:110`, already threaded through
   `TurnDispatch.swift:46` into `TurnEnqueuer`) — the same identifier space as
   `SessionContextSnapshot.historyMessageIds`, which is what lets a *history* row still carry its
   image. `TurnRunner.run` is `async` (`:100-105`) and calls the synchronous `loadTurnInputs` at
   `:126`, so the lookup slots in before it; `ContextBuilder.assemble` stays pure and synchronous,
   receiving a plain `[Int64: ImagePart]`. Entries survive their run and age out by LRU pressure.
7. `MessageContent` parts on `ChatMessage` + image encoding in both adapters. **A single-text-part
   message must still serialize `content` as a JSON string, not a one-element array**, so every
   existing text turn is byte-identical on the wire.
8. `LLMInputReservationPolicy` image case using `⌈w/28⌉ × ⌈h/28⌉` capped at 4784 — measured
   conservative on the live ChatGPT route (§4.1).
9. `CLAW_IMAGE_INPUT` (bool, default true) + a nil service when off.
10. **No persistence change.** Because the cache is in-memory, `StoredMessage.content` stays `String`,
    the DB never sees bytes, base64, or a `file_id`, and there is no v10 migration. The stored row
    holds the caption or a stable `[photo]` marker; `assemble` renders the image part and its
    adjacent fenced `<claw-untrusted>` text part, and degrades to an "attached photo no longer
    available" marker whenever the cache no longer holds it — evicted, over budget, or lost to a
    restart. The `file_id` column earns its place only when surviving a restart matters enough to pay
    for a migration and a `getFile` round-trip per run.
11. Typing pulse around the fetch, best-effort and non-claiming.
12. Doc lockstep: `ARCHITECTURE.md:226-229,432,820`, `PRD.md:41,46,111-116,114`, plus the
    user-visible set (`README.md`, `docs/GETTING_STARTED.md`, `docs/INSTALL.md`,
    `docs/CUSTOMIZATION.md`, `deploy/README.md`) for the new env var. ARCHITECTURE is amended
    **before** code lands.

**Explicitly out (YAGNI):** album batching and multi-update claiming; image documents; stickers,
animations, `video_note`, `paid_media`, stories; `reply_to_message` photo resolution (`TMessage` has
no `reply_to_message` field at all today — recursive decode); local re-encode/downscale/EXIF strip;
DB blob storage and retention machinery; `detail` tuning (ignored by Anthropic anyway); Files API
paths; a moderation pre-pass; a per-model vision capability table; re-fetch-on-replay; multiple
images per turn beyond a hard cap of 1.

**Outbound images are a separate feature, not a variation of this one.** `TelegramTransport`
(`Sources/ClawCore/Transport/TelegramTransport.swift:43-51`) exposes `getMe`/`sendRichMessageDraft`/
`sendChatAction`/`setMyCommands` plus `MessageDelivery`/`CallbackResponding` — no `sendPhoto`, no
`sendDocument`, no `InputFile`, and a grep for `multipart` across `Sources/` returns nothing. Sending
a chart back from `execute_code` needs a whole new multipart path.

---

## 9. Scope decisions

Settled by the owner on 2026-07-28:

1. **Durability** — a bounded in-memory LRU cache scoped to the process, not the run. Revised the
   same day: replay-once was chosen first and then rejected, because it leaves the
   photo-then-question-as-a-separate-message flow half-working — the follow-up would be answered from
   the assistant's own description rather than from the pixels. Replay is bounded newest-first within
   an aggregate byte budget, reusing the semantics of `ChatGPTProviderStateCodec.affordable`. Bytes
   still never reach the database and there is still no migration; they simply do not die with the
   run.
2. **Albums** — out. N photos remain N turns in the first slice.
3. **Image documents** — refused with "resend as a photo".
4. **EXIF** — residual leak accepted and documented. No codec dependency; refusing documents removes
   the case where EXIF definitely survives.
5. **Routes** — **both** the OpenAI-compatible Chat Completions route and the ChatGPT subscription
   route are supported. Both are now verified to carry images (§3.3, §4.1).

Settled by code or spec, never open: command parsing and confirmation resolution (a caption bypasses
both, per `ARCHITECTURE.md:230-239`); provenance (`.untrusted`, mandatory); the gate default (on, per
`VoiceConfig.swift:20-24`); doc lockstep (mandated by `CLAUDE.md`).

Deferred, flagged not asked: the **missing RateLimiter** (`ARCHITECTURE.md:224-225`, zero grep hits).
The first slice ships a feature-local cap of one image per turn as the stopgap rather than blocking
on the real limiter.

---

## 10. Contradictions and unverified items

**Resolved during verification:**

- The `⌈w/28⌉ × ⌈h/28⌉` patch formula was flagged as unverified by the critic pass. It is
  **published verbatim** at `platform.claude.com/docs/en/build-with-claude/vision` (§3.4, fetched
  2026-07-28). Confirmed.
- The high-resolution tier label was also challenged. Anthropic's own table reads *"Claude 4.7 and
  later models"*. Confirmed as originally written.
- `ARCHITECTURE.md` §6.1 step (3b) is at **`:226-229`**, not `:232-235`. Lines 232-239 are the
  *voice-note* paragraph and must not be edited for this work.
- `TelegramClient`'s base URL is a **defaulted init parameter** (`:22`), not a compile-time constant.
  The conclusion holds — nothing wires a config path to it — but the mechanism is "no knob exists",
  not immutability. The genuinely compile-time-constant case is the ChatGPT endpoint
  (`LLMRoute.swift:77`).
- The claim that images invalidate the whole Anthropic prompt-cache prefix is **wrong**. Images
  invalidate the messages tier only.

- The ChatGPT subscription route was probed live (§4.1) and **accepts `input_image`**. `detail` is
  omitted rather than resolved — the contested `"low"` value is simply never sent.

**Still UNVERIFIED:**

- The server-side byte/dimension ceiling for a data-URL `input_image` on the ChatGPT route.
- OpenAI's per-image byte cap; the patch multiplier for non-mini OpenAI models (assumed 1.0 in §7);
  `detail:"low"` token cost on patch-based models.
- **`Prices.json` has no `gpt-5.6` entries**, so the models this account can actually reach (`sol`,
  `terra`, `luna`) fall through to estimated rather than priced cost. Pre-existing and independent
  of images, but images raise the stakes. Worth its own issue.
- Whether iOS/Android Telegram clients use the same 1280/2560 bound and quality 87, and whether their
  encoders strip EXIF.
- Whether the ChatGPT `models` endpoint exposes a modality flag.
- Telegram `file_id` longevity for `getFile` re-resolution.
- Whether `api.telegram.org` enforces an undocumented rate limit on `GET /file/bot<token>/…`.
- `ARCHITECTURE.md:387`'s claimed retention policy for the message archive **does not exist in
  code**, and `sessions.summary_ref` has no reader and no writer anywhere.

**Coverage gap:** the prior-art lane (OpenClaw / Hermes image-intake patterns beyond the media-group
timeout constant, and cross-platform Swift image codecs) died on a connection error and was not
re-run. It bears only on forks 3 and 5, both of which are recommended toward the no-dependency
option, so the gap does not block a decision.
