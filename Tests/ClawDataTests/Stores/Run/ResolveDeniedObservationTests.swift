import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct ResolveDeniedObservationTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB

    let sessionID: Int64
    let runID: Int64
    let observationMessageID: Int64
  }

  /// A run suspended to AWAITING_APPROVAL through the real reducer, with the assistant anchor and
  /// its placeholder tool observation persisted exactly as `commitSuspendedTurn` (Task 14) leaves
  /// them: adjacent rows, the observation carrying the pending `tool_call_id` and the sentinel
  /// "awaiting owner approval" content.
  private func makeSuspendedFixture() throws -> Fixture {
    let queue = try TestDatabase.make()
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: 7),
        chatID: 7,
        userID: 7,
        text: "write the plan",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionID = try #require(claim.sessionID)
    let runID = try #require(claim.runID)
    let runs = RunStoreGRDB(writer: queue)
    _ = try #require(try runs.pickUp(runID: runID, now: Date()))

    let observationMessageID = try queue.write { db -> Int64 in
      try db.execute(
        sql: """
        INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_calls)
        VALUES (?, ?, 'assistant', 'I will write the plan.', 'trusted', ?, '[{"id":"c1"}]')
        """,
        arguments: [sessionID, runID, Date()]
      )
      try db.execute(
        sql: """
        INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
        VALUES (?, ?, 'tool', 'awaiting owner approval', 'untrusted', ?, 'c1')
        """,
        arguments: [sessionID, runID, Date()]
      )
      let placeholderID = db.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(
        db,
        runID: runID,
        event: .suspendForApproval,
        now: Date(),
        terminal: nil
      )
      return placeholderID
    }

    return Fixture(
      queue: queue,
      runs: runs,
      sessionID: sessionID,
      runID: runID,
      observationMessageID: observationMessageID
    )
  }

  private func runState(_ queue: DatabaseQueue, runID: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runID])
    }
  }

  private func observationContent(_ queue: DatabaseQueue, id: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT content FROM messages WHERE id = ?", arguments: [id])
    }
  }

  @Test
  func rejectFillsThePlaceholderAndFailsTheRun() throws {
    // given
    let env = try makeSuspendedFixture()

    // when — the owner-deny path: cancel is nil → resolveDenied → FAILED
    let result = try env.runs.resolveDeniedObservation(
      runID: env.runID,
      observationMessageID: env.observationMessageID,
      content: "The owner declined this action.",
      cancel: nil,
      now: Date()
    )

    // then — the placeholder is filled in place (no dangling tool_call) and the run is FAILED
    #expect(result == .committed)
    #expect(try runState(env.queue, runID: env.runID) == RunState.failed.rawValue)
    #expect(
      try observationContent(env.queue, id: env.observationMessageID)
        == "The owner declined this action."
    )
  }

  @Test
  func nextTurnAssemblyStaysWellFormedAfterDeny() throws {
    // given
    let env = try makeSuspendedFixture()

    // when
    _ = try env.runs.resolveDeniedObservation(
      runID: env.runID,
      observationMessageID: env.observationMessageID,
      content: "The approval expired before the owner responded.",
      cancel: nil,
      now: Date()
    )

    // then — the anchor and its observation are contiguous and every tool_call_id is answered
    // (the placeholder no longer reads "awaiting owner approval"): no orphan proposal row survives
    let rows = try env.queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
        SELECT role, content, tool_call_id FROM messages
        WHERE run_id = ? AND role IN ('assistant', 'tool')
        ORDER BY id ASC
        """,
        arguments: [env.runID]
      )
    }
    #expect(rows.count == 2)
    #expect((rows[0]["role"] as String) == "assistant")
    #expect((rows[1]["role"] as String) == "tool")
    #expect((rows[1]["tool_call_id"] as String?) == "c1")
    #expect((rows[1]["content"] as String) != "awaiting owner approval")
  }

  @Test
  func cancelFixesTheObservationOnAnAlreadyTerminatedRun() throws {
    // given — /stop has already moved the run to CANCELLED in its command transaction; the waiter
    // now fixes the observation the command left as a placeholder
    let env = try makeSuspendedFixture()
    _ = try CommandStoreGRDB(writer: env.queue).applyStop(
      updateID: 100,
      sessionKey: SessionKey.telegramDM(chatID: 7),
      now: Date()
    )
    #expect(try runState(env.queue, runID: env.runID) == RunState.cancelled.rawValue)

    // when — cancel is non-nil; the FSM refuses the already-terminal run, but the observation
    // still gets its synthetic content
    let result = try env.runs.resolveDeniedObservation(
      runID: env.runID,
      observationMessageID: env.observationMessageID,
      content: "Cancelled by /stop.",
      cancel: .cancelled,
      now: Date()
    )

    // then — the run stays CANCELLED (no illegal re-transition) and history is well-formed
    #expect(result == .ignored)
    #expect(try runState(env.queue, runID: env.runID) == RunState.cancelled.rawValue)
    #expect(
      try observationContent(env.queue, id: env.observationMessageID) == "Cancelled by /stop."
    )
  }
}
