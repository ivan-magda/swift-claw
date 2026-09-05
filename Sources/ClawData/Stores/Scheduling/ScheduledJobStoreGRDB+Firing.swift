import ClawCore
import Foundation
import GRDB

// MARK: - Occurrence Compare-and-Advance

extension ScheduledJobStoreGRDB {
  /// Moves a job off the occurrence it is currently due at, and reports whether this caller won.
  ///
  /// The WHERE arms (id, the stored due instant, ACTIVE) are what make two racers for the same
  /// (job, due) structurally single-winner: the loser matches no row and changes nothing. A
  /// recurring job advances to `nextOccurrence`; a one-shot has no next, so firing means done —
  /// terminal, NULL next, invisible to the ticker index. Both the fire claim and the misfire skip
  /// turn on this one predicate, so a change to the race is a change to both.
  static func advanceOccurrence(
    _ db: Database,
    jobId: Int64,
    due: Date,
    nextOccurrence: Date?,
    now: Date
  ) throws -> Bool {
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
    return db.changesCount > 0
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
      // Step 1: the compare-and-advance. This IS the atomic claim expressed on the occurrence.
      // `last_fired_at` is deliberately NOT set here: it must move only when a run is actually
      // created, so an overlap-skipped fire (insertFireRows → nil) leaves it untouched, like a
      // misfire skip. insertFireRows stamps it with `fireAt` after the overlap guard passes.
      //
      // Step 2: no winner ⇒ claimed elsewhere or the job mutated — abort silently, no fire.
      guard
        try Self.advanceOccurrence(
          db,
          jobId: jobId,
          due: due,
          nextOccurrence: nextOccurrence,
          now: now
        )
      else {
        return nil
      }
      return try insertFireRows(
        db,
        jobId: jobId,
        fireAt: fireAt,
        fireKind: .scheduledOccurrence,
        now: now
      )
    }
  }

  /// Steps 3-6 of the fire transaction: lazy session, trigger message, PENDING run, the learning
  /// binding when the daemon is armed, audit, and the `last_fired_at` stamp. Shared by
  /// `claimAndFire` (which advances the schedule first) and
  /// `fireNow` (which doesn't). `fireAt` is the fire's logical instant — `claimAndFire`'s T_fire,
  /// `now` for `fireNow` — recorded to `last_fired_at` only if the overlap guard lets the fire run.
  func insertFireRows(  // swiftlint:disable:this function_body_length
    _ db: Database,
    jobId: Int64,
    fireAt: Date,
    fireKind: ScheduledFireKind,
    now: Date
  ) throws -> ClaimedFire? {
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

    let sessionId = try Self.ensureJobSession(
      db,
      jobId: jobId,
      existingSessionId: jobRow["session_id"],
      now: now
    )

    // Skip this occurrence when the prior run on this job's session is still live; the schedule
    // already advanced, so it drops like a misfire rather than resetting the shared window.
    if try Self.shouldSkipOverlappingFire(
      db,
      sessionId: sessionId,
      action: .jobOverlapSkipped,
      argsRedacted: "{\"job_id\":\(jobId)}",
      now: now
    ) {
      return nil
    }

    // The overlap guard passed — this fire creates a run, so stamp last_fired_at now (never on the
    // claim, which also matches an about-to-be-skipped occurrence). Rides the same transaction.
    try db.execute(
      sql: "UPDATE scheduled_jobs SET last_fired_at = ?, updated_ts = ? WHERE id = ?",
      arguments: [EpochSecondCodec.epoch(fireAt), EpochSecondCodec.epoch(now), jobId]
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

    let runId = try Self.insertPendingJobRun(
      db,
      sessionId: sessionId,
      triggerMessageId: triggerMessageId,
      jobId: jobId,
      now: now
    )

    // The run now exists, so this fire has granted exposure and may consume a trial assignment.
    // Every path above returns before here, which is what keeps a compare-and-swap loss and an
    // overlap skip from consuming one. Riding this transaction means neither the run nor the
    // lessons it ran against can exist without the other.
    var binding: RunLearningBinding?
    if learningEnabled {
      binding = try ScheduledLearningStoreGRDB.bindFire(
        db,
        jobId: jobId,
        runId: runId,
        fireKind: fireKind,
        occurrenceAt: fireAt,
        now: now
      )
    }

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
      ownerChatId: ownerChatId,
      binding: binding
    )
  }
}

// MARK: - Run-Now and Misfire Skip

extension ScheduledJobStoreGRDB {
  public func fireNow(jobId: Int64, now: Date) throws(StoreError) -> RunNowOutcome {
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
        return .ineligible
      }

      // NO schedule advance and NO status change — /runnow on a PAUSED job tests it without
      // unmuting it. insertFireRows stamps last_fired_at (fireAt = now) only if a run is created;
      // a nil means the overlap guard skipped this fire (a prior run on the session is still
      // live) — distinct from an absent job, so the owner ack can differ.
      // `.ownerRunNow`, not `.scheduledOccurrence`: both consume exposure identically, but the
      // binding has to freeze which one happened, and `RunOrigin` collapses them into `.scheduled`.
      let fire = try insertFireRows(
        db,
        jobId: jobId,
        fireAt: now,
        fireKind: .ownerRunNow,
        now: now
      )
      guard let fire else {
        return .skippedActiveRun
      }
      return .fired(fire)
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
      // A concurrently-mutated job means no skip.
      guard
        try Self.advanceOccurrence(
          db,
          jobId: jobId,
          due: due,
          nextOccurrence: nextOccurrence,
          now: now
        )
      else {
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

// MARK: - Fire-Row Helpers

private extension ScheduledJobStoreGRDB {
  /// The job fire's per-session serialization guard: true (and a `.jobOverlapSkipped` audit
  /// written in the fire transaction) when the target session already carries a live run.
  /// Firing again would reset the shared context window out from under that run, emptying its
  /// context on resume — so the caller drops this occurrence like a misfire. (The heartbeat path
  /// returns nil instead and audits from the gateway, where its skip-reason enum lives.)
  static func shouldSkipOverlappingFire(
    _ db: Database,
    sessionId: Int64,
    action: AuditAction,
    argsRedacted: String,
    now: Date
  ) throws -> Bool {
    guard try RunStoreGRDB.hasLiveRun(db, sessionId: sessionId) else {
      return false
    }
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .system,
        action: action,
        argsRedacted: argsRedacted,
        sessionId: sessionId,
        ts: now
      )
    )
    return true
  }

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
