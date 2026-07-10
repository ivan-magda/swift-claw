import Foundation

public struct StopCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionId: Int64?
  /// Every run `/stop` terminated — the RUNNING turn AND any queued PENDING turns (FSM:
  /// PENDING + /stop → CANCELLED). Empty when there was nothing to stop.
  public let cancelledRunIds: [Int64]
  /// PENDING approvals of the terminated runs, CAS'd to REJECTED (decision `cancelled`) in the same
  /// command transaction. The handler signals the coordinator per id so a held/boot-parked
  /// lane releases. Defaulted so the `newlyClaimed: false` early return needs no change.
  public let resolvedApprovalIds: [Int64]

  public init(
    newlyClaimed: Bool,
    sessionId: Int64?,
    cancelledRunIds: [Int64],
    resolvedApprovalIds: [Int64] = []
  ) {
    self.newlyClaimed = newlyClaimed
    self.sessionId = sessionId
    self.cancelledRunIds = cancelledRunIds
    self.resolvedApprovalIds = resolvedApprovalIds
  }
}

public struct NewCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionId: Int64?
  public let supersededRunIds: [Int64]
  /// PENDING approvals of the superseded runs, CAS'd to REJECTED (decision `superseded`) in the
  /// same command transaction. The handler signals the coordinator per id. Defaulted so the
  /// `newlyClaimed: false` early return needs no change.
  public let resolvedApprovalIds: [Int64]

  public init(
    newlyClaimed: Bool,
    sessionId: Int64?,
    supersededRunIds: [Int64],
    resolvedApprovalIds: [Int64] = []
  ) {
    self.newlyClaimed = newlyClaimed
    self.sessionId = sessionId
    self.supersededRunIds = supersededRunIds
    self.resolvedApprovalIds = resolvedApprovalIds
  }
}

public protocol CommandStore: Sendable {
  /// Atomic `/stop`: claim update + resolve session + every PENDING/RUNNING→CANCELLED + one
  /// audit row per cancelled run, in one write.
  func applyStop(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws(StoreError) -> StopCommandResult
  /// Atomic `/new`: claim update + resolve session + RUNNING/PENDING→SUPERSEDED +
  /// resetWindowAndDetaint + audit in one write.
  func applyNew(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws(StoreError) -> NewCommandResult
}
