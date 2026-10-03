import ClawCore
import Foundation
import GRDB

extension CommandStoreGRDB {
  static let draftStopAuditSource = "stop button"

  public func applyDraftStop(
    updateID: Int64,
    runID: Int64,
    now: Date
  ) throws(StoreError) -> StopCommandResult {
    try database.writeMapping { db in
      guard try ProcessedUpdateStoreGRDB.claimUpdate(db: db, updateID: updateID, claimedAt: now)
      else {
        return StopCommandResult(newlyClaimed: false, sessionID: nil, cancelledRunIDs: [])
      }
      let sessionID = try Int64.fetchOne(
        db,
        sql: "SELECT session_id FROM runs WHERE id = ?",
        arguments: [runID]
      )
      guard let sessionID, try RunStoreGRDB.cancelRun(db, runID: runID, now: now) else {
        return StopCommandResult(newlyClaimed: true, sessionID: sessionID, cancelledRunIDs: [])
      }
      let resolved = try ApprovalStoreGRDB.resolvePendingApprovals(
        db,
        runIDs: [runID],
        decision: .cancelled,
        now: now
      )
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .owner,
          action: .turnCancelled,
          argsRedacted: Self.draftStopAuditSource,
          decision: ApprovalDecision.cancelled.rawValue,
          runID: runID,
          sessionID: sessionID,
          ts: now
        )
      )
      return StopCommandResult(
        newlyClaimed: true,
        sessionID: sessionID,
        cancelledRunIDs: [runID],
        resolvedApprovalIDs: resolved
      )
    }
  }
}
