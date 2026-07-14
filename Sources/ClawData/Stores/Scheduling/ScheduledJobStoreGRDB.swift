import ClawCore
import Foundation
import GRDB

/// GRDB implementation of `ScheduledJobStore`. Occurrence instants persist as UTC epoch-second
/// INTEGERs so the fused claim's compare-and-advance is exact integer equality; callers pass
/// whole-second `Date`s (`OccurrenceCalculator` emits whole seconds). `Sendable` is declared
/// because the task-group race test captures the store in `@Sendable` child tasks — strict
/// concurrency rejects that until the conformance exists (the only stored property is the
/// `Sendable` `MappedDatabase`). Method groups live in same-type extensions below purely to
/// keep each extension's body under the project's `type_body_length` gate; the store is still
/// one type with one stored property.
public struct ScheduledJobStoreGRDB: Sendable {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
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
      return try rows.map { row in try Self.jobFromRow(row) }
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
      return try rows.map { row in try Self.jobFromRow(row) }
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

// MARK: - Fused Claim

extension ScheduledJobStoreGRDB {
  public func claimAndFire(
    jobId: Int64,
    due: Date,
    fireAt: Date,
    nextOccurrence: Date?,
    now: Date
  ) throws(StoreError) -> ClaimedFire? {
    try database.writeMapping { db in
      // Step 1: the compare-and-advance. This IS the atomic claim expressed on the occurrence:
      // the WHERE arms (id, stored due, ACTIVE) make two racers for the same (job, due)
      // structurally single-winner.
      if let nextOccurrence {
        try db.execute(
          sql: """
            UPDATE scheduled_jobs
            SET next_occurrence = ?, last_fired_at = ?, updated_ts = ?
            WHERE id = ? AND next_occurrence = ? AND status = ?
            """,
          arguments: [
            EpochSecondCodec.epoch(nextOccurrence),
            EpochSecondCodec.epoch(fireAt),
            EpochSecondCodec.epoch(now),
            jobId,
            EpochSecondCodec.epoch(due),
            ScheduledJobStatus.active.rawValue,
          ]
        )
      } else {
        // One-shot: fired means done — terminal, NULL next, invisible to the ticker index.
        try db.execute(
          sql: """
            UPDATE scheduled_jobs
            SET next_occurrence = NULL, last_fired_at = ?, status = ?, updated_ts = ?
            WHERE id = ? AND next_occurrence = ? AND status = ?
            """,
          arguments: [
            EpochSecondCodec.epoch(fireAt),
            ScheduledJobStatus.completed.rawValue,
            EpochSecondCodec.epoch(now),
            jobId,
            EpochSecondCodec.epoch(due),
            ScheduledJobStatus.active.rawValue,
          ]
        )
      }
      // Step 2: zero changes ⇒ claimed elsewhere or the job mutated — abort silently, no fire.
      guard db.changesCount > 0 else {
        return nil
      }
      return try Self.insertFireRows(db, jobId: jobId, now: now)
    }
  }

  /// Steps 3-6 of the fire transaction: lazy session, trigger message, PENDING run, audit.
  /// Shared verbatim by `fireNow` (which skips only step 1's advance).
  static func insertFireRows(_ db: Database, jobId: Int64, now: Date) throws -> ClaimedFire {
    guard
      let jobRow = try Row.fetchOne(
        db,
        sql: "SELECT owner_chat_id, prompt, session_id FROM scheduled_jobs WHERE id = ?",
        arguments: [jobId]
      )
    else {
      throw StoreError.unexpected("claimed scheduled job \(jobId) has no row")
    }
    let ownerChatId: Int64 = jobRow["owner_chat_id"]
    let prompt: String = jobRow["prompt"]

    let sessionId = try ensureJobSession(
      db,
      jobId: jobId,
      existingSessionId: jobRow["session_id"],
      now: now
    )

    // Each fire opens on a fresh context window (the /new mechanism): prior fires stay durable
    // for audit and FTS, but a past turn — including a bad one — never replays into this run's
    // context. The trigger inserted below is the new window's first row.
    try SessionMessageStoreGRDB.resetWindowAndDetaint(db, sessionId: sessionId, now: now)

    // Step 4: the trigger message — the owner's own confirmed text, frozen at arm time, so
    // trusted-tier deliberately (anything the RUN ingests stays untrusted).
    try db.execute(
      sql: """
        INSERT INTO messages(session_id, role, content, provenance, ts)
        VALUES (?, ?, ?, ?, ?)
        """,
      arguments: [
        sessionId,
        MessageRole.user.rawValue,
        prompt,
        Provenance.trusted.rawValue,
        now,
      ]
    )
    let triggerMessageId = db.lastInsertedRowID

    let runId = try insertPendingJobRun(
      db,
      sessionId: sessionId,
      triggerMessageId: triggerMessageId,
      jobId: jobId,
      now: now
    )

    // Step 6: the audit row rides the same transaction as its side effect (house rule).
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .system,
        action: .jobExecuted,
        argsRedacted: "{\"job_id\":\(jobId)}",
        runId: runId,
        sessionId: sessionId,
        ts: now
      )
    )

    return ClaimedFire(
      runId: runId,
      sessionId: sessionId,
      triggerMessageId: triggerMessageId,
      ownerChatId: ownerChatId
    )
  }
}

// MARK: - Run-Now and Misfire Skip

extension ScheduledJobStoreGRDB {
  public func fireNow(jobId: Int64, now: Date) throws(StoreError) -> ClaimedFire? {
    try database.writeMapping { db in
      let rawStatus = try String.fetchOne(
        db,
        sql: "SELECT status FROM scheduled_jobs WHERE id = ?",
        arguments: [jobId]
      )
      guard
        let rawStatus,
        let status = ScheduledJobStatus(rawValue: rawStatus),
        status == .active || status == .paused
      else {
        return nil
      }

      // A real fire for the bookkeeping (last_fired_at), but NO schedule advance and NO status
      // change — /runnow on a PAUSED job tests it without unmuting it.
      try db.execute(
        sql: "UPDATE scheduled_jobs SET last_fired_at = ?, updated_ts = ? WHERE id = ?",
        arguments: [EpochSecondCodec.epoch(now), EpochSecondCodec.epoch(now), jobId]
      )
      return try Self.insertFireRows(db, jobId: jobId, now: now)
    }
  }

  public func skipMisfire(
    jobId: Int64,
    due: Date,
    nextOccurrence: Date?,
    skippedCount: Int,
    now: Date
  ) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      // The same CAS predicate as the claim — a concurrently-mutated job means no skip.
      if let nextOccurrence {
        try db.execute(
          sql: """
            UPDATE scheduled_jobs
            SET next_occurrence = ?, updated_ts = ?
            WHERE id = ? AND next_occurrence = ? AND status = ?
            """,
          arguments: [
            EpochSecondCodec.epoch(nextOccurrence),
            EpochSecondCodec.epoch(now),
            jobId,
            EpochSecondCodec.epoch(due),
            ScheduledJobStatus.active.rawValue,
          ]
        )
      } else {
        try db.execute(
          sql: """
            UPDATE scheduled_jobs
            SET next_occurrence = NULL, status = ?, updated_ts = ?
            WHERE id = ? AND next_occurrence = ? AND status = ?
            """,
          arguments: [
            ScheduledJobStatus.completed.rawValue,
            EpochSecondCodec.epoch(now),
            jobId,
            EpochSecondCodec.epoch(due),
            ScheduledJobStatus.active.rawValue,
          ]
        )
      }
      guard db.changesCount > 0 else {
        return false
      }

      try db.execute(
        sql: """
          INSERT INTO scheduler_state(id, last_misfire_at, last_misfire_skipped_count)
          VALUES (1, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            last_misfire_at = excluded.last_misfire_at,
            last_misfire_skipped_count = excluded.last_misfire_skipped_count
          """,
        arguments: [EpochSecondCodec.epoch(now), skippedCount]
      )
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .system,
          action: .jobMisfire,
          argsRedacted: "{\"job_id\":\(jobId),\"skipped_count\":\(skippedCount)}",
          ts: now
        )
      )
      return true
    }
  }
}

// MARK: - Scheduler State

extension ScheduledJobStoreGRDB {
  public func schedulerState() throws(StoreError) -> SchedulerState {
    try database.readMapping { db in
      guard
        let row = try Row.fetchOne(db, sql: "SELECT * FROM scheduler_state WHERE id = 1")
      else {
        return SchedulerState(
          lastTickAt: nil,
          lastMisfireAt: nil,
          lastMisfireSkippedCount: 0,
          lastHeartbeatAt: nil,
          heartbeatCountDay: nil,
          heartbeatCount: 0
        )
      }
      return SchedulerState(
        lastTickAt: EpochSecondCodec.date(fromEpoch: row["last_tick_at"]),
        lastMisfireAt: EpochSecondCodec.date(fromEpoch: row["last_misfire_at"]),
        lastMisfireSkippedCount: row["last_misfire_skipped_count"],
        lastHeartbeatAt: EpochSecondCodec.date(fromEpoch: row["last_heartbeat_at"]),
        heartbeatCountDay: row["heartbeat_count_day"],
        heartbeatCount: row["heartbeat_count"]
      )
    }
  }

  public func recordTick(at tickTime: Date) throws(StoreError) {
    try database.writeMapping { db in
      try db.execute(
        sql: """
          INSERT INTO scheduler_state(id, last_tick_at) VALUES (1, ?)
          ON CONFLICT(id) DO UPDATE SET last_tick_at = excluded.last_tick_at
          """,
        arguments: [EpochSecondCodec.epoch(tickTime)]
      )
    }
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

  private static func insertVerbAudit(
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

// MARK: - Heartbeat Fire (the gating lives in SchedulerService)

extension ScheduledJobStoreGRDB {
  public func fireHeartbeat(
    prompt: String,
    ownerChatId: Int64,
    now: Date,
    day: String
  ) throws(StoreError) -> ClaimedFire {
    try database.writeMapping { db in
      let sessionId = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: SessionKey.heartbeat,
        now: now
      )

      // Same per-fire isolation as a job fire: each beat starts on a fresh window of the
      // persistent heartbeat session.
      try SessionMessageStoreGRDB.resetWindowAndDetaint(db, sessionId: sessionId, now: now)

      // The gateway-authored template WRAPS HEARTBEAT.md content, so the combined trigger text
      // carries the untrusted tier — workspace-file data must never enter context as trusted
      // (contrast the scheduled-job trigger, which is pure owner-confirmed text).
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId,
          MessageRole.user.rawValue,
          prompt,
          Provenance.untrusted.rawValue,
          now,
        ]
      )
      let triggerMessageId = db.lastInsertedRowID

      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id, origin)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId,
          RunState.pending.rawValue,
          now,
          now,
          triggerMessageId,
          RunOrigin.heartbeat.rawValue,
        ]
      )
      let runId = db.lastInsertedRowID

      // Day-counter roll: same `day` increments; a new `day` resets to 1. `day` is computed by
      // the caller in CLAW_TIMEZONE so the cap boundary aligns with quiet hours, not UTC.
      let previous = try Row.fetchOne(
        db,
        sql: "SELECT heartbeat_count_day, heartbeat_count FROM scheduler_state WHERE id = 1"
      )
      let previousDay = previous?["heartbeat_count_day"] as String?
      let previousCount = previous?["heartbeat_count"] as Int? ?? 0
      let newCount = previousDay == day ? previousCount + 1 : 1
      try db.execute(
        sql: """
          INSERT INTO scheduler_state(id, last_heartbeat_at, heartbeat_count_day, heartbeat_count)
          VALUES (1, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            last_heartbeat_at = excluded.last_heartbeat_at,
            heartbeat_count_day = excluded.heartbeat_count_day,
            heartbeat_count = excluded.heartbeat_count
          """,
        arguments: [EpochSecondCodec.epoch(now), day, newCount]
      )

      return ClaimedFire(
        runId: runId,
        sessionId: sessionId,
        triggerMessageId: triggerMessageId,
        ownerChatId: ownerChatId
      )
    }
  }
}

// MARK: - Fire-Row Helpers

private extension ScheduledJobStoreGRDB {
  /// Step 3: the job's dedicated session, created lazily on first fire. The session row
  /// stores NO chat id — the delivery target stays on the job row.
  static func ensureJobSession(
    _ db: Database,
    jobId: Int64,
    existingSessionId: Int64?,
    now: Date
  ) throws -> Int64 {
    if let existingSessionId {
      return existingSessionId
    }
    let sessionId = try SessionMessageStoreGRDB.upsertSession(
      db,
      sessionKey: SessionKey.scheduledJob(id: jobId),
      now: now
    )
    try db.execute(
      sql: "UPDATE scheduled_jobs SET session_id = ? WHERE id = ?",
      arguments: [sessionId, jobId]
    )
    return sessionId
  }

  /// Step 5: the PENDING run TurnRunner will pick up, stamped with origin + job linkage.
  static func insertPendingJobRun(
    _ db: Database,
    sessionId: Int64,
    triggerMessageId: Int64,
    jobId: Int64,
    now: Date
  ) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id,
          origin, job_id)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        sessionId,
        RunState.pending.rawValue,
        now,
        now,
        triggerMessageId,
        RunOrigin.scheduled.rawValue,
        jobId,
      ]
    )
    return db.lastInsertedRowID
  }
}

extension ScheduledJobStoreGRDB: ScheduledJobStore {}
