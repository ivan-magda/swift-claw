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
  }

  private let outcome: Outcome
  private(set) var calls = 0

  init(_ outcome: Outcome) {
    self.outcome = outcome
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    calls += 1
    switch outcome {
    case .respond(let response): return response
    case .fail(let error): throw error
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
  streamingEnabled: Bool = false,
  toolDispatcher: (any ToolDispatching)? = nil,
  usageStore: any UsageStore = RecordingUsageStore(),
  auditLog: any AuditLog = RecordingAuditLog(),
  clock: any Clock<Duration> = ContinuousClock()
) -> AgentRuntime {
  AgentRuntime(
    provider: provider,
    typingIndicator: typing,
    draftStreamer: drafts,
    streamingEnabled: streamingEnabled,
    costResolver: costResolver,
    budget: budget,
    model: model,
    toolDispatcher: toolDispatcher,
    usageStore: usageStore,
    auditLog: auditLog,
    clock: clock
  )
}

func requireCompleted(
  _ result: TurnResult
) throws -> (content: String, usage: ProviderUsage) {
  guard case .completed(let content, let usage) = result else {
    struct Mismatch: Error, CustomStringConvertible {
      let result: TurnResult
      var description: String { "expected TurnResult.completed, got \(result)" }
    }
    throw Mismatch(result: result)
  }
  return (content, usage)
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
