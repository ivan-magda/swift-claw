import ClawCore
import Foundation
import GRDB

extension CoderJobStoreGRDB {
  public func recordProcess(id: UUID, event: CoderProcessEvent, now: Date) throws(StoreError) {
    try database.writeMapping { db in
      guard let job = try CoderJobRecord.fetch(db, id: id) else {
        throw StoreError.unexpected("Coder process event has no job")
      }
      guard let update = try Self.processUpdate(job: job, event: event) else {
        return
      }
      try db.execute(
        sql: """
          UPDATE coder_jobs SET process_ownership = ?, process_receipt_json = ?, updated_ts = ?
          WHERE id = ?
          """,
        arguments: [
          update.ownership.rawValue, try CoderJobRecord.encodeJSON(update.receipt),
          EpochSecondCodec.epoch(now), id.uuidString,
        ]
      )
    }
  }
}

// MARK: - Process Transitions

private extension CoderJobStoreGRDB {
  static func processUpdate(
    job: CoderJob,
    event: CoderProcessEvent
  ) throws -> (ownership: CoderProcessOwnership, receipt: CoderProcessReceipt)? {
    switch event {
    case .willLaunch(let receipt):
      guard job.state == .running, job.slotReserved,
        job.ownership == .none || job.ownership == .stopped
      else {
        throw StoreError.unexpected("Coder job cannot begin a process launch")
      }
      return (.launching, receipt)
    case .didLaunch(let receipt):
      guard job.ownership == .launching, job.processReceipt?.launchID == receipt.launchID else {
        return nil
      }
      return (.owned, receipt)
    case .stopped(let launchID):
      guard let receipt = job.processReceipt, receipt.launchID == launchID else {
        return nil
      }
      return (.stopped, receipt)
    case .unresolved(let launchID):
      guard let receipt = job.processReceipt, receipt.launchID == launchID else {
        return nil
      }
      return (.unresolved, receipt)
    }
  }
}
