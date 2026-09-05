import ClawCore
import Foundation
import GRDB

@testable import ClawData

/// A migrated database holding one armed scheduled job plus the three stores the terminal and
/// settlement suites drive: the fire path that binds a run, the run store that terminates it, and
/// the learning store that reads back its receipt.
struct BoundRunEnvironment {
  let queue: any DatabaseWriter
  let jobs: ScheduledJobStoreGRDB
  let runs: RunStoreGRDB
  let learning: ScheduledLearningStoreGRDB
  let jobId: Int64
  let sessionId: Int64
  let now: Date

  static func make(
    learningEnabled: Bool = true,
    databasePath: String? = nil
  ) throws -> BoundRunEnvironment {
    let writer: any DatabaseWriter
    if let databasePath {
      writer = try DatabaseQueue(
        path: databasePath,
        configuration: ClawDatabase.makeConfiguration()
      )
    } else {
      writer = try ClawDatabase.makeInMemoryQueue()
      try emptyDatabase.get().backup(to: writer)
    }
    return try make(learningEnabled: learningEnabled, writer: writer)
  }

  static func make(
    learningEnabled: Bool = true,
    writer: any DatabaseWriter
  ) throws -> BoundRunEnvironment {
    try ClawDatabase.migrate(writer)
    let jobs = ScheduledJobStoreGRDB(writer: writer, learningEnabled: learningEnabled)
    let now = Date(timeIntervalSince1970: 1_782_000_600)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatId: 777,
        label: "digest",
        prompt: "Summarize my unread items",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: now
      ),
      now: now
    )
    // The fire path creates the job's session lazily; establishing it up front lets the fixture
    // seed unbound runs on the same lane without firing first.
    let sessionId = try writer.write { db in
      let sessionId = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: SessionKey.scheduledJob(id: job.id),
        now: now
      )
      try db.execute(
        sql: "UPDATE scheduled_jobs SET session_id = ? WHERE id = ?",
        arguments: [sessionId, job.id]
      )
      return sessionId
    }
    return BoundRunEnvironment(
      queue: writer,
      jobs: jobs,
      runs: RunStoreGRDB(writer: writer),
      learning: ScheduledLearningStoreGRDB(writer: writer),
      jobId: job.id,
      sessionId: sessionId,
      now: now
    )
  }

  /// A fresh bound run on the job's session, already picked up and RUNNING. The job's previous run
  /// must be terminal — the fire path's overlap guard skips an occurrence while one is live.
  func runningBoundRun() throws -> Int64 {
    let runId = try pendingBoundRun()
    _ = try runs.pickUp(runId: runId, now: now)
    return runId
  }

  /// A fresh bound run left PENDING — the shape `/stop` cancels before any lane picks it up.
  func pendingBoundRun() throws -> Int64 {
    try Self.fire(jobs, jobId: jobId, now: now).runId
  }

  /// A run on the job's session with no learning binding: the heartbeat/pre-upgrade shape, and the
  /// only run in this fixture that must leave `run_settlements` empty.
  func unboundRun() throws -> Int64 {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId, MessageRole.user.rawValue, "no binding", Provenance.trusted.rawValue, now,
        ]
      )
      let triggerMessageId = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id, origin)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          sessionId, RunState.running.rawValue, now, now, triggerMessageId,
          RunOrigin.scheduled.rawValue,
        ]
      )
      return db.lastInsertedRowID
    }
  }

  func assistantTurn(
    runId: Int64,
    model: String = "m",
    content: String = "done"
  ) -> AssistantTurn {
    AssistantTurn(
      runId: runId,
      sessionId: sessionId,
      chatId: 777,
      content: content,
      usage: makeProviderUsage(runId: runId, sessionId: sessionId, model: model),
      chunks: [chunk(payload: content)]
    )
  }

  func degradedTurn(runId: Int64, cause: TerminalCause) -> DegradedTurn {
    DegradedTurn(
      runId: runId,
      sessionId: sessionId,
      chatId: 777,
      usage: nil,
      chunk: chunk(payload: "degraded"),
      cause: cause
    )
  }

  /// A bound run parked on an approval: assistant anchor, an unresolved placeholder observation,
  /// and AWAITING_APPROVAL — the shape `commitSuspendedTurn` leaves behind.
  func suspendedApproval() throws -> (runId: Int64, observationMessageId: Int64) {
    let runId = try runningBoundRun()
    let observationMessageId = try park(runId: runId)
    return (runId, observationMessageId)
  }

  /// The approval crash window: the pre-execution claim committed (AWAITING_APPROVAL → RUNNING)
  /// and the process died before the result record, so the placeholder is still unresolved.
  func claimedApprovalCrashWindow() throws -> (runId: Int64, observationMessageId: Int64) {
    let parked = try suspendedApproval()
    try queue.write { db in
      _ = try RunStoreGRDB.transitionRun(
        db,
        runId: parked.runId,
        event: .resumeApproved,
        now: now,
        terminal: nil
      )
    }
    return parked
  }

  func settledAt(runId: Int64) throws -> Date? {
    try learning.settlement(runId: runId)?.settledAt
  }

  func settlementRowCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM run_settlements") ?? -1
    }
  }
}

// MARK: - Fixture Plumbing

private extension BoundRunEnvironment {
  static let emptyDatabase: Result<DatabaseQueue, any Error> = Result {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return queue
  }

  static func fire(
    _ jobs: ScheduledJobStoreGRDB,
    jobId: Int64,
    now: Date
  ) throws -> ClaimedFire {
    guard case .fired(let fired) = try jobs.fireNow(jobId: jobId, now: now) else {
      throw StoreError.unexpected("job \(jobId) refused to fire")
    }
    return fired
  }

  /// The anchor + placeholder observation pair and the suspend transition, written directly so the
  /// fixture does not need a `PendingToolAction` it never inspects.
  func park(runId: Int64) throws -> Int64 {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_calls)
          VALUES (?, ?, 'assistant', '', 'trusted', ?,
            '[{"id":"c1","name":"file_write","arguments":"{}"}]')
          """,
        arguments: [sessionId, runId, now]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', ?, 'untrusted', ?, 'c1')
          """,
        arguments: [sessionId, runId, RunStoreGRDB.placeholderObservationContent, now]
      )
      let observationMessageId = db.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(
        db,
        runId: runId,
        event: .suspendForApproval,
        now: now,
        terminal: nil
      )
      return observationMessageId
    }
  }

  func chunk(payload: String) -> OutboxChunk {
    OutboxChunk(
      stepIndex: 0,
      chatId: 777,
      payload: payload,
      payloadHash: ContentHash.fnv1a(payload)
    )
  }
}
