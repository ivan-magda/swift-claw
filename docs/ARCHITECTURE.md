# swift-claw — Architecture

| | |
|---|---|
| **Status** | Normative technical spec (v1 scope approved) |
| **Date** | 2026-06-15 |
| **Owner** | Ivan Magda |
| **Related** | [`PRD.md`](./PRD.md) · [`TESTING.md`](./TESTING.md) · research: [impl-grounding](./research/swift-claw-impl-grounding-2026-06-15.md), [best-practices](./research/swift-claw-best-practices-2026-06-15.md) |

> Clean-room, original implementation. References OpenClaw/Hermes/teleclaw concepts only; copies no code.

> **Authority.** This document is the NORMATIVE technical spec. The load-bearing contracts below — §5 concurrency lane, §6.1 inbound sequence, §6.4 outbound outbox, §7 Store API + FSM tables, §9 context assembly — are authoritative and binding on the implementation. Where the `research/` sketches and this spec disagree, **this spec wins**. The PRD references this document for the technical contracts (notably §9 context assembly).

---

## 1. Guiding principles

1. **One reused agent loop behind thin surfaces.** A single agent runtime; Telegram is the only surface in v1, but it sits behind a normalized message envelope so other surfaces could be added.
2. **Local-first long-running daemon as control plane.** One supervised process owns connectivity, state, policy, and scheduling.
3. **The harness acts, the model proposes.** Deterministic code validates/authorizes/executes/records every side effect.
4. **Enforce policy in code.** Risk levels, allow/deny, approvals, rate limits, budgets, quiet hours are checked by the runtime, not the prompt.
5. **Untrusted inbound.** Messages, web pages, tool output, attachments — and durable memory — are *data*. A strict instruction hierarchy is applied in code; untrusted data is wrapped/labeled and can never claim system authority.
6. **Secure-by-default, fail-closed.** Dangerous tools off; consequential actions approval-gated; numeric-ID default-deny; access checks and rate limiters deny/throttle on internal error rather than failing open.
7. **Stop and ask, never go silent.** Every failure mode (provider outage, budget exhaustion, storage full, unsupported input) produces a plain-language user-facing message, never silence or a raw error/stack.
8. **Boring & legible.** Small, well-bounded modules; a layered dependency DAG; a pure domain core; heavy use of Swift value types + actors.
9. **Portable, pragmatically.** macOS-primary; Linux-clean is a soft guideline through the early increments, hardened by a **macOS + Linux GRDB/FTS5 build+test CI gate live on every PR** (`ci.yml`, §17). Portable protocol seams are kept throughout.

## 2. System context

```
                 ┌─────────────────────────────────────────────┐
   Telegram  ───►│  swift-claw daemon (clawd)                   │───► LLM endpoint — one of two
   (Bot API,     │                                              │     wire routes behind LLMProvider:
    long-poll)◄──│  ServiceGroup supervises:                    │◄───
                 │   • TelegramPollerService (intake)           │     (a) configured OpenAI-compatible
                 │   • SchedulerService (ticker)        [Inc4]   │         (OpenAI/OpenRouter/Groq/
                 │   • (future services)                        │          Ollama/LiteLLM…), static key
                 │                                              │     (b) ChatGPT Codex Responses at a
                 │  owns: routing · access control · sessions · │         FIXED endpoint, subscription
                 │  agent runtime · memory · outbox · tools/    │         OAuth credential  [P-auth]
                 │  approvals · scheduler · audit · shutdown    │
                 └───────┬───────────────────────┬─────────────┘
                         │                        │
              ┌──────────▼─────────┐   ┌──────────▼───────────────┐
              │ SQLite (GRDB, WAL) │   │ ~/.swift-claw/workspace  │
              │ sessions/messages/ │   │ SOUL/AGENTS/USER/TOOLS/  │
              │ runs/usage/audit/  │   │ MEMORY.md, memory/*.md   │
              │ outbox/memory/...  │   │ skills/<name>/SKILL.md    │
              └────────────────────┘   └──────────────────────────┘
                         │
              ┌──────────▼───────────────┐
              │ ExecutionBackend (sandbox)│  [Inc5b]
              │ apple/container (macOS)   │
              │ microVM/Podman (Linux)    │
              └───────────────────────────┘
```

The Telegram client is a deliberate **thin clean-room implementation** over AsyncHTTPClient. The research's *primary* recommendation was `nerzh/swift-telegram-bot`; the thin client was its **runner-up**. We choose it deliberately for clean-room provenance, zero bus-factor on an external maintainer, and full control over transport, escaping, and the long-poll/offset durability contract. The committed surface is ~8–10 endpoints (see §18), not "~5."

State root: `~/.swift-claw/` (DB, secrets, logs) + `~/.swift-claw/workspace/` (identity/memory/skills). Profile override via `~/.swift-claw-<profile>/`.

## 3. Component architecture (modules)

SwiftPM package `swift-claw`. Module prefix `Claw`; daemon binary `clawd`. The dependency graph is a **layered DAG**, not a star: stores are reached through **protocols declared in `ClawCore`**, so `ClawAgent` and `ClawGateway` depend only on `ClawCore` for persistence (concrete `ClawData` is injected at the composition root in `clawd`). The rule generalizes: **seams live in `ClawCore`, implementations in sibling targets, composed at `clawd`** — e.g. `WorkspaceReading` is a `ClawCore` protocol; concrete `FileSystemWorkspace` (`ClawWorkspace`) is injected at the root.

```
clawd
  └─ ClawGateway ─────────────┐
        ├─ ClawAgent ─────────┤
        ├─ ClawTelegram ──────┤
        │    └─ ClawHTTP ─────┤
        ├─ ClawLLM ───────────┤
        │    └─ ClawAuth ─────┤
        ├─ ClawTools ─────────┼──► ClawCore  (protocols + value types; depends on nothing)
        ├─ ClawMCP ───────────┤
        ├─ ClawWorkspace ─────┤
        ├─ ClawSecrets ───────┤
        ├─ ClawExec ──────────┤
        │    └─ ClawSubprocess ┤
        └─ ClawData (concrete store impls; conforms to ClawCore store protocols)
              (injected only at the clawd composition root)

claw-eval (internal executable target; not declared in Package.products)
  └─ ClawEvaluation ──► the same ClawCore/ClawHTTP/ClawSubprocess runtime seams
```

| Target | Kind | Responsibility | Key types |
|---|---|---|---|
| `ClawCore` | lib | Pure domain: value types, config model, **error taxonomy** (§19), **store protocols**, tool/provider/credential/transport/sandbox protocols, the **provider-neutral route, credential, replay-state, accounting, and stream-lifecycle contracts** (§8), the shared **HTTP seam** (`HTTPExecuting`/`HTTPStreaming`/`HTTPResult`, request + response headers — F16), and the 32 768-char `ReplySplitter`. No I/O. | `IncomingMessage`, `SessionKey`, `Principal`, `AppConfig`, `RunState`, `ApprovalState`, `RiskLevel`, `RunBudget`, `HTTPResult`, `HTTPRequest`, `HTTPStreamExchange`, `BoundedAsyncChannel`, `ReplySplitter`, `LLMProviderID`, `LLMProviderDescriptor`, `ResolvedLLMRoute`, `LLMEgressIdentity`, `LLMRequestAuthorization`, `LLMEventStream`, `ProviderExchangeState`, `ProviderCallID`, `LLMCostPolicy`, error taxonomy types; protocols: `LLMProvider`, `LLMCredentialSource`, `LLMCredentialStore`, `ChannelIntake`, `MessageDelivery`, `TelegramTransport` (composite), `HTTPExecuting`, `HTTPStreaming`, `SecretStore`, `ExecutionBackend`, `Tool`, `SearchProviding`, `MessageStore`, `SessionStore`, `RunStore`, `AllowlistStore`, `UpdateCursorStore`, `OutboxStore`, `UsageStore`, `AuditLog`, `MemoryStore`, `ApprovalStore`, `WorkspaceReading` (+ its value types `WorkspaceFile`, `LoadedFile`, `SkillScanResult`) |
| `ClawData` | lib | GRDB persistence: schema, `DatabaseMigrator`, store implementations. WAL. **Thin `Sendable` wrappers over `any DatabaseWriter`** (not actors guarding the pool); relies on GRDB serialization. | `Database`, concrete `…Store` types conforming to the `ClawCore` protocols |
| `ClawHTTP` | lib | Shared AsyncHTTPClient implementation of the `ClawCore` HTTP seams plus client-wide redirect and decompression profiles. It contains no Telegram-, provider-, or experiment-specific policy. | `AsyncHTTPExecutor`, `HTTPClientProfile` |
| `ClawTelegram` | lib | Thin Bot API client over AsyncHTTPClient; long-poll loop; envelope normalization; **`sendRichMessage` (markdown) + plain `sendMessage` fallback**; `sendChatAction`. (Escaping/splitter live in `ClawCore`.) | `TelegramClient`, `TelegramLongPoller`, `MessageEnvelope`, `InputRichMessage` |
| `ClawAuth` | lib | ChatGPT protocol metadata + device-code OAuth, model catalog, the refreshable credential actor, and one CLI-neutral workflow per auth command. Depends only on `ClawCore`, so no auth concept reaches the agent loop. | `ChatGPTProviderMetadata`, `ChatGPTDeviceAuthorization`, `ChatGPTOAuthClient`, `ChatGPTCredentialSource`, `ChatGPTModelCatalog`, `AuthLoginWorkflow`, `AuthStatusWorkflow`, `AuthLogoutWorkflow`, `AuthBootstrap` |
| `ClawLLM` | lib | **Both wire adapters behind one `LLMProvider`** (§8): OpenAI-compatible Chat Completions + ChatGPT Codex Responses (translation, SSE reconstruction, replay filtering, attempt exposure, retry engine); the OpenAI-shaped message model; the static credential source; usage/cost; retries; **SSE streaming (v1)**; the provider stack factory. Depends on `ClawAuth`. | `OpenAICompatibleProvider`, `ChatGPTResponsesProvider`, `ChatGPTResponsesRequestEncoder`, `ChatGPTResponsesSSEParser`, `ChatGPTProviderStateCodec`, `ProviderAttemptExposure`, `StaticLLMCredentialSource`, `ProviderStackFactory`, `ChatMessage`, `ChatRequest`, `ChatResponse`, `ToolCall`, `Usage`, `CostTable`, `SSEParser` |
| `ClawSecrets` | lib | Concrete secret backends + the encrypted **provider and MCP credential maps** and their crash-aware publication protocol (§15). | `EncryptedFileSecretStore`, `EnvSecretStore`, `SecretStoreResolver`, `EncryptedLLMCredentialStore`, `EncryptedMCPCredentialStore`, `SecretStatePaths`, `SecureFilePublisher`, `RuntimeSecretPreparer` |
| `ClawWorkspace` | lib | Identity/memory files (`SOUL/AGENTS/USER/TOOLS/MEMORY.md`, `memory/*.md`, `skills/*`), Yams frontmatter, MCP catalog loading, caps + untrusted-tier injection. | `WorkspaceStore`, `WorkspaceFile`, `MemoryDoc`, `FrontmatterParser`, `MCPConfigLoader` |
| `ClawTools` | lib | Tool registry + read-only tools (v1); policy gate + approval orchestration arrive in the P-tools phase (Inc 5a). | `ToolRegistry`, `ToolContext`; `WebSearchTool`, `WebFetchTool`, `FileReadTool` (v1); `PolicyGate`, `ApprovalCoordinator` [Inc5a] |
| `ClawMCP` | lib | MCP **client** (§10.3): the Streamable HTTP transport over the shared HTTP seam, one session per configured server, catalog resolution, metadata redaction, name/schema normalization, and the `Tool` adapter that puts a remote tool on the same seam as a built-in. Depends only on `ClawCore` + the official Swift SDK, so no MCP concept reaches the agent loop or the policy gate. | `MCPStreamableHTTPTransport`, `MCPServerSession`, `MCPCatalogResolver`, `ResolvedMCPCatalog`, `MCPMetadataSanitizer`, `MCPTool`, `MCPToolNamer`, `MCPSchemaNormalizer` |
| `ClawSubprocess` | lib | Shared low-level process infrastructure: the package-internal fixed-path adapter with bounded concurrent stdout/stderr capture, stdin forwarding, caller-supplied environment-key removal, timeout, cancellation, and process-group teardown; plus the hardened cross-process instance lock. It contains no container-specific policy. | `SubprocessRunning`, `SwiftSubprocessRunner`, `SubprocessCommand`, `SubprocessResult`, `InstanceLock` |
| `ClawExec` | lib | macOS 26 arm64 execution implementation: apple/container argv and ambient container-environment sanitization, disposable scratch, serialized VM lifecycle, probe/reap/canary maintenance. Linux supplies no backend until Inc 6. | `ContainerBackend`, `ExecSandboxSettings` |
| `ClawAppleSpeech` | lib | macOS 26 on-device speech-to-text behind the `ClawCore` `VoiceTranscribing` seam (`SpeechAnalyzer`/`SpeechTranscriber`, idempotent model-asset provisioning). Compiles to an empty module on Linux (`#if canImport(Speech)`); the factory returns nil there, fail-closed to the canned reply. | `AppleSpeechTranscriber`, `SystemVoiceTranscriber` |
| `ClawAgent` | lib | Agent runtime: context assembly, the run loop, budgets, cancellation, and the per-session lane. It also owns the package-internal empty context and typing collaborators used by internal evaluation and shared test support; their protocol seams remain in `ClawCore`. | `AgentRuntime`, `ContextBuilder`, `RunBudget`, `SessionActor`, `EmptyMemoryStore`, `EmptyRetriever`, `NoopTypingIndicator` |
| `ClawGateway` | lib | Wiring: `ServiceGroup`, Services, routing, access control, session resolution, outbox dispatch, shutdown. | `Gateway`, `TelegramPollerService`, `SchedulerService` [Inc4], `Router`, `AccessControl`, `RateLimiter`, `OutboxDispatcher` |
| `ClawEvaluation` | lib | Internal deterministic validation harness: frozen-input orchestration, isolated worker attempts, receipts, restart boundaries, and result publication over the production provider and infrastructure seams. It is not part of the daemon or a public SDK. | `EvaluationController`, `EvaluationWorker`, `EvaluationLiveFreezeVerifier`, `EvaluationPageExperiment` |
| `claw-eval` | internal exe target | Thin CLI entry for the scheduled-task learning validation harness. It remains locally buildable so its source closure and frozen binary can be verified, but is deliberately absent from the manifest's declared `Package.products` and from installation/release documentation. | `ClawEvalCommand` |
| `clawd` | exe | Thin entry: load config + secrets → acquire startup lock → build ServiceGroup → run. | `main` |
| `*Tests` | test | One suite per lib; `MockTransport`, `MockProvider`, in-memory DB. (Real `ClawTools` mocks introduced when read-only tools land in Inc 3.) | — |

Each unit answers: *what does it do, how is it used, what does it depend on.* `ClawCore` depends on nothing, so the domain, protocols, and error taxonomy are trivially unit-testable.

`SearchProviding` is a `ClawCore` protocol; the default backend is Exa (`https://api.exa.ai/search`, a pinned trusted endpoint and documented trust dependency like `base_url`, including Exa's right to use query input/output to provide/improve its services). `Secrets.searchApiKey` keys it; unconfigured means the tool is absent and doctor reports info, not an error.

### 3.1 Code map — where each section lives in the code

The durable spec→code link runs **from this document to the code**, by stable symbol name (symbol
names are refactoring-tracked; line numbers and section coordinates are not). Code comments do not
cite section numbers back; where a constant or case would read as a bug without a pointer, the full
form `ARCHITECTURE.md §N` is used, sparingly.

| Spec section | Implementing symbols (target) |
|---|---|
| §3 Internal evaluation harness | `EvaluationController`, `EvaluationWorker`, `EvaluationLiveFreezeVerifier`, `EvaluationPageExperiment` (ClawEvaluation); `ClawEvalCommand` (claw-eval) |
| §4 Process & runtime | `RunCommand`, `RunComposition`, `EnvironmentLoader`, `DaemonBuilder`, `AuthCommand`, `FatalProcessTerminator` (clawd); `InstanceLock` (ClawSubprocess); `Daemon`, `DeveloperLogging`, `DaemonRuntimeBundle`, `RuntimeShutdownCoordinator`, `LaneAdmissionShutdownService` (ClawGateway); `AuthBootstrap`, `AuthMutationCoordinator` (ClawAuth); `AsyncHTTPExecutor`, `HTTPClientProfile` (ClawHTTP); `RuntimeHTTPClients` (ClawTelegram) |
| §5 Per-session lane | `SessionLaneRegistry`, `SessionActor`, `ProviderDeadlineCoordinator` (ClawAgent); `TurnEnqueuer`, `TurnDispatch` (ClawGateway) |
| §5.3 Run budget | `RunBudget` (ClawCore); `BudgetBreaker` (ClawGateway) |
| §6.1 Inbound lifecycle | `MessageRouter`, `AccessControl`, `TurnRunner` (ClawGateway); `SessionMessageStore.claimAndPersistInbound` (ClawCore/ClawData) |
| §6.1 Voice intake | `VoiceAttachment`, `VoiceTranscribing`, `MediaFetching`, `VoiceConfig`, `VoiceTranscriptArbiter` (ClawCore); `TVoice`, `TelegramClient.downloadFile` (ClawTelegram); `VoiceMessageService`, `MessageRouter.routeVoice` (ClawGateway); `AppleSpeechTranscriber`, `SystemVoiceTranscriber` (ClawAppleSpeech); `ContextBuilder.untrustedUserLabel` fencing (ClawAgent) |
| §6.1 Image intake | `PhotoAttachment`, `PhotoSize`, `ImagePart`, `ImageMediaType`, `ImageBounds`, `ImageMarkers`, `ImageReplaySelection`, `ImageConfig` (ClawCore); `TPhotoSize`, `TMessage.photoAttachment` (ClawTelegram); `ImageMessageService`, `ImageCache`, `MessageRouter.routeImage`, `TurnDispatch.imageCache`, `TurnRunner.attach` (ClawGateway); `ContextBuilder.userMessage` (ClawAgent) |
| §6.2/§6.5 Tool & approval flow | `ToolPolicyGate`, `GatedToolDispatcher` (ClawTools); `ApprovalWaiter`, `ApprovedActionExecutor`, `ApprovalCallbackHandler`, `ApprovalCoordinator`, `DeferredApprovalParker`, `ApprovalBootReconciler`, `ApprovalExpiryService` (ClawGateway) |
| §6.3/§14 Scheduler | `SchedulerService`, `HeartbeatSettings`, `ScheduleSurface`, `ScheduleDraftParser` (ClawGateway); `OccurrenceCalculator`, `OccurrencePolicy`, `ScheduleDraft` (ClawCore) |
| §6.4 Transactional outbox | `OutboxDispatcher`, `OutboxSignal`, `ReplySender` (ClawGateway); `OutboxStore` (ClawCore); `OutboxStoreGRDB`, `OutboxDedupKey` (ClawData); `ReplySplitter`, `ContentHash` (ClawCore) |
| §7 Persistence | store protocols under `ClawCore/Persistence/`; `ClawDatabase` (migrator + `classifyError`), `MappedDatabase`, `…GRDB` stores (ClawData) |
| §8 LLM provider | `LLMProvider`, `ChatRequest`/`ChatResponse`, `MessageContent`, `CostResolver`, `UsageResolver` (ClawCore); `ProviderErrorClassifier` (ClawLLM) |
| §8.1 Route selection | `LLMProviderID`, `LLMProviderDescriptor`, `LLMProviderCapabilities`, `LLMProviderRegistry`, `ResolvedLLMRoute`, `LLMEgressIdentity`, `SessionTraceID` (ClawCore); `ProviderStackFactory`, `ProviderStack` (ClawLLM) |
| §8.2 Credential seam | `LLMCredentialSource`, `LLMRequestAuthorization`, `LLMCredentialGeneration`, `LLMCredentialRejection`, `LLMCredentialStore`, `StoredOAuthCredential` (ClawCore); `StaticLLMCredentialSource` (ClawLLM); `ChatGPTCredentialSource`, `ChatGPTProviderMetadata`, `ChatGPTTokenMetadata`, `ChatGPTCredentialFreshness` (ClawAuth); `EncryptedLLMCredentialStore` (ClawSecrets) |
| §8.3 ChatGPT Responses route | `StreamingTerminalValidationPolicy` (ClawCore); `ChatGPTWireValues`, `ChatGPTDeviceAuthorization`, `ChatGPTOAuthClient`, `ChatGPTModelCatalog`, `AuthLoginWorkflow`, `AuthStatusWorkflow`, `AuthLogoutWorkflow`, `ModelSelection` (ClawAuth); `ChatGPTResponsesProvider`, `ChatGPTResponsesRequestEncoder`, `ChatGPTResponsesSSEParser`, `ChatGPTResponsesAccumulator`, `ChatGPTPromptCacheKey` (ClawLLM) |
| §8.4 Streams & attempt exposure | `LLMEventStream`, `LLMStreamTermination`, `ProviderFailure`, `ProviderFailureAccounting`, `ProviderInferenceCancellation`, `HTTPStreamExchange`, `HTTPTransportFailure`, `BoundedAsyncChannel` (ClawCore); `ProviderAttemptExposure`, `ChatGPTResponsesAttemptEngine` (ClawLLM) |
| §8.5 Provider replay state | `ProviderExchangeState` (ClawCore); `ChatGPTProviderStateCodec` (ClawLLM) |
| §8.6 Reliability & cost | `ProviderCallID`, `ProviderCallIDGenerating`, `LLMCostPolicy`, `LLMInputReservationPolicy` (ClawCore); `OpenAICompatibleProvider`, `SSEParser`, `PriceFileLoader` (ClawLLM) |
| §9 Memory & context | `ContextBuilder`, `BudgetFitter`, `DropMarker`, `MemoryRanker`, `CandidateCapRecallCutoff`, `HistoryHygiene`, `LabeledContextFactory`, `EmptyMemoryStore`, `EmptyRetriever` (ClawAgent); `WorkspaceReading`, `WorkspaceSkills`, `SkillDescriptor`, `SkillScanResult`, `WorkspaceWarning`, `FrontmatterFence` (ClawCore); `FileSystemWorkspace` (ClawWorkspace); `SkillDiagnostics` (ClawGateway) |
| §10 Tool system & policy | `ToolRegistry`, `FileReadTool`, `FileWriteTool`, `MemoryWriteTool`, `WebFetchTool`, `WebSearchTool`, `SkillLoadTool` (ClawTools); `Tool`, `ToolDefinition`, `RiskLevel`, `ToolDispatching`, `ToolFenceLabels`, `WorkspacePathContainment` (ClawCore) |
| §10.3 MCP client | `MCPStreamableHTTPTransport`, `MCPServerSession`, `MCPCatalogResolver`, `ResolvedMCPCatalog`, `MCPServerOutcome`, `MCPMetadataSanitizer`, `MCPTool`, `MCPToolNamer`, `MCPSchemaNormalizer`, `MCPDescriptionCap`, `MCPValueBridge`, `MCPDiscoveryLimits`, `MCPTransportLimits` (ClawMCP); `MCPConfig`, `MCPServerConfig`, `MCPToolFilter`, `MCPHTTPHeader`, `MCPLimits`, `MCPNaming`, `MCPConfigError` (ClawCore); `MCPConfigLoader` (ClawWorkspace); `EncryptedMCPCredentialStore`, `MCPCredentialLoad`, `SealedCredentialFile` (ClawSecrets); `MCPBootInputs`, `MCPProbe`, `MCPSessionFactory`, `MCPDoctorRows`, `MCPCommand`, `MCPSessionLifecycleService`, `DaemonBuilder.resolveMCPStack` (clawd) |
| §11 Approval system | `Approval`, `ApprovalFSM`, `PendingToolAction`, `RecordedToolAction` (ClawCore); `ApprovalStoreGRDB` (ClawData); the §6.2/§6.5 gateway symbols above |
| §12 Security & trust | `SecretRedactor`, `SSRFGuard`, `FakeIPDetector`, `ExfilArgGuard`, `CanonicalURL` (ClawTools); `ToolOutputCap`, `SSEFraming`, `ContextTier` provenance labels, `LabeledContext`, and the `ResolvedAddress`/`CIDR` address vocabulary (ClawCore) |
| §12.1 Group mode | `ChatMode`, `ChatKind`, `TranscriptAuthor`, `ChatMembershipStatus`, `RawChatMemberUpdate`, `SessionKey.telegramTopic`, `SessionMessageStore.claimAndPersistObserved` (ClawCore); `AccessControl`, `AddressingResolver`, `MessageRouter.noteObservedEvent`, `OutboxDispatcher` flood-control holds (ClawGateway); `ToolPolicyGate.groupAskTierVerdict` (ClawTools); `RetrieverGRDB` session restriction (ClawData) |
| §13 Execution / sandbox | `ExecutionBackend`, `SandboxMaintenance`, execution value types, `PreparedToolAction` (ClawCore); `ExecuteCodeTool`, `ExfilArgGuard`, `ToolPolicyGate` dangerous arm (ClawTools); `SubprocessRunning`, `SwiftSubprocessRunner` (ClawSubprocess); `ContainerBackend`, `ExecSandboxSettings` (ClawExec); `SandboxBootstrapper`, `SandboxLifecycleService`, `SandboxHealthRows`, `ApprovedActionExecutor` fill (ClawGateway); `DaemonBuilder.prepareSandbox` (clawd) |
| §15 Config & secrets | `AppConfig`, `MCPConfigSource`, `MCPServerConfig`, `QuietHours`, `StateRootResolver`, `SecretStore` + `LLMCredentialStore` seams (ClawCore); `MCPConfigLoader` (ClawWorkspace); `EncryptedFileSecretStore`, `EnvSecretStore`, `SecretStoreResolver`, `EncryptedLLMCredentialStore`, `EncryptedMCPCredentialStore`, `SecretStatePaths`, `SecureFilePublisher`, `RuntimeSecretPreparer` (ClawSecrets); `AuthBootstrap` (ClawAuth) |
| §16 Observability | `DoctorReport`, `DoctorReporting`, `HealthValue`, `HealthRowsBuilder`, `SkillDiagnostics`, `SchedulerHealth`, `ApprovalsHealthRows` (ClawGateway); `ApprovalsHealth`, `RunsHealth`, `AuditLog` (ClawCore); `AuditLogGRDB` (ClawData); `LLMAuthDoctor` (ClawSecrets); `DoctorHealth`, `MCPDoctorRows`, `MCPProbe` (clawd) |
| §19 Error taxonomy | `ClawCore/Errors/` (`ClawExitCode`, `ConfigError`, `TelegramError`, `StoreError`, `ProviderError`, `ProviderFailure`, `CredentialStoreError` — aliased `LLMCredentialStoreError`); `ClawDatabase.classifyError` → `throws(StoreError)` seam (ClawData); `AuthCommandResultMapper` (ClawAuth) |
| §19.1 Run/approval FSM | `RunFSM`, `ApprovalFSM` (ClawCore) |

## 4. Process & runtime model

- Built on **`swift-service-lifecycle` `ServiceGroup`** (SSWG) over SwiftNIO. The daemon is a **process supervisor**, not a web framework — no listen socket by default (long-polling is outbound), which is the better secure-by-default posture.
- Each long-running concern is a `Service`: `TelegramPollerService` (Inc 0), `OutboxDispatcher` (Inc 1), `SchedulerService` (Inc 4). `ServiceGroup` provides ordered startup and **ordered graceful shutdown** on SIGTERM/SIGINT.
- **Startup cross-process lock.** At boot, `clawd` acquires an advisory `flock` on the state root. A second `clawd` against the same state root **refuses to boot** (distinct non-retryable exit) rather than fighting over `getUpdates`. The recovery runbook records which PID holds the lock.
- **The same lock arbitrates credential mutation.** The running daemon is the **only** process allowed to refresh and save a provider credential, so `clawd auth login` / `clawd auth logout` and `clawd mcp set-token` / `clawd mcp clear-token` acquire that state-root lock and fail with a plain stop-the-daemon message when it is held. `clawd auth status` and `clawd mcp list` / `clawd mcp probe` are **read-only — no lock, no refresh; no network beyond the probe's own** — so they can diagnose a live daemon. Auth subcommands deliberately do **not** load a full `AppConfig`: a narrow bootstrap resolves only the state root (same default and permission policy as daemon config) plus the raw model value, so login works *before* a model is configured and status can diagnose auth while unrelated config is invalid.
- **Distinct startup exit codes.** Config-validation failure and secret-load failure are **distinct non-retryable exit codes**, so a deterministic startup failure (missing/`0600`-wrong age key, bad config) backs off under the supervisor instead of hot-looping. `clawd doctor --check-config` validates config/secrets **without starting the daemon**, and any config/secret error is the first thing it prints.
- **Shutdown choreography:** stop intake → let the in-flight turn finish (bounded) → drain the outbox → flush memory/state → checkpoint DB (bounded; PASSIVE fallback if a CLI read txn is open) → close → exit.
- **Dependent resources close in a fixed order *after* the graph, never underneath it.** `RunCommand` owns the concrete HTTP clients and runs the same sequence on success, signal, and service failure: (1) close lane admission and stop service intake; (2) cancel and await the service graph and every registered lane task; (3) await the credential source's throwing `shutdown()` commit rule (§8.2); (4) close the dedicated LLM client; (5) close the independent Telegram and tool clients. Refresh work therefore has a concrete owner and keeps its transport alive until a token rotation is either persisted or reported failed. A credential shutdown error becomes the run's cleanup failure when no earlier failure exists and is logged only after redaction; client shutdown still runs.
- **A lane-drain timeout is a failure path, not a clean exit.** If the graceful-shutdown duration expires, the lane registry returns the still-active run IDs and a typed fatal cleanup failure. `RunCommand` then **does not** close credentials or clients underneath live tasks: it exits without orderly dependent-resource shutdown and lets process teardown own the remainder, leaving any `RUNNING` row to the boot reconciler (§19.1). Never report that timeout as a clean shutdown.
- **Supervision with throttling:** launchd (`KeepAlive`, `RunAtLoad`, `ThrottleInterval`) on macOS; systemd (`Restart=on-failure`, `RestartSec`, `StartLimitIntervalSec`+`StartLimitBurst`, `TimeoutStopSec`) on Linux. Throttling is documented in the units so a deterministic failure backs off.
- **Logging:** `swift-log` to stdout/stderr; journald/newsyslog handle rotation.

## 5. Concurrency model

### 5.1 Per-session lane (normative)

> **Correctness note (must-read).** Swift actors do **NOT** serialize across `await` — an actor reentrantly admits other calls while a turn is suspended on an LLM/network `await`. **"An actor serializes turns" is FALSE as written.** Ordered-enqueue-to-first-suspension (e.g. `ActorQueue`) orders work only up to the first suspension point and is **insufficient** for the run lane.

The lane mechanism is explicit:

- A `SessionActor` (one per `SessionKey`) holds `var currentTurn: Task<Void, Never>?`.
- Each new turn **chains** after the prior, so a turn runs to completion (across all its own suspension points) before the next begins:

  ```swift
  func enqueue(_ work: @Sendable @escaping () async -> Void) {
      let prev = currentTurn
      currentTurn = Task {
          _ = await prev?.value      // wait out the previous turn fully
          await work()               // run this turn to completion
      }
  }
  ```

- **Default = strict FIFO queue per session.** A plain inbound message **QUEUES** behind the current turn. Cross-session work runs concurrently; within a session, strictly ordered and non-interleaved. User-facing contract: two quick messages produce two in-order, non-interleaved replies.
- **Only `/stop` and `/new` SUPERSEDE.** `/stop` cancels the current turn cooperatively (`RunState → CANCELLED`). `/new` resets the session window, detaints it, and cancels the current turn (`RunState → SUPERSEDED`). A plain message never supersedes. `/new` resolves any pending durable approval as `superseded` (audited, §11) and still clears the session's pending command confirmation entry. `/new` also clears `sessions.has_private_data` in the same detaint transaction (Inc 5a, §12).
- **Cancellation semantics.** Cancellation threads through the run loop and (Inc 2+) streaming + tool execution via structured concurrency (`withThrowingTaskGroup`, cancellation handlers). On cancel: stop further LLM/tool work; any already-sent Telegram chunks remain (they are committed side effects, recorded in the outbox); no orphan `AWAITING_APPROVAL` row is left (the reconciliation sweep / FSM resolves it — §7).
- **The registry owns the turn lifecycle, not just a map of actors.** `enqueue(sessionID:runID:work:)` **atomically** checks an `accepting` state and registers the new task, closing the lookup-then-enqueue race. Shutdown flips that state to `stopping`, rejects racing enqueues with a typed shutting-down result, cancels every queued or running lane task, and awaits all registered tasks; completion unregisters through a `defer`, including cancellation while still waiting on a preceding lane task. **A turn does not unregister until its `LLMEventStream`, if any, has joined** (§8.4) — so "the lane drained" means the provider producer and its nested HTTP exchange actually finished, not merely that they were signaled. Enqueues that win before admission closes are registered and drained. Provider children outside a lane (schedule drafting) use the same loser-draining deadline coordinator below, so their service cannot return while provider work remains.

### 5.2 Dependencies and state

- **`swift-async-queue` is dropped from the locked deps.** The plain actor + stored `currentTurn` Task handle above replaces it (single-owner DM bot → effectively one hot `SessionKey`; cross-session contention is near-empty in v1). It remains a noted escape hatch (§18) to revisit only if measured multi-session ordering/cancellation bugs appear.
- **Swift 6 strict concurrency.** Domain types are `Sendable` value types; mutable state lives in actors. Stores are thin `Sendable` wrappers over `any DatabaseWriter` relying on GRDB's internal serialization — **not** actors guarding the pool. Idempotency uses a single `db.write { }` transaction (§7), not a session-actor DB guard.
- **Backpressure & budgets.** Hard per-run caps (turns/tool-calls/tokens/wall-clock) **and a USD cost ceiling + rolling daily cap** (§5.3 / RunBudget), checked in code before each provider call. On exhaustion the run stops and the owner is told which cap was hit (§19 degradation UX). Which gates a call must clear is a **policy injected at composition**, not a model-name check — a plan-included route skips only the USD gates (§8.6).
- **Streaming channels are bounded and suspending — never unbounded, never lossy.** No `AsyncThrowingStream` may carry HTTP body bytes or LLM events: a full channel suspends its producer rather than dropping a chunk or an event, and cancellation wakes a producer blocked on a full buffer so a join cannot deadlock (§8.4).
- **Deadline races never discard a loser.** Interactive, buffered, and schedule deadline races use nonthrowing child results plus a lock-backed winner state; no throwing task group drops a loser on the floor. A raced-but-successful response still supplies authoritative usage even when the deadline stays the owner-visible outcome, and draft/typing/timer children are drained before the coordinator returns. This prevents both lost accounting and work that outlives its turn.

### 5.3 RunBudget defaults

Concrete, config-overridable defaults for a single-owner daily-driver. These are the pinned numbers the PRD (FR-R3, NFR-Cost) refers to.

| Field | Meaning | Default |
|---|---|---|
| `maxTurns` | LLM round-trips per run | 12 |
| `maxToolCalls` | tool calls per run | 20 |
| `maxInputTokens` | provider-input cap (messages + advertised tool definitions) | 100000 |
| `reservedOutput` / `max_tokens` | mandatory, non-null (doctor rejects null) | 4096 |
| `wallClockDeadline` | per run | 180 s |
| `perRunUSD` | cost ceiling per run | $0.50 |
| `perDayUSD` | rolling daily spend cap (kill-switch + owner DM on trip) | $10.00 |
| `retryBudget` | attempts per request (~10% retry ratio) | 3 |
| `perToolOutputCap` | per-tool output (counted toward next-turn input) | 25000 tokens |
| `referenceUSDPerToken` | pinned cost reference for the offline token breaker | $0.000015 |
| `dayTokenCeiling` | derived hard offline failsafe = `perDayUSD ÷ referenceUSDPerToken` | ≈ 666 667 |

All overridable in config. The **hard offline failsafe is `dayTokenCeiling`** (a per-day token breaker checked before each call, so it trips even when no price is known); the USD caps ($0.50/run, $10/day) are the user-facing limits, enforced best-effort when a price is known. A **run in Inc 1 is exactly one LLM round-trip** — `maxTurns`/`maxToolCalls` exist but stay inert until tools land in Inc 3. `perToolOutputCap` is 25 000 tokens, enforced as its grapheme-domain equivalent 80 000 graphemes via the pinned estimator inverse (Inc 3b). Context assembly reserves the estimated size of the complete advertised tool array before filling message sections, so the final request can fit under `maxInputTokens`; provider-call preflight still estimates that complete request independently.

## 6. Data flow

### 6.1 Inbound message lifecycle — NORMATIVE numbered sequence (Inc 0/1)

The single most safety-critical invariant in the system. **The offset cursor advances LAST, only after the inbound write commits.** Never span the dedup check across an `await`.

```
TelegramPollerService loop:
  (1) getUpdates(offset = lastUpdateId + 1, long-poll timeout, allowed_updates)
       └─ 409 Conflict → DISTINCT typed error (not generic 5xx); surface loudly
          in doctor as "another poller active"; do NOT treat as retryable spin.
  for each update in the batch:
    (2) claimUpdate(update_id):
          INSERT OR IGNORE into processed_updates  ── in a SYNCHRONOUS actor
          critical section (NO await) ── returns inserted: Bool.
          If already seen → SKIP this update. (Reentrancy makes a "have I seen
          this?" check across an await unsafe; the claim is synchronous.)
    (3) normalize → IncomingMessage / callback / unsupported-type.
        AccessControl: numeric userId ∈ allowlist?   [default-DENY; fail CLOSED;
          BEFORE any LLM / tool / expensive work]
            └─ no → minimal "private bot" reply (unknown-sender path, §15); STOP.
    (3a) RateLimiter (per-user + global token bucket; honor retry_after;
         fail CLOSED on store/lock error).
    (3b) Non-text intake: unsupported type → friendly "I can't read X yet";
         a caption outranks the attachment it rides on for EVERY media type
         except a photo — a captioned voice note normalizes to a text turn
         and is never transcribed, and a caption on media we cannot read is
         processed as its text; edited message → flagged isEdited and
         processed as a NEW turn (Inc 1); true /retry answer-replacement is
         deferred to Inc 2 (FR-G6).
         Photo (flag-gated): allowed sender only → one typing pulse →
         choose the rung of Telegram's server-rendered size ladder that fits
         the byte cap (a rung IS the resize; nothing is decoded, scaled, or
         re-encoded here) → download via getFile (bounded, token-redacted) →
         identify the format from the leading bytes, never from the
         sender-declared mime → the photo AND its caption dispatch DIRECTLY
         as ONE untrusted-provenance turn. The caption is NEVER
         command-parsed and NEVER offered to a parked confirmation (a photo
         carries no forward metadata, so the owner's own image and a
         forwarded one are indistinguishable; neither may steer a control
         path); persist marks the message row .untrusted, taints the session
         in the same fused write, and stores a "[photo]" marker as the row's
         only durable evidence that an image was there; assembly renders it
         fenced. No usable rung / undecodable / over cap / download failed →
         a canned reply and no turn. Flag off → a BARE photo gets the same
         canned "can't read photos" reply as before the feature, but a
         CAPTIONED one still dispatches its caption on this same direct
         untrusted path, marker leading and no bytes behind it: the owner's
         question is theirs and is never swallowed by the refusal, and the
         product itself steers them into this flag when their model cannot
         see. One photo per message: an album arrives as one update per
         photo, hence one turn per photo.
         Voice note (flag-gated, macOS 26): allowed sender only → download via
         getFile (bounded, token-redacted) → on-device transcription →
         the transcript dispatches DIRECTLY as an untrusted-provenance turn —
         it is NEVER command-parsed and NEVER offered to a parked confirmation
         (machine-derived, possibly forwarded audio must not steer control
         paths); persist marks the message row .untrusted and taints the
         session in the same fused write; assembly renders it fenced. Engine
         unavailable / flag off → the same canned "can't read voice messages"
         reply as before the feature.
    (4) ONE db.write transaction:
          • persist inbound message (sessions/messages, FK-linked to runs later)
          • record side effects / dedup rows belonging to this update
          • COMMIT
    (5) advance + persist lastUpdateId  ── ONLY after step (4) commits.
        The NEXT getUpdates(offset = lastUpdateId+1) acks the update to Telegram.
  then hand to the SessionActor lane:
       AgentRuntime.runTurn (queued per §5):
         a. ContextBuilder.assemble(...)        [§9 budgeted; truncation markers]
         b. TelegramClient.sendChatAction(typing)   [re-issued ~4s if blocking]
         c. (budget check) LLMProvider.complete / stream(messages)
              [one ProviderCallID per logical round-trip; EVERY exit path joins
               the owning stream before the turn returns — §8.4]
         d. (Inc 5a) tool calls → PolicyGate → run safe / request approval
         e. persist assistant message + its opaque provider state (db.write)
                                                   [COMMIT before send — §6.4]
         f. enqueue outbound chunks (outbox) → OutboxDispatcher sends (§6.4)
         g. recordUsage (idempotent on provider_call_id) + appendAudit (db.write)
```

> **Inc 1 fusion (claim + persist in one write).** Steps (2) and (4) are a single synchronous `db.write` — `claimAndPersistInbound` performs the `INSERT OR IGNORE` dedup claim *and* the inbound-message persist in one transaction (the §7.4/§7.5 idempotency invariant), not two separate commits; the cursor (5) still advances last.
>
> **Why the order matters.** If the offset were persisted *first* (the old diagram), a crash before step 4 commits would resume from the advanced cursor and Telegram would never redeliver — silently dropping messages. Advancing last makes "no missed/dup updates" actually true: a crash before step 4 simply re-fetches and the synchronous `claimUpdate` dedups any duplicate.
>
> **Poison-update policy.** If normalization of one update throws, advance the offset *past* it (never wedge the poller on one bad update), log it, and increment a `dropped_updates` counter surfaced in doctor.
>
> **Inbound image bytes are memory-only.** A photo's bytes never reach the database — no blob column, no migration, nothing on disk. They live in a bounded in-process cache keyed by session and message id, and they outlive the run that stored them so a follow-up question about the same photo still reaches the model as pixels. Entries age out oldest-first once the entry count or the byte ceiling is crossed. A single request replays only what its aggregate byte budget affords, newest first, so an image one turn could not carry is still there for the next. **When a row's marker says photo and no bytes survive** (evicted, dropped by the replay budget, or lost to a restart), assembly appends an explicit "no longer available" notice. That notice sits *outside* the untrusted fence: it is our own statement about system state, not sender-supplied input. The model must never be left answering about pixels it cannot see.
>
> **Step (3a) is aspirational, not implemented.** No rate limiter exists yet: nothing enforces a per-user or global token bucket on intake, and the only bounds on inbound media are structural — one photo per message, one bounded download, and a hard byte cap that refuses rather than truncates. Treat the step as the contract a limiter must satisfy when it lands, not as a description of today's daemon.

### 6.2 Tool & approval flow (Inc 5a/5b)

```
model proposes tool_call
  └─ PolicyGate.evaluate(tool, args)          [risk tier (§10) + allow/deny + sandbox req]
       • read-only/safe → execute (no tap) → observation        [v1 tools live here]
       • ask        → ApprovalCoordinator.request:
                        persist PENDING (approvals) incl. ownerUserId, canonical-args
                          hash, policy_version, random callback nonce, fully-resolved target
                        send inline buttons
                        ├─ approve  (callback path — §6.5) → re-validate args-hash +
                        │            policy_version → execute ORIGINALLY-RECORDED args
                        ├─ reject   → cancel safely
                        └─ expire (approval-expiry ticker, default 1h) → DENY (terminal)
       • dangerous  → absent from the registry unless explicitly enabled in config; once
                        registered, ALWAYS suspend through ApprovalCoordinator (never auto-run),
                        and execute only inside its declared sandbox after approval
       • LETHAL-TRIFECTA GATE (§12): if session.tainted && privileged/egress action,
         FORCE the approval path in code regardless of the tool's own tier.
  └─ AuditLog.append(actor, tool, args-redacted, decision, result-size, ts, run_id, session_id)
```

### 6.3 Scheduler flow (Inc 4)

```
SchedulerService ticks every 60s
  └─ due jobs computed by comparing last_fired_at / next-occurrence to WALL CLOCK
     (not by counting ticks) → robust across sleep/wake clock gaps
       └─ catch-up cap: collapse N missed occurrences into ≤1 delivery (max-age skip)
       └─ confirm-before-arm: a NEW LLM-parsed schedule requires owner confirmation
       └─ run as a reduced-privilege agent turn (no auto-approval; default-DENY — in
          Inc 4, pre-approval-FSM, any would-park approval outcome is an IMMEDIATE
          audited DENY with no pending state; when Inc 5a's FSM lands the same branch
          becomes park-with-timeout → EXPIRED → DENY; may not ingest untrusted web
          content while holding high-sensitivity memory; own daily spend budget)
       └─ deliver result to owner's Telegram DM (via outbox)
       └─ AuditLog: create/execute/cancel/failure
  └─ overlap guards (DB, not flock): per-occurrence compare-and-advance CLAIM (no double-fire of
     one occurrence) + per-session live-run skip (serializes overlapping occurrences).
  └─ doctor exposes last_tick_at / due_count / last_misfire.
```

### 6.4 Outbound delivery — transactional outbox (NORMATIVE, Inc 1)

Exactly-once across the network is **impossible**. We implement an honest **at-least-once outbox** with idempotent completion.

```
table outbound_deliveries(
  run_id, step_index, chat_id,
  dedup_key UNIQUE  = run_id + ':' + step_index,   -- deterministic, NOT UUID/wall-clock
  payload_hash, telegram_message_id NULL,
  status [PENDING | SENT | FAILED], created_ts, sent_ts )

OutboxDispatcher:
  (1) For each ReplySplitter chunk, INSERT OR IGNORE one row with its own step_index
      (each chunk = its own step_index, so a partial multipart send recovers).
  (2) Send via sendMessage (or editMessageText for streaming coalesce).
  (3) On HTTP 200 → UPDATE status=SENT, telegram_message_id=<id>, sent_ts.
  (4) On crash/replay: rows still PENDING are re-sent; INSERT OR IGNORE +
      deterministic dedup_key prevent duplicate rows; a true network double-send
      is the irreducible at-least-once tail.
```

**Two honestly-distinct idempotency mechanisms** (do not conflate them):

- **(a) DB-internal dedup** via `INSERT OR IGNORE` inside one `db.write` txn — true for inbound `update_id`, `provider_usage`, `audit_events`.
- **(b) External side effects** via the transactional outbox — intent committed → effect performed **at-least-once** → completion recorded idempotently.

**Ordering invariant:** the inbound message + the run row **COMMIT before** the outbound reply is sent. So a disk-full/crash stops the turn before an unrecoverable side effect.

### 6.5 Callback (approval) path (Inc 5a)

`callback_query` updates arrive through the **same untrusted `getUpdates` stream** as messages but bypass §6.1 message ordering (they are callbacks). They MUST:

- run the **same numeric-ID default-deny** access check first; **and**
- be honored only if `callback.from.id == approval.ownerUserId` (persisted on the PENDING row);
- carry a `callback_id` that is a **≥128-bit single-use RANDOM nonce bound to the session** — NOT a sequential/PK/counter value;
- get the same audit + rate-limit treatment as messages;
- re-validate the stored canonical-args hash **and** `policy_version` at execution (an approval granted under an old policy cannot execute under a changed one);
- on expiry → DENY, enforced by the approval-expiry ticker (default 1h window, configurable via `approval_expiry`) (`PENDING → EXPIRED → DENY`).

## 7. Persistence & data model

**GRDB.swift v7** (Swift-6 concurrency-native), **WAL**, `DatabaseMigrator` for explicit versioned migrations, FTS5 for recall. One `DatabaseWriter` behind thin `Sendable` store wrappers.

Connection invariants (every connection): `PRAGMA foreign_keys = ON`; `busy_timeout = 5s`; `eraseDatabaseOnSchemaChange = false` (explicit). CLI tools open **read-only short txns** and must not hold a long read that blocks the shutdown checkpoint (bounded with a PASSIVE fallback). Periodic WAL checkpoint policy + a WAL-size signal in doctor.

### 7.1 Tables (introduced per increment)

| Table | Inc | Purpose | Key FKs |
|---|---|---|---|
| `allowlist` | 0 | numeric user IDs permitted (the security boundary) | — |
| `processed_updates` | 0 | claimed Telegram `update_id`s (dedup; synchronous claim) | — |
| `update_cursor` | 0 | last *confirmed* `lastUpdateId` (advanced last, §6.1) | — |
| `sessions` | 1 | session key, created/updated, rolling-summary ref, `tainted` | — |
| `messages` | 1 | role, content (un-redacted by design), session, ts, token counts; provenance marker (trusted/untrusted); **FTS5 external-content index added Inc 3a (not Inc 1)**; **`tool_calls` TEXT (JSON `[ToolCall]`, assistant proposals) and `tool_call_id` TEXT (set iff `role='tool'`), migration `v5`; `role` gains `tool`; tool rows persist with `provenance='untrusted'`**; **P-auth: nullable `provider_state_issuer` TEXT + `provider_state` BLOB under a CHECK that they are both null or both non-null, migration `v9` — opaque replay state (§8.5), never FTS-indexed, never prompt content; existing rows stay valid** | `messages.run_id → runs.id`, `messages.session_id → sessions.id` |
| `runs` | 1 | RunState FSM, budgets used, `updated_ts` lease; **Inc 4: `origin` `'interactive' \| 'scheduled' \| 'heartbeat'` (default `'interactive'` — drives reduced privilege, the proactive budget, and doctor metrics) + nullable `job_id`** | `runs.session_id → sessions.id`, `runs.job_id → scheduled_jobs.id` |
| `provider_usage` | 1 | model (the **qualified `configuredReference`**, §8.1), tokens (incl. cached/uncached where reported), computed USD, `cost_source`, `is_estimated`; **P-auth: non-null `provider_call_id` TEXT + a UNIQUE index, migration `v9` (existing rows get deterministic `legacy:<rowid>` values); `cost_source` admits `included_plan`** | `run_id → runs.id`, `session_id → sessions.id` |
| `outbound_deliveries` | 1 | transactional outbox (§6.4) | `run_id → runs.id` |
| `audit_events` | 1 | **ordinary append-only** audit (actor, action, tool, args-redacted, result-size, decision, ts) | carries `run_id`, `session_id` |
| `memory_items` | 3 | type, content, source/provenance, ts, importance, sensitivity (durable facts; `confidence` deferred, `visibility`→`sensitivity` — Inc 3a) | `session_id → sessions.id` (nullable) |
| `scheduled_jobs` | 4 | `owner_chat_id` (set in code at arm time), `label`, `prompt` (owner-authored, trusted, frozen at confirm), `recurrence` (`{"schema_version":1,"rule":<RecurrenceRule JSON>}`; NULL ⇔ one-shot), `timezone` (IANA), materialized `next_occurrence` (advanced only inside the claim; NULL once terminal; partial index `(status, next_occurrence)`), `last_fired_at`, status FSM `ACTIVE\|PAUSED\|COMPLETED\|CANCELLED`, `session_id` (the job's dedicated session `sched:job:<id>`, NULL until first fire), `created_ts`/`updated_ts` | `session_id → sessions.id` |
| `scheduler_state` | 4 | single row (`id = 1` CHECK): `last_tick_at`, `last_misfire_at`, `last_misfire_skipped_count`, `last_heartbeat_at`, `heartbeat_count_day` (day string in `CLAW_TIMEZONE` — the cap boundary aligns with quiet hours, not UTC), `heartbeat_count`; `due_count` is computed by query, never stored | — |
| `approvals` | 5a | PENDING/APPROVED/REJECTED/EXPIRED (EXPIRED resolves to a DENY outcome at execution), tool + canonical args, **canonical-args hash, policy_version, ownerUserId, random callback nonce**, expiry | `approvals.run_id → runs.id` |

`runs.state = AWAITING_APPROVAL` references `approvals.id` as the **one** canonical source of truth for "blocked on approval" (no ambiguous dual flags).

**Every assistant anchor keeps the provider state produced with it** (§8.5), in the same transaction as the anchor: intermediate tool proposals carry it in `ToolExchange`; a suspended run persists the assistant anchor and its state in the same transaction as the approval checkpoint, and a resumed run loads it back before the next provider call; completed and degraded commits persist it for every executed exchange; the final assistant message persists its state in the same transaction as the usage and outbox rows. **Reading it is lenient, exactly like the existing `tool_calls` history metadata:** a mismatched null pair, a non-blob value, an oversized payload, or adapter-level malformed JSON **drops that optional state while preserving the ordinary message** — it never becomes prompt content and never breaks an otherwise usable session. Actual SQLite failures still pass through the typed store-error mapping (§19); leniency covers the *shape* of an optional column, never a storage fault.

The `approvals` row (Inc 5a) additionally carries `session_id`, `observation_message_id`, `tool_call_id`, `reason` (`ask_tier | exfil_trifecta`), `prompt_message_id`, and `resolved_ts`, and enforces a **UNIQUE partial index `WHERE state = 'PENDING'`** — at most one live approval per run. `outbound_deliveries` gains nullable `approval_id` + `reply_markup` (additive, so pre-upgrade PENDING rows stay valid; the envelope is not smuggled into `payload`): the button prompt travels through the transactional outbox, and when `approval_id` is set `markSent` writes the resulting `telegram_message_id` onto the linked approval's `prompt_message_id` **in the same transaction**.

Synthetic session keys (Inc 4): `sched:job:<id>` (one dedicated session per scheduled job, created lazily at first fire) and `sched:heartbeat`. `sessions` carries no chat id — a job run's delivery/notice target is `scheduled_jobs.owner_chat_id`; the heartbeat's is the config-resolved owner DM. `SessionKey.chatId(from:)` returns nil for both by design, so boot reconciliation resolves crashed-run owner notices for job runs via `scheduled_jobs.owner_chat_id` and for heartbeat runs via the config-derived target passed in at boot (§6.3, spec §5.2/§12).

### 7.2 Audit (Inc 1) — ordinary append-only, NOT tamper-evident

The audit table is an **ordinary append-only** record — genuinely useful for "why did it do that." **Hash-chaining / tamper-evidence / an `audit verify` tool are dropped from v1.** In-DB hash-chaining is *not* tamper-evident against the real threat (a same-host/compromised daemon can recompute and re-seal the chain), so v1 does not claim it. If integrity is added later (post-v1), it MUST use an **external anchor** (sign chain checkpoints with a key outside the daemon's writable scope and/or emit the head hash to an append-only off-daemon sink) and the audit row MUST be written in the **same transaction as the side effect**. Do not claim "tamper-evident" without an external anchor.

### 7.3 FTS5 + data lifecycle

- **External-content FTS5 over `messages`** (avoids duplicating sensitive text; keeps the owner-delete path a single source of truth). The vtable + sync triggers live in migrations — **built in Inc 3a via GRDB's FTS5 builder (`synchronize(withTable:)`, `content_rowid='id'`, `unicode61 remove_diacritics 2`), not Inc 1**. FTS synchronization indexes **only the textual message column**: opaque provider state is never indexed and never recall-eligible (§8.5).
- Content is stored **un-redacted by design**. The database itself is **not** encrypted at rest — only the two secret envelopes are (§15) — so the compensating controls are the `0700` state root and owner-only file modes.
- The owner **data-deletion path also deletes/rebuilds FTS rows**, so deleted content is not recoverable via the index. A `messages` redesign requires an FTS rebuild migration.
- **Export + delete** covers conversation history (not just memory items); a retention/compaction policy bounds the message archive (see PRD FR for export/delete).

### 7.4 Idempotency (summary)

Dedup key + side effect committed in one `db.write` transaction; deterministic keys (not wall-time/UUID); the inbound dedup `claimUpdate` is done **synchronously** inside the owning actor critical section. External side effects go through the **outbox** (§6.4), not a "DB+network in one transaction" claim (impossible). **Vector search** (`sqlite-vec`) is deferred and isolated behind a protocol (§7.6); v1 recall is FTS5/BM25.

**Usage rows dedup on `provider_call_id`** — one locally generated ID per logical provider round-trip, stable across clean wire retries and the stream-to-buffered fallback — **never on a run-wide row-count guard**. That distinction is load-bearing: a terminal commit after cancellation or supersession must still attempt *its own* call's row even when the run already holds usage from an earlier tool round, or the last call of a cancelled multi-round run goes unbilled. When a late row inserts, **the same transaction recomputes the run's denormalized token and USD totals from all of its usage rows**; replaying that terminal commit observes the unique key and changes neither totals nor day budgets.

### 7.5 Store API (Inc 1) — load-bearing signatures

The seam between `ClawData` and the rest. Protocols live in `ClawCore`; `ClawData` implements them.

```swift
// dedup — synchronous claim, no await spanning the check
func claimUpdate(_ updateId: Int64) throws -> Bool        // INSERT OR IGNORE → inserted?

// inbound + assistant persistence share ONE write txn with their dedup/side-effects
func persistInbound(_ msg: IncomingMessage) throws         // db.write { dedup row + message }
func persistAssistant(_ reply: AssistantTurn) throws       // db.write { message + run update }

// outbox
func claimOutbound(runId: Int64, stepIndex: Int, chatId: Int64,
                   payloadHash: String) throws -> Bool      // INSERT OR IGNORE
func markSent(runId: Int64, stepIndex: Int, telegramMessageId: Int64) throws

// usage + audit (each INSERT OR IGNORE in its own/shared write txn)
func recordUsage(_ usage: ProviderUsage) throws
func appendAudit(_ event: AuditEvent) throws

// access (fail closed on store/lock error)
func allowlistContains(_ userId: Int64) throws -> Bool

// confirmed cursor — advanced LAST (§6.1 step 5)
func advanceCursor(to lastUpdateId: Int64) throws
```

All write methods execute inside a single `db.write { }` closure so the dedup key and the side effect share one transaction.

### 7.6 sqlite-vec — deferral honesty

`sqlite-vec` is **not** "add later via a protocol and a migration." It **requires a custom SQLite amalgamation** (`SQLITE_ENABLE_FTS5` **+** sqlite-vec, statically linked, **initialized before the connection opens**) and a **separate Linux-CI re-validation** (GRDB does not test it upstream; the vec binding ships its own connection). A stock `DatabaseMigrator` **cannot** create a `vec0` table. It stays strictly behind a protocol and deferred; risk = High (§18).

## 8. LLM provider abstraction

- **Contract: one domain seam, two wire adapters, and a separate credential seam.** `LLMProvider` — `complete(request:)` + `stream(request:)` — is the **only** model-execution seam `AgentRuntime` consumes. Behind it sit two wire routes: the configured **OpenAI-compatible Chat Completions** route (the supported default) and the **ChatGPT Codex Responses** route (§8.3). **Authentication and wire protocol are separate choices:** credentials resolve through their own `LLMCredentialSource` seam (§8.2), so OAuth never becomes a property of the agent loop and the Responses wire format is never folded into the Chat Completions adapter. Concrete adapters stop at the composition root — `AgentRuntime`, `ScheduleDraftParser`, the scheduler, and the gateway receive `any LLMProvider` and **never branch on a provider ID or a capability**.
- **Internal model is OpenAI-shaped** (`role`/`content`/`tool_calls`), doubling as the Chat Completions wire format — minimal translation; the Responses adapter owns its own translation and never leaks it upward. **Content is ordered parts** (text and image), modeled for every role rather than just `.user`, so the type does not need re-cutting the first time a tool hands back an image.
- **Image input ships on both wire routes.** Chat Completions emits an `image_url` content part; the Responses route emits an `input_image` part. Both carry a `data:` URL and **never a remote one**: the Telegram file URL carries the bot token, and a provider will fetch whatever it is handed. **`detail` is never sent** on either route, because each route infers the fidelity it reads an image at and pinning that would substitute our guess for the provider's own. A message carrying no image still emits exactly the shape its route has always emitted — a bare `content` string on Chat Completions, a one-element `input_text` array on Responses — so no text-only turn changes shape on either. A high visual-token estimate budgets the image instead of a grapheme count, so a run is refused rather than overspent. A route that rejects the request **because the configured model cannot see** narrows to a distinct `visionUnsupported` error, matched only on an invalid-request rejection naming an image content part: telling the owner to change models over an unrelated outage is worse than showing them the generic failure. **This detection is route-dependent by nature.** A gateway that ignores an unsupported field (an Anthropic-compatible one does) never rejects, so there the miss cannot be detected and the owner gets an answer that ignored the image.
- **`LLMProvider` also keeps the seam** for a native adapter later (e.g. Anthropic Messages for prompt caching / extended thinking). The Responses adapter is that seam's first non-Chat-Completions wire format — evidence it holds.
- **Client:** thin, over AsyncHTTPClient. Composition builds a **dedicated, redirect-disabled LLM client**, distinct from the Telegram and tool clients, so **no bearer — static or subscription — can follow a redirect off its intended host**; default TLS verification stays on. **SSE streaming is v1**: a small SSE parser → throttled `editMessageText` (coalesce, min-interval ~1–2s, first chunk ASAP). If streaming is unavailable, fall back to blocking + re-issue `sendChatAction` every ~4s for the turn duration. The metric is **perceived latency (time-to-first-token)**, not just first-reply latency. (URLSession can't stream SSE on Linux → AsyncHTTPClient is the portable choice.) On the Chat Completions route, a stream whose response head carries a retryable-class status before any SSE bytes is a clean rejection (`ProviderError.rejected`) and falls back to the blocking path once; mid-stream failures still degrade with no re-issue.

### 8.1 Route selection — the qualified model reference

`CLAW_LLM_MODEL` is parsed **once**, at composition, into a typed `ResolvedLLMRoute`. It keeps four values distinct — two of them carried by its `LLMProviderDescriptor` — and collapsing any pair is a defect:

| Value | Meaning |
|---|---|
| `providerID` (descriptor) | `openai-compatible` or `openai-chatgpt` |
| `configuredReference` | the exact configured value — the identity written to `provider_usage`, cost policy, and safe diagnostics |
| `wireModel` | the raw value sent in `ChatRequest` |
| `egress` (descriptor, `LLMEgressIdentity`) | the validated configured endpoint, **or** a managed endpoint identity |

Selection rules are deliberately narrow, because the cost of a false positive is routing an owner's existing model to a different provider:

- The recognized prefix is **exactly `openai-chatgpt/`** — case-sensitive, trailing slash included — and is stripped **once**: `openai-chatgpt/team/model` selects the ChatGPT route and sends `team/model` as the wire model.
- **Every other value is a raw model on the current route, unchanged.** **A slash alone never implies a provider:** `openrouter/openai/gpt-5.4` has no recognized prefix and stays a raw model. Existing model values keep their current meaning, including values containing `/`.
- An empty qualified suffix is a configuration error; a ChatGPT suffix must match `[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}`. Raw values keep their existing validation behavior.
- **The model is validated before the base URL.** A base URL is required only on the current route; the ChatGPT route never reads it, and `CLAW_LLM_API_KEY` is never used for ChatGPT authorization or request construction (the shared secret transition may still read, seal, and redact that key with the owner's other runtime secrets — §15).
- `LLMConfig` carries the resolved route plus the provider-neutral timeout/retry/streaming/structured-output/reservation settings — not a raw `baseURL`+`model`+`apiKey` triple. **No optional base URL leaks into execution code.**

Composition keeps an explicit **registry of provider descriptors**: one `Sendable` value per provider naming its prefix, egress identity, credential mode, and the capabilities composition validates configuration against (structured-output support and the wire output-token field). **Capability validation covers every configured route, not only the primary**: `CLAW_LLM_STRUCTURED_OUTPUT` naming a mode the fallback (§8.6) cannot serve fails config load with the offending route named, rather than surfacing the first time the fallback carries a turn. Adapter selection switches on credential mode; wire-intrinsic refusals a descriptor cannot vary (a route with no stop-string field on the wire, say) stay in the adapter that owns the wire. `AgentRuntime` still sees only the existing request fields and `any LLMProvider`. **Adding a managed provider = registering a descriptor + composing an adapter** — never another branch in `AgentRuntime`, the scheduler, or the gateway.

`configuredReference` and `wireModel` stay distinct end-to-end: `wireModel` goes on the wire; `configuredReference` goes into `ProviderUsage`, cost policy, and safe diagnostics. **This is what stops subscription and API-billed calls for the same wire model from sharing an accounting identity** (§8.6). Interactive and scheduled calls both carry both identities, and both use the one shared session-trace formatter.

`PolicyFingerprint.StaticInputs` folds the resolved **egress identity** — never a credential — instead of a raw base URL. For the current route that is the canonical configured endpoint; for ChatGPT, the provider ID plus its fixed endpoint. Switching between those sinks therefore still invalidates a parked approval (§11) even when no base URL is configured at all. **The identity folded in is the configured primary's, resolved once at composition, and that is a known, accepted gap rather than an oversight.** A runtime failover to the fallback route (§8.6) does not move `policy_version`, so an approval parked mid-turn stays valid across a switch and the action executes with its output going to the fallback's sink, not the sink in force when the owner approved. The gap was reviewed and kept: recomputing the fingerprint per call would void approvals from inside the run they belong to, and configuring a fallback is an explicit statement that both sinks are trusted. **Both routes in a roster therefore carry the trust of the more sensitive one**, and the owner docs say so. Only editing the configured primary voids a parked approval.

### 8.2 Credential seam (`LLMCredentialSource`)

Authentication resolves per request behind its own vendor-neutral protocol, so `LLMProvider` never learns about OAuth grants or ChatGPT accounts:

- `authorization()` returns immutable headers, the exact values to redact, and a **generation** identifying the credential snapshot used for one request.
- `reject(generation:disposition:)` is **generation-aware**: the source changes state only if that generation is still current, so **a late 401 from an older request can never invalidate a newer token**. `.refresh` is the first clean 401; `.authenticationRequired` is the retry's second and **latches the source terminally**, so a later turn cannot start another refresh loop.
- On the first matching clean 401, the source **durably publishes an expired-token marker before refresh or replacement may continue**. If that publication is uncertain or fails, the source retries only the marker write and exposes no replacement credential; a restarted worker therefore cannot reuse a token the provider already rejected.
- `shutdown()` is the credential lifecycle's commit point, owned and awaited by `RunCommand` in a fixed order (§4).

Two implementations. The **static source** serves the current route: a fixed bearer from the configured key, a constant generation, no-op rejection and shutdown; an absent key yields an *empty* authorization, which is what keeps local servers working. The **ChatGPT source** is an actor owning single-flight OAuth refresh:

- A token is **fresh** only when `expiresAt > now + 120 s`. An expiring token starts **exactly one** refresh flight over an immutable snapshot; concurrent callers await that same flight. **One operation-ID-guarded finalizer owned by the actor is the only code that may save, publish, increment the generation, clear the flight, and resume waiters** — waiters never perform post-await cleanup, so a stale flight's completion cannot clear or increment a newer one. Cancelling one waiter promptly resumes *only* that waiter; it never cancels the shared refresh or disturbs the others.
- **A rotated pair is durably stored before it is exposed.** A write failure parks the actor in `pendingPersistence` holding the new pair; later callers retry **only** that bounded write and **never refresh again with a refresh token the vendor may already have consumed**. A crash in the vendor-rotated-but-not-yet-published window can require a fresh login: no local file protocol closes that gap, and the docs must not pretend otherwise. The running process, however, never publishes split state.
- A refresh response that omits a new refresh token preserves the current one; a response containing one rotates the pair together. Terminal grant failures (`invalid_grant`, `invalid_token`, `invalid_request`, `refresh_token_reused`, token-endpoint 401/403) latch `authenticationRequired`. **429 is quota/throttle, not bad authentication**, and enters a Retry-After-aware cooldown. Transport, 408, and 5xx use the bounded retry budget and then a ≤30-second cooldown, so a wave of new turns cannot hammer the token endpoint; callers during cooldown get a typed throttle with the bounded remaining delay and start no network work. Every wait uses an injected clock.
- **Shutdown has an explicit commit point.** Before the worker has a decoded, validated replacement pair, shutdown may cancel it and nothing is accepted. Once it has one, it hands that pair to the matching finalizer even if cancellation races the handoff, and the finalizer completes durable persistence while stopping — without publishing new authorization to callers. Shutdown closes admission, resumes all waiters with cancellation, retries a pending publication, and **reports a typed error rather than success** if publication still cannot finish.
- JWT reading is **unverified metadata extraction, never authorization** — only `exp` and the account claim, under strict base64url and decoded-size bounds. Signature validation stays the server's responsibility. A missing or malformed account claim **omits the optional header rather than failing composition**.
- Mutable state lives in the actor; values crossing tasks are immutable and `Sendable`. Login runs only while the daemon is stopped, so generations are process-local and never persisted.

**Each adapter allowlists the credential header names it accepts** and rejects any that collide with its own — the dictionary-shaped seam is otherwise an open door. A credential source supplies only credential-dependent headers; `Host`, content negotiation, client identity, session routing, and endpoint selection remain properties of the concrete wire adapter and cannot be replaced through it.

### 8.3 ChatGPT Codex Responses route — private and unofficial

> **Private-route warning (fixed, normative).** This route is **behavior observed in two reference implementations** (OpenClaw and Hermes, at pinned revisions), **not a public, supported, third-party ChatGPT inference API.** No vendor contract stands behind it: the endpoints, headers, device-authorization flow, and event shapes can change or be withdrawn **without notice**, and the vendor's terms govern what a subscription may be used for. It ships as an owner-selected convenience, confined behind the adapter seams, and **must never be documented or described as stable or supported**. The configured OpenAI-compatible route remains the supported default and is unaffected by anything in this section.

- **The inference endpoint, OAuth issuer, client ID, redirect URI, originator, and User-Agent are compile-time HTTPS constants, not configuration.** Changing one is a code change plus a source-study update. Two properties follow structurally: **a user-supplied base URL can never receive a subscription bearer token**, and bearer headers are constructed only *after* the fixed URL is selected. Redirects are disabled, same-host included.
- **No-import boundary (structural, not a promise).** swift-claw never reads, imports, modifies, or locks another tool's credentials — notably Codex CLI's `~/.codex/auth.json`. Every production credential path derives from one state-root-relative path abstraction owned by `ClawSecrets`; neither the store nor its callers accept an arbitrary import path, and the source tree contains **no Codex-home lookup and no `.codex/auth.json` literal**, enforced by a source-level guard. The boundary is thus a property of the code's shape rather than of CLI control flow.
- **Device authorization is bounded in every dimension:** the fixed Codex device flow; a 15-minute **monotonic** login deadline; a server-supplied poll interval clamped to at least one second and to the remaining deadline; each HTTP timeout capped to that remaining deadline so one stalled request cannot overrun the advertised window; explicit pending-versus-failed status classification; and a token expiry resolved from a positive `expires_in`, then the access token's `exp` claim — **a token with no usable future expiry is malformed, not something to store into a refresh loop**. Remote strings are length-bounded, control-character-stripped, and validated before use or display. Cancellation exits without saving.
- **Request translation:** system messages concatenate in order into `instructions`; remaining messages map to Responses input items; tool definitions flatten to `function` tools. Every call sends `store: false` and `stream: true` — **both `complete` and `stream` use SSE**, `complete` simply consumes it without publishing deltas — includes only `reasoning.encrypted_content` (opaque replay material; reasoning summaries and commentary are never owner-visible output), and carries a content-derived `prompt_cache_key` that contains **no raw prompt text** and is stable across sessions for the same static prefix.
- **`max_output_tokens` is omitted on this route** (the studied Codex backend does not honor it), so **local limits are the only output bound.** The configured output cap degrades to a *local reservation* for preflight and accounting. Per-run token, turn, tool-call, byte, event, item, and wall-clock ceilings all stay enforced locally, which bounds a call — but a **token budget can overshoot by at most one in-flight provider call**, and hidden reasoning means swift-claw **cannot claim a strict provider-output-token cap here.** State that limitation; do not claim the cap.
- **Capabilities are enforced at configuration, before network I/O — never silently degraded at runtime.** Structured output must be `off` on this route and a request with non-nil stop strings fails config validation with a route-specific explanation, because the studied route offers no relied-upon contract for either; schedule drafting uses its existing prompt-and-parse fallback instead. `CLAW_LLM_STREAMING=false` disables Telegram draft publication, **not** Responses SSE on the wire.
- **SSE reconstruction is from output-item events, never from the terminal response object** — the studied backend can send a null `output` on a valid completed response, so trusting the terminal object loses whole answers. The **first recognized terminal event is final**; conflicting terminals already decoded in the same delivered batch are rejected rather than waiting for a future event or EOF. A successful terminal caches the authoritative `ChatResponse`, then cancels and joins the exchange instead of waiting out a server-kept-open connection. Reasoning and `commentary`/`analysis` phases are **never published as deltas and never enter `ChatResponse.content`**; they survive only as opaque replay state (§8.5). A 2xx stream that reaches EOF without a recognized successful terminal is an **ambiguous failure — neither a successful empty answer nor a retryable clean rejection.**
- **Strict terminal reconciliation is evaluation-only instrumentation.** The package-internal `StreamingTerminalValidationPolicy` defaults to `firstTerminal`, preserving the production behavior above. Only the frozen evaluation harness selects `throughStreamEnd`: under the same attempt deadline, it withholds success until EOF and validates every supplied terminal model alias independently of SSE chunking. The policy is not configuration, is not exposed by `clawd`, and does not redefine the production provider contract.

### 8.4 Owning streams and attempt exposure

**`stream` returns an owning session synchronously** (`LLMEventStream`), not a bare `AsyncThrowingStream`, so the caller holds the cancel-and-join handle **before** authorization or network work can race a deadline. `cancel()` is synchronous, idempotent, and nonblocking, so a task-cancellation handler can signal the producer without awaiting actor isolation; `cancelAndAwait()` signals and joins; `awaitTermination()` joins without signaling. Both awaiting methods **ignore the caller's cancellation status, resume all joiners once, and return the same cached terminal value**; a natural producer failure is thrown by the iterator *and* cached as the matching terminal, so joining never erases its typed cause. **The runtime calls one awaiting method on every exit path** — normal, throwing, deadline, early-consumer — so the service graph cannot finish while a producer is live. Iterator termination is a safety signal, **not** the lifecycle join: an `onTermination` callback can neither await cleanup nor deliver the accounting disposition.

A successful terminal caches the authoritative `ChatResponse` **before** closing the event channel, and **the cached response — not delivery of the final buffered event — resolves a terminal-versus-cancellation race**. A decided terminal value does not release joiners: they resume only once the producer and its nested HTTP exchange have actually finished cleanup. The same ownership holds one level down — an HTTP stream is an owning `HTTPStreamExchange` preserving transport backpressure, so **joining an `LLMEventStream` transitively joins all of its HTTP work**.

**Attempt exposure is one monotonic reducer** — the vendor-neutral answer to "could this attempt have generated tokens?":

```
notStarted → mayHaveStarted → completed | failed | cancelled
                └─ proven clean head or definitely-not-sent failure → notStarted before wait/retry
```

- The executor invokes a synchronous **`beginHandoff` exactly once**, immediately before submitting the request. Under one lock it either observes prior cancellation and refuses submission, or moves the attempt to `mayHaveStarted`. **Cancellation after that linearization is conservative even if no response head ever arrives.**
- A typed transport failure carries `definitelyNotSent` or `mayHaveBeenSent`. **`definitelyNotSent` is claimable only** before handoff or for a narrow allowlist of typed failures whose transport contract proves no request channel became writable (a refused connection, say). **Unknown, timeout, and generic pre-head failures are `mayHaveBeenSent`** and are never retried automatically — retrying one would hide a generated attempt behind a later successful response. Production code **never infers accounting from error text**; tests inject the handoff closure and disposition directly.
- **A recognized non-success head proves the attempt did not generate**: the reducer returns to `notStarted` *before* reading its bounded diagnostic body, refreshing, sleeping, or starting another attempt. Cancellation racing that reset chooses `mayHaveStarted` unless the clean-rejection transition already won. Each retry gets a fresh handoff transition, so **exposure never leaks from one wire attempt into the next**.
- Observed-token counts are checked, nonnegative **lower bounds** derived only from already-bounded visible text and tool arguments.

`ProviderFailure` pairs a redaction-safe `ProviderError` cause with that accounting disposition; `ProviderInferenceCancellation` carries it out of `complete`, where cancellation before inference stays a raw `CancellationError`. **The runtime branches on the accounting disposition, never on whether the caller used `stream` or `complete`** (§19). **Cancellation is never owner-facing provider-outage copy.**

The two execution methods are **not** interchangeable retry surfaces on a managed route: the ChatGPT adapter drives both from **one shared SSE attempt engine** and therefore does not expose a rejection for `AgentRuntime` to reissue through the other method, because both use the same wire transport and reissuing would reset the retry budget. The Chat Completions route's existing stream-to-buffered fallback is unaffected — it fell back across two genuinely different transports, and that behavior is unchanged.

### 8.5 Opaque provider replay state

Responses reasoning continuity cannot be expressed as text and tool calls, so `ChatResponse`, the terminal streaming event, `ChatMessage`, `ToolExchange`, and final assistant commits gain an optional `ProviderExchangeState` — an `issuer` plus an opaque `payload`. **The adapter that produced it is the only code that may interpret it.**

- The issuer is a **structured logical identity, never a configurable URL**: it binds the provider version, a hash of the **locally generated credential profile ID** (never JWT metadata, an account claim, or a rotating token), a wire-model hash, and a replay epoch. It exposes no profile or account identifier. **Re-login makes every prior state foreign; refresh preserves compatibility** — which is exactly why the provenance is local, not vendor-derived.
- The adapter replays only state whose provider version, credential-profile hash, model hash, and newest epoch **all** match, selected newest-first under the aggregate request cap and re-emitted in chronological order. **Only optional state is ever evicted — ordinary text and tool calls are never dropped.** Foreign, malformed, or oversized state is ignored with a **metadata-only** warning; it never breaks a session and is never sent to another provider.
- **Function calls never live in the opaque payload.** They stay in `ChatMessage.toolCalls` and are always synthesized as input items; a replayed assistant message item replaces only synthesized assistant *text*. Replay state therefore cannot drop a tool proposal.
- Provider state is **opaque outside its adapter**: never rendered into a prompt as text, never FTS-indexed or recall-eligible, never exposed to tools, audit arguments, logs, Telegram, or memory files. The ordinary text estimator never decodes it — a separate byte-derived reservation counts it for budget preflight (§8.6). The Chat Completions adapter ignores it entirely.
- `AgentRuntime` stays provider-agnostic: it appends `response.providerState` when it appends the assistant `ChatMessage` and **never inspects issuer or payload**. All replay decisions belong to the concrete adapter.
- A **clean** `invalid_encrypted_content` rejection marks a **new replay epoch**, retries once with no prior state (counted against the normal attempt budget), and stamps the successful response with that epoch — so later turns and restarts derive the new epoch and cannot reintroduce poisoned state. If the state-free retry fails, **no durable reset is claimed** and the owner gets `/new` guidance. An invalid-state error arriving *after* response data begins is likewise never replayed.

### 8.6 Reliability, retry budget, and cost accounting

- **Reliability:** retry only retryable errors (408/429/5xx response heads) and failures **proven** `definitelyNotSent` (§8.4), with capped exponential backoff + full jitter and a retry budget (~3/req); honor `retry_after`, clamped to the smaller of 30 s and the configured request timeout (the turn deadline can still cancel earlier). **One configured retry budget counts every wire attempt of a call** — clean-401 refresh, replay-epoch recovery, 408, 429, 5xx, and definitely-not-sent transport retries — so no path silently resets it. **The automatic-retry boundary closes on the first non-comment SSE `data:` field byte**, before the event delimiter or JSON decode: a fragmented, malformed, or unknown data event can never be replayed after a disconnect, while framing comments alone do not cross it. Retries count against both budgets (§5.3). **A configured fallback narrows the one-budget rule in exactly one place:** on a **ChatGPT primary with a fallback configured**, the first 429 is terminal and spends no retry budget at all. A subscription wall clears on the plan's own clock, so re-proving it inside the turn deadline costs the owner an answer the other route could still produce. **A static-bearer route never takes that narrowing**, whether it stands first or second: an API-key 429 is a transient rate limit rather than a plan wall, so it spends the full budget as before. Neither does the fallback, which has nowhere to fail onto.
- **Route fallback (this replaces "single-provider in v1").** Composition resolves a **roster** — the primary `LLMRouteBinding` plus the optional fallback — from `CLAW_LLM_MODEL` plus the optional `CLAW_LLM_FALLBACK_MODEL` (§15). **An absent fallback leaves a primary-only roster and every behavior above unchanged.** The route state mirrors that shape exactly: two positions, one cooldown window, and one explicit failover attempt, so there is no index arithmetic and no empty roster to guard against. **A third route is therefore a redesign of the roster and of everything that traverses it, not a configuration change** — it is deferred work (§20), not a switch to flip. Each binding carries its own provider, wire model, `configuredReference`, cost policy, and reservation policy, so the two routes are accounted for separately end to end. `AgentRuntime` and `ScheduleDraftParser` share the roster and the cooldown, and switch on the same terms.
  - **Only re-issue-safe causes may switch:** quota exhausted, credential rejected, access denied, connection failed, and pre-stream rejections. The first three are the clean head rejections §8.4 already reports as `notStarted`; the last two are what a streaming round already re-issues once onto the buffered path, and a cause that cannot double-charge the same provider cannot double-charge a different one. **`retryable` is excluded deliberately**, because the exchange may already owe tokens, the same reason the buffered reattempt refuses it. A wrapped `ProviderFailure` the provider itself tagged `mayHaveStarted` vetoes a switch whatever its cause: re-issuing it could double-charge, and deltas may already have reached the owner's draft.
  - **A failed primary is put on a cooldown**, so an exhausted plan is not probed on every turn: 60 s for transport-shaped failures, `CLAW_LLM_PRIMARY_COOLDOWN_SECONDS` (default 900) for persistent ones, doubling on each further failure to a one-hour cap. A provider `retry_after` hint longer than the tier default wins; a shorter one is ignored, because a hint clamped for retry pacing says nothing about when a plan resets. While the primary's window is live the next turn **starts** on the fallback rather than re-proving the wall. **Only the primary carries a window**, because the fallback is the last route and nothing ever switches off it. **The window lives in memory**: a restart costs exactly one probe against a route that may already have recovered, and a stopped-daemon `doctor` reports it as unobservable rather than clear (§16.1).
  - **A switch is audited and told once.** Each switch appends a `provider_fallback` audit row and arms a one-time owner notice; the matching notice fires on the turn where the primary answers again (§19). Both routes failing reports the **primary's** cause, because "your plan quota is out" is the actionable fact, plus one sentence saying the backup was tried.
  - **Never silently fall back to a pricier tier** survives, three ways. The second route exists only because the owner configured it. The **active** binding's cost policy is what reaches the budget gate, so a metered fallback behind an included-plan primary is charged and capped as metered from the call it takes over. And the transition notice is mandatory, so no turn moves to a billed route without saying so.
  - **The USD caps can be exceeded by one call on the switching round-trip.** The budget preflight runs once per round-trip, before the provider call, against the route active at that moment; the re-issue on the next route is the same round-trip and is **not** re-gated. Under a flat-rate primary the USD legs are skipped entirely (they are inert there), so the metered fallback's first call is ungated even when the daily cap is already spent. Later turns start on the fallback and gate normally, which bounds the exposure at roughly one ungated metered call per cooldown window. **This is accepted behavior, and the owner-facing spending docs state it.**
- **Cost is an injected policy, not a name check.** Composition injects an `LLMCostPolicy` (`metered` | `includedPlan`) into both `AgentRuntime` and `ScheduleDraftParser`; **no call site infers billing from a model-name prefix.**
  - **Metered (best-effort, layered — no hand-maintained table):** resolve per-call USD as **provider-returned cost → vendored MIT price file → conservative heuristic** (`totalTokens × referenceUSDPerToken`), attributed in `provider_usage` (every row records `cost_usd` + `cost_source` + `is_estimated`); this feeds the USD breaker (§5.3). **Never a silent $0** — a heuristic computing to 0 with tokens > 0 is floored at $0.000001, while a *confirmed* provider $0 is recorded as $0. An unknown model falls through to the heuristic, and doctor surfaces the price-source mix. Per-call USD dashboards are deferred; the USD breaker + the offline token ceiling are v1.
  - **Included plan (subscription route):** `cost_usd = 0`, `cost_source = included_plan`, and `is_estimated = false` when token counts are provider-returned. **`cost_source = included_plan` is the durable proof that the zero is *confirmed*, not silent** — it satisfies the never-a-silent-$0 rule rather than bypassing it. Provider-reported dollar cost is ignored on this route. Missing counts fall back to the conservative estimator and set the combined `is_estimated` flag while the cost stays a confirmed zero (the schema keeps its single flag, whose meaning is the logical OR of token and cost estimation).
  - **The included-plan policy skips USD gates only** — including when earlier API-billed usage has already crossed a USD cap. USD day and run totals still record rows and stay auditable, but cannot reject a call the plan already covers. **Input/output reservations, per-run input caps, the daily token breaker, turn caps, tool-call caps, and wall-clock deadlines all remain active, and schedule drafting uses the same policy. This is not an unlimited-budget mode.**
- **Input reservation is a policy too.** Preflight and missing-usage estimates charge the message context and the complete advertised tool array. Composition injects an `LLMInputReservationPolicy`: text estimation only for the current route; for ChatGPT, an additional checked, byte-derived reservation over selected replay state (deliberately over-estimating re-encoding **without decoding the opaque payload**), participating in per-call, per-run, daily-token, and missing-usage estimates. Foreign state may over-reserve until the adapter drops it — the right direction to err, because **replay state must never bypass a token gate**. Provider-returned usage remains authoritative after the call.
- **Usage identity:** every logical round-trip carries a locally generated `ProviderCallID` — stable across clean wire retries and the stream-to-buffered fallback, fresh for each tool-loop round and each schedule parse — and usage rows are idempotent on it (§7.4). The stored model is the **qualified `configuredReference`** (§8.1), so included-plan usage can never collide with API-billed usage for the same wire model.

## 9. Memory & context architecture — SINGLE NORMATIVE SOURCE

> §9 is the **single normative source** for context assembly. The PRD references this section; any divergent ordered list elsewhere is superseded by this one.

### 9.1 Workspace files

`~/.swift-claw/workspace/`: `SOUL.md` (persona/tone/boundaries), `AGENTS.md` (operating rules), `USER.md` (owner profile/timezone), `TOOLS.md` (tool notes), `MEMORY.md` (curated long-term), `memory/YYYY-MM-DD.md` (daily logs), `HEARTBEAT.md` (proactive tasks), `skills/<name>/SKILL.md` (agentskills.io standard; Yams for frontmatter). **Missing files never crash** — each loads to `(text, wasTruncated)`.

**Skill identity is settled at scan time**, so nothing downstream has to re-decide it: the frontmatter `name` must match `^[a-z0-9]+(-[a-z0-9]+)*$` at 1–64 characters **and** equal its own directory name, `description` is collapsed to a single line and then capped at 300 graphemes (the spec allows 1024; the index has to scale with skill count, not with one author's prose, and a block scalar must not let one skill occupy several of the index's one-line-per-skill rows), and a name claimed by two directories drops **every** claimant — silently shadowing one is the bug class the loader exists to avoid. Each rejection reaches the owner as a notice (§9.2), not only the log. The scan feeds the index row; the body is loaded on demand by `skill_load` (§10.1), never injected wholesale.

**`/skills` is the complete owner diagnostic.** An allowlisted request starts a fresh workspace scan
and renders every accepted descriptor as the canonical `- <name>: <description>` line, followed by
every rejection reason. The renderer labels empty sections. The command does not dispatch an agent
turn or mutate skill state. Ordinary turns keep their compact failure surface: they announce every
scanner warning except an unreadable `skills/` directory, plus any cap drops. Repeated directory
read failures stay in the log, `/skills`, and the unhealthy doctor row. Non-allowlisted senders
receive no skill information.

### 9.2 Canonical ordered list + budget formula

One canonical ordered assembly. Each section carries a **priority** and a **truncatable** flag.

| # | Section | Tier | Priority | Truncatable |
|---|---|---|---|---|
| 1 | System / security policy | system (trusted) | highest | no (degrade-not-drop) |
| 2 | Identity files (SOUL/AGENTS) | system (trusted) | high | no |
| 3 | Developer config / tool policy (TOOLS) | system (trusted) | high | no |
| 4 | Current date/time | system (trusted) | high | no |
| 4b | Pinned job lessons (bound scheduled run only) | **untrusted/labeled wrapper** | high | no — the whole frozen set, or the run fails |
| 5 | Owner profile (USER.md) | **untrusted/labeled wrapper** | med-high | no — hard cap 1375; overflow → omit + owner error (not silent truncation) |
| 6a | Durable memory file (MEMORY.md) | **untrusted/labeled wrapper** | med | no — hard cap 2200; overflow → omit + owner error |
| 6b | Durable memory items (`memory_items`) | **untrusted/labeled wrapper** | med | yes (budget cap; recency + importance — relevance deferred, Inc 3a) |
| 7 | Session history / rolling summary | mixed; **provenance preserved** | med | yes |
| 8 | Retrieved (FTS5 recall) + tool observations | **untrusted/labeled wrapper** | low | yes |
| 9 | Skills | untrusted/labeled | low | yes — whole units only (prefix drop + count marker) |

**Budget:** `inputCap = modelMax − reservedOutput`. Fill **greedily by priority**. A truncatable section is **cut to its cap** with a literal marker string (e.g. `…[truncated]`). A non-truncatable section **degrades but is never dropped**.

**Row 9 (skills index) drops whole units, and says so.** One unit per installed skill (`- <name>: <description>`), each non-truncatable — half a description is a mis-activation waiting to happen. Under a tight cap the row therefore **stops at the first non-fitting unit** (a deterministic prefix of the scan's sorted order, so which skills survive stays under the owner's control) rather than greedily skipping big units for small ones, and appends a `(showing N of M skills)` marker **cost-accounted inside the row's cap** like any other unit. The row supplies the marker wording; the fitter stays row-agnostic. A cap too tight for the kept skills *and* the marker keeps the skills and omits the marker — the annotation never evicts the content it describes, and a row that would be emptied by its own marker is the case the owner most needs to hear about. **The owner notice is derived from what the row asked for, not from what survived**, so it fires identically whether the row came back shrunk or was dropped whole: a skill that never activates looks identical to a skill that does not exist. **This prefix rule is scoped to the skills row**: row 6b's memory items are also non-truncatable units but keep the greedy fill, since their selection is already rank-ordered.

**Row 4b (pinned lessons) exists only for a run whose fire froze a lesson set** — a scheduled fire under `CLAW_LEARNING_ENABLED`, never an inbound turn or a heartbeat. It renders the job's whole frozen set inside the untrusted fence under the label `job lessons`, and it is measured with the non-truncatable rows, so the truncatable rows share only what is left after it. A set that cannot fit **fails the run before provider dispatch** rather than truncating, and a bound run never falls back to the job's current, empty or shortened set: either substitution would evaluate a hypothesis the binding never froze. Because a model wrote those lessons, a non-empty set also arms the run's untrusted-ingestion flag before the first dispatch and excludes high-sensitivity memory from row 6b, exactly as untrusted tool metadata and a tainted session do — it augments those inputs and never replaces them.

**Proactive-run assembly (`origin ∈ {scheduled, heartbeat}`):** row 1 renders the dedicated proactive prompt (`SystemPrompt.proactive` — autonomous-execution framing, no /schedule pointer) instead of the interactive policy prompt, and row 8's message recall is omitted entirely — the retriever's dedup excludes only the current session's in-window rows, so recall would resurface the prior fires that the per-fire window reset (§14) fences off. All other rows assemble identically. The policy fingerprint folds BOTH prompt variants, keeping `policy_version` origin-independent so the approval recompute seams need no run in scope.

### 9.3 Memory tier, caps, and trust

- **Untrusted tier.** `MEMORY.md`/`USER.md` are injected inside the **SAME untrusted/labeled wrapper** as other data — **never the system tier** — so poisoned memory cannot claim system authority.
- **Caps (grapheme `String.count`):** `MEMORY.md` = **2200**, `USER.md` = **1375**. **On overflow → ERROR, never silent truncation.** For these **hand-curated** files, "force consolidation" means the runtime **omits the over-cap file for the turn and delivers an owner-facing consolidation notice** — it never auto-rewrites the file (Inc 3a). **This is the v1 contract** (it resolves the former §21 open question; it is not also listed as open).
- **Flush-before-compact:** durable facts are written to disk *before* any history summarization.
- **Compaction preserves provenance:** never fold an UNTRUSTED `tool_result` into the trusted rolling summary; retain an `untrusted` marker (§12).
- **High-sensitivity memory is NOT auto-injected** into a turn that already ingested untrusted content (§12).
- **Confirm-on-write** shows the **EXACT verbatim text** post-Unicode-normalization, with invisible/zero-width/bidi chars **made visible/stripped**. The pattern scan is **defense-in-depth only** (not an acceptance gate — it must not block the owner's own notes).
- `/memory review` + `/memory delete` (confirm-gated) with provenance.
- **Recall:** FTS5/BM25 over the message archive; durable facts (`memory_items`) by recency + importance, subject to the budget above. **Item-lane *relevance* is deferred** until item-FTS / `sqlite-vec` lands (Inc 3a); message recall uses BM25. Row-8 recall searches `user`/`assistant` roles only — tool rows stay FTS-indexed (and delete with their message) but are excluded from BM25 recall.

### 9.4 Counting unit

Grapheme counting (`String.count`) is used uniformly for all caps and budgets.

## 10. Tool system & policy

### 10.1 Read-only tier (v1)

v1 ships **read-only tools only**: `web_search`, `web_fetch`, workspace **file READ**, `skill_load`. They are read-only + idempotent + low-blast-radius → **`safe` tier (no tap)**. Per-tool output cap **~25k tokens** (enforced as its grapheme-domain equivalent 80 000 graphemes via the pinned estimator inverse), counted toward the **next turn's input budget** (it is re-sent until compaction). `web_fetch` enforces an **SSRF blocklist** (a tested invariant): after DNS resolution and following any redirects, the destination must be a **public** address — requests to private/RFC-1918, loopback (`127.0.0.0/8`, `::1`), link-local (`169.254.0.0/16`, incl. the `169.254.169.254` cloud-metadata endpoint), and other reserved ranges are **refused** — and it is also subject to the outbound **exfil gate** (§12). Two **scoped, owner-trusted widenings** exist for hosts behind a fake-IP VPN/proxy (a resolver that answers every DNS query from a synthetic pool inside the RFC 2544 benchmarking range and tunnels the real connection): an address inside an owner-configured `CLAW_WEBFETCH_EXEMPT_CIDRS` block passes, and an address inside `198.18.0.0/15` passes when a **fresh DNS canary probe** (`FakeIPDetector`: known-public hosts plus a random nonexistent host must ALL answer from the pool) confirms interception is active at that moment. Inside a widened range the hostname-SSRF check is delegated to the owner's own tunnel, which re-resolves the real name at its edge; every other blocklist row — loopback, RFC-1918, link-local/metadata — stays refused unconditionally; IP-**literal** targets never receive either widening (a fake-IP resolver never rewrites a literal, and pool addresses recycle, so a literal pool target is meaningless), where "literal" covers every numeric spelling `getaddrinfo` resolves without DNS — the legacy integer/hex/octal forms too, not just canonical dotted-quad/IPv6; and the refusal copy names the resolved address and the opt-in key so the failure is diagnosable. `CLAW_WEBFETCH_EXEMPT_CIDRS` is egress policy, so it folds into the `policy_version` fingerprint (§11): changing it voids an outstanding `web_fetch` approval as `stale_policy`.

**`skill_load` — the model names a skill, never a path.** Its input schema is `{ "name": string }` and nothing else; the name is resolved by exact match against a **fresh scan** at call time, so a frontmatter string never becomes a path component. A hit returns the `SKILL.md` body with the frontmatter stripped by the same fence rule the scanner used (a fence is a line whose trimmed text is `---`; a shared locator, so a file the scanner indexed parses identically in the loader — if the file changed underneath and the fence is gone, the loader errors rather than guessing). An **unknown name is a success**, not an error: the payload lists the installed names, which is what lets a mistyped or hallucinated name self-correct inside the same turn. Duplicate claimants **refuse**, naming both directories. Posture: `egressClass = .none`, `RiskLevel = .safe`, output resolved through `WorkspacePathContainment` against the **workspace root** for the whole `skills/<dir>/SKILL.md` path (defence in depth — a symlinked skill directory must not serve a file from outside the workspace, and anchoring on `<root>/skills` instead would let a symlinked `skills/` redefine the boundary it is checked against; the scan applies the same rule, refusing to index anything when `skills/` itself resolves outside the workspace), then **redacted and size-capped** on the `file_read` path. Unlike every other tool result it sets **`ingestedUntrusted: false`** (§12).

**Tool results carry a declared fence label.** A `ToolDefinition` names the label its output renders under, defaulting to the tool's own name; both fencing seams — the live observation in `AgentRuntime` and the history replay in `ContextBuilder` — resolve it by tool **name** (replay has only the persisted name, never the tool instance). `skill_load` declares `skills`, which is what keeps the index row and the loaded body under one label end to end and lets §12's carve-out name exactly that label. **Only a registered tool's own declaration earns a label.** Tool names arrive from the provider stream, so a name no tool claims — a model-invented one, whose dispatch answers with an "unknown tool" observation, or one whose rows outlived its registration — fences under the neutral `tool` label, never under itself; otherwise a call named for a privileged label would mint that label on demand. The same rule covers an unattributable replay: when a persisted anchor declares one `tool_call` id twice, that id resolves to no tool and its rows take the neutral label rather than the first declaration's, so a duplicated id cannot lend `skills` to another tool's output.

### 10.2 Default risk-tier table

| Class | Examples | Default tier | Approval |
|---|---|---|---|
| Read-only / idempotent / low blast | `web_search`, `web_fetch`, file READ | `safe` | none (but exfil gate applies) |
| Owner-authored workspace procedure | `skill_load` (no egress; does **not** taint) | `safe` | none |
| Writes | file write, memory write | `ask` | per-action approval (Inc 5a) |
| Shell / exec | `execute_code` | `dangerous` | approval + sandbox (Inc 5b) |
| Egress-from-sandbox | opted-in network in an exec run | `dangerous` | approval; run is `canExfiltrate=true` |
| Remote / MCP | every `mcp__<server>__<tool>` | `ask` by default; named `safe` override allowed | default per-action approval; egress is `arbitraryDestination`, the trifecta can still force approval, and the result is untrusted (§10.3) |

(Inc 5a) **Registry** of < 20 narrow, typed tools (not a generic shell), each with input/output schemas, declared `RiskLevel`, timeout, sandbox requirement, audit behavior. The **`PolicyGate`** evaluates every proposed call before dispatch, independent of the model, and re-validates the approved action against the originally-approved canonical action + `policy_version` at execution. File tools are workspace-scoped: every path is resolved to its **canonical real path** (`realpath`, after `..` and symlink resolution) and **asserted to lie within the workspace root** — a tested invariant covering both the link and its final target — with size-capped output and secret redaction. Tool annotations are non-authoritative UX hints; the code gate is authoritative. (Batch approval + a time-boxed auto-approve toggle are deferred to the P-tools phase.)

### 10.3 MCP client

swift-claw is an MCP **client** and only a client: it consumes tools from owner-configured servers over **Streamable HTTP** and exposes none of its own. The transport is ours, over the shared `HTTPExecuting`/`HTTPStreaming` seam (§3) rather than the SDK's URLSession one, because URLSession cannot stream SSE on Linux (§18) — the same reason the LLM adapters own their framing.

- **A remote tool is an ordinary `Tool`.** The adapter's whole job is to land one on the existing seam with a per-instance `ToolDefinition`; the policy gate, approval FSM, `policy_version` fingerprint, redaction, audit, and trifecta gate learn nothing about MCP and get no MCP branch. Teaching any of them the word "MCP" would mean the adapter sits in the wrong place.
- **Naming is total before registry construction.** `ToolRegistry` traps on a duplicate name, so composition may not depend on a name being rejectable. Every fragment folds to `[A-Za-z0-9_]`, every cap truncates rather than refuses, an empty fragment falls back to a placeholder, and a collision takes the lowest free numeric suffix assigned in **config order** — so adding a server never renames another's tools behind the owner's back. The `mcp__` prefix rules out a collision with a built-in by construction.
- **Every MCP tool starts at `ask`.** Its `riskLevel` is `.ask`, its `egressClass` is `.arbitraryDestination`, and every payload carrying server-derived text is `ingestedUntrusted: true`. Its server-authored provider metadata — name, description, and parameter schema — also carries untrusted provenance and arms run taint before the first provider call. Ask-tier approval does not bypass the outbound argument guards: exact secrets and secret-shaped values still block, as do private-file substrings under the trifecta condition. Owner config may downgrade a **named** tool to `safe`; the trifecta gate still forces approval when taint and private data are present. Config rejects `dangerous`, and the egress class remains fixed because a remote endpoint is an arbitrary destination.
- **Owner headers cannot control the HTTP recipient or framing.** Config rejects names the MCP protocol or HTTP transport owns, including `Host`, `Content-Length`, `Transfer-Encoding`, and connection-specific fields. It applies the same rule to `authHeader` and rejects case-insensitive duplicate static names, so one validated config produces one wire value for each field.
- **Only two payload shapes leave the adapter:** the remote result (untrusted, always) and a **local failure written in our own words** (trusted, because we wrote it). The adapter renders the compatibility content array when present and falls back to canonical JSON for a structured-only result. Third-party text never reaches a payload the gate reads as trusted; where a failure line quotes the remote side at all, the quoted value is structurally constrained first (a media type must be shaped like one) rather than trusted to be well-behaved.
- **The catalog is pinned at boot.** No `list_changed` handling, no live refresh: the tool surface a run is fingerprinted against is the one it was composed with. Each remote definition contributes its configured endpoint, case-normalized auth-header name, non-secret static headers in canonical order, and unsanitized remote tool identity to `policy_version`, without the stored token, so moving a server, changing its request context, or renaming a tool voids parked approvals even when the provider-facing definition remains unchanged after normalization.
- **A remote party's misbehavior is never a boot failure.** An unreachable, oversized, or misbehaving server is **skipped** with a bounded, secret-redacted reason and the daemon boots with the rest; discovery caps pages, tools, bytes per server, each assembled message, buffered protocol messages, descriptions, and results. Catalog admission also caps the aggregate MCP provider-definition estimate at 25 000 tokens, considering servers in config order and skipping any server that would cross the cap. An **owner** error — malformed `mcp.yaml`, a broken credential envelope — fails loud with its own exit code. The asymmetry is deliberate: the owner can fix their file, and a third party must not be able to take the daemon down. A skip is still a **health** failure: `clawd doctor` reports it and exits non-zero, because doctor answers "is this working" and the daemon answers "can I run at all."
- **Every exchange is bounded.** The initialize handshake uses `connectTimeoutSeconds`; each list page and tool-call exchange uses `requestTimeoutSeconds`. The SDK resolves a request only when a reply carries its id, so the session also races each SDK continuation against the same phase budget and removes a timed-out continuation through the SDK cancellation path. A whole tool invocation retains a connect-plus-request budget because it may reconnect once. `Tool.timeout` adds a margin to that combined budget, keeping `execute` inside the dispatcher's bound and the approved executor's direct await (§6.2) finite. **Reconnect-and-retry follows only a failure that proves the call never ran.** A timed-out or otherwise ambiguous call remains at-most-once-unknown, the same disposition the HTTP seam names `mayHaveBeenSent` (§19), and its observation warns the model to verify remote effects before retrying.
- **Approvals bind to the complete endpoint and remote operation.** The canonical target names the configured absolute URL, including scheme, port, path, and query. `execute` compares that target with the approved value before sending. Provider-facing names, descriptions, and schemas pass through the process secret redactor; approval display names also lose control and Unicode formatting characters before they enter a fixed prompt row.
- **Credentials are per-server, bound to the URL they were issued for.** Static tokens live in their own AES-GCM envelope under the shared key (§15), and a token whose recorded URL fingerprint no longer matches the configured one is treated as **absent**: re-pointing a server must not hand the old host's credential to a new one. The daemon acquires the instance lock before reading the envelope, then holds it for the process lifetime, so a successful CLI mutation cannot race a stale boot snapshot. Every token in the decrypted map joins the redaction union before the log backend is installed, including records for removed or re-pointed servers. Only a configured server with a matching URL binding receives its token.
- **Nothing the model can call manages MCP.** There is no admin tool, no credential tool, and no catalog-mutating tool — the registry holds only adapters bound to one discovered remote tool each. Management is CLI-only under the instance lock (§17), and the Telegram `/mcp` command renders boot status and nothing else. The client advertises **no** capabilities in the handshake, so no server can drive sampling, elicitation, or roots back into the daemon; resources and prompts are not consumed.

- **The wire says what was agreed, and a session is handed back.** The handshake offers the newest revision the SDK speaks and the server answers with the one it will use; every request after it carries **that** answer, since a server pinned to an older revision may refuse anything else. A session is a resource on someone else's server, so the shutdown graph disconnects every one the boot opened — including a server that contributed no tool and is therefore held by no adapter — while the tool HTTP client is still open to carry the spec's `DELETE`.

stdio transport, OAuth 2.1 client auth, and live catalog refresh are deferred, each behind the seams above rather than behind a rewrite.

## 11. Approval system (Inc 5a)

A **state machine** persisted in `approvals` so it survives restart. See §7.1 columns and the **ApprovalState FSM table** in §19.1. Requesting an approval **suspends the run to a durable checkpoint** (`runs.state = AWAITING_APPROVAL`, persisted) — a restart resumes the exact pending action rather than re-running the turn. Key contracts:

- **Bound to the exact action** (tool + fully-resolved target + canonical args); executes the **recorded** args (never a fresh model turn); a past approval is **never** cached into a future auto-run.
- **Durable checkpoint = persist-the-partial-exchange**, not a serialized wire checkpoint: the assistant proposal + every completed observation + a **placeholder observation row updated in place** (the v5 `messages` columns) pin rowid adjacency at suspend; the approved action runs the recorded args; the run then continues as an ordinary assembly round-trip whose context bound is the filled observation's message id, with **carried-over turn/tool-call/token/USD counters** and a **fresh per-segment wall-clock** (suspension time never counts against any budget).
- **Callback auth** (§6.5): same default-deny check; `callback.from.id == approval.ownerUserId`; ≥128-bit single-use random nonce; re-validate args-hash + `policy_version`. Args-hash + `policy_version` validation happens **inside the callback resolution CAS** as the §19.1 approve guard (a mismatch commits `PENDING → REJECTED`, `decision = stale_policy`, and never reaches `APPROVED`); the at-execution recheck survives only as the boot crash-window belt (§6.5), whose granted-then-denied audit pair is documented — a mismatch there fails the **run** while the row stays `APPROVED`.
- **`policy_version`** (Inc 5a) is the first 16 hex chars of a **length-prefixed SHA-256** over the policy-relevant inputs at run start: **system-tier prompt materials** (the system/security prompt text + the loaded contents of `SOUL.md`/`AGENTS.md`/`TOOLS.md`, a missing/unreadable file hashing as empty), the **tool registry surface** (sorted tool names, each with its canonical parameter JSON, declared `RiskLevel`, metadata provenance, optional credential-free invocation identity, declared **fence label** — a trust declaration on par with risk, since it selects the prompt carve-out the tool's output renders under, so changing it voids an outstanding approval as `stale_policy` — and `ToolEgressClass`), and the **pinned egress + policy config** (the resolved **LLM egress identity** — the canonical configured endpoint on the current route, or the provider ID plus fixed endpoint on a managed one, so the sink is fingerprinted even when no base URL is configured (§8.1); **that identity is the configured primary's, resolved once at composition, so a runtime failover to the fallback route does not move it and the sink an approval binds to is not guaranteed to be the sink that serves the resumed run** — search-endpoint presence, canonical workspace root). **Secret values are never hashed, and an egress identity never contains a credential.** It is computed in two parts — a static sub-hash over the tool/config inputs at the composition root, folded into `ContextBuilder`'s prompt-material hash — persisted to `runs.policy_version` at pick-up and copied onto every approval; a **strict-inequality** mismatch at resolution denies with `stale_policy`.
- **Expiry → DENY** (terminal). Expiry is a **liveness / bounded-state control, not an attacker defense** — the single owner is the only approver, so the timer blocks no third party; its job is to guarantee a parked approval **self-resolves** instead of pinning a run (and its session lane) forever, with DENY as the fail-closed default direction. Default window **1h**, configurable via `approval_expiry`; enforced by a periodic expiry ticker and the boot reconciliation sweep (§19.1).
- **Escaping a pending approval:** a plain message **queues** behind it (strict FIFO — it never supersedes, §5.1); to abandon the parked action before expiry the owner uses `/stop` (cancel) or `/new` (reset + detaint), both of which resolve `AWAITING_APPROVAL` (§19.1). Otherwise silence rides out to `EXPIRED → DENY`.
- **Queue-behind survives restart:** boot reconciliation **re-parks a waiter on the lane** of every unexpired `AWAITING_APPROVAL` run, preserving the FIFO queue-behind contract across restart and giving **exactly one execution locus** — the callback handler, expiry ticker, and `/stop`//`new` command paths only CAS the row and signal the coordinator; the waiter task performs the resume/deny (observation update, run transition, owner notice, button disarm).
- **`ownerUserId` resolution:** the run's **delivery chat id** — the DM chat id for interactive runs, `scheduled_jobs.owner_chat_id` for job runs, the config-resolved owner DM for heartbeat runs — under the Telegram private-chat-id ≡ user-id identity. **No approval row is ever minted from a group topic** — a shared room has nobody who holds the owner's authority, so the gate refuses or executes there instead of parking (§12.1), and this resolution stays a DM-only concern.
- **Approval prompt contract:** show the **fully-resolved canonical target** (absolute path after symlink/`..` resolution; full URL incl. query/body, **never model-truncated**), a **TAINT banner** when the originating turn ingested untrusted content, and human-meaningful **blast radius** (create vs overwrite; egress yes/no). Redaction hides **secrets**, not the destination fields the owner needs to judge risk. Workspace-contained **privileged files** are **writable via `file_write` behind an explicit ⚠ privileged-file banner** in the prompt (owner decision, 2026-07-09) — flagged, not refused in code, because they steer a later turn. The set is every fixed prompt file (`SOUL.md`/`AGENTS.md`/`TOOLS.md`/`USER.md`/`MEMORY.md`/`HEARTBEAT.md`) plus any `SKILL.md`, whose body `skill_load` serves back untainted as guidance to follow; matching is by **basename** on the resolved canonical target, so a skill manifest is covered wherever under `skills/` it sits, and is **case-insensitive** — a case-insensitive filesystem indexes `skill.md` as a skill, while a creating write carries the caller's own spelling rather than an on-disk one.

## 12. Security & trust model

**Defense in independent layers — none of which is "the model behaved."** Security rests on four layers that each hold even if the model is fully subverted by prompt injection: (1) the **numeric-ID default-deny boundary** — untrusted senders never reach the model; (2) **untrusted-data labeling + the in-code instruction hierarchy** — inbound/tool/retrieved content, remote tool metadata, and durable memory are treated as data and cannot claim authority; (3) the **in-code policy gate + risk tiers** — every side effect is authorized by deterministic code at the dispatch site, never by the prompt; (4) the **enforced lethal-trifecta gate + approvals + blast-radius caps + the VM sandbox** — consequential actions are gated and contained. A successful injection therefore yields, at most, what an *unprivileged* turn could already do.

- **Boundary:** numeric Telegram user ID, default-deny, enforced before any LLM/tool/expensive work; fail-closed on internal error. No username path anywhere (identity-rebinding CVE class).
- **Instruction hierarchy (in code):** system/security policy > developer config > identity files (SOUL/AGENTS/TOOLS) > user task > tool observations > retrieved/inbound content > durable memory (MEMORY.md/USER.md — untrusted tier). Durable memory never sits at the system tier.
- **The `skills` label is a carve-out in what fenced content is FOR, never in what it can DO.** A `SKILL.md` body is untrusted content **the owner has permitted**: it renders inside the ordinary `<claw-untrusted>` fence under the `skills` label, and the system prompt licenses the model to follow it as guidance for how to carry out a task. The absolute rule is unchanged — fenced content can never alter instructions, tools, or permissions, and the permission itself lives in **trusted policy text, never in the skill**. The carve-out names the label, not the tool: widening it to `skill_load` would let any future tool inherit follow-this authority by choosing a name. **A label is only trustworthy if content cannot mint one:** the renderer defuses every `claw-untrusted` tag (case-insensitively) it finds inside the content it fences, so a fetched page or file cannot open a nested fence claiming `skills` and have its text read as owner-authored procedure. The nonce guards only the *close* — it cannot guard an open, whose nonce the forger picks.
- **Approval audit vocabulary (Inc 5a):** three actions — `approval_requested`, `approval_granted`, `approval_denied` — with the `decision` column carrying `rejected | expired | cancelled | superseded | stale_policy`; each row is appended **in the same transaction** as the state transition it records. A callback that fails **auth** (non-allowlisted or non-owner sender, unknown nonce) is **not** an approval decision — it audits as an access event (`message_in` / `forbidden`), leaving the approval row untouched.
- **Lethal trifecta = ENFORCED GATE, not a flag.** Taint is a **sticky, persisted session property**: `session.tainted = true` once ANY untrusted content is ingested — meaning **external/tool/retrieved content** (web/file/tool output, Inc 3b+) **or machine-derived inbound text** (a voice transcript — the wire captures no forward metadata, so the owner's own note and forwarded third-party audio are indistinguishable; every transcript persists `.untrusted` at the message row, taints in the same fused write, and renders fenced). Untrusted message rows are **excluded from FTS recall**: resurfacing one into a later or detainted session would re-ingest attacker-influenceable content without re-arming the taint flag. **Durable memory (MEMORY/USER/`memory_items`) is untrusted-*labeled* data that sets `hasPrivateDataAccess` but does NOT itself taint the session** (Inc 3a). **`skill_load` is the second such exception**: a `SKILL.md` has the same owner-authored-workspace provenance as `SOUL.md`/`AGENTS.md`, which assembly already injects untainted, so the tool sets `ingestedUntrusted: false` — tainting there would charge the owner the suppression of high-sensitivity memory for the whole session as the price of following their own procedure. `file_read` taints unconditionally even for the same file, which is why the dedicated tool exists. **A bound scheduled run's pinned lesson row (§9.2 row 4b) is neither exception — it taints**: a model wrote those lessons, so a non-empty set arms the flag before that run's first dispatch instead of waiting for a tool observation to do it. When `tainted` **and** a privileged/egress action is proposed → the runtime **FORCES the approval path** (or requires `/new`), **in code**, independent of the tool's own risk tier. Compaction/rolling-summary **preserves the untrusted provenance marker**. Taint persists on every commit path of a run that ingested untrusted content, including degraded and failed turns; a `/new`-superseded run does not re-taint the fresh window.
- **Exfiltration.** `canExfiltrate` covers **every** outbound network sink — the **LLM provider endpoint** AND `http_fetch` — not just "a different chat." Once `hasIngestedUntrusted && hasPrivateDataAccess`: a subsequent `http_fetch` **requires approval** showing the full resolved URL (incl. query/body); fetch args containing substrings of `MEMORY.md`/`USER.md` or secret-shaped tokens are **blocked by `redact()` before dispatch**; **the LLM egress sink is pinned on both routes** — an allowlisted configured `base_url`, or a compile-time-constant endpoint that by construction cannot be aimed at an owner-supplied URL (§8.3) — and stays a documented trust dependency either way; high-sensitivity memory is **not auto-injected** into a turn that already ingested untrusted content. There is **no** "reply to owner DM ⇒ exfil-free" exemption. **"Gated by approval" is the durable approval fabric** (Inc 5a, §11): the would-egress action suspends the run onto a durable `approvals` row bound to the exact recorded action (tool + canonical args/target; for `web_fetch`, the canonical URL), resolved only by an authenticated inline-button callback under the nonce/CAS contract. A restart **re-parks** the pending approval (boot reconciliation, §6.5) — the buttons still resolve; a plain "yes" text is **inert** for tool approvals; silence rides out to `EXPIRED → DENY`. The exfiltration trifecta's private-data leg is evaluated per turn (context assembly plus in-run reads); private content that entered persisted history via an earlier run's tool observation is not counted by later turns, so if the memory file is over-cap (omitted from assembly) and the turn performs no private read, a remembered private substring can egress without approval — accepted for v1, the session-persisted private-data flag belongs to Inc 5a's durable approval work. Inc 5a lands it: `sessions.has_private_data` is **set on every commit path** where the per-turn private-data leg was true (including degraded and failed turns), **read** into the trifecta gate's private-data leg (`session.has_private_data ∪ assemblyPrivateData ∪ runPrivateData`), **cleared** by `/new` alongside detaint, and **re-arms** on the next private ingestion. **Outbound sinks are classified:** pinned trusted egress (the LLM endpoint — an owner-configured/pinned `base_url` or a compile-time constant — and the search endpoint; their providers see model-authored content under their ToS) is protected by the arg guard and endpoint pinning, not approval; arbitrary-destination egress (`web_fetch`, and every `mcp__*` call — a third-party endpoint the owner pinned but whose behavior we do not control) additionally requires the trifecta approval. The owner explicitly accepts the search provider seeing model-authored queries.
- **`/new`** = fresh conversation window AND **detaint** ("clears anything the bot read from web/files this session"). **Durable memory PERSISTS by design**; forgetting facts is a separate confirm-gated `/memory delete`.
- **Prompt injection:** assume no reliable model-level fix; mitigate by least-privilege + approvals + blast-radius caps + the taint gate, not a classifier. Delimit/spotlight untrusted content; strip invisible/zero-width/bidi chars; tool output can never change system instructions.
- **Secrets:** never in replies or logs. **Exact-value redaction** of the loaded secret values (bot token, api keys, age-decrypted material) is the **PRIMARY** mechanism at both the log boundary and the outbound-reply boundary (the values are already in memory — cheap, deterministic); pattern-based scanning is **secondary** defense-in-depth. The gateway owns the destination chat id; outbound controls strip auto-fetching image/link elements.
- **Rotating credentials extend exact-value redaction to a dynamic set.** A static key is redactable once at load; an OAuth pair is not. The credential actor therefore keeps a bounded exact-value set covering the current token pair **and the prior pair during rotation** — the window in which a stale value can still surface — and each authorization carries the relevant set to the provider. OAuth and store code redact **before constructing any error**; inference redacts response heads, bounded error bodies, transport errors, and logs before they leave `ClawLLM`. **Never logged, even at debug level:** access/refresh tokens; device-auth IDs, user codes after the prompt, authorization codes, PKCE verifiers; the ChatGPT account ID; request/response bodies; provider replay payloads; owner prompt or model output text. **Safe diagnostics** are provider ID, qualified model, status code, attempt number, bounded retry delay, event/byte counts, credential freshness class, and generation number. Control characters and terminal escape sequences are stripped from remote text before it reaches stderr or Telegram — a remote string is never trusted with a terminal.
- **Opaque provider state is data with no reader** (§8.5). Replay payloads are never rendered into prompts, FTS-indexed, recall-eligible, or exposed to tools, audit arguments, logs, Telegram, or memory files, and are never sent to any provider but the issuer that produced them. They are the one context-carrying value with **no untrusted-tier wrapper**, and that is sound only because nothing outside the owning adapter ever interprets them: the moment anything else reads one, it needs the wrapper.
- **Accepted v1 limitation — `file_write` symlink TOCTOU.** `file_write` re-validates the approved path against the live filesystem at execution time (§10.2), but the directory creation, staging, and rename that follow are path-based, so a process racing the daemon on the same host could swap a parent directory for a symlink inside that window and redirect the write outside the workspace. This is **out of the v1 threat model** for the same reason §7 drops in-DB hash-chaining: a same-host attacker running as the daemon's user does not need the race — they can already write anywhere the daemon can. The four layers above defend against a subverted *model*, not a hostile co-resident process. If hardening is added later, bind the containment validation and the write to the same filesystem object (descriptor-relative, no-follow traversal; `openat2` + `RESOLVE_BENEATH` is Linux-only, Darwin needs a manual `O_NOFOLLOW` ancestor walk) — do not claim the race is closed without that.

### 12.1 Group mode (config-gated, off by default)

`CLAW_GROUP_CHATS` is a comma-separated list of Telegram chat ids `clawd` serves as a **shared room** instead of the owner's DM. Empty is the default, and with it empty nothing in this subsection exists: every claim in §1–§12 above is the DM's, unqualified. Group mode is a **deployment mode, not a product capability** — `docs/PRD.md` NG1 (multi-user) still stands, and the public install/customization docs do not carry it. It exists for a supervised, time-boxed event on a separate installation, and the trade it makes below is only defensible under exactly those conditions.

- **The mode is derived from the session key, never re-read from config.** `SessionKey` mints `tg:dm:<chatId>` for a DM and `tg:topic:<chatId>:<threadId|general>` for one forum topic; `SessionKey.mode(from:)`, `chatId(from:)` and `threadId(from:)` recover the three facts every consumer needs from the key alone. That matters because most consumers hold only a session id: `TurnRunner.resume`, a scheduled fire, and boot reconciliation all read the mode off the row they already loaded. **`AppConfig.groupChats` has exactly one reader** — the access decision — so no second component can drift about which conversation is which. The General topic carries no `message_thread_id` on the wire, so its key takes a `general` suffix that no numeric thread id can collide with; a non-forum group has one conversation and lands on that same key correctly.
- **Access is an allowlist of chats, not of users.** `AccessControl.decide` keeps the numeric-ID default-deny boundary for `.private` (the owner's allowlist, unchanged) and adds a **chat-id** grant for `.group`/`.supergroup`: being in an allowlisted room is itself the membership proof, so no `getChatMember` call, no per-user check and no per-attendee allowlist entry exists. `.channel` and any chat kind this build has never seen are refused, so a new Telegram surface can never inherit either grant. A refused DM is answered (the stranger can ask the owner for access); a refused chat is answered with **silence**, so the bot never announces itself to a room it was added to uninvited.
- **Intake observes before it decides to answer.** `AddressingResolver` decides whether a message is talking to the bot — an `@handle` mention, a slash command this build recognizes, or a reply to something the bot itself said — **before** the content switch, so an unaddressed photo or voice note is never downloaded or transcribed. An addressed message takes the ordinary `claimAndPersistInbound` path. Unaddressed text takes `claimAndPersistObserved`: the same claim, the same session upsert, the same message insert, **no run**. The router skips unaddressed media without downloading, transcribing, or storing a transcript row. The addressed and observed text paths share the claim key, so Telegram stores one text update at most once whichever path it takes. The bot follows the topic's text and speaks only when called. Group mode makes the bot's own `@handle` load-bearing, so a daemon configured with group chats **refuses to boot** without a resolved bot username rather than sitting silently in every room.
- **A stored group line names its speaker.** `TranscriptAuthor` renders `<display name>: <text>` at persist time, not at assembly time, so a recall hit pulled back out of history still says who said it and the name is in the FTS index. The separator and every line break are folded out of a display name first, so one line can never present itself as two speakers. A DM line is stored exactly as typed.
- **Recall never leaves the topic.** `Retriever.searchRelevantMessages` takes a `restrictToSessionId`; a group topic passes its own session id, a DM passes `nil` and keeps its cross-session reach. Without that restriction one room's words would surface in another room's prompt, because a group line is stored trusted (below) and trusted rows are exactly what recall returns.
- **There are no approvals in a shared room, so the gate refuses instead of asking.** Nobody in a group holds the owner's approval authority and no keyboard there could be trusted to resolve one, so `ToolPolicyGate` changes five decisions when `context.mode == .group`: the ask tier **allows on the gate-resolved target** rather than parking; a tool that only ever does its real work on the approval waiter (`memory_write`) is **refused** with a reason; a write whose canonical target is a **privileged prompt file** (`SOUL.md`/`AGENTS.md`/`TOOLS.md`/`USER.md`/`MEMORY.md`/`HEARTBEAT.md`, any `SKILL.md`) is **refused**, because in a DM the owner's ⚠ banner was the thing catching it and here there is no banner; the `.dangerous` arm **executes the prepared action** instead of parking it; and a held trifecta **allows**. Everything that is not an approval round-trip is untouched: `execEnabled`, `WorkspacePathContainment`, the SSRF classifier, the unconditional and conditional exfiltration argument scans, secret redaction, the tool-output cap, and the sandbox all run exactly as they do in a DM. The sandbox, not a prompt, is the containment for what a topic executes.
- **The owner-scoped command families are refused.** `Command.isDirectOnly` covers `/remember`, `/memory`, `/schedule`, `/pause`, `/resume`, `/run`, `/cancel`; a group invocation gets one refusal naming both families, so an attendee learns the rule rather than just this rejection. Two reasons, both structural: durable memory and the schedule table are single-owner state delivered to a chat id the arming message chose, and both park a confirmation that the **next plain message** resolves — in a shared room that message belongs to whoever typed fastest, so one attendee could commit a draft another one wrote. `/new` and `/stop` act on the topic's own session and stay available; the read-only reports name nothing private and stay available.
- **A reply goes back into the topic that asked, as a reply.** Migration `v10` adds `runs.trigger_telegram_message_id` (Telegram's own message id, distinct from the `messages` row id `trigger_message_id` already carries) and nullable `outbound_deliveries.message_thread_id` / `reply_to_message_id`. The outbox target is stamped **at enqueue from the run's own session key**, so every path that enqueues — a turn reply, a command reply, a scheduled fire, a boot crash notice — lands in the right topic without a second lookup. The typing indicator carries the topic id. Telegram accepts streaming drafts only in private chats, so a group turn keeps reissuing the topic-scoped typing action until the final reply arrives.
- **One throttled chat no longer stalls every other one.** The outbox drain is strictly ordered per chat and stops on a send failure, which in a DM meant one stalled conversation. With several topics live, a Telegram 429 is the one failure that says how long to wait, so the dispatcher puts a **per-chat hold** on the retry-after window, skips that chat's rows, and carries on with the others; order inside a run survives because a run answers exactly one chat. Every other failure keeps the existing stall-and-wait behavior.
- **Membership and migration are observed, never acted on.** A `my_chat_member` update logs who added or removed the bot, in which room, with the chat id and title — that log line is how an operator learns the id to configure. A `migrate_to_chat_id` message logs, at error level, that the chat id an access grant names has been replaced. Neither event edits the allowlist: rewriting it at runtime would re-point a grant at an id nobody approved, so the daemon goes quiet in that room and says exactly what to edit.

**What group mode gives up, and why that is acceptable here.** §12's four layers are not equally intact in a shared room, and pretending otherwise would be worse than saying it:

- **Attendee text is trusted, not fenced.** `ChatMode.storedProvenance` stores every group line as `.trusted` — including a voice transcript, which in a DM persists untrusted and taints the session. The reason is mechanical: recall returns only trusted rows, so storing an attendee's words untrusted would make the topic's own history unsearchable. The consequence is that **an attendee's message is prompt-injection surface that reaches the model unfenced**, and that a topic never arms taint from what people say in it. Tool output is unchanged and still taints, so a topic that fetches a page is tainted from that point on.
- **The trifecta gate is disarmed, not merely unarmed.** Even where taint *is* armed by a tool, the arbitrary-destination egress arm allows instead of requiring approval, because there is no approver. The argument scans that block private substrings and secret-shaped tokens before dispatch still run, and the LLM egress sink is still pinned — but "gated by approval" is not a guarantee group mode offers.
- **The owner's durable memory is in the room.** `memory_items`, `MEMORY.md` and `USER.md` assemble into a group topic exactly as they do into a DM, and because attendee text does not taint, high-sensitivity items are **not** suppressed there. A group-mode installation therefore must not share a state root with the owner's personal one.

The accepted reasoning is the deployment, not a mitigation: a **supervised, one-week event on a separate installation** whose workspace and memory hold nothing private, with a human watching. Outside those conditions the trade does not hold, which is why the mode is off by default and absent from the public docs.

**Two accepted limitations, recorded so they are not rediscovered as bugs:**

- **`/new` clears the window, not the archive.** A reset moves `window_start_message_id` forward and clears taint and the private-data flag for that topic, so the visible conversation starts fresh. It does not delete rows, and topic-restricted recall still searches the topic's older messages — so a fact from before the reset can resurface. Making a reset unrecallable is a retention feature, not a windowing one.
- **The daily `RunBudget` is one budget for the whole daemon.** It is per-day and per-run, never per-chat or per-person, so one busy topic can exhaust the day for every topic and for the owner's DM. Per-person rate limits and per-topic budgets are deliberately out of scope.

## 13. Execution / sandbox architecture (Inc 5b macOS; Inc 6 Linux)

- **`ExecutionBackend` protocol** (`Sendable`), driven via `swiftlang/swift-subprocess`:
  - **macOS 26+ arm64 (Inc 5b):** `ContainerBackend` shells out to the fixed
    `/usr/local/bin/container` apple/container CLI. Every container receives its own
    Virtualization.framework VM; a container escape therefore still needs a hypervisor escape.
  - **Linux (Inc 6):** the backend remains open behind the same protocol. A pinned Linux-host
    spike must prove lifecycle, no-egress, opted-in egress, resource caps/cgroups, rootless
    operation, and cleanup. If the selected backend is not a hardware-virtualized microVM, PRD
    FR-X1 must be amended before implementation.
- **Feature floor:** the package remains macOS 15 compatible, but `execute_code` is absent unless
  the host is macOS 26 or newer on arm64. Linux, macOS 15, and Intel macOS fail closed and doctor
  explains why. No macOS-15 degraded mode exists.
- **Isolation unit:** one untrusted execution = one fresh disposable, never-reused VM. Scratch is
  created and destroyed per run. No warm pool, snapshot clone, or interactive persistent session
  ships in this increment.
- **Secure-by-default launcher:** no live workspace, home, or ambient host path is mounted. The
  sole host mount is the daemon-owned per-execution scratch directory containing bounded copies of
  approved inputs; it is mounted at `/work` with the explicit `readonly` option. Every run uses a
  read-only root filesystem plus `/tmp` tmpfs, `--cap-drop ALL`, `--init`, explicit CPU/memory caps,
  a digest-pinned workload image, an explicit interpreter entrypoint, deterministic identity, and
  unconditional cleanup. apple/container owns the init image: the backend resolves its exact
  runtime reference, pulls it over HTTPS, passes it explicitly, and reports it as a
  version-coupled trust dependency without claiming digest verification the CLI cannot expose.
- **Workload image pin:** the distribution ships a release-verified default digest pin
  (`PinnedImageReference.verifiedDefault`), so `CLAW_EXEC_ENABLED=true` is a complete config.
  `CLAW_EXEC_IMAGE` overrides it and must itself be digest-pinned and registry-allowlisted; an
  invalid override fails config load without falling back to the default. Rotating the default
  digest repeats the release verification procedure in `LOCAL_DEV.md`.
- **Network is explicit in both directions:** default execution emits
  `--network none --no-dns`; owner-approved `network: true` emits `--network default`. Omitting
  `--network` is forbidden because apple/container attaches the default network and grants full
  egress. Networked execution is `canExfiltrate=true` and remains dangerous/approval-gated.
- **Staging is a gated data crossing:** every source is an existing regular workspace-relative
  file resolved through canonical realpath containment. The approval binds source path, realpath,
  byte count, and SHA-256; execution re-resolves and re-hashes before copying. Code and every
  staged file always pass exact-secret and secret-shape scanning; networked runs additionally pass
  the MEMORY/USER substring tier.
- **Backend state lives in an actor, but actor isolation is not a run limiter.** A stored `Task`
  chain serializes the whole spawn → execution → cleanup operation across suspension points, so at
  most one VM contributes its peak memory footprint.
- **Timeout and output:** the program budget starts after spawn; the whole call returns within that
  budget plus a 20-second teardown allowance. The launcher explicitly configures process-group
  teardown, drains stdout/stderr concurrently, retains at most 1 MiB per stream while continuing
  to drain, and then destroys the named container and scratch on every exit path.
- **Maintenance and doctor:** `SandboxMaintenance.prepare()` reaps owned leftovers, pre-pulls the
  pinned workload and exact runtime-owned init references, and boots a hardening canary. Any
  failed host, version, digest, capability, network, resource, reaper, rootfs, staging, or
  interpreter assertion keeps `execute_code` out of the registry. `shutdown()` cancels the
  execution chain and reaps again.
- **swift-subprocess is only a launcher.** It provides no isolation. Pin exact release 1.0.0, use
  streaming capture and an explicit teardown sequence, and keep the hardware VM as the boundary.
- `sandbox-exec`/Seatbelt may wrap the launcher only as optional defense-in-depth; it is never the
  isolation boundary.

## 14. Scheduler architecture (Inc 4)

- **`Calendar.RecurrenceRule`** (in-toolchain, DST/TZ-correct, `Sendable`/`Codable`) + a ~150-line custom 60s ticker.
- Jobs persisted in `scheduled_jobs`; **fire-once-per-occurrence**; **two complementary DB guards, not flock**: (1) an **atomic per-occurrence CLAIM** — the compare-and-advance of `next_occurrence` — so the SAME occurrence can never double-fire, and (2) a **per-session live-run gate** that skips a fire while a prior run on that session is still live (PENDING/RUNNING/AWAITING_APPROVAL), so overlapping occurrences of one job/heartbeat serialize instead of racing the shared context window. Due-time computed against **wall clock** (clock-gap-robust), with a catch-up cap (§6.3). (Reconciliation, Inc 4: the research corpus suggests actor-lock *plus* flock as overlap guards — rejected; these two DB-level guards replace them, and the §4 startup flock already covers the second-process case.)
- Scheduled runs are **reduced-privilege** agent runs (confirm-before-arm, no auto-approval, default-DENY — in Inc 4 (pre-approval-FSM) an immediate audited DENY with no pending state; with Inc 5a's FSM the same branch becomes park-with-timeout → EXPIRED → DENY — own daily budget); delivery routed to the owner's DM via the outbox; audit on create/execute/cancel/fail. NL → schedule via an LLM parse step that requires owner confirmation; the parse obeys turn spend discipline — day-cap preflight before the call, a run-less `provider_usage` row after (`run_id NULL`), and a 30 s deadline so the poller is never blinded. Attack-case to test: a self-scheduling injection cannot create a recurring fetch-and-follow C2 loop.
- **Per-fire context isolation.** The fire transaction resets the session's context window (`window_start_message_id` → the pre-fire high-water mark, taint/private-data cleared — `/new` semantics) before inserting the trigger row, so every fire that runs starts on a fresh transcript of its persistent `sched:job:<id>` (or `sched:heartbeat`) session. That reset is session-global, so a fire into a session that already has a live run (PENDING/RUNNING/AWAITING_APPROVAL — e.g. one parked on an approval) is **skipped entirely** rather than run: resetting would advance the shared `window_start_message_id` past the live run's own rows and empty its context on resume (silent data loss). A skip resets nothing and inserts no trigger/run — the occurrence is dropped misfire-style with the schedule still advancing, audited as `job_overlap_skipped` (jobs) or `heartbeat_skipped` with the overlap reason (heartbeat). Prior fires stay durable (audit, FTS, interactive recall) but never replay into a proactive run's context, and proactive turns assemble under the dedicated proactive prompt with recall omitted (§9.2) — a fired task can never read as a "please arm a schedule" chat message, and one bad fire cannot poison the next.
- `getUpdates` recovery is pinned: socket read timeout = long-poll timeout + 10 s; backoff-reconnect on timeout/network error. Scheduler-side gap recovery is lateness-based (§6.3's catch-up table) — no wake detection. Doctor exposes `last_tick_at`.

### 14.1 Scheduled learning terminal decisions

The generic learning loop follows the accepted
[production design](superpowers/specs/2026-09-02-generic-production-learning-loop-design.md)
and the fixed `scheduled-learning/v1`
[algorithm](research/170-generic-scheduled-task-learning-algorithm.md). `ClawCore` owns its
protocols and value types; `ScheduledLearningStoreGRDB` commits its transitions through
`writeMapping`. The workflow coordinator consumes store recommendations separately from the
terminal transaction.

`applyTrialDecision(_:trial:feedbackRevision:now:)` captures the reviewed trial identity,
candidate and replacement digests, base digest and revision, algorithm, and current feedback
revision. In one transaction it checks the repeatable non-cancelled job, epoch and generation,
all reviewed identities, stable base and feedback revision, then projects the entire assigned
cohort from authoritative evidence, evaluator operations and effective owner signals. Promotion
requires at least two distinct positive runs, zero negatives or hard vetoes, and resolution of
all assigned runs. It revalidates the candidate's immutable provenance and effective source
edges. Trial feedback may advance the reviewed revision without changing an unrelated candidate
source edge. Production freezes no deterministic adapter, so it requires no deterministic receipt.

The transaction writes a canonical terminal receipt, compare-and-swaps the stable pointer and
revision, and closes the exact trial. The receipt keeps the complete cohort, including every
positive run, its evaluation dependency, effective feedback revision, correction digest and owner
confirmation. Activation and evidence remain separate: promotion is heuristic, while the receipt
reports owner-confirmed support. A repeated exact terminal request returns its original receipt.
An unresolved cohort produces no terminal receipt until a policy deadline or veto permits fallback.
Fallback leaves the stable pointer untouched. Stale reviewed predicates record a stale decision;
only the matching live trial may close. Candidate-edit predecessor closure, candidate rejection,
and disputes of required candidate-source evaluations use the same terminal receipt helper within
their existing feedback/edit transaction.

`rollback(_:now:)` names one promotion receipt. It restores that promotion's direct retained base
only if both the current stable digest and revision still identify the promotion in the same epoch.
Owner triggers reference a durable, effective authenticated `candidate_reject` or
`promotion_rollback` event on the exact candidate or promotion subject. Support-withdrawal triggers
reference an effective owner not-useful, correction or evaluation-dispute event affecting one of
the receipt's positive runs; the store reprojects only that fixed positive set and rolls back when
fewer than two valid supports remain. A later active-run heuristic issue cannot supply this trigger.
Trusted safety receipts bind the promotion and a security, secret-leakage, corruption or invariant
failure. Adapter critical/regression triggers remain inert because production freezes no adapter.
Stale triggers record a stale receipt and leave state unchanged. A successful rollback also closes
a live successor trial with a stale receipt because that trial depended on the withdrawn base.
Rollback keeps the epoch and
advances the stable revision; owner reset remains its separate epoch-raising transaction. A closed
or rolled-back replacement cannot open another trial against the same base and algorithm.

The owner view decodes terminal receipts as well as admission, reflection and reset receipts.
`currentPromotion(jobId:)` finds the exact active promotion independently of the last decision.
For `/learning <jobId>`, `commitPromotionReply` rechecks that promotion, claims the transport update,
and writes the exact promotion feedback target and all command-reply outbox chunks in one
transaction. Only the final chunk carries the rollback button. The gateway pokes `OutboxSignal`
after commit. A stale promotion exposes no new target. Callback-driven progression belongs to the
workflow coordinator; the feedback boundary still authenticates, consumes and records the request.

### 14.2 Scheduled learning workflow

`ScheduledLearningService` queues lane-settlement and authenticated-feedback notifications on its
stored drain task. Owner callbacks and challenge acknowledgements enqueue work without awaiting
an inference. Direct `advance(runId:)` and `advance(jobId:)` calls await a bounded `LearningWorkflow`
pass. The composition root supplies the actual provider roster, shared primary cooldown, configured
budget and cost resolver, the redactor including MCP secrets, and notices using the shared outbox
signal. A failed boot operation reconciliation prevents learning dispatch; ordinary delivery remains
available.

The run pass seals evidence, evaluates it under the durable operation claim, recomputes its trial
assignment and advances the job. Evaluation commit includes the content-free `learning_evaluated`
audit event in the same transaction. The job pass applies pending immutable candidate controls,
reconciles trial decisions and exact promotion rollback triggers, admits retained artifacts and
commits review notices, then discovers eligible reflection windows. These transitions use their
existing store claims and compare-and-swap transactions. Exact rollback-trigger replay returns its
original receipt; a later distinct feedback event receives a distinct decision.

Recovery reads in `LearningWorkflowStore` do not arm jobs. The periodic sweep pages through armed
job IDs, recovering sealed unevaluated runs, artifacts awaiting admission or notice, controls and
trial deadlines. Terminal denied or completed operations do not occupy the claimable queue.
`LearningWorkflow.maxTransitionsPerInvocation` limits a job pass to 64 reviewed transitions and
logs an error when more work remains. The next sweep resumes durable work.

Trigger discovery preserves the canonical trigger digest and the current global feedback revision
required by admission. When an attempted trigger has the identical evidence window, base, algorithm
and qualifying issue codes, candidate or promotion controls alone do not authorize another
reflection. Discovery compares the prior exact operation keys across the trailing control-only
revision sequence and waits. New evidence or run/evaluation feedback can authorize another trigger.
This follows the algorithm's owner-edit bypass and effective-feedback retry boundary; it resolves
the reference reducer's discrepancy between skipping trigger discovery on a candidate event and
rediscovering the same window on its clock path. No persisted revision or algorithm parameter changes.

## 15. Configuration & secrets

- **Environment variables are the active configuration surface; `config.toml` remains future work.** The typed `AppConfig` is loaded from the environment/`.env` today; the structured-file behavior described below is the intended shape once that file lands, not a shipped surface. **A provider-qualified `CLAW_LLM_MODEL` value (`openai-chatgpt/<model>`) is the only configuration selector the subscription route adds** — there is deliberately **no per-provider environment namespace**. The model value carries the route selector, provider-owned OAuth state lives in the credential store, and fixed protocol details are implementation constants (§8.3), so ad-hoc `CLAW_CHATGPT_*` variables would only duplicate the structure that structured configuration will supply; they are **deferred with `config.toml`**, not merely unimplemented. When it lands, the registry deserializes provider-specific blocks into the same resolved route (§8.1) without changing any downstream seam.
- **`CLAW_LLM_FALLBACK_*` is the one deliberate exception to that rule, and stays a single prefix.** `CLAW_LLM_FALLBACK_MODEL`, `CLAW_LLM_FALLBACK_BASE_URL`, `CLAW_LLM_FALLBACK_API_KEY`, and `CLAW_LLM_FALLBACK_MAX_TOKENS_FIELD` describe a **second route** (§8.6), which needs an endpoint and a key of its own rather than a provider's. Reusing the primary's would point the fallback at the endpoint that just failed, and would let a missing primary endpoint pass validation on the strength of one the fallback supplied. The exception buys a route, not a namespace: it adds no per-provider variable, and `CLAW_LLM_PRIMARY_COOLDOWN_SECONDS` (default 900) carries no prefix because it describes the daemon's own backoff. The fallback key is a runtime secret like the primary's: it seals into `secrets.enc` with the rest, and `clawd secrets seal` blanks its plaintext line alongside them. **One list names every sealed variable** (`EnvSecretStore.EnvKey.sealed`), read by both the env-file scrub and the message telling an owner what to remove when the scrub cannot run, so a secret can never reach the envelope while its plaintext line survives unmentioned.
- **Config:** a typed `AppConfig` (validated at load); env/`.env` for development; an invalid config is **rejected and preserved** — the offending file is moved aside as `config.toml.rejected.<timestamp>` and the last-known-good config is kept, never silently overwritten or partially applied; **`doctor --check-config` validates without starting the daemon**; config-validation and secret-load failures are **distinct non-retryable exit codes**. `max_tokens` MUST be a bounded non-null value — **doctor rejects a config with null `max_tokens`** (§5.3). **`approval_expiry`** (Inc 5a) is a bounded duration with a validated **floor 60s, ceiling 86400s (24h), default 3600s (1h)** — how long a pending approval waits before `EXPIRED → DENY` (§11/§19.1); a violation is a distinct non-retryable `ConfigError` (exit code `configInvalid`).
- **The MCP server list is a file, not an environment namespace** (§10.3). A per-server catalog needs nesting that `CLAW_*` variables cannot express, so it is a YAML document read from `CLAW_MCP_CONFIG` or, unset, probed at `<state-root>/mcp.yaml`. **An absent probed file turns the feature off; a path the owner set that clawd cannot read or parse is a `configInvalid` boot failure** — an owner who named a file meant it. Unknown keys are rejected rather than ignored, so a typo surfaces as an error instead of a server that never loads and never says why. The file holds **no secrets**: its `headers` map is for non-secret extras. Config validation rejects malformed HTTP field names and values, protocol-owned headers such as `Mcp-Session-Id`, and any entry that shadows the configured auth header. A present `tools.include` list defines the whole allowlist; an empty list exposes no tools, while an absent list lets `exclude` decide.
- **MCP tokens are a third envelope, again not a third key.** `<state-root>/mcp-credentials.enc` sits beside `secrets.enc` and `llm-credentials.enc` under the same `secret.key`, with its own purpose-labeled associated data, and shares the crash-aware publication protocol above rather than reimplementing it. Its plaintext is a versioned map of server name → token **plus a fingerprint of the URL the token was issued for**; a mismatch at load reports as its own outcome and the token is treated as absent (§10.3). Mutation is CLI-only under the instance lock, and the daemon reads the map once at boot. Startup validates a present envelope even when the catalog is empty, so a retired or corrupt credential file cannot bypass the secret integrity check.
- **Onboarding / first-run:** the owner ID enters the default-deny allowlist via the **config file in v1**. An UNKNOWN sender's `/start` may echo **THAT sender's own numeric ID** (so they can self-allowlist) but **never reveals allowlist contents** and **never itself grants access**. A doctor check confirms **"at least one owner is allowlisted."** Pairing (later) = a high-entropy single-use expiring rate-limited audited secret provisioned out-of-band; pairing writes go through the same audited, idempotent allowlist path.
- **Secrets:** a `SecretStore` protocol. **Not the macOS Keychain** (a launchd daemon can't use the Data-Protection keychain; the System keychain is root-only/deprecation-flagged). Implementation: a `swift-crypto` **AES-GCM envelope** — `[1-byte version] + SealedBox.combined` (12-byte random nonce ‖ ciphertext ‖ 16-byte tag, over associated data) — sealing `secrets.enc` and `llm-credentials.enc`, unsealed into memory at startup. The 32-byte symmetric key sits beside them as `secret.key`, mode `0600`, opened only through no-follow, regular-file, owner-uid and mode checks. Dev fallback: `0600` `.env` / env vars (warned on every boot).
- **Provider credentials are a second envelope, not a second key.** `ClawSecrets` adds `<state-root>/llm-credentials.enc` beside `secret.key` and `secrets.enc`, encrypted under the **existing** 256-bit `secret.key` with **distinct versioned associated data** — so swapping the two envelopes fails authentication rather than decrypting the wrong purpose. Its plaintext is a versioned, provider-keyed map holding **at most one record per provider** (`openai-chatgpt` is the first). Re-login replaces that record; **logout rewrites a valid empty map** and never deletes `secret.key` or `secrets.enc`. Logout is **local deletion, not server-side revocation** — an issued access token may stay valid until its vendor expiry, and the owner-facing copy must say so.
- **Credential publication is crash-aware.** The store opens `secret.key` through the existing no-follow/regular-file/owner-UID/mode-`0600` checks, opens an existing envelope under the same rules, **rejects an oversized envelope before allocating its plaintext**, and publishes through a same-directory `0600` temp file → fsync the file → atomic rename → fsync the parent directory. Malformed, unsupported-version, oversized, or undecryptable envelopes fail closed, and **no raw decoding or cryptography error carrying plaintext crosses the seam** (§19). A pre-rename failure leaves the old map; a failure after rename but before the directory fsync is a **typed commit-uncertain result** whose caller reloads and retries publication before making the credential available. The map's read-modify-write is serialized by the credential actor in the daemon and by the instance lock in mutating CLI commands (§4); cancellation is checked before publication starts and the bounded synchronous publication then runs to completion. Because replacement is atomic from a reader's view, a status read racing a daemon refresh sees only a complete old or new envelope, and unrelated provider records survive a single-record write. **No local file protocol can close the window between a vendor rotating a refresh token and local publication** — a crash there can require a fresh login.
- **Login completes the encrypted backend before it creates a credential.** The resolver already requires the encrypted backend once *either* `secret.key` or `secrets.enc` exists, so `auth login` must not create a key by itself and strand an environment-backed install in a partial state: when neither artifact exists it first loads the existing environment runtime secrets, seals them through the same operation as `clawd secrets seal`, **verifies a real decrypt**, and only then writes `llm-credentials.enc`. Missing required runtime secrets fail login **before any credential file is created**; exactly one of the two artifacts present fails closed with the same repair guidance as daemon startup. The shared seal operation records which artifacts it created and their device/inode identities, and on same-process failure removes the new envelope first and the new key second — each deletion gated by no-follow metadata requiring the **recorded inode, owner, regular-file type, and expected mode**, so it can never delete a pre-existing or substituted entry — then fsyncs the parent directory. **A crash between two file creations cannot be made atomic across two pathnames**; the resolver detects that partial state and requires the owner to rerun `clawd secrets seal`. This transition runs **even on the ChatGPT route**, which needs no API key, because Telegram and optional search secrets must stay bootable once the encrypted backend becomes authoritative.
- **A logged-out subscription route still boots.** With ChatGPT selected, an absent envelope or provider record is a **valid logged-out state** — the daemon boots so Telegram can deliver login guidance rather than dying where the owner cannot see it. An envelope that exists but is insecure, malformed, or undecryptable is a **secret-load failure** (its own non-retryable exit code — §4). The current API route never opens an unused OAuth envelope during composition.

## 16. Observability

- **Structured logs** (`swift-log`) — metadata only by default (model, tokens, finish reason, tool, latency, status); prompt/completion content capture is opt-in. Exact-value secret redaction at the boundary (§12).
- **`status` / `doctor` are clawd CLI subcommands AND Telegram commands** (`/status`, `/cost`) — **distinct** from the NG4 REST non-goal. `doctor --check-config` validates without starting the daemon. There is a **machine-readable JSON-to-stdout** form pollable by launchd/systemd watchdog.
- **`doctor --check-config` carries a network-free `llm.auth` row.** It **never refreshes, fetches models, or contacts the provider** — a diagnostic that mutates credentials or spends a login is not a diagnostic. Current route with a static key reports `provider=openai-compatible mode=static`, without one `mode=none`; a decryptable, refreshable ChatGPT credential reports `provider=openai-chatgpt mode=oauth status=<fresh|expiring|expired-refresh-on-use>` and passes; no usable credential **fails** the row with `clawd auth login` guidance; a malformed key or envelope fails as a decrypt row. The existing `secrets` row still validates `secrets.enc` independently. `llm.auth` inspects the **primary** route only, so a fallback's credential is first exercised when the fallback carries a turn.
- **A stopped daemon answers for configuration, never for live routing.** `doctor --check-config` carries `llm.fallback_configured`, since whether a second route exists is a fact about the environment. The cooldown windows live in the running daemon's memory (§8.6), so the full `doctor` run by a separate process renders `llm.active_route` as the configured primary and `llm.primary_cooldown_s` as `unknown` rather than claiming the primary is clear.
- **MCP health is reported at three ranges from one row builder.** `doctor --check-config` prints the offline rows only — config and token state, no socket, same rule as `llm.auth`; a full `clawd doctor` adds a live probe over the same session path the daemon boots with, so a server that probes clean is one that will load; and the running daemon answers `/mcp` from the boot snapshot it already holds, which is what keeps that command status-only. `clawd mcp list` and `clawd mcp probe` are the same two ranges as standalone commands. All three read one row builder, so an owner comparing `clawd doctor` against `/mcp` cannot be told two different stories about the same server.
- **Workspace skill health uses a fresh scan.** Full `clawd doctor` and each Telegram `/status`
  request scan the configured workspace root and add the headline row `context.skills` with
  `accepted=<count> rejected=<count> fits_cap=<true|false>`. The counts come from the scan's
  accepted descriptors and warnings. `fits_cap` compares the complete canonical index text with
  the absolute `skillsCap`, including equality as a fit; it does not estimate the smaller residual
  budget available to a particular turn. Any rejection or an over-cap index fails the row, makes
  full doctor exit nonzero, and remains visible in `/status`. `doctor --check-config` stays limited
  to config and secret checks and does not scan the workspace.

### 16.1 Health table (doctor / status)

Every store-backed health query reserves zero, `none`, and empty values for successful reads. A
failed read renders each dependent row as failed and `unreadable`; doctor does not substitute an
empty healthy state.

| Subsystem | Fields |
|---|---|
| poller | `connected`, `last_update_at`, `last_offset`, `last_409_at`, `last_429_at`, `dropped_updates` |
| LLM | `last_success_at`, `consecutive_failures`, `last_error_class`, `retry_budget` |
| LLM routes | `active_route` = the route the next turn starts on (the answering route plus `(primary <ref> cooling)` while a window is live; `(configured primary)` from outside the daemon); `fallback_configured` = `yes (<model reference>)` or `no`; `primary_cooldown_s` = remaining seconds, `none`, or `unknown`. **`active_route` is a headline row**, so it rides the group line into the Telegram `/doctor` summary (which keeps headlines and failures only) and the owner can always see which model answered; `primary_cooldown_s` is a headline **only while a window is live**, and `fallback_configured` never is |
| LLM auth | `provider`, `mode` (`static` \| `none` \| `oauth`), `status` (`fresh` \| `expiring` \| `expired-refresh-on-use`), decrypt result — **network-free**; never a token, account id, or expiry-bearing secret |
| DB | `writable`, `WAL_size`, `last_checkpoint_at`, `free_disk` |
| scheduler | `last_tick_at`, `due_count`, `last_misfire` |
| runs | `in_flight`, `oldest_run_age`, `last_FAILED` |
| spend | `today_usd`, `remaining_budget` (per-run + per-day) |
| sandbox | `available`, `os_ok`, `engine_version`, `version_ok`, `image_digest_ok`, `caps_empty`, `net_isolated`, `caps_match`, `reaper_ok`, `rootfs_ro`, `staging_ro`, `interpreters_ok`, `last_error` |
| MCP | per server: `enabled`, `token` (`set` \| `absent` \| `bound-to-a-different-url`), effective include/exclude, and — where the boot snapshot or a live probe is available — `tool_count` or the recorded `skip_reason`; never a token value |
| context skills | `accepted`, `rejected`, `fits_cap`; headline row from a fresh scan in full doctor and `/status`; unhealthy when `rejected > 0` or `fits_cap = false` |
| config/secret | validation result — **printed first** if it errored |

- **Audit:** ordinary append-only (§7.2) — useful for "why did it do that." No tamper-evidence claim in v1.
- **Cost:** per-call USD from a local pricing table, attributed per run; unknown model price → loud doctor warning, never silent $0.

## 17. Deployment & portability

- **Build:** SwiftPM (**platform floor macOS 15** — `Calendar.RecurrenceRule` requires it, Inc 4/§14); two release binaries: a **macOS-native `arm64` binary** and a **Linux `x86_64` binary built natively in the `swift:6.3-noble` container** with `--static-swift-stdlib` (the Swift runtime is bundled; the system `libsqlite3` is the sole external runtime dependency). A musl **Static Linux SDK** → fully-static/distroless image is deferred: GRDB v7 declares SQLite as a `.systemLibrary` and the musl SDK ships none, so a musl cross-compile can't link (see §18 Deployment escape hatch).
`execute_code` has its own stricter runtime gate: macOS 26+ arm64. It stays absent on every other
build; the portable `ExecutionBackend` types and all fake-backed tests still compile on Linux.
- **Portability is enforced continuously:** a **GRDB + FTS5 build+test gate runs on both macOS and Linux on every PR** (`ci.yml`) — the portability gate is live, not deferred. Portable protocol seams + AsyncHTTPClient/OpenAI-compat choices are kept throughout; pragmatic macOS-native code is permitted behind a protocol and covered by the Linux CI gate.
- **Supervise:** launchd plist (macOS) / systemd unit (Linux), with throttling (§4). Logs to stdout/stderr.
- **Credential mutation is a stop-the-daemon operator step.** `clawd auth login` / `clawd auth logout` and `clawd mcp set-token` / `clawd mcp clear-token` acquire the same state-root instance lock the daemon holds (§4), so under launchd/systemd the owner stops the supervised service, runs the command, and starts it again — the daemon is the only process permitted to refresh and save a credential while running. `clawd auth status` and `clawd mcp list` / `clawd mcp probe` are read-only and safe against a live daemon. The printed `CLAW_LLM_MODEL=openai-chatgpt/<model>` assignment is applied by the owner: **login never edits `.env`, a launchd plist, a systemd unit, a shell profile, or a future config file.**
- **CI:** the macOS + Linux **GRDB + FTS5 build+test gate** (`ci.yml`) runs on every PR and blocks merge; releases (`release.yml`) publish as **GitHub Releases with SHA256 checksums + build-provenance attestations**, not a container image.

## 18. Technology decisions

| Decision | Choice | Rationale | Alternative / escape hatch | Risk |
|---|---|---|---|---|
| Daemon framework | `swift-service-lifecycle` ServiceGroup / NIO | structured supervised lifecycle; no listen socket | Hummingbird 2 (if REST later) | Low |
| Telegram client | **thin clean-room client** over AsyncHTTPClient (research **runner-up**; primary was `nerzh/swift-telegram-bot`) | deliberate clean-room provenance, zero bus-factor, full transport + offset-durability control; ~8–10 endpoints (getUpdates, sendMessage, **sendRichMessage**, editMessageText, sendChatAction, answerCallbackQuery, getMe, setMyCommands, getFile) | `nerzh/swift-telegram-bot` | Low–Med |
| Persistence | GRDB.swift v7 (WAL, FTS5, migrations); **pin GRDB** via committed `Package.resolved` + Dependabot + the CI gate (the `from:` range is the floor, `Package.resolved` is the pin); links the system `libsqlite3` (vendoring a SQLite amalgamation is deferred — it arrives only with sqlite-vec, §7.6); macOS + Linux CI job exercises GRDB+FTS5 | Swift-6 concurrency-native, boring, full-featured | SQLite.swift / raw C | Low |
| Vectors | deferred, behind protocol; **requires custom SQLite amalgamation + Linux re-validation** (§7.6) | `sqlite-vec` is alpha; stock migrator can't make a `vec0` table | FTS5/BM25 for v1 | High |
| LLM provider | **One `LLMProvider` domain contract, two wire adapters** — configured OpenAI-compatible Chat Completions + ChatGPT Codex Responses — with authentication behind a **separate `LLMCredentialSource` seam**; an ordered roster with one active route per provider call (§8.6) | swap providers/models via one config value; keeps OAuth and wire formats out of the agent loop; pinned/allowlisted `base_url` on the configured route, a compile-time endpoint on the managed one | native Anthropic adapter later; teaching `LLMProvider` about OAuth (rejected — forces unrelated providers to implement ChatGPT concepts) | Med |
| ChatGPT subscription auth | Codex **device-code** OAuth + the private ChatGPT Codex Responses route, behind `ClawAuth`/`ClawLLM` adapters, on a **swift-claw-owned** credential envelope [P-auth] | direct native route: no Codex subprocess coupling daemon availability/upgrades to another program, no shared credential file with cross-process rotation hazards, logout unambiguous, fully testable with scripted HTTP | **unofficial and vendor-dependent (§8.3)** — the escape hatch is the supported OpenAI-compatible route, always one `CLAW_LLM_MODEL` change away; rejected alternatives: import `~/.codex/auth.json`, shell out to Codex, add an API proxy | **High** |
| MCP client | official `modelcontextprotocol/swift-sdk` for the protocol, **our own Streamable HTTP transport** over the shared HTTP seam [P-mcp] | the SDK owns the wire format and its evolution; its bundled transport is URLSession-based and cannot stream SSE on Linux, and our own sits on the seam every test already scripts | SDK `HTTPClientTransport` on macOS-only builds; stdio for local servers (deferred, §10.3) | Low–Med |
| Web search backend | Exa (`https://api.exa.ai/search`) behind `SearchProviding` [Inc 3b] | pinned trusted endpoint, documented trust dependency like `base_url` (Exa may use query input/output to provide/improve its services) | unconfigured `Secrets.searchApiKey` ⇒ tool absent, doctor reports info not error | Low |
| HTTP/SSE | AsyncHTTPClient + small SSE parser (**streaming in v1**) | URLSession can't stream SSE on Linux | — | Low |
| Sandbox | `apple/container` (macOS) + microVM/Podman (Linux) behind `ExecutionBackend` [Inc 5b] | hardware-virt boundary for untrusted code | colima (weaker, older-macOS) | Med |
| Secrets | `SecretStore` over a swift-crypto AES-GCM envelope + a local `0600` key | daemon can't use macOS Keychain; portable | 0600 env file (dev) | Low |
| Scheduling | `Calendar.RecurrenceRule` + custom ticker/store [Inc 4]; **raises the platform floor to macOS 15** | in-toolchain, DST-correct; Codable round-trip + DST suite pinned as toolchain-drift tripwires | SwifCron (vendored) | Low |
| Concurrency | std-lib actors + stored `currentTurn` Task handle (await-to-order, cancel-to-supersede) | per-session lanes without an external queue lib | `dfed/swift-async-queue` (escape hatch only) | Low |
| Config files | YAML for SKILL.md frontmatter via Yams | maintained YAML parser | — | Low |
| Deployment | native-container Linux `x86_64` binary (`swift:6.3-noble`, `--static-swift-stdlib`) + macOS-native `arm64` binary; GitHub Releases with SHA256 checksums + provenance attestations; launchd + systemd | Swift runtime bundled; only `libsqlite3` needed at runtime; publishes without a container registry | musl Static Linux SDK → distroless/scratch (blocked today: GRDB links system SQLite, musl SDK ships none) / swift-sdk-generator (glibc) | Low |

## 19. Cross-cutting concerns

- **Error taxonomy.** A top-level error taxonomy lives in `ClawCore`: `ProviderError`, `TelegramError` (incl. the **distinct 409 conflict** type), `PolicyDenied`, `BudgetExhausted`, `StoreError`, `ConfigError`. Each is tagged **retryable | terminal | user-visible**. The retry classifier and the "failures-as-observations" rule both consume this taxonomy. `ProviderError` additionally carries the redaction-safe `authenticationRequired`, `accessDenied`, `quotaLimited`, and `cleanRejection` cases — the first three drive distinct owner messages, the last represents a terminal response head where inference did not start. `CredentialStoreError` (aliased `LLMCredentialStoreError`) is the **closed, redaction-safe** store taxonomy shared by the provider and MCP credential stores (missing key material, insecure permissions, unreadable or malformed envelope, decryption failure, unsupported version, oversized data, pre-commit write failure, commit-uncertain publication) mapped to the existing secret-load exit code; **raw `Crypto`, `POSIX`, and Foundation errors never cross that seam** — the same rule as `StoreError` at the GRDB seam (§7).
- **Failures are wrapped, not merely typed.** `ProviderFailure` pairs the cause with the §8.4 attempt-exposure accounting disposition, and `ProviderInferenceCancellation` carries it out of the buffered path. **The runtime branches on that disposition, never on which execution method the caller used.** Clean head rejections (auth, access, quota, other) are `notStarted` and write **no** estimated usage row; once a body was handed off, every failure without a proven clean rejection is `mayHaveStarted` — transport loss before the head, failure under an accepted 2xx head, terminal-free EOF, malformed or oversized SSE, parsed provider errors — and records conservative usage. **None of those ambiguous failures is retried automatically.**
- **Error handling:** tool/run failures captured as observations, not crashes; the loop stays alive; typed errors at boundaries.
- **Retries/backoff:** one layer, retryable-only classifier, capped exponential + full jitter, retry budget (~3/req), honor `retry_after`. **An attempt that may have been sent is never retried automatically** (§8.4), and one budget counts every wire attempt of a call — refresh, replay recovery, throttle, and server retries alike. Retries count against budgets (§5.3).
- **Idempotency:** synchronous `claimUpdate` dedup for inbound; deterministic outbox keys for outbound; at-least-once delivery (§6.4).
- **Cancellation:** cooperative throughout; `/stop` (→ CANCELLED) and `/new` (→ SUPERSEDED) via the SessionActor; a plain message queues.
- **Degradation UX (user-visible contract):** on provider failure/timeout after retries → "I couldn't reach the model, try again" (no secrets/stack); on budget exhaustion → "I stopped because <cap> was hit"; the typing indicator is cleared. On `SQLITE_FULL`/disk-full → refuse new turns + reply "storage full" once + do **not** crash-loop; doctor free-disk preflight. 409 → loud doctor surfacing + startup lock prevents a second poller.
- **A route switch is audited and announced on transitions only** (§8.6). The switch appends a `provider_fallback` audit row whose `decision` is the failure kind that caused it, and the turn's reply carries one notice naming both routes; the turn where the primary answers again carries the matching restored notice. **No notice on the steady state in between**, because an owner who is told every turn stops reading it. A turn that switched and then failed anyway reports the primary's cause with one added sentence that the backup was tried, so the reply neither hides the switch nor buries the actionable failure.
- **Authentication, access, and quota are three distinct messages, and only one of them mentions login.** A missing, expired-without-refresh, or invalid credential — and a latched second clean 401 — yields *"ChatGPT authentication is required. Stop clawd, run `clawd auth login`, then start clawd again."*, naming the process lock because login cannot run under a live daemon (§4). **Access denial** says the subscription or account cannot use the requested route or model. **Quota** says to retry after the reported delay or plan reset and leaves credentials valid. **Neither claims that logging in will fix it** — sending an owner through a pointless login is its own failure. `ScheduleDraftParseResult` carries the same vendor-neutral authentication-required / access-denied / quota-limited outcomes with the same guidance and no-debit rule, instead of collapsing every subscription failure into `providerUnavailable`.
- **Cancellation is never outage copy** (§8.4). A `notStarted` cancellation produces no message and no usage row; a `mayHaveStarted` one still produces no outage copy but records conservative usage — estimated input plus `max(local output reservation, observed visible-text-and-tool-argument estimate)` — and the terminal usage path can record it even when cancellation already won the run row. Normal run cancellation owns the owner-visible UX.

### 19.1 Run / approval FSM (NORMATIVE)

`RunState = PENDING / RUNNING / AWAITING_APPROVAL / DONE / FAILED / CANCELLED / SUPERSEDED`.

**FSM invariants:** synchronous reduce; **no default arm** (every state×event is explicit); side effects after commit; expiry → DENY is a first-class terminal.

**RunState transition table:**

| State | Event | Next |
|---|---|---|
| (none) | inbound claimed + persisted | PENDING |
| PENDING | lane picks up turn | RUNNING |
| PENDING | `/stop` / `/new` | CANCELLED / SUPERSEDED |
| RUNNING | turn completes + reply enqueued | DONE |
| RUNNING | retryable failure exhausted / terminal error | FAILED |
| RUNNING | `/stop` | CANCELLED |
| RUNNING | `/new` | SUPERSEDED |
| RUNNING | tool needs approval | AWAITING_APPROVAL |
| AWAITING_APPROVAL | approval APPROVED | RUNNING |
| AWAITING_APPROVAL | REJECTED / EXPIRED→DENY | FAILED |
| AWAITING_APPROVAL | `/stop` / `/new` | CANCELLED / SUPERSEDED |
| **RUNNING (at boot)** | reconciliation sweep | FAILED (or re-enqueue if idempotent via outbox) |
| **AWAITING_APPROVAL (expired, at boot)** | reconciliation sweep | DENY → FAILED |

**ApprovalState transition table:**

| State | Event | Next |
|---|---|---|
| (none) | request created (PENDING row, nonce, ownerUserId) | PENDING |
| PENDING | valid callback (auth + nonce + args-hash + policy_version OK) | APPROVED |
| PENDING | reject callback | REJECTED |
| PENDING | expiry ticker / boot sweep finds age > `approval_expiry` (default 1h) | EXPIRED → DENY (terminal) |
| PENDING | run CANCELLED/SUPERSEDED | REJECTED (audit `decision = cancelled \| superseded`; no orphan) |

A cancelled/superseded run resolves its PENDING approval to **`REJECTED`** — the state stays within §7.1's four values and the audit `decision` column records why (`cancelled` for `/stop`, `superseded` for `/new`). Never add a fifth ApprovalState.

**Boot reconciliation sweep:** any `RUNNING` at boot → `FAILED` (or re-enqueue if idempotent via the outbox); any expired `AWAITING_APPROVAL` → DENY; an `updated_ts` **lease** on `RUNNING` rows distinguishes stuck from in-flight; the expiry ticker (default 1h window, `approval_expiry`) enforces approval expiry `PENDING → EXPIRED → DENY`.

## 20. Roadmap (technical increments)

Re-cut for the approved v1 scope. **Inc 0–3 = the v1 daily-driver milestone**: conversational + durable memory + read-only tools + streaming. Each increment lands a working, supervised slice, and each **"Done when" is an automated acceptance test** (per-requirement verified-by-test), not a manual check.

The numbered increments are the v1→Linux **build order**. **P-auth** is an independently-acceptable provider increment (delivered behind its own phase gates, §8): it neither gates nor reorders the numbered work, and nothing outside its own adapters depends on it. **P-skills** is likewise independent: it lands on top of Inc 3's workspace and read-only-tool seams and reorders nothing.

| Inc / Phase | Title | Done when |
|---|---|---|
| **0** | Supervised default-deny Telegram daemon (echo) | Bot echoes an allowlisted DM; un-allowlisted DM refused (default-deny); **startup flock** blocks a second clawd; **409 handled** as a typed loud error; onboarding self-ID echo works; non-text gets "I can't read X yet"; doctor skeleton runs; survives SIGTERM + restart. |
| **1** | LLM turn (blocking) + persistence | Allowlisted DM gets a real OpenAI-compatible answer, persisted (sessions/messages/runs/usage/audit + **outbox** + **`claimUpdate` ordering**), multi-turn, surviving restart; **`sendRichMessage` (markdown) + plain `sendMessage` fallback** (no formatting errors); **degradation UX**; **USD budget** breaker; context caps. |
| **2** | Streaming + per-session lane | **SSE → `sendRichMessageDraft` (streaming rich drafts, finalized via `sendRichMessage`)**; per-session **Task-chaining** lane; a second message queues in order; `/stop` cancels; `/new` resets+detaints; `SecretStore` (no plaintext on disk). |
| **3** | Memory & workspace + read-only tools | Workspace files injected at the **untrusted tier** (budgeted, caps, flush-before-compact); durable facts on confirm; `memory_items` (recalled by importance + recency) and **FTS5/BM25 recall over the message archive**, both across restarts; `/memory`; `web_search`/`web_fetch` + file READ at **`safe`** tier with the **exfil gate**. |
| **4** | Scheduler & proactive | "Every weekday 07:00 Europe/Berlin…" fires once per occurrence across restarts/DST; **confirm-before-arm**; reduced-privilege runs; clock-gap catch-up cap; delivery via outbox; opt-in heartbeat with quiet hours. *(Scope reconciliation: the external research roadmap bundles memory/workspace into its "Increment 4" — this repo shipped those in Inc 3a; this increment is scheduler/proactive only.)* |
| **5a** | Approval fabric + write tools | *Prep first: add `approval-requested/granted/denied` audit cases + a per-run prompt/workspace fingerprint for `policy_version` to bind to.* Then a consequential **write** tool (`file_write`/`memory_write`, `ask` tier) requires explicit approval via the **durable FSM** (**callback auth + ≥128-bit nonce + suspend-to-`AWAITING_APPROVAL` + boot reconciliation + expiry ticker**); a **forged or third-party callback cannot approve**; the **enforced lethal-trifecta gate** (upgraded from Inc 3b's ephemeral grant to the durable FSM) forces approval on a tainted privileged/egress action. **No virtualization.** |
| **5b** | Sandbox + code execution (macOS) | Built on 5a's approval fabric: on macOS 26 arm64, untrusted code (`execute_code`, `dangerous`) runs in one fresh disposable apple/container VM behind exact-action approval. No live host path/network is exposed by default; staged copies are containment/secret/hash gated; opted-in egress is `canExfiltrate=true`; doctor fails closed. **Prerequisite:** verify and pin the workload image. |
| **6** | Linux sandbox + portability & deployment | Resolve and implement the Linux `ExecutionBackend` after a pinned host spike and FR-X1 conformance/amendment; keep the existing macOS + Linux GRDB/FTS5 gate; complete the remaining supervised Linux packaging work. |
| **P-skills** | Workspace skills — load and follow | A `SKILL.md` the owner installed reaches the model as a **loadable** skill, not just a name: the scan settles identity (`name` matches the identifier shape **and** its directory; over-long descriptions capped; colliding names drop every claimant), the index renders under the `skills` fence label, the model calls **`skill_load` with a name** and gets the frontmatter-stripped body back under that **same** label, and the session is **not tainted** — high-sensitivity memory still assembles afterwards. A **path-shaped name resolves against the scan like any other name and misses**, and a **symlinked skill directory — or a symlinked `skills/` itself — is refused**; an **unknown name succeeds** listing the installed names; a **duplicate refuses naming both directories**. Skills the budget dropped and manifests the scan rejected both **surface to the owner as notices** (with `(showing N of M skills)` in-prompt), instead of vanishing into the log. |
| **P-auth** | ChatGPT subscription authentication | `clawd auth login` completes a device-code login, stores a refreshable credential under the state root, discovers eligible models, and prints an exact `CLAW_LLM_MODEL=openai-chatgpt/<model>` assignment; that value composes the Responses provider **without requiring or using a base URL or API key**, while **every other model value composes the existing Chat Completions provider with unchanged URL and key behavior**; access-token refresh is race-safe under concurrent turns and **a stale request cannot invalidate a newer token generation**; Responses SSE text, usage, tool calls, and replay state map onto the existing agent contracts and survive durable history; subscription calls record token usage with **zero USD and `included_plan`** as the cost source while token preflight/accounting, tool, turn, and wall-clock limits still apply (subject to the documented one-in-flight-call token overshoot); **authentication failures say to run `clawd auth login`, entitlement and quota failures do not**; tests use deterministic HTTP, clock, sleeper, credential-store, and concurrency doubles, and **no test contacts OpenAI**. |

**P-mcp** landed the MCP **client** (§10.3) on the same terms as P-auth — an independently-acceptable increment that neither gates nor reorders the numbered work: remote tools from owner-configured Streamable HTTP servers appear in the registry beside the built-ins and flow through the unchanged gate, approval FSM, fingerprint, redaction, and audit surfaces. *Done when* a configured server's tools reach the dispatcher named `mcp__<server>__<tool>` after the built-ins; an ask-tier remote call round-trips through approval and re-execution with an `ingestedUntrusted` observation; an unreachable server is skipped with a doctor-visible reason while the daemon and the other servers boot unaffected; `policy_version` is stable across two resolutions of the same catalog and changes when the catalog does; and a stored token is unprintable through the redaction union, including the log backend.

*(Later/optional: native Anthropic adapter w/ prompt caching; Hummingbird `/v1/chat/completions` REST; MCP stdio transport, OAuth 2.1 client auth, and live catalog refresh (§10.3); a roster longer than two routes; per-call USD dashboards.)*

## 21. Open architectural questions

Genuinely-open (decided ones have moved into the body above):

- **Linux sandbox backend (decide before Inc 6):** KVM-backed microVM versus a documented PRD
  amendment for a userspace-kernel profile; rootless Podman + gVisor remains only a candidate until
  the pinned Linux-host spike proves its cgroup, network, and cleanup behavior.
- Rolling summary vs aggressive compaction + just-in-time retrieval (treat rolling summary as one strategy; keep out-of-window references).

*Resolved and moved into the spec:* MCP transport on Linux (= a custom Streamable HTTP transport over the shared HTTP seam, not stdio-only — §10.3); supersede-vs-queue (= strict FIFO queue, only `/stop`/`/new` supersede — §5.1); error-on-overflow (= v1 contract — §9.3); memory char-counting (= grapheme `String.count` — §9.4); memory injection tier (= untrusted/labeled, never system — §9.3); confirm-on-write (= the default, with verbatim normalized preview — §9.3); HTML-vs-MarkdownV2 parse mode (= moot — the Inc 1 primary path is rich **markdown** via `InputRichMessage`, with plain `sendMessage` as the fallback — §6.4).

## 22. References

- [`PRD.md`](./PRD.md)
- Research: [Swift implementation grounding](./research/swift-claw-impl-grounding-2026-06-15.md) · [best practices & Swift how-to](./research/swift-claw-best-practices-2026-06-15.md) · [OpenClaw & Hermes study](./research/persistent-agents-openclaw-hermes.md) · [ChatGPT subscription auth & provider abstraction](./research/chatgpt-subscription-auth-provider-abstraction-2026-07-05.md) (§8.3's source study — the pinned OpenClaw/Hermes revisions behind the private route) · [MCP in OpenClaw & Hermes](./research/mcp-openclaw-hermes-2026-08-02.md) (§10.3's source study)
- Product brief: [`teleclaw-prompt.md`](./teleclaw-prompt.md)
