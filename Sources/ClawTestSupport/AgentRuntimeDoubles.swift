import ClawAgent
import ClawCore
import Foundation

// MARK: - Providers

/// Scripted multi-round-trip provider: returns responses in order, records every request, then
/// throws `exhaustionError` once the script is spent. The default exhaustion is a fixed terminal
/// rejection ("unscripted round-trip"); callers that exercise a specific head/accounting failure
/// pass their own error (e.g. an empty script whose first call fails, or a tool round that succeeds
/// then fails), so one double covers plain playback, fail-only, and playback-then-fail.
public actor SequenceProvider: LLMProvider {
  private var responses: [ChatResponse]
  private let exhaustionError: any Error & Sendable
  public private(set) var requests: [ChatRequest] = []

  public init(
    _ responses: [ChatResponse],
    then exhaustionError: any Error & Sendable = ProviderError.terminal(
      status: nil,
      message: "unscripted round-trip"
    )
  ) {
    self.responses = responses
    self.exhaustionError = exhaustionError
  }

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    requests.append(request)
    guard responses.isEmpty == false else {
      throw exhaustionError
    }
    return responses.removeFirst()
  }

  nonisolated public func stream(request: ChatRequest) -> LLMEventStream {
    LLMEventStream.make { _ in
      do {
        return .completed(try await self.complete(request: request))
      } catch let cause as ProviderError {
        return .failed(ProviderFailure(cause: cause, accounting: .notStarted))
      } catch {
        return .failed(
          ProviderFailure(
            cause: .terminal(status: nil, message: "scripted provider failed"),
            accounting: .notStarted
          )
        )
      }
    }
  }
}

/// Holds a provider response until the supplied gate opens. Progress-signal tests pair it with a
/// gate-opening typing double to pin "typing before response" without scheduler timing.
public actor GatedProvider: LLMProvider {
  private let gate: TypingReleaseGate
  private let response: ChatResponse

  public init(gate: TypingReleaseGate, response: ChatResponse) {
    self.gate = gate
    self.response = response
  }

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    await gate.awaitRelease()
    return response
  }
}

/// Never returns within the deadline: sleeps an hour so the injected no-op `sleep` lets the
/// wall-clock deadline win the race deterministically. The post-sleep throw is unreachable under
/// an injected clock (the sleep is cancelled) and only names the brownout it stands in for.
public struct HangingProvider: LLMProvider {
  public init() {}

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    try await Task.sleep(for: .seconds(3600))
    throw ProviderError.terminal(status: nil, message: "unreachable")
  }
}

/// Hangs like `HangingProvider`, but — having reached transport — reports the ambiguous inference
/// cancellation on cancel, the shape the managed route's `complete` produces when a mid-flight
/// attempt may already be billing. Stands in for the "deadline fires while the model may have been
/// asked" case, which owes a conservative debit rather than nothing.
public struct HangingInferenceProvider: LLMProvider {
  private let observedCompletionTokens: Int

  public init(observing observedCompletionTokens: Int = 0) {
    self.observedCompletionTokens = observedCompletionTokens
  }

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    do {
      try await Task.sleep(for: .seconds(3600))
    } catch {
      throw ProviderInferenceCancellation(observing: observedCompletionTokens)
    }
    throw ProviderError.terminal(status: nil, message: "unreachable")
  }
}

/// Throws a bare `CancellationError` from `complete` — the shape an external cancel (owner `/stop`,
/// shutdown) takes once it reaches the in-flight provider call, before anything is generated. Drives
/// the no-debit cancellation arm both the turn and schedule surfaces share.
public struct CancellingProvider: LLMProvider {
  public init() {}

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    throw CancellationError()
  }
}

/// Finishes a real reply only after it is cancelled: the provider that races a won deadline and
/// lands its response anyway. The response is a loser the coordinator drains, so its authoritative
/// usage survives while the owner still sees the timeout.
public struct RacedSuccessProvider: LLMProvider {
  private let response: ChatResponse

  public init(response: ChatResponse) {
    self.response = response
  }

  public func complete(request: ChatRequest) async throws -> ChatResponse {
    while !Task.isCancelled {
      await Task.yield()
    }
    return response
  }
}

// MARK: - Provider call identity

/// Mints `call-1`, `call-2`, … in call order, so a test can name the identity a given round-trip
/// records instead of matching a random UUID. Lock-guarded, not an actor:
/// `ProviderCallIDGenerating` is synchronous, mirroring the live `UUIDProviderCallIDGenerator` —
/// a value type needing no coordination — and an actor cannot satisfy a synchronous requirement.
public final class SequentialCallIDGenerator: ProviderCallIDGenerating, @unchecked Sendable {
  private let lock = NSLock()
  private let prefix: String
  private var issued = 0

  public init(prefix: String = "call") {
    self.prefix = prefix
  }

  public func next() -> ProviderCallID {
    lock.lock()
    defer { lock.unlock() }
    issued += 1
    return ProviderCallID(rawValue: "\(prefix)-\(issued)")
  }
}

// MARK: - Dispatcher

/// Scripted tool dispatcher: name → outcome factory; records every dispatched call+context.
public actor ScriptedDispatcher: ToolDispatching {
  public struct Record: Sendable {
    public let call: ToolCall
    public let context: ToolDispatchContext
  }

  nonisolated public let definitions: [ToolDefinition]
  private let respond: @Sendable (ToolCall, ToolDispatchContext) -> ToolDispatchOutcome
  public private(set) var records: [Record] = []

  public init(
    definitions: [ToolDefinition] = [],
    respond: @escaping @Sendable (ToolCall, ToolDispatchContext) -> ToolDispatchOutcome
  ) {
    self.definitions = definitions
    self.respond = respond
  }

  public func dispatch(
    call: ToolCall,
    context: ToolDispatchContext
  ) async -> ToolDispatchOutcome {
    records.append(Record(call: call, context: context))
    return respond(call, context)
  }
}

// MARK: - Audit log

/// Audit log recording events; can throw a scripted error on every write. Lock-guarded, not an
/// actor: `AuditLog` is a synchronous protocol an actor cannot satisfy without crossing into
/// isolated state, which Swift 6 strict concurrency flags at the conformance itself.
public final class RecordingAuditLog: AuditLog, @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [AuditEvent] = []
  private let thrown: StoreError?

  public var events: [AuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storedEvents
  }

  public init(thrown: StoreError? = nil) {
    self.thrown = thrown
  }

  public func appendAudit(_ event: AuditEvent) throws(StoreError) {
    lock.lock()
    defer { lock.unlock() }
    if let thrown {
      throw thrown
    }
    storedEvents.append(event)
  }
}

// MARK: - Empty context collaborators

/// A workspace with nothing on disk: every file load is `.missing`, no skills. Stands in for
/// `ContextBuilder` collaborators in tests that only care about history rendering.
public struct EmptyWorkspace: WorkspaceReading {
  public init() {}

  public func load(file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
    .missing
  }

  public func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile {
    .missing
  }

  public func scanSkills() -> SkillScanResult {
    SkillScanResult(descriptors: [], warnings: [])
  }
}

package typealias EmptyMemoryStore = ClawAgent.EmptyMemoryStore
package typealias EmptyRetriever = ClawAgent.EmptyRetriever
