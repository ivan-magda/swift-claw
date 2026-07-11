import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct CommandStoreTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let sessions: SessionMessageStoreGRDB
    let runs: RunStoreGRDB
    let commands: CommandStoreGRDB
    let sessionKey: String
    let sessionId: Int64
    let firstRunId: Int64
  }

  private struct InjectedCrash: Error {}

  private func fixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)

    let sessions = SessionMessageStoreGRDB(writer: queue)
    let sessionKey = SessionKey.telegramDM(chatId: 42)
    let firstClaim = try sessions.claimAndPersistInbound(
      inbound(updateId: 1, sessionKey: sessionKey, text: "first")
    )
    let sessionId = try #require(firstClaim.sessionId)
    let firstRunId = try #require(firstClaim.runId)

    return Fixture(
      queue: queue,
      sessions: sessions,
      runs: RunStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      sessionKey: sessionKey,
      sessionId: sessionId,
      firstRunId: firstRunId
    )
  }

  private func inbound(updateId: Int64, sessionKey: String, text: String) -> InboundMessage {
    InboundMessage(
      updateId: updateId,
      sessionKey: sessionKey,
      chatId: 42,
      userId: 42,
      text: text,
      isEdited: false,
      ts: Date(timeIntervalSince1970: Double(updateId))
    )
  }

  @Test func stopCancelsRunningAndQueuedPendingRunsAndAuditsEach() throws {
    // given — one RUNNING turn and one queued PENDING turn behind it
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runId: env.firstRunId, now: Date(timeIntervalSince1970: 10))
    )
    let queued = try env.sessions.claimAndPersistInbound(
      inbound(updateId: 2, sessionKey: env.sessionKey, text: "queued")
    )
    let queuedRunId = try #require(queued.runId)
    let now = Date(timeIntervalSince1970: 100)

    // when
    let result = try env.commands.applyStop(updateId: 100, sessionKey: env.sessionKey, now: now)

    // then — BOTH terminate (spec FSM table: PENDING + /stop → CANCELLED)
    #expect(
      result
        == StopCommandResult(
          newlyClaimed: true,
          sessionId: env.sessionId,
          cancelledRunIds: [env.firstRunId, queuedRunId]
        )
    )
    let states = try runStates(env.queue)
    #expect(states[env.firstRunId] == RunState.cancelled.rawValue)
    #expect(states[queuedRunId] == RunState.cancelled.rawValue)
    #expect(try processedCount(env.queue, updateId: 100) == 1)
    #expect(try messageCount(env.queue, content: "/stop") == 0)

    let audits = try auditRows(env.queue)
    #expect(audits.count == 2)
    #expect(audits.compactMap { $0["run_id"] as Int64? } == [env.firstRunId, queuedRunId])
    for audit in audits {
      #expect(audit["actor"] as String == AuditActor.owner.rawValue)
      #expect(audit["action"] as String == AuditAction.turnCancelled.rawValue)
      #expect(audit["args_redacted"] as String == "/stop")
      #expect(audit["decision"] as String == "cancelled")
      #expect(audit["session_id"] as Int64? == env.sessionId)
    }
  }

  @Test func newSupersedesActiveRunsResetsWindowDetaintsAndAudits() throws {
    // given
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runId: env.firstRunId, now: Date(timeIntervalSince1970: 10))
    )
    let queued = try env.sessions.claimAndPersistInbound(
      inbound(updateId: 2, sessionKey: env.sessionKey, text: "queued")
    )
    let queuedRunId = try #require(queued.runId)
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET tainted = 1, window_start_message_id = 0 WHERE id = ?",
        arguments: [env.sessionId]
      )
    }
    let latestMessageId = try #require(
      try env.queue.read { db in
        try Int64.fetchOne(
          db,
          sql: "SELECT MAX(id) FROM messages WHERE session_id = ?",
          arguments: [env.sessionId]
        )
      }
    )
    let now = Date(timeIntervalSince1970: 200)

    // when
    let result = try env.commands.applyNew(updateId: 200, sessionKey: env.sessionKey, now: now)

    // then
    #expect(
      result
        == NewCommandResult(
          newlyClaimed: true,
          sessionId: env.sessionId,
          supersededRunIds: [env.firstRunId, queuedRunId]
        )
    )
    let states = try runStates(env.queue)
    #expect(states[env.firstRunId] == RunState.superseded.rawValue)
    #expect(states[queuedRunId] == RunState.superseded.rawValue)
    let session = try #require(
      try env.queue.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT window_start_message_id, tainted, updated_ts FROM sessions WHERE id = ?",
          arguments: [env.sessionId]
        )
      }
    )
    #expect(session["window_start_message_id"] as Int64 == latestMessageId)
    #expect(session["tainted"] as Bool == false)
    #expect(session["updated_ts"] as Date == now)
    #expect(try messageCount(env.queue, content: "/new") == 0)

    let audits = try auditRows(env.queue)
    #expect(audits.count == 2)
    #expect(
      audits.map { $0["action"] as String } == [
        AuditAction.turnSuperseded.rawValue, AuditAction.turnSuperseded.rawValue,
      ]
    )
    #expect(audits.map { $0["decision"] as String } == ["superseded", "superseded"])
    #expect(audits.map { $0["args_redacted"] as String } == ["/new", "/new"])
    #expect(audits.map { $0["run_id"] as Int64? } == [env.firstRunId, queuedRunId])
  }

  @Test func newDetaintsBothStickyFlagsAndReportsSupersededRuns() throws {
    // given — an active session carrying BOTH sticky flags plus one RUNNING and one queued run
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runId: env.firstRunId, now: Date(timeIntervalSince1970: 10))
    )
    let queued = try env.sessions.claimAndPersistInbound(
      inbound(updateId: 2, sessionKey: env.sessionKey, text: "queued")
    )
    let queuedRunId = try #require(queued.runId)
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET tainted = 1, has_private_data = 1 WHERE id = ?",
        arguments: [env.sessionId]
      )
    }
    let now = Date(timeIntervalSince1970: 200)

    // when
    let result = try env.commands.applyNew(updateId: 200, sessionKey: env.sessionKey, now: now)

    // then — supersede AND both-flag detaint are observed jointly after the single /new commit
    #expect(result.supersededRunIds == [env.firstRunId, queuedRunId])
    let states = try runStates(env.queue)
    #expect(states[env.firstRunId] == RunState.superseded.rawValue)
    #expect(states[queuedRunId] == RunState.superseded.rawValue)
    let flags = try sessionFlags(env.queue, sessionId: env.sessionId)
    #expect(flags.tainted == false)
    #expect(flags.hasPrivateData == false)
  }

  @Test func newSupersedeAndDetaintCommitTogether() throws {
    // given — active runs and both sticky flags set, with a store that throws AFTER the in-txn
    // supersede+detaint so we can observe whether they persist independently of a later failure
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runId: env.firstRunId, now: Date(timeIntervalSince1970: 10))
    )
    let queued = try env.sessions.claimAndPersistInbound(
      inbound(updateId: 2, sessionKey: env.sessionKey, text: "queued")
    )
    let queuedRunId = try #require(queued.runId)
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET tainted = 1, has_private_data = 1 WHERE id = ?",
        arguments: [env.sessionId]
      )
    }
    let statesBefore = try runStates(env.queue)
    let crashingStore = CommandStoreGRDB(
      writer: env.queue,
      afterSupersedeAndDetaintForTesting: { throw InjectedCrash() }
    )
    let now = Date(timeIntervalSince1970: 500)

    // when — the post-detaint throw surfaces classified at the seam, never as its raw type
    #expect(throws: StoreError.self) {
      try crashingStore.applyNew(updateId: 500, sessionKey: env.sessionKey, now: now)
    }

    // then — the whole transaction rolls back: supersede and detaint commit together or not at all,
    // so a future split into two transactions (leaving supersede persisted) would break this
    #expect(try processedCount(env.queue, updateId: 500) == 0)
    let statesAfter = try runStates(env.queue)
    #expect(statesAfter == statesBefore)
    #expect(statesAfter[env.firstRunId] != RunState.superseded.rawValue)
    #expect(statesAfter[queuedRunId] != RunState.superseded.rawValue)
    let flags = try sessionFlags(env.queue, sessionId: env.sessionId)
    #expect(flags.tainted == true)
    #expect(flags.hasPrivateData == true)
  }

  @Test func duplicateCommandDoesNotRepeatEffects() throws {
    // given
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runId: env.firstRunId, now: Date(timeIntervalSince1970: 10))
    )
    let now = Date(timeIntervalSince1970: 300)
    let first = try env.commands.applyStop(updateId: 300, sessionKey: env.sessionKey, now: now)

    // when
    let duplicate = try env.commands.applyStop(updateId: 300, sessionKey: env.sessionKey, now: now)

    // then
    #expect(first.cancelledRunIds == [env.firstRunId])
    #expect(
      duplicate == StopCommandResult(newlyClaimed: false, sessionId: nil, cancelledRunIds: [])
    )
    #expect(try processedCount(env.queue, updateId: 300) == 1)
    #expect(try auditRows(env.queue).count == 1)
    let states = try runStates(env.queue)
    #expect(states[env.firstRunId] == RunState.cancelled.rawValue)
  }

  @Test func crashAfterClaimRollsBackClaimAndAllowsRetry() throws {
    // given
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runId: env.firstRunId, now: Date(timeIntervalSince1970: 10))
    )
    let crashingStore = CommandStoreGRDB(
      writer: env.queue,
      afterClaimForTesting: { throw InjectedCrash() }
    )
    let now = Date(timeIntervalSince1970: 400)

    // when — the injected crash surfaces classified at the seam, never as its raw type
    #expect(throws: StoreError.self) {
      try crashingStore.applyStop(updateId: 400, sessionKey: env.sessionKey, now: now)
    }

    // then
    #expect(try processedCount(env.queue, updateId: 400) == 0)
    #expect(try runStates(env.queue)[env.firstRunId] == RunState.running.rawValue)

    let retry = try env.commands.applyStop(updateId: 400, sessionKey: env.sessionKey, now: now)
    #expect(retry.cancelledRunIds == [env.firstRunId])
    #expect(try processedCount(env.queue, updateId: 400) == 1)
    #expect(try runStates(env.queue)[env.firstRunId] == RunState.cancelled.rawValue)
  }

  private func runStates(_ queue: DatabaseQueue) throws -> [Int64: String] {
    try queue.read { db in
      let rows = try Row.fetchAll(db, sql: "SELECT id, state FROM runs")
      return Dictionary(
        uniqueKeysWithValues: rows.map { row in (row["id"] as Int64, row["state"] as String) }
      )
    }
  }

  private func sessionFlags(
    _ queue: DatabaseQueue,
    sessionId: Int64
  ) throws -> (tainted: Bool, hasPrivateData: Bool) {
    let row = try #require(
      try queue.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT tainted, has_private_data FROM sessions WHERE id = ?",
          arguments: [sessionId]
        )
      }
    )
    return (tainted: row["tainted"], hasPrivateData: row["has_private_data"])
  }

  private func processedCount(_ queue: DatabaseQueue, updateId: Int64) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM processed_updates WHERE update_id = ?",
        arguments: [updateId]
      ) ?? 0
    }
  }

  private func messageCount(_ queue: DatabaseQueue, content: String) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages WHERE content = ?",
        arguments: [content]
      ) ?? 0
    }
  }

  private func auditRows(_ queue: DatabaseQueue) throws -> [Row] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT actor, action, args_redacted, decision, run_id, session_id
          FROM audit_events
          ORDER BY id ASC
          """
      )
    }
  }
}
