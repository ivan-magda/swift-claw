import ClawCore
import Foundation
import GRDB

public struct CoderJobStoreGRDB: CoderJobStore {
  let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func admit(
    id: UUID,
    prepared: CoderPreparedRequest,
    origin: CoderOrigin,
    maxConcurrentJobs: Int,
    now: Date
  ) throws(StoreError) -> CoderAdmission {
    try database.writeMapping { db in
      if let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM coder_jobs WHERE origin_run_id = ? AND tool_call_id = ?",
        arguments: [origin.runID, origin.toolCallID]
      ) {
        return .existing(try CoderJobRecord.decode(row))
      }
      let unresolved =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM coder_jobs WHERE process_ownership = ?)",
          arguments: [CoderProcessOwnership.unresolved.rawValue]
        ) ?? false
      guard !unresolved else {
        return .recoveryRequired
      }
      let reserved = try Self.reservedJobs(db)
      guard reserved.count < maxConcurrentJobs else {
        return .busy
      }
      let workspaceConflict = reserved.contains { job in
        Self.conflicts(job.prepared, with: prepared)
      }
      if prepared.request.workspace == .inPlace && workspaceConflict {
        return .workspaceBusy
      }
      return .admitted(
        try CoderJobRecord.insert(
          db,
          id: id,
          prepared: prepared,
          origin: origin,
          now: now
        )
      )
    }
  }

  public func job(id: UUID) throws(StoreError) -> CoderJob? {
    try database.readMapping { db in
      try CoderJobRecord.fetch(db, id: id)
    }
  }

  public func lastFailedJob() throws(StoreError) -> CoderJob? {
    try database.readMapping { db in
      try Row.fetchOne(
        db,
        sql: """
          SELECT * FROM coder_jobs WHERE state IN (?, ?, ?)
          ORDER BY updated_ts DESC, id DESC LIMIT 1
          """,
        arguments: [
          CoderJobState.failed.rawValue, CoderJobState.timedOut.rawValue,
          CoderJobState.interrupted.rawValue,
        ]
      ).map(CoderJobRecord.decode)
    }
  }

  public func reservedJobs() throws(StoreError) -> [CoderJob] {
    try database.readMapping { db in
      try Self.reservedJobs(db)
    }
  }

  public func markRunning(id: UUID, now: Date) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try db.execute(
        sql: "UPDATE coder_jobs SET state = ?, updated_ts = ? WHERE id = ? AND state = ?",
        arguments: [
          CoderJobState.running.rawValue, EpochSecondCodec.epoch(now), id.uuidString,
          CoderJobState.admitted.rawValue,
        ]
      )
      return db.changesCount > 0
    }
  }

  public func requestCancellation(id: UUID, now: Date) throws(StoreError) -> CoderJob? {
    try database.writeMapping { db in
      try db.execute(
        sql: "UPDATE coder_jobs SET state = ?, updated_ts = ? WHERE id = ? AND state IN (?, ?)",
        arguments: [
          CoderJobState.stopping.rawValue, EpochSecondCodec.epoch(now), id.uuidString,
          CoderJobState.admitted.rawValue, CoderJobState.running.rawValue,
        ]
      )
      return try CoderJobRecord.fetch(db, id: id)
    }
  }
}

// MARK: - Reservation Queries

private extension CoderJobStoreGRDB {
  static func reservedJobs(_ db: Database) throws -> [CoderJob] {
    try Row.fetchAll(db, sql: "SELECT * FROM coder_jobs WHERE slot_reserved = 1 ORDER BY id")
      .map(CoderJobRecord.decode)
  }

  static func conflicts(
    _ reserved: CoderPreparedRequest,
    with proposed: CoderPreparedRequest
  ) -> Bool {
    guard reserved.request.workspace == .inPlace else {
      return false
    }
    if let checkout = proposed.checkoutPath, checkout == reserved.checkoutPath {
      return true
    }
    if let common = proposed.commonGitDirectory, common == reserved.commonGitDirectory {
      return true
    }
    return false
  }
}
