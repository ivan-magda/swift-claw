import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct CommandStoreTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let sessions: SessionMessageStoreGRDB
    let runs: RunStoreGRDB
    let commands: CommandStoreGRDB
    let sessionKey: String
    let sessionID: Int64
    let firstRunID: Int64
  }

  private struct InjectedCrash: Error {}

  private func fixture() throws -> Fixture {
    let queue = try TestDatabase.make()

    let sessions = SessionMessageStoreGRDB(writer: queue)
    let sessionKey = SessionKey.telegramDM(chatID: 42)
    let firstClaim = try sessions.claimAndPersistInbound(
      inbound(updateID: 1, sessionKey: sessionKey, text: "first")
    )
    let sessionID = try #require(firstClaim.sessionID)
    let firstRunID = try #require(firstClaim.runID)

    return Fixture(
      queue: queue,
      sessions: sessions,
      runs: RunStoreGRDB(writer: queue),
      commands: CommandStoreGRDB(writer: queue),
      sessionKey: sessionKey,
      sessionID: sessionID,
      firstRunID: firstRunID
    )
  }

  private func inbound(updateID: Int64, sessionKey: String, text: String) -> InboundMessage {
    InboundMessage(
      updateID: updateID,
      sessionKey: sessionKey,
      chatID: 42,
      userID: 42,
      text: text,
      isEdited: false,
      ts: Date(timeIntervalSince1970: Double(updateID))
    )
  }

  @Test
  func stopCancelsRunningAndQueuedPendingRunsAndAuditsEach() throws {
    // given — one RUNNING turn and one queued PENDING turn behind it
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runID: env.firstRunID, now: Date(timeIntervalSince1970: 10))
    )
    let queued = try env.sessions.claimAndPersistInbound(
      inbound(updateID: 2, sessionKey: env.sessionKey, text: "queued")
    )
    let queuedRunID = try #require(queued.runID)
    let now = Date(timeIntervalSince1970: 100)

    // when
    let result = try env.commands.applyStop(updateID: 100, sessionKey: env.sessionKey, now: now)

    // then — BOTH terminate (spec FSM table: PENDING + /stop → CANCELLED)
    #expect(
      result
        == StopCommandResult(
          newlyClaimed: true,
          sessionID: env.sessionID,
          cancelledRunIDs: [env.firstRunID, queuedRunID]
        )
    )
    let states = try runStates(env.queue)
    #expect(states[env.firstRunID] == RunState.cancelled.rawValue)
    #expect(states[queuedRunID] == RunState.cancelled.rawValue)
    #expect(try processedCount(env.queue, updateID: 100) == 1)
    #expect(try messageCount(env.queue, content: "/stop") == 0)

    let audits = try auditRows(env.queue)
    #expect(audits.count == 2)
    #expect(
      audits.compactMap {
        $0["run_id"] as Int64?
      } == [env.firstRunID, queuedRunID]
    )
    for audit in audits {
      #expect(audit["actor"] as String == AuditActor.owner.rawValue)
      #expect(audit["action"] as String == AuditAction.turnCancelled.rawValue)
      #expect(audit["args_redacted"] as String == "/stop")
      #expect(audit["decision"] as String == "cancelled")
      #expect(audit["session_id"] as Int64? == env.sessionID)
    }
  }

  @Test
  func newSupersedesActiveRunsResetsWindowDetaintsAndAudits() throws {
    // given
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runID: env.firstRunID, now: Date(timeIntervalSince1970: 10))
    )
    let queued = try env.sessions.claimAndPersistInbound(
      inbound(updateID: 2, sessionKey: env.sessionKey, text: "queued")
    )
    let queuedRunID = try #require(queued.runID)
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET tainted = 1, window_start_message_id = 0 WHERE id = ?",
        arguments: [env.sessionID]
      )
    }
    let latestMessageID = try #require(
      try env.queue.read { db in
        try Int64.fetchOne(
          db,
          sql: "SELECT MAX(id) FROM messages WHERE session_id = ?",
          arguments: [env.sessionID]
        )
      }
    )
    let now = Date(timeIntervalSince1970: 200)

    // when
    let result = try env.commands.applyNew(updateID: 200, sessionKey: env.sessionKey, now: now)

    // then
    #expect(
      result
        == NewCommandResult(
          newlyClaimed: true,
          sessionID: env.sessionID,
          supersededRunIDs: [env.firstRunID, queuedRunID]
        )
    )
    let states = try runStates(env.queue)
    #expect(states[env.firstRunID] == RunState.superseded.rawValue)
    #expect(states[queuedRunID] == RunState.superseded.rawValue)
    let session = try #require(
      try env.queue.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT window_start_message_id, tainted, updated_ts FROM sessions WHERE id = ?",
          arguments: [env.sessionID]
        )
      }
    )
    #expect(session["window_start_message_id"] as Int64 == latestMessageID)
    #expect(session["tainted"] as Bool == false)
    #expect(session["updated_ts"] as Date == now)
    #expect(try messageCount(env.queue, content: "/new") == 0)

    let audits = try auditRows(env.queue)
    #expect(audits.count == 2)
    #expect(
      audits.map {
        $0["action"] as String
      } == [
        AuditAction.turnSuperseded.rawValue,
        AuditAction.turnSuperseded.rawValue,
      ]
    )
    #expect(
      audits.map {
        $0["decision"] as String
      } == ["superseded", "superseded"]
    )
    #expect(
      audits.map {
        $0["args_redacted"] as String
      } == ["/new", "/new"]
    )
    #expect(
      audits.map {
        $0["run_id"] as Int64?
      } == [env.firstRunID, queuedRunID]
    )
  }

  @Test
  func newDetaintsBothStickyFlagsAndReportsSupersededRuns() throws {
    // given — an active session carrying BOTH sticky flags plus one RUNNING and one queued run
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runID: env.firstRunID, now: Date(timeIntervalSince1970: 10))
    )
    let queued = try env.sessions.claimAndPersistInbound(
      inbound(updateID: 2, sessionKey: env.sessionKey, text: "queued")
    )
    let queuedRunID = try #require(queued.runID)
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET tainted = 1, has_private_data = 1 WHERE id = ?",
        arguments: [env.sessionID]
      )
    }
    let now = Date(timeIntervalSince1970: 200)

    // when
    let result = try env.commands.applyNew(updateID: 200, sessionKey: env.sessionKey, now: now)

    // then — supersede AND both-flag detaint are observed jointly after the single /new commit
    #expect(result.supersededRunIDs == [env.firstRunID, queuedRunID])
    let states = try runStates(env.queue)
    #expect(states[env.firstRunID] == RunState.superseded.rawValue)
    #expect(states[queuedRunID] == RunState.superseded.rawValue)
    let flags = try sessionFlags(env.queue, sessionID: env.sessionID)
    #expect(flags.tainted == false)
    #expect(flags.hasPrivateData == false)
  }

  @Test
  func newSupersedeAndDetaintCommitTogether() throws {
    // given — active runs and both sticky flags set, with a store that throws AFTER the in-txn
    // supersede+detaint so we can observe whether they persist independently of a later failure
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runID: env.firstRunID, now: Date(timeIntervalSince1970: 10))
    )
    let queued = try env.sessions.claimAndPersistInbound(
      inbound(updateID: 2, sessionKey: env.sessionKey, text: "queued")
    )
    let queuedRunID = try #require(queued.runID)
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET tainted = 1, has_private_data = 1 WHERE id = ?",
        arguments: [env.sessionID]
      )
    }
    let statesBefore = try runStates(env.queue)
    let crashingStore = CommandStoreGRDB(
      writer: env.queue,
      afterSupersedeAndDetaintForTesting: {
        throw InjectedCrash()
      }
    )
    let now = Date(timeIntervalSince1970: 500)

    // when — the post-detaint throw surfaces classified at the seam, never as its raw type
    #expect(throws: StoreError.self) {
      try crashingStore.applyNew(updateID: 500, sessionKey: env.sessionKey, now: now)
    }

    // then — the whole transaction rolls back: supersede and detaint commit together or not at all,
    // so a future split into two transactions (leaving supersede persisted) would break this
    #expect(try processedCount(env.queue, updateID: 500) == 0)
    let statesAfter = try runStates(env.queue)
    #expect(statesAfter == statesBefore)
    #expect(statesAfter[env.firstRunID] != RunState.superseded.rawValue)
    #expect(statesAfter[queuedRunID] != RunState.superseded.rawValue)
    let flags = try sessionFlags(env.queue, sessionID: env.sessionID)
    #expect(flags.tainted == true)
    #expect(flags.hasPrivateData == true)
  }

  @Test
  func duplicateCommandDoesNotRepeatEffects() throws {
    // given
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runID: env.firstRunID, now: Date(timeIntervalSince1970: 10))
    )
    let now = Date(timeIntervalSince1970: 300)
    let first = try env.commands.applyStop(updateID: 300, sessionKey: env.sessionKey, now: now)

    // when
    let duplicate = try env.commands.applyStop(updateID: 300, sessionKey: env.sessionKey, now: now)

    // then
    #expect(first.cancelledRunIDs == [env.firstRunID])
    #expect(
      duplicate == StopCommandResult(newlyClaimed: false, sessionID: nil, cancelledRunIDs: [])
    )
    #expect(try processedCount(env.queue, updateID: 300) == 1)
    #expect(try auditRows(env.queue).count == 1)
    let states = try runStates(env.queue)
    #expect(states[env.firstRunID] == RunState.cancelled.rawValue)
  }

  @Test
  func groupCommandsAttributeTheirAuditsToAGroupMember() throws {
    // given
    let queue = try TestDatabase.make()
    let commands = CommandStoreGRDB(writer: queue)
    let sessionKey = SessionKey.telegramTopic(chatID: -1_001, threadID: 77)

    // when
    _ = try commands.applyStop(updateID: 1, sessionKey: sessionKey, now: Date())
    _ = try commands.applyNew(updateID: 2, sessionKey: sessionKey, now: Date())

    // then
    let actors = try auditRows(queue).map { row in
      row["actor"] as String
    }
    #expect(actors == [AuditActor.groupMember.rawValue, AuditActor.groupMember.rawValue])
  }

  @Test
  func crashAfterClaimRollsBackClaimAndAllowsRetry() throws {
    // given
    let env = try fixture()
    _ = try #require(
      try env.runs.pickUp(runID: env.firstRunID, now: Date(timeIntervalSince1970: 10))
    )
    let crashingStore = CommandStoreGRDB(
      writer: env.queue,
      afterClaimForTesting: {
        throw InjectedCrash()
      }
    )
    let now = Date(timeIntervalSince1970: 400)

    // when — the injected crash surfaces classified at the seam, never as its raw type
    #expect(throws: StoreError.self) {
      try crashingStore.applyStop(updateID: 400, sessionKey: env.sessionKey, now: now)
    }

    // then
    #expect(try processedCount(env.queue, updateID: 400) == 0)
    #expect(try runStates(env.queue)[env.firstRunID] == RunState.running.rawValue)

    let retry = try env.commands.applyStop(updateID: 400, sessionKey: env.sessionKey, now: now)
    #expect(retry.cancelledRunIDs == [env.firstRunID])
    #expect(try processedCount(env.queue, updateID: 400) == 1)
    #expect(try runStates(env.queue)[env.firstRunID] == RunState.cancelled.rawValue)
  }

  private func runStates(_ queue: DatabaseQueue) throws -> [Int64: String] {
    try queue.read { db in
      let rows = try Row.fetchAll(db, sql: "SELECT id, state FROM runs")
      return Dictionary(
        uniqueKeysWithValues: rows.map { row in
          (row["id"] as Int64, row["state"] as String)
        }
      )
    }
  }

  private func sessionFlags(
    _ queue: DatabaseQueue,
    sessionID: Int64
  ) throws -> (
    tainted: Bool,
    hasPrivateData: Bool
  ) {
    let row = try #require(
      try queue.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT tainted, has_private_data FROM sessions WHERE id = ?",
          arguments: [sessionID]
        )
      }
    )
    return (tainted: row["tainted"], hasPrivateData: row["has_private_data"])
  }

  private func processedCount(_ queue: DatabaseQueue, updateID: Int64) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM processed_updates WHERE update_id = ?",
        arguments: [updateID]
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
