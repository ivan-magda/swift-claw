import ClawCore
import Foundation
import GRDB

/// The `/schedule` arm commit — the 3a remember-confirm composition (claim + effect + audit in
/// ONE transaction, `MemoryCommandStoreGRDB` pattern) applied to job creation. A replayed `yes`
/// fails the claim and creates nothing.
public struct ScheduleCommandStoreGRDB: ScheduleCommandStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func applyArm(
    updateId: Int64,
    job: NewScheduledJob,
    now: Date
  ) throws -> ScheduleArmResult {
    try writer.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: updateId,
        claimedAt: now
      )
      guard newlyClaimed else {
        return ScheduleArmResult(newlyClaimed: false, job: nil)
      }

      let stored = try ScheduledJobStoreGRDB.insertJob(db, job, now: now)

      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .owner,
          action: .jobCreated,
          argsRedacted: "/schedule",
          decision: "armed job \(stored.id)",
          ts: now
        )
      )

      return ScheduleArmResult(newlyClaimed: true, job: stored)
    }
  }
}
