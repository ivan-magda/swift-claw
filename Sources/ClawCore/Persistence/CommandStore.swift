import Foundation

public struct StopCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionID: Int64?
  /// Every run `/stop` terminated — the RUNNING turn, any queued PENDING turns, and any run parked
  /// in AWAITING_APPROVAL (FSM: PENDING + /stop → CANCELLED). Empty when there was nothing to stop.
  public let cancelledRunIDs: [Int64]
  /// PENDING approvals of the terminated runs, CAS'd to REJECTED (decision `cancelled`) in the same
  /// command transaction. The handler signals the coordinator per id so a held/boot-parked
  /// lane releases. Defaulted so the `newlyClaimed: false` early return needs no change.
  public let resolvedApprovalIDs: [Int64]

  public init(
    newlyClaimed: Bool,
    sessionID: Int64?,
    cancelledRunIDs: [Int64],
    resolvedApprovalIDs: [Int64] = []
  ) {
    self.newlyClaimed = newlyClaimed
    self.sessionID = sessionID
    self.cancelledRunIDs = cancelledRunIDs
    self.resolvedApprovalIDs = resolvedApprovalIDs
  }
}

public struct NewCommandResult: Sendable, Equatable {
  public let newlyClaimed: Bool
  public let sessionID: Int64?
  public let supersededRunIDs: [Int64]
  /// PENDING approvals of the superseded runs, CAS'd to REJECTED (decision `superseded`) in the
  /// same command transaction. The handler signals the coordinator per id. Defaulted so the
  /// `newlyClaimed: false` early return needs no change.
  public let resolvedApprovalIDs: [Int64]

  public init(
    newlyClaimed: Bool,
    sessionID: Int64?,
    supersededRunIDs: [Int64],
    resolvedApprovalIDs: [Int64] = []
  ) {
    self.newlyClaimed = newlyClaimed
    self.sessionID = sessionID
    self.supersededRunIDs = supersededRunIDs
    self.resolvedApprovalIDs = resolvedApprovalIDs
  }
}

public protocol CommandStore: Sendable {
  /// Atomic `/stop`: claim update + resolve session + every PENDING/RUNNING/AWAITING_APPROVAL →
  /// CANCELLED + one audit row per cancelled run, in one write.
  func applyStop(
    updateID: Int64,
    sessionKey: String,
    now: Date
  ) throws(StoreError) -> StopCommandResult

  /// Atomic `/new`: claim update + resolve session + PENDING/RUNNING/AWAITING_APPROVAL→SUPERSEDED +
  /// context-window reset + detaint + audit in one write.
  func applyNew(
    updateID: Int64,
    sessionKey: String,
    now: Date
  ) throws(StoreError) -> NewCommandResult
}
