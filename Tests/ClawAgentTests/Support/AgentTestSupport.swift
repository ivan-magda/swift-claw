import ClawTestSupport
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

// MARK: - Test doubles

// The generic typing doubles (`RecordingTyping`, `TypingReleaseGate`, `GatingTyping`) live in
// `ClawTestSupport` so the gateway's approve-resume tests share the same activity contract.

/// Returns a scripted response or throws a scripted `ProviderError`;
/// records its call count so the preflight-stop path can assert the provider was never reached.
actor StubProvider: LLMProvider {
  enum Outcome: Sendable {
    case respond(ChatResponse)
    case fail(ProviderError)
    /// A vendor-neutral provider failure carrying its own accounting disposition — the shape the
    /// managed route throws, so the runtime's debit decision can be exercised on `.accounting`
    /// rather than the cause class.
    case failFailure(ProviderFailure)
    /// The ambiguous cancellation marker: the model may have been asked, so conservative usage is
    /// still owed.
    case failInferenceCancellation(ProviderInferenceCancellation)
    /// Plain task cancellation: nothing was generated to bill.
    case failCancellation
  }

  private let outcome: Outcome
  private(set) var calls = 0
  private(set) var lastRequest: ChatRequest?

  init(_ outcome: Outcome) {
    self.outcome = outcome
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    calls += 1
    lastRequest = request

    switch outcome {
    case .respond(let response): return response
    case .fail(let error): throw error
    case .failFailure(let failure): throw failure
    case .failInferenceCancellation(let cancellation): throw cancellation
    case .failCancellation: throw CancellationError()
    }
  }
}

/// A provider whose `complete` blocks until `gate` is released (i.e. until typing has fired once).
actor GatedProvider: LLMProvider {
  private let gate: TypingReleaseGate
  private let response: ChatResponse

  init(gate: TypingReleaseGate, response: ChatResponse) {
    self.gate = gate
    self.response = response
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    await gate.awaitRelease()
    return response
  }
}

/// Usage store recording rows; can throw a scripted error on the Nth write. A lock-guarded class,
/// not an actor: `UsageStore` is a synchronous (non-`async`) protocol, mirroring production
/// `UsageStoreGRDB` — a `Sendable` value type whose thread safety comes from GRDB's writer, not
/// actor isolation. An actor cannot satisfy a synchronous protocol requirement without crossing
/// into isolated state, which Swift 6 strict concurrency now flags at the conformance itself.
final class RecordingUsageStore: UsageStore, @unchecked Sendable {
  private let lock = NSLock()
  private var _recorded: [ProviderUsage] = []
  private let failOnWrite: Int?
  private let thrown: StoreError

  var recorded: [ProviderUsage] {
    lock.lock()
    defer { lock.unlock() }
    return _recorded
  }

  init(failOnWrite: Int? = nil, thrown: StoreError = StoreError.unexpected("scripted")) {
    self.failOnWrite = failOnWrite
    self.thrown = thrown
  }

  func recordUsage(_ usage: ProviderUsage) throws(StoreError) {
    lock.lock()
    defer { lock.unlock() }
    if let failOnWrite, _recorded.count + 1 == failOnWrite {
      throw thrown
    }
    _recorded.append(usage)
  }

  func todayTokensAndCost(now: Date) throws(StoreError) -> (tokens: Int, costUSD: Double) {
    (0, 0)
  }

  func todayTokensAndCost(
    origins: [RunOrigin],
    now: Date
  ) throws(StoreError) -> (tokens: Int, costUSD: Double) {
    (0, 0)
  }

  func costSourceMix(now: Date) throws(StoreError) -> [CostSource: Int] {
    [:]
  }

  func latestPromptUsage() throws(StoreError) -> LatestPromptUsage? {
    lock.lock()
    defer { lock.unlock() }
    return _recorded.last.map { last in
      LatestPromptUsage(
        promptTokens: last.promptTokens,
        runId: last.runId,
        isEstimated: last.isEstimated
      )
    }
  }
}

// MARK: - Builders

func makeCostResolver(
  priceTable: PriceTable = .empty,
  referenceUSDPerToken: Double = RunBudget.default.referenceUSDPerToken
) -> CostResolver {
  CostResolver(priceTable: priceTable, referenceUSDPerToken: referenceUSDPerToken)
}

func makeRuntime(
  provider: any LLMProvider,
  typing: any TypingIndicator = RecordingTyping(),
  drafts: any RichDraftStreaming = NoopRichDraftStreaming(),
  costResolver: CostResolver = makeCostResolver(),
  budget: RunBudget = .default,
  model: String = "gpt-4o",
  configuredReference: String? = nil,
  costPolicy: LLMCostPolicy = .metered,
  reservationPolicy: LLMInputReservationPolicy = .textOnly,
  streamingEnabled: Bool = false,
  toolDispatcher: (any ToolDispatching)? = nil,
  usageStore: any UsageStore = RecordingUsageStore(),
  auditLog: any AuditLog = RecordingAuditLog(),
  providerCallIDGenerator: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator(),
  clock: any Clock<Duration> = ContinuousClock()
) -> AgentRuntime {
  AgentRuntime(
    roster: makeSingleRouteRoster(
      provider: provider,
      wireModel: model,
      configuredReference: configuredReference,
      costPolicy: costPolicy,
      reservationPolicy: reservationPolicy
    ),
    typingIndicator: typing,
    draftStreamer: drafts,
    streamingEnabled: streamingEnabled,
    costResolver: costResolver,
    budget: budget,
    toolDispatcher: toolDispatcher,
    usageStore: usageStore,
    auditLog: auditLog,
    providerCallIDGenerator: providerCallIDGenerator,
    clock: clock
  )
}

/// A two-route runtime. The primary is an included-plan route and the fallback a metered one — the
/// pairing that makes a mis-attributed usage row visible, because a fallback charged through the
/// primary's accountant would read as a confirmed $0 under the wrong model name.
func makeRuntime(
  primary: any LLMProvider,
  fallback: (any LLMProvider)?,
  cooldown: (any RouteCooldownTracking)? = nil,
  budget: RunBudget = .default,
  toolDispatcher: (any ToolDispatching)? = nil,
  usageStore: any UsageStore = RecordingUsageStore(),
  auditLog: any AuditLog = RecordingAuditLog(),
  clock: any Clock<Duration> = ContinuousClock()
) -> AgentRuntime {
  var bindings = [
    LLMRouteBinding(
      provider: primary,
      wireModel: "primary-wire",
      configuredReference: "primary-model",
      costPolicy: .includedPlan,
      reservationPolicy: .textOnly
    )
  ]
  if let fallback {
    bindings.append(
      LLMRouteBinding(
        provider: fallback,
        wireModel: "fallback-wire",
        configuredReference: "fallback-model",
        costPolicy: .metered,
        reservationPolicy: .textOnly
      )
    )
  }
  return AgentRuntime(
    roster: ProviderRoster(bindings: bindings),
    cooldown: cooldown,
    typingIndicator: RecordingTyping(),
    draftStreamer: NoopRichDraftStreaming(),
    streamingEnabled: false,
    costResolver: makeCostResolver(),
    budget: budget,
    toolDispatcher: toolDispatcher,
    usageStore: usageStore,
    auditLog: auditLog,
    clock: clock
  )
}

/// `RunBudget.default` with the round-trip ceiling a test needs to pin.
func makeBudget(maxTurns: Int) -> RunBudget {
  let base = RunBudget.default
  return RunBudget(
    maxInputTokens: base.maxInputTokens,
    maxOutputTokens: base.maxOutputTokens,
    wallClockDeadlineSeconds: base.wallClockDeadlineSeconds,
    retryBudget: base.retryBudget,
    perRunUSD: base.perRunUSD,
    perDayUSD: base.perDayUSD,
    proactivePerDayUSD: base.proactivePerDayUSD,
    referenceUSDPerToken: base.referenceUSDPerToken,
    maxTurns: maxTurns,
    maxToolCalls: base.maxToolCalls,
    dayTokenCeilingOverride: base.dayTokenCeilingOverride
  )
}

func requireCompleted(
  _ result: TurnResult
) throws -> (content: String, usage: ProviderUsage, providerState: ProviderExchangeState?) {
  guard case .completed(let content, let usage, let providerState) = result else {
    struct Mismatch: Error, CustomStringConvertible {
      let result: TurnResult
      var description: String { "expected TurnResult.completed, got \(result)" }
    }
    throw Mismatch(result: result)
  }
  return (content, usage, providerState)
}

func requireDegraded(
  _ result: TurnResult
) throws -> (kind: DegradationKind, usage: ProviderUsage?) {
  guard case .degraded(let kind, let usage) = result else {
    struct Mismatch: Error, CustomStringConvertible {
      let result: TurnResult
      var description: String { "expected TurnResult.degraded, got \(result)" }
    }
    throw Mismatch(result: result)
  }
  return (kind, usage)
}

func userMessage(_ content: String) -> StoredMessage {
  StoredMessage(role: .user, content: content, provenance: .trusted)
}

func makeBuildResult(hasPrivateDataAccess: Bool = false) -> BuildResult {
  BuildResult(
    messages: [ChatMessage(role: .user, content: "go")],
    ownerNotices: [],
    hasPrivateDataAccess: hasPrivateDataAccess
  )
}

/// Opaque replay state of a chosen byte size. The runtime reserves against these bytes without
/// decoding them, so the payload is arbitrary filler; only its length matters to the reservation.
func replayState(issuer: String = "openai-chatgpt", bytes: Int) -> ProviderExchangeState {
  ProviderExchangeState(issuer: issuer, payload: Data(repeating: 0x61, count: bytes))
}

/// A one-message build result whose sole user turn carries opaque replay state, for exercising the
/// input reservation in the runtime's gates and estimated rows.
func buildResultCarryingState(bytes: Int) -> BuildResult {
  BuildResult(
    messages: [
      ChatMessage(role: .user, content: "go", providerState: replayState(bytes: bytes))
    ],
    ownerNotices: [],
    hasPrivateDataAccess: false
  )
}
