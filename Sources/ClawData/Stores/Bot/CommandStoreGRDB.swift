import ClawCore
import Foundation
import GRDB

public struct CommandStoreGRDB: CommandStore {
  private let database: MappedDatabase
  private let afterClaimForTesting: @Sendable () throws -> Void
  private let afterSupersedeAndDetaintForTesting: @Sendable () throws -> Void

  public init(writer: any DatabaseWriter) {
    self.init(writer: writer, afterClaimForTesting: {})
  }

  init(
    writer: any DatabaseWriter,
    afterClaimForTesting: @Sendable @escaping () throws -> Void = {},
    afterSupersedeAndDetaintForTesting: @Sendable @escaping () throws -> Void = {}
  ) {
    database = MappedDatabase(writer: writer)
    self.afterClaimForTesting = afterClaimForTesting
    self.afterSupersedeAndDetaintForTesting = afterSupersedeAndDetaintForTesting
  }

  public func applyStop(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws(StoreError) -> StopCommandResult {
    try database.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: updateId,
        claimedAt: now
      )
      guard newlyClaimed else {
        return StopCommandResult(newlyClaimed: false, sessionId: nil, cancelledRunIds: [])
      }

      try afterClaimForTesting()

      let sessionId = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: sessionKey,
        now: now
      )
      let cancelledRunIds = try RunStoreGRDB.cancelRuns(db, sessionId: sessionId, now: now)
      let resolvedApprovalIds = try ApprovalStoreGRDB.resolvePendingApprovals(
        db,
        runIds: cancelledRunIds,
        decision: .cancelled,
        now: now
      )
      try Self.insertStopAudits(
        db,
        actor: Self.commandActor(for: sessionKey),
        sessionId: sessionId,
        runIds: cancelledRunIds,
        now: now
      )

      return StopCommandResult(
        newlyClaimed: true,
        sessionId: sessionId,
        cancelledRunIds: cancelledRunIds,
        resolvedApprovalIds: resolvedApprovalIds
      )
    }
  }

  private static func insertStopAudits(
    _ db: Database,
    actor: AuditActor,
    sessionId: Int64,
    runIds: [Int64],
    now: Date
  ) throws {
    guard !runIds.isEmpty else {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: actor,
          action: .turnCancelled,
          argsRedacted: "/stop",
          decision: "nothing_to_stop",
          sessionId: sessionId,
          ts: now
        )
      )
      return
    }

    for runId in runIds {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: actor,
          action: .turnCancelled,
          argsRedacted: "/stop",
          decision: "cancelled",
          runId: runId,
          sessionId: sessionId,
          ts: now
        )
      )
    }
  }

  public func applyNew(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws(StoreError) -> NewCommandResult {
    try database.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: updateId,
        claimedAt: now
      )
      guard newlyClaimed else {
        return NewCommandResult(newlyClaimed: false, sessionId: nil, supersededRunIds: [])
      }

      try afterClaimForTesting()

      let sessionId = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: sessionKey,
        now: now
      )
      let supersededRunIds = try RunStoreGRDB.supersedeRuns(db, sessionId: sessionId, now: now)
      let resolvedApprovalIds = try ApprovalStoreGRDB.resolvePendingApprovals(
        db,
        runIds: supersededRunIds,
        decision: .superseded,
        now: now
      )

      try SessionMessageStoreGRDB.resetWindowAndDetaint(db, sessionId: sessionId, now: now)

      try afterSupersedeAndDetaintForTesting()

      try Self.insertNewAudits(
        db,
        actor: Self.commandActor(for: sessionKey),
        sessionId: sessionId,
        runIds: supersededRunIds,
        now: now
      )

      return NewCommandResult(
        newlyClaimed: true,
        sessionId: sessionId,
        supersededRunIds: supersededRunIds,
        resolvedApprovalIds: resolvedApprovalIds
      )
    }
  }

  private static func insertNewAudits(
    _ db: Database,
    actor: AuditActor,
    sessionId: Int64,
    runIds: [Int64],
    now: Date
  ) throws {
    guard !runIds.isEmpty else {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: actor,
          action: .turnSuperseded,
          argsRedacted: "/new",
          decision: "fresh_window",
          sessionId: sessionId,
          ts: now
        )
      )
      return
    }

    for runId in runIds {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: actor,
          action: .turnSuperseded,
          argsRedacted: "/new",
          decision: "superseded",
          runId: runId,
          sessionId: sessionId,
          ts: now
        )
      )
    }
  }

  private static func commandActor(for sessionKey: String) -> AuditActor {
    SessionKey.mode(from: sessionKey) == .group ? .groupMember : .owner
  }
}
