import ClawCore
import Foundation
import GRDB

public struct CommandStoreGRDB: CommandStore {
  private let database: MappedDatabase
  private let afterClaimForTesting: @Sendable () throws -> Void
  private let afterSupersedeAndDetaintForTesting: @Sendable () throws -> Void

  public init(writer: any DatabaseWriter) { self.init(writer: writer, afterClaimForTesting: {}) }

  init(
    writer: any DatabaseWriter,
    afterClaimForTesting: @Sendable @escaping () throws -> Void = {},
    afterSupersedeAndDetaintForTesting: @Sendable @escaping () throws -> Void = {}
  ) {
    database = MappedDatabase(writer: writer)
    self.afterClaimForTesting = afterClaimForTesting
    self.afterSupersedeAndDetaintForTesting = afterSupersedeAndDetaintForTesting
  }

  public func applyStop(updateID: Int64, sessionKey: String, now: Date) throws(StoreError)
    -> StopCommandResult
  {
    try database.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateID: updateID,
        claimedAt: now
      )
      guard newlyClaimed else {
        return StopCommandResult(newlyClaimed: false, sessionID: nil, cancelledRunIDs: [])
      }

      try afterClaimForTesting()

      let sessionID = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: sessionKey,
        now: now
      )
      let cancelledRunIDs = try RunStoreGRDB.cancelRuns(db, sessionID: sessionID, now: now)
      let resolvedApprovalIDs = try ApprovalStoreGRDB.resolvePendingApprovals(
        db,
        runIDs: cancelledRunIDs,
        decision: .cancelled,
        now: now
      )
      try Self.insertStopAudits(
        db,
        actor: Self.commandActor(for: sessionKey),
        sessionID: sessionID,
        runIDs: cancelledRunIDs,
        now: now
      )

      return StopCommandResult(
        newlyClaimed: true,
        sessionID: sessionID,
        cancelledRunIDs: cancelledRunIDs,
        resolvedApprovalIDs: resolvedApprovalIDs
      )
    }
  }

  private static func insertStopAudits(
    _ db: Database,
    actor: AuditActor,
    sessionID: Int64,
    runIDs: [Int64],
    now: Date
  ) throws {
    guard !runIDs.isEmpty else {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: actor,
          action: .turnCancelled,
          argsRedacted: "/stop",
          decision: "nothing_to_stop",
          sessionID: sessionID,
          ts: now
        )
      )
      return
    }

    for runID in runIDs {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: actor,
          action: .turnCancelled,
          argsRedacted: "/stop",
          decision: "cancelled",
          runID: runID,
          sessionID: sessionID,
          ts: now
        )
      )
    }
  }

  public func applyNew(updateID: Int64, sessionKey: String, now: Date) throws(StoreError)
    -> NewCommandResult
  {
    try database.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateID: updateID,
        claimedAt: now
      )
      guard newlyClaimed else {
        return NewCommandResult(newlyClaimed: false, sessionID: nil, supersededRunIDs: [])
      }

      try afterClaimForTesting()

      let sessionID = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: sessionKey,
        now: now
      )
      let supersededRunIDs = try RunStoreGRDB.supersedeRuns(db, sessionID: sessionID, now: now)
      let resolvedApprovalIDs = try ApprovalStoreGRDB.resolvePendingApprovals(
        db,
        runIDs: supersededRunIDs,
        decision: .superseded,
        now: now
      )

      try SessionMessageStoreGRDB.resetWindowAndDetaint(db, sessionID: sessionID, now: now)

      try afterSupersedeAndDetaintForTesting()

      try Self.insertNewAudits(
        db,
        actor: Self.commandActor(for: sessionKey),
        sessionID: sessionID,
        runIDs: supersededRunIDs,
        now: now
      )

      return NewCommandResult(
        newlyClaimed: true,
        sessionID: sessionID,
        supersededRunIDs: supersededRunIDs,
        resolvedApprovalIDs: resolvedApprovalIDs
      )
    }
  }

  private static func insertNewAudits(
    _ db: Database,
    actor: AuditActor,
    sessionID: Int64,
    runIDs: [Int64],
    now: Date
  ) throws {
    guard !runIDs.isEmpty else {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: actor,
          action: .turnSuperseded,
          argsRedacted: "/new",
          decision: "fresh_window",
          sessionID: sessionID,
          ts: now
        )
      )
      return
    }

    for runID in runIDs {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: actor,
          action: .turnSuperseded,
          argsRedacted: "/new",
          decision: "superseded",
          runID: runID,
          sessionID: sessionID,
          ts: now
        )
      )
    }
  }

  private static func commandActor(for sessionKey: String) -> AuditActor {
    SessionKey.mode(from: sessionKey) == .group ? .groupMember : .owner
  }
}
