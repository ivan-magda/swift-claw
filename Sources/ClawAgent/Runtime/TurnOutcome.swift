import ClawCore

/// Why a turn produced no usable answer. Maps to a plain-language degradation reply; the runtime
/// carries the vendor-neutral provider disposition through to the gateway rather than collapsing
/// every subscription failure into `providerUnavailable`, so auth/access/quota/replay each earn
/// distinct owner guidance. The stable `auditDecision` string is what the audit log records, so it
/// survives case renames.
public enum DegradationKind: Sendable, Equatable {
  case providerUnavailable
  case outputTruncated
  case contextUnavailable
  case accountingFailed
  /// The credential is missing, expired, or refused.
  case authenticationRequired
  /// The subscription/account is not entitled to the requested route or model.
  case accessDenied
  /// A clean throttle with the provider's bounded retry hint when one was supplied.
  case quotaLimited(retryAfterSeconds: Int?)
  /// Replay state the route would not accept.
  case invalidProviderState
  /// The configured route cannot process image input.
  case visionUnsupported

  /// The stable string recorded by the audit log. Categorical cases deliberately omit payloads.
  public var auditDecision: String {
    switch self {
    case .providerUnavailable: "providerUnavailable"
    case .outputTruncated: "outputTruncated"
    case .contextUnavailable: "contextUnavailable"
    case .accountingFailed: "accountingFailed"
    case .authenticationRequired: "authenticationRequired"
    case .accessDenied: "accessDenied"
    case .quotaLimited: "quotaLimited"
    case .invalidProviderState: "invalidProviderState"
    case .visionUnsupported: "visionUnsupported"
    }
  }
}

/// A route transition the owner is told about exactly once. Standing state belongs to the health
/// rows; a notice on every turn of a multi-hour outage trains the owner to skip it.
public enum RouteNotice: Sendable, Equatable {
  // swiftlint:disable:next identifier_name
  case switched(from: String, to: String)
  case restored(route: String)
}

/// The outcome of one orchestrated turn. `runTurn` never throws — every failure becomes one of
/// these so the gateway always has something to persist and send (never silence).
public enum TurnResult: Sendable, Equatable {
  /// A usable answer plus provider-truth usage and any opaque replay state it produced.
  case completed(content: String, usage: ProviderUsage, providerState: ProviderExchangeState?)
  /// No usable answer. Usage is present only when the attempt still owes accounting.
  case degraded(DegradationKind, usage: ProviderUsage?)
  /// The offline budget gate refused before another provider call.
  case budgetStopped(cap: String)
  /// The batch drained after recording an ask-tier action.
  case suspended(pending: PendingToolAction, usage: ProviderUsage)
}

/// The outcome of the bounded agentic loop: the terminal `TurnResult` plus everything the
/// gateway needs to persist and gate the next turn.
public struct TurnOutcome: Sendable {
  public let result: TurnResult
  /// Every round-trip that proposed tool calls, to persist.
  public let exchanges: [ToolExchange]
  /// Whether provider metadata or an executed observation ingested untrusted content.
  public let ingestedUntrusted: Bool
  /// Whether assembly or any executed observation accessed private data.
  public let hadPrivateData: Bool
  /// The one route transition this turn owes the owner.
  public let routeNotice: RouteNotice?
  /// Package-only attempt instrumentation. Production construction leaves it empty; controlled
  /// callers may inspect counts, model observations, and a payload-free failure cause without
  /// expanding the public owner-facing result taxonomy.
  package let attemptDiagnostics: AttemptDiagnostics

  public init(
    result: TurnResult,
    exchanges: [ToolExchange] = [],
    ingestedUntrusted: Bool = false,
    hadPrivateData: Bool = false,
    routeNotice: RouteNotice? = nil
  ) {
    self.init(
      result: result,
      exchanges: exchanges,
      ingestedUntrusted: ingestedUntrusted,
      hadPrivateData: hadPrivateData,
      routeNotice: routeNotice,
      attemptDiagnostics: .empty
    )
  }

  package init(
    result: TurnResult,
    exchanges: [ToolExchange],
    ingestedUntrusted: Bool,
    hadPrivateData: Bool,
    routeNotice: RouteNotice?,
    attemptDiagnostics: AttemptDiagnostics
  ) {
    self.result = result
    self.exchanges = exchanges
    self.ingestedUntrusted = ingestedUntrusted
    self.hadPrivateData = hadPrivateData
    self.routeNotice = routeNotice
    self.attemptDiagnostics = attemptDiagnostics
  }
}
