import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct JobRunFailureTests {
  private struct JobFixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let runID: Int64
    let sessionID: Int64
  }

  /// Seeds job 7 (owner chat 4242), its synthetic session, the trusted trigger message, and a
  /// PENDING scheduled run — the exact §5.2 fused-claim output shape, by hand.
  private func makeJobRunFixture() throws -> JobFixture {
    let queue = try TestDatabase.make()
    let now = Date()
    let seeded: (runID: Int64, sessionID: Int64) = try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO scheduled_jobs(id, owner_chat_id, label, prompt, recurrence, timezone,
            next_occurrence, last_fired_at, status, session_id, created_ts, updated_ts)
          VALUES (7, 4242, 'digest', 'Summarize my unread items', NULL, 'Europe/Berlin',
            NULL, NULL, 'ACTIVE', NULL, ?, ?)
          """,
        arguments: [now, now]
      )
      try db.execute(
        sql: "INSERT INTO sessions(session_key, created_ts, updated_ts) VALUES (?, ?, ?)",
        arguments: [SessionKey.scheduledJob(id: 7), now, now]
      )
      let sessionID = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, 'user', 'Summarize my unread items', 'trusted', ?)
          """,
        arguments: [sessionID, now]
      )
      let messageID = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id,
            origin, job_id)
          VALUES (?, 'PENDING', ?, ?, ?, 'scheduled', 7)
          """,
        arguments: [sessionID, now, now, messageID]
      )
      return (db.lastInsertedRowID, sessionID)
    }
    return JobFixture(
      queue: queue,
      runs: RunStoreGRDB(writer: queue),
      runID: seeded.runID,
      sessionID: seeded.sessionID
    )
  }

  private func jobFailedCount(_ queue: DatabaseQueue, runID: Int64) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM audit_events
          WHERE action = 'job_failed' AND decision = 'job:7' AND run_id = ?
          """,
        arguments: [runID]
      ) ?? 0
    }
  }

  @Test
  func degradedCommitOfAJobRunAppendsJobFailedInTheSameTransaction() throws {
    // given
    let fixture = try makeJobRunFixture()
    #expect(try fixture.runs.pickUp(runID: fixture.runID, now: Date()) == .scheduled)

    // when
    let commit = try fixture.runs.commitDegradedTurn(
      DegradedTurn(
        runID: fixture.runID,
        sessionID: fixture.sessionID,
        chatID: 4242,
        usage: nil,
        chunk: OutboxChunk(
          stepIndex: 0,
          chatID: 4242,
          payload: "degraded",
          payloadHash: ContentHash.fnv1a("degraded")
        ),
        cause: .providerFailure
      ),
      now: Date()
    )

    // then
    #expect(commit == .committed)
    #expect(try jobFailedCount(fixture.queue, runID: fixture.runID) == 1)
  }

  @Test
  func failRunOnAJobRunAppendsJobFailed() throws {
    // given
    let fixture = try makeJobRunFixture()
    #expect(try fixture.runs.pickUp(runID: fixture.runID, now: Date()) == .scheduled)

    // when
    try fixture.runs.failRun(runID: fixture.runID, cause: .providerFailure, now: Date())

    // then
    #expect(try jobFailedCount(fixture.queue, runID: fixture.runID) == 1)
  }

  @Test
  func bootReconcileResolvesTheJobRunNoticeViaOwnerChatIDAndAuditsJobFailed() throws {
    // given — a job run left RUNNING by a crash; its sched:job:7 session key has no chat id
    let fixture = try makeJobRunFixture()
    #expect(try fixture.runs.pickUp(runID: fixture.runID, now: Date()) == .scheduled)

    // when
    let replies = try fixture.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "unfinished",
      heartbeatNoticeChatID: nil
    )

    // then — the notice targets scheduled_jobs.owner_chat_id, no longer silently skipped (A6),
    // as the whole-chat row it has always been: a job session belongs to no topic
    #expect(replies == [DegradationReply(chatID: 4242, runID: fixture.runID, text: "unfinished")])
    let row = try #require(try OutboxStoreGRDB(writer: fixture.queue).pendingOutbound().first)
    #expect(row.target == .chat(4242))
    #expect(try jobFailedCount(fixture.queue, runID: fixture.runID) == 1)
    let state = try fixture.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM runs WHERE id = ?",
        arguments: [fixture.runID]
      )
    }
    #expect(state == "FAILED")
  }

  @Test
  func nonJobRunsNeverEmitJobFailed() throws {
    // given — an ordinary interactive run (no job_id), failed the same way
    let queue = try TestDatabase.make()
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: 42),
        chatID: 42,
        userID: 42,
        text: "hi",
        isEdited: false,
        ts: Date()
      )
    )
    let runID = try #require(claim.runID)
    let runs = RunStoreGRDB(writer: queue)
    #expect(try runs.pickUp(runID: runID, now: Date()) == .interactive)

    // when
    try runs.failRun(runID: runID, cause: .providerFailure, now: Date())

    // then
    let count = try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_events WHERE action = 'job_failed'")
        ?? 0
    }
    #expect(count == 0)
  }

  /// Seeds the sched:heartbeat session, its untrusted trigger, and a heartbeat run left RUNNING
  /// by a crash — the §12 shape reconciliation must route via the config-derived owner target.
  private func makeHeartbeatRunFixture() throws -> (queue: DatabaseQueue, runID: Int64) {
    let queue = try TestDatabase.make()
    let now = Date()
    let runID: Int64 = try queue.write { db in
      try db.execute(
        sql: "INSERT INTO sessions(session_key, created_ts, updated_ts) VALUES (?, ?, ?)",
        arguments: [SessionKey.heartbeat, now, now]
      )
      let sessionID = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, role, content, provenance, ts)
          VALUES (?, 'user', 'Review the checklist below…', 'untrusted', ?)
          """,
        arguments: [sessionID, now]
      )
      let messageID = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO runs(session_id, state, created_ts, updated_ts, trigger_message_id, origin)
          VALUES (?, 'RUNNING', ?, ?, ?, 'heartbeat')
          """,
        arguments: [sessionID, now, now, messageID]
      )
      return db.lastInsertedRowID
    }
    return (queue, runID)
  }

  @Test
  func bootReconcileRoutesTheHeartbeatCrashNoticeViaTheConfigTarget() throws {
    // given
    let fixture = try makeHeartbeatRunFixture()
    let runs = RunStoreGRDB(writer: fixture.queue)

    // when — the boot caller passes the config-resolved owner DM (spec §12/A6)
    let replies = try runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "unfinished",
      heartbeatNoticeChatID: 777
    )

    // then — the notice targets the owner; no jobFailed (a heartbeat run has no job)
    #expect(replies == [DegradationReply(chatID: 777, runID: fixture.runID, text: "unfinished")])
    let state = try fixture.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM runs WHERE id = ?",
        arguments: [fixture.runID]
      )
    }
    #expect(state == RunState.failed.rawValue)
    let jobFailedRows = try fixture.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_events WHERE action = 'job_failed'")
        ?? 0
    }
    #expect(jobFailedRows == 0)
  }

  @Test
  func bootReconcileWithoutAConfigTargetStillFailsTheHeartbeatRunSilently() throws {
    // given — heartbeat disabled/misconfigured: no target, no notice, but never a wedged run
    let fixture = try makeHeartbeatRunFixture()
    let runs = RunStoreGRDB(writer: fixture.queue)

    // when
    let replies = try runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "unfinished",
      heartbeatNoticeChatID: nil
    )

    // then
    #expect(replies.isEmpty)
    let state = try fixture.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM runs WHERE id = ?",
        arguments: [fixture.runID]
      )
    }
    #expect(state == RunState.failed.rawValue)
  }
}
