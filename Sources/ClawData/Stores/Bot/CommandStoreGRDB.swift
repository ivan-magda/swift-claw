import ClawCore
import Foundation
import GRDB

public struct CommandStoreGRDB: CommandStore {
  private let database: MappedDatabase
  private let afterClaimForTesting: @Sendable () throws -> Void

  public init(writer: any DatabaseWriter) {
    self.init(writer: writer, afterClaimForTesting: {})
  }

  init(
    writer: any DatabaseWriter,
    afterClaimForTesting: @Sendable @escaping () throws -> Void
  ) {
    database = MappedDatabase(writer: writer)
    self.afterClaimForTesting = afterClaimForTesting
  }

  public func applyStop(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws -> StopCommandResult {
    try database.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: updateId,
        claimedAt: now
      )
      guard newlyClaimed else {
        return StopCommandResult(newlyClaimed: false, sessionId: nil, cancelledRunId: nil)
      }

      try afterClaimForTesting()

      let sessionId = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: sessionKey,
        now: now
      )
      let runId = try RunStoreGRDB.fetchActiveRunId(db, sessionId: sessionId)

      // swift-format-ignore
      let cancelledRunId: Int64? =
        if let runId,
          try RunStoreGRDB.transitionRun(db, runId: runId, event: .cancel, now: now) != nil {
          runId
        } else {
          nil
        }

      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .owner,
          action: .turnCancelled,
          argsRedacted: "/stop",
          decision: cancelledRunId == nil ? "nothing_to_stop" : "cancelled",
          runId: cancelledRunId,
          sessionId: sessionId,
          ts: now
        )
      )

      return StopCommandResult(
        newlyClaimed: true,
        sessionId: sessionId,
        cancelledRunId: cancelledRunId
      )
    }
  }

  public func applyNew(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws -> NewCommandResult {
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

      try SessionMessageStoreGRDB.resetWindowAndDetaint(db, sessionId: sessionId, now: now)
      try Self.insertNewAudits(db, sessionId: sessionId, runIds: supersededRunIds, now: now)

      return NewCommandResult(
        newlyClaimed: true,
        sessionId: sessionId,
        supersededRunIds: supersededRunIds
      )
    }
  }

  private static func insertNewAudits(
    _ db: Database,
    sessionId: Int64,
    runIds: [Int64],
    now: Date
  ) throws {
    guard !runIds.isEmpty else {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .owner,
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
          actor: .owner,
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
}
