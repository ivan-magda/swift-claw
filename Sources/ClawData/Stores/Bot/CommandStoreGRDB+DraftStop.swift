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
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateID: updateID,
        claimedAt: now
      )
      guard newlyClaimed else {
        return StopCommandResult(newlyClaimed: false, sessionID: nil, cancelledRunIDs: [])
      }

      let sessionID = try Int64.fetchOne(
        db,
        sql: "SELECT session_id FROM runs WHERE id = ?",
        arguments: [runID]
      )
      guard let sessionID else {
        return StopCommandResult(newlyClaimed: true, sessionID: nil, cancelledRunIDs: [])
      }

      let didCancelRun = try RunStoreGRDB.cancelRun(db, runID: runID, now: now)
      guard didCancelRun else {
        return StopCommandResult(newlyClaimed: true, sessionID: sessionID, cancelledRunIDs: [])
      }

      let resolvedApprovalIDs = try ApprovalStoreGRDB.resolvePendingApprovals(
        db,
        runIDs: [runID],
        decision: .cancelled,
        now: now
      )

      let auditEvent = AuditEvent(
        actor: .owner,
        action: .turnCancelled,
        argsRedacted: Self.draftStopAuditSource,
        decision: ApprovalDecision.cancelled.rawValue,
        runID: runID,
        sessionID: sessionID,
        ts: now
      )
      try AuditLogGRDB.insertAudit(db, auditEvent)

      return StopCommandResult(
        newlyClaimed: true,
        sessionID: sessionID,
        cancelledRunIDs: [runID],
        resolvedApprovalIDs: resolvedApprovalIDs
      )
    }
  }
}
