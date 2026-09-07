import ClawCore
import Foundation
import GRDB

/// GRDB persistence for scheduled jobs. Occurrence instants use UTC epoch seconds so the
/// fused claim compares exactly; callers must pass whole-second dates.
public struct ScheduledJobStoreGRDB: Sendable {
  let database: MappedDatabase
  /// `CLAW_LEARNING_ENABLED`. Disarmed, a fire binds nothing and the learning tables stay empty.
  let learningEnabled: Bool

  public init(writer: any DatabaseWriter, learningEnabled: Bool = false) {
    database = MappedDatabase(writer: writer)
    self.learningEnabled = learningEnabled
  }
}

// MARK: - CRUD

extension ScheduledJobStoreGRDB {
  public func create(_ job: NewScheduledJob, now: Date) throws(StoreError) -> ScheduledJob {
    try database.writeMapping { db in
      try Self.insertJob(db, job, now: now)
    }
  }

  /// In-transaction insert, exposed so the arm commit can fuse update-claim + create +
  /// jobCreated audit inside the command store's transaction.
  static func insertJob(_ db: Database, _ job: NewScheduledJob, now: Date) throws -> ScheduledJob {
    let recurrenceJSON: String?
    if let envelope = job.recurrence {
      do {
        recurrenceJSON = try envelope.encodedJSON()
      } catch {
        // Domain-typed at the seam: an EncodingError must not leak past the store either
        // (mirrors jobFromRow's decode wrap).
        throw StoreError.unexpected("unencodable recurrence envelope: \(error)")
      }
    } else {
      recurrenceJSON = nil
    }

    try db.execute(
      sql: """
        INSERT INTO scheduled_jobs(owner_chat_id, label, prompt, recurrence, timezone,
          next_occurrence, status, created_ts, updated_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        job.ownerChatId,
        job.label,
        job.prompt,
        recurrenceJSON,
        job.timezone,
        EpochSecondCodec.epoch(job.nextOccurrence),
        ScheduledJobStatus.active.rawValue,
        EpochSecondCodec.epoch(now),
        EpochSecondCodec.epoch(now),
      ]
    )
    guard let created = try fetchJob(db, id: db.lastInsertedRowID) else {
      throw StoreError.unexpected("scheduled job insert returned no row")
    }
    return created
  }

  public func job(id: Int64) throws(StoreError) -> ScheduledJob? {
    try database.readMapping { db in
      try Self.fetchJob(db, id: id)
    }
  }

  public func listAll() throws(StoreError) -> [ScheduledJob] {
    try database.readMapping { db in
      let rows = try Row.fetchAll(db, sql: "SELECT * FROM scheduled_jobs ORDER BY id ASC")
      return try rows.map { row in
        try Self.jobFromRow(row)
      }
    }
  }

  public func dueJobs(now: Date) throws(StoreError) -> [ScheduledJob] {
    try database.readMapping { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM scheduled_jobs
          WHERE status = ? AND next_occurrence IS NOT NULL AND next_occurrence <= ?
          ORDER BY next_occurrence ASC, id ASC
          """,
        arguments: [ScheduledJobStatus.active.rawValue, EpochSecondCodec.epoch(now)]
      )
      return try rows.map { row in
        try Self.jobFromRow(row)
      }
    }
  }
}

// MARK: - Row mapping

extension ScheduledJobStoreGRDB {
  static func fetchJob(_ db: Database, id: Int64) throws -> ScheduledJob? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM scheduled_jobs WHERE id = ?",
        arguments: [id]
      )
    else {
      return nil
    }
    return try jobFromRow(row)
  }

  static func jobFromRow(_ row: Row) throws -> ScheduledJob {
    let recurrence: RecurrenceEnvelope?
    if let json = row["recurrence"] as String? {
      do {
        recurrence = try RecurrenceEnvelope.decode(fromJSON: json)
      } catch {
        // Domain-typed at the seam: a DecodingError must not leak past the store either.
        throw StoreError.unexpected("undecodable recurrence envelope: \(error)")
      }
    } else {
      recurrence = nil
    }

    guard let status = ScheduledJobStatus(rawValue: row["status"]) else {
      throw StoreError.unexpected("unknown scheduled job status")
    }
    guard
      let createdTs = EpochSecondCodec.date(fromEpoch: row["created_ts"]),
      let updatedTs = EpochSecondCodec.date(fromEpoch: row["updated_ts"])
    else {
      throw StoreError.unexpected("scheduled job row missing timestamps")
    }

    return ScheduledJob(
      id: row["id"],
      ownerChatId: row["owner_chat_id"],
      label: row["label"],
      prompt: row["prompt"],
      recurrence: recurrence,
      timezone: row["timezone"],
      nextOccurrence: EpochSecondCodec.date(fromEpoch: row["next_occurrence"]),
      lastFiredAt: EpochSecondCodec.date(fromEpoch: row["last_fired_at"]),
      status: status,
      sessionId: row["session_id"],
      createdTs: createdTs,
      updatedTs: updatedTs
    )
  }
}

// MARK: - Owner Verbs (audits ride the status flip's transaction)

extension ScheduledJobStoreGRDB {
  public func pause(id: Int64, now: Date) throws(StoreError) -> ScheduledJob? {
    try database.writeMapping { db in
      guard let current = try Self.fetchJob(db, id: id) else {
        return nil
      }
      switch current.status {
      case .paused:
        return current  // idempotent re-pause: no write, no duplicate audit
      case .completed, .cancelled:
        return nil  // terminal — the FSM has no exit
      case .active:
        break
      }

      try db.execute(
        sql: "UPDATE scheduled_jobs SET status = ?, updated_ts = ? WHERE id = ? AND status = ?",
        arguments: [
          ScheduledJobStatus.paused.rawValue,
          EpochSecondCodec.epoch(now),
          id,
          ScheduledJobStatus.active.rawValue,
        ]
      )
      try Self.insertVerbAudit(
        db,
        action: .jobPaused,
        jobId: id,
        sessionId: current.sessionId,
        now: now
      )
      return try Self.fetchJob(db, id: id)
    }
  }

  public func resume(
    id: Int64,
    nextOccurrence: Date?,
    now: Date
  ) throws(StoreError) -> ScheduledJob? {
    try database.writeMapping { db in
      guard let current = try Self.fetchJob(db, id: id) else {
        return nil
      }
      switch current.status {
      case .active:
        return current  // idempotent: an already-running schedule is never re-aimed
      case .completed, .cancelled:
        return nil
      case .paused:
        break
      }

      try db.execute(
        sql: """
          UPDATE scheduled_jobs SET status = ?, next_occurrence = ?, updated_ts = ?
          WHERE id = ? AND status = ?
          """,
        arguments: [
          ScheduledJobStatus.active.rawValue,
          nextOccurrence.map(EpochSecondCodec.epoch),
          EpochSecondCodec.epoch(now),
          id,
          ScheduledJobStatus.paused.rawValue,
        ]
      )
      try Self.insertVerbAudit(
        db,
        action: .jobResumed,
        jobId: id,
        sessionId: current.sessionId,
        now: now
      )
      return try Self.fetchJob(db, id: id)
    }
  }

  public func cancel(id: Int64, now: Date) throws(StoreError) -> ScheduledJob? {
    try database.writeMapping { db in
      guard let current = try Self.fetchJob(db, id: id) else {
        return nil
      }
      guard current.status == .active || current.status == .paused else {
        return nil
      }

      // Terminal, row retained for audit; NULL next keeps it out of the ticker index forever.
      try db.execute(
        sql: """
          UPDATE scheduled_jobs SET status = ?, next_occurrence = NULL, updated_ts = ?
          WHERE id = ? AND status IN (?, ?)
          """,
        arguments: [
          ScheduledJobStatus.cancelled.rawValue,
          EpochSecondCodec.epoch(now),
          id,
          ScheduledJobStatus.active.rawValue,
          ScheduledJobStatus.paused.rawValue,
        ]
      )
      try Self.insertVerbAudit(
        db,
        action: .jobCancelled,
        jobId: id,
        sessionId: current.sessionId,
        now: now
      )
      return try Self.fetchJob(db, id: id)
    }
  }
}

// MARK: - Owner Verb Audit

private extension ScheduledJobStoreGRDB {
  static func insertVerbAudit(
    _ db: Database,
    action: AuditAction,
    jobId: Int64,
    sessionId: Int64?,
    now: Date
  ) throws {
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .owner,
        action: action,
        argsRedacted: "{\"job_id\":\(jobId)}",
        sessionId: sessionId,
        ts: now
      )
    )
  }
}

extension ScheduledJobStoreGRDB: ScheduledJobStore {}
