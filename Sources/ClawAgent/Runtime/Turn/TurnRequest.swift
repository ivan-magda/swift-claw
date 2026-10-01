import ClawCore

/// Everything one turn segment runs from: who it serves, the assembled context, the session's
/// persisted trust flags, and the spend it starts from.
public struct TurnRequest: Sendable {
  public let scope: TurnScope
  /// The assembled messages and their privacy and policy metadata, including whether a bound run's
  /// pinned lessons are present.
  public let context: BuildResult
  public let session: SessionTrust
  public let spend: SpendSnapshot
  /// Transient run presentation; omitted for legacy provider-scoped progress.
  public let progress: TurnProgressReporter?

  public init(
    scope: TurnScope,
    context: BuildResult,
    session: SessionTrust,
    spend: SpendSnapshot,
    progress: TurnProgressReporter? = nil
  ) {
    self.scope = scope
    self.context = context
    self.session = session
    self.spend = spend
    self.progress = progress
  }
}

/// The session's persisted trust flags when a turn segment starts.
public struct SessionTrust: Sendable, Equatable {
  /// The session's persisted untrusted-ingestion state.
  public let isTainted: Bool
  /// The session's persisted private-data flag.
  public let hasPrivateData: Bool

  public init(isTainted: Bool, hasPrivateData: Bool) {
    self.isTainted = isTainted
    self.hasPrivateData = hasPrivateData
  }
}

/// The spend a turn segment starts from: today's persisted totals, loaded when the segment starts,
/// and the usage a resumed run recorded before it suspended.
public struct SpendSnapshot: Sendable, Equatable {
  /// The persisted daily token total.
  public let todayTokens: Int
  /// The persisted daily metered spend.
  public let todayUSD: Double
  /// The persisted daily proactive spend.
  public let proactiveTodayUSD: Double
  /// Usage already recorded for a suspended run, or nil for a fresh run.
  public let carryOver: ResumeUsage?

  public init(
    todayTokens: Int,
    todayUSD: Double,
    proactiveTodayUSD: Double,
    carryOver: ResumeUsage?
  ) {
    self.todayTokens = todayTokens
    self.todayUSD = todayUSD
    self.proactiveTodayUSD = proactiveTodayUSD
    self.carryOver = carryOver
  }
}
