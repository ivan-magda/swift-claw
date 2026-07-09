import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ResolveDeniedObservationTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let sessionId: Int64
    let runId: Int64
    let observationMessageId: Int64
  }

  /// A run suspended to AWAITING_APPROVAL through the real reducer, with the assistant anchor and
  /// its placeholder tool observation persisted exactly as `commitSuspendedTurn` (Task 14) leaves
  /// them: adjacent rows, the observation carrying the pending `tool_call_id` and the sentinel
  /// "awaiting owner approval" content.
  private func makeSuspendedFixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 7),
        chatId: 7,
        userId: 7,
        text: "write the plan",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    let runs = RunStoreGRDB(writer: queue)
    _ = try #require(try runs.pickUp(runId: runId, now: Date()))

    let observationMessageId = try queue.write { db -> Int64 in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_calls)
          VALUES (?, ?, 'assistant', 'I will write the plan.', 'trusted', ?, '[{"id":"c1"}]')
          """,
        arguments: [sessionId, runId, Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', 'awaiting owner approval', 'untrusted', ?, 'c1')
          """,
        arguments: [sessionId, runId, Date()]
      )
      let placeholderId = db.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(
        db,
        runId: runId,
        event: .suspendForApproval,
        now: Date()
      )
      return placeholderId
    }

    return Fixture(
      queue: queue,
      runs: runs,
      sessionId: sessionId,
      runId: runId,
      observationMessageId: observationMessageId
    )
  }

  private func runState(_ queue: DatabaseQueue, runId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
    }
  }

  private func observationContent(_ queue: DatabaseQueue, id: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT content FROM messages WHERE id = ?", arguments: [id])
    }
  }

  @Test func rejectFillsThePlaceholderAndFailsTheRun() throws {
    // given
    let env = try makeSuspendedFixture()

    // when — the owner-deny path: cancel is nil → resolveDenied → FAILED
    let result = try env.runs.resolveDeniedObservation(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      content: "The owner declined this action.",
      cancel: nil,
      now: Date()
    )

    // then — the placeholder is filled in place (no dangling tool_call) and the run is FAILED
    #expect(result == .committed)
    #expect(try runState(env.queue, runId: env.runId) == RunState.failed.rawValue)
    #expect(
      try observationContent(env.queue, id: env.observationMessageId)
        == "The owner declined this action."
    )
  }

  @Test func nextTurnAssemblyStaysWellFormedAfterDeny() throws {
    // given
    let env = try makeSuspendedFixture()

    // when
    _ = try env.runs.resolveDeniedObservation(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
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
        arguments: [env.runId]
      )
    }
    #expect(rows.count == 2)
    #expect((rows[0]["role"] as String) == "assistant")
    #expect((rows[1]["role"] as String) == "tool")
    #expect((rows[1]["tool_call_id"] as String?) == "c1")
    #expect((rows[1]["content"] as String) != "awaiting owner approval")
  }

  @Test func cancelFixesTheObservationOnAnAlreadyTerminatedRun() throws {
    // given — /stop has already moved the run to CANCELLED in its command transaction; the waiter
    // now fixes the observation the command left as a placeholder
    let env = try makeSuspendedFixture()
    _ = try env.runs.cancelActiveRun(sessionId: env.sessionId, reason: .cancelled, now: Date())
    #expect(try runState(env.queue, runId: env.runId) == RunState.cancelled.rawValue)

    // when — cancel is non-nil; the FSM refuses the already-terminal run, but the observation
    // still gets its synthetic content
    let result = try env.runs.resolveDeniedObservation(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      content: "Cancelled by /stop.",
      cancel: .cancelled,
      now: Date()
    )

    // then — the run stays CANCELLED (no illegal re-transition) and history is well-formed
    #expect(result == .ignored)
    #expect(try runState(env.queue, runId: env.runId) == RunState.cancelled.rawValue)
    #expect(
      try observationContent(env.queue, id: env.observationMessageId) == "Cancelled by /stop."
    )
  }
}
