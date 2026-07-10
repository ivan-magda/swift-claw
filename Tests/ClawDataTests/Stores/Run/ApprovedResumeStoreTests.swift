import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ApprovedResumeStoreTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let sessionId: Int64
    let runId: Int64
    let observationMessageId: Int64
  }

  private static let placeholder = "awaiting owner approval"

  /// A run suspended to AWAITING_APPROVAL through the real reducer, with an assistant anchor and a
  /// placeholder observation row persisted (the shape Task 14's `commitSuspendedTurn` leaves).
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
        text: "remember the plan",
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
          VALUES (?, ?, 'assistant', '', 'trusted', ?, '[{"id":"c1","name":"file_write","arguments":"{}"}]')
          """,
        arguments: [sessionId, runId, Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', ?, 'untrusted', ?, 'c1')
          """,
        arguments: [sessionId, runId, Self.placeholder, Date()]
      )
      let messageId = db.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(db, runId: runId, event: .suspendForApproval, now: Date())
      return messageId
    }

    return Fixture(
      queue: queue,
      runs: runs,
      sessionId: sessionId,
      runId: runId,
      observationMessageId: observationMessageId
    )
  }

  private func runState(_ queue: DatabaseQueue, _ runId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
    }
  }

  private func messageContent(_ queue: DatabaseQueue, _ messageId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [messageId]
      )
    }
  }

  @Test func completeApprovedObservationFillsInPlaceAndResumesTheRun() throws {
    // given
    let env = try makeSuspendedFixture()

    // when
    let result = try env.runs.completeApprovedObservation(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      content: "Wrote 12 B to /w/plan.md (created).",
      now: Date()
    )

    // then — the placeholder is updated in place (same row id) and the run is RUNNING again
    #expect(result == .committed)
    #expect(
      try messageContent(env.queue, env.observationMessageId)
        == "Wrote 12 B to /w/plan.md (created)."
    )
    #expect(try runState(env.queue, env.runId) == RunState.running.rawValue)
  }

  @Test func completeApprovedObservationIsExactlyOnce() throws {
    // given — a first resume already flipped the run to RUNNING
    let env = try makeSuspendedFixture()
    _ = try env.runs.completeApprovedObservation(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      content: "first",
      now: Date()
    )

    // when — a duplicate signal re-runs the same method
    let second = try env.runs.completeApprovedObservation(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      content: "second",
      now: Date()
    )

    // then — the run is no longer AWAITING, so the reducer no-ops and the content is unchanged
    #expect(second == .ignored)
    #expect(try messageContent(env.queue, env.observationMessageId) == "first")
  }

  @Test func applyApprovedMemoryWriteFusesTheInsertWithTheObservationFill() throws {
    // given
    let env = try makeSuspendedFixture()
    let item = NewMemoryItem(text: "the plan is ready", kind: .project, sessionId: env.sessionId)

    // when
    let result = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved to memory as project.",
      now: Date()
    )

    // then — one fused transaction: memory row inserted, observation filled, run RUNNING
    #expect(result == .committed)
    let memoryCount = try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items")
    }
    #expect(memoryCount == 1)
    #expect(
      try messageContent(env.queue, env.observationMessageId) == "Saved to memory as project."
    )
    #expect(try runState(env.queue, env.runId) == RunState.running.rawValue)
  }

  @Test func applyApprovedMemoryWriteIsExactlyOnce() throws {
    // given — the fused write already committed once
    let env = try makeSuspendedFixture()
    let item = NewMemoryItem(text: "remember me once", kind: .user, sessionId: env.sessionId)
    _ = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved.",
      now: Date()
    )

    // when — re-running the fused method after the observation is filled
    let second = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved again.",
      now: Date()
    )

    // then — the guard on the AWAITING→RUNNING flip means NO second memory row (§6.3 exactly-once)
    #expect(second == .ignored)
    let memoryCount = try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items")
    }
    #expect(memoryCount == 1)
  }

  /// Re-suspends the fixture's run on a SECOND placeholder (the multi-suspend shape: approve #1,
  /// resume, propose another gated call) and returns the new placeholder's message id.
  private func suspendAgain(_ env: Fixture) throws -> Int64 {
    try env.queue.write { db -> Int64 in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', ?, 'untrusted', ?, 'c2')
          """,
        arguments: [env.sessionId, env.runId, Self.placeholder, Date()]
      )
      let messageId = db.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(
        db,
        runId: env.runId,
        event: .suspendForApproval,
        now: Date()
      )
      return messageId
    }
  }

  @Test func replayAfterASecondSuspendIsIgnoredAndLeavesTheRunParked() throws {
    // given — approval #1 fully resumed, then the run suspends again on approval #2: the run is
    // AWAITING_APPROVAL once more, so the AWAITING→RUNNING flip alone would let a boot replay of
    // #1 commit and steal #2's park
    let env = try makeSuspendedFixture()
    _ = try env.runs.completeApprovedObservation(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      content: "first",
      now: Date()
    )
    let secondPlaceholderId = try suspendAgain(env)

    // when — a boot replay re-runs approval #1's commit against its already-filled observation
    let replay = try env.runs.completeApprovedObservation(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      content: "replayed",
      now: Date()
    )

    // then — ignored: run STILL parked for #2, #1's observation untouched, #2's placeholder intact
    #expect(replay == .ignored)
    #expect(try runState(env.queue, env.runId) == RunState.awaitingApproval.rawValue)
    #expect(try messageContent(env.queue, env.observationMessageId) == "first")
    #expect(try messageContent(env.queue, secondPlaceholderId) == Self.placeholder)
  }

  @Test func memoryWriteReplayAfterASecondSuspendIsIgnoredAndLeavesTheRunParked() throws {
    // given — the fused memory write committed once, then the run suspends again
    let env = try makeSuspendedFixture()
    let item = NewMemoryItem(text: "the plan is ready", kind: .project, sessionId: env.sessionId)
    _ = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved.",
      now: Date()
    )
    _ = try suspendAgain(env)

    // when — a boot replay re-runs the fused write for the resolved approval
    let replay = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved again.",
      now: Date()
    )

    // then — ignored: no second memory row, run still parked for the new approval
    #expect(replay == .ignored)
    #expect(try runState(env.queue, env.runId) == RunState.awaitingApproval.rawValue)
    let memoryCount = try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items")
    }
    #expect(memoryCount == 1)
  }

  @Test func resumeUsageDerivesCountersFromPersistedRows() throws {
    // given — the fixture already has one assistant row and one tool row; add usage + a second
    // assistant/tool pair so the counts and sums are unambiguous (D4)
    let env = try makeSuspendedFixture()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_calls)
          VALUES (?, ?, 'assistant', '', 'trusted', ?, '[]')
          """,
        arguments: [env.sessionId, env.runId, Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', 'obs', 'untrusted', ?, 'c2')
          """,
        arguments: [env.sessionId, env.runId, Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
            cost_usd, cost_source, is_estimated, ts)
          VALUES (?, ?, 'm', 100, 20, 0.03, 'price_file', 0, ?)
          """,
        arguments: [env.runId, env.sessionId, Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
            cost_usd, cost_source, is_estimated, ts)
          VALUES (?, ?, 'm', 50, 10, 0.01, 'price_file', 0, ?)
          """,
        arguments: [env.runId, env.sessionId, Date()]
      )
    }

    // when
    let usage = try env.runs.resumeUsage(runId: env.runId)

    // then — 2 assistant rounds, 2 tool calls, 180 tokens, $0.04
    #expect(usage.rounds == 2)
    #expect(usage.toolCalls == 2)
    #expect(usage.tokens == 180)
    #expect(usage.costUSD == 0.04)
  }

  @Test func runOriginReadsTheRunsColumn() throws {
    // given
    let env = try makeSuspendedFixture()

    // when / then — resume reads origin without re-picking-up the run
    #expect(try env.runs.runOrigin(runId: env.runId) == .interactive)
    #expect(try env.runs.runOrigin(runId: 9999) == nil)
  }

  @Test func failRunStalePolicyFailsTheRunAndAuditsTheDenial() throws {
    // given
    let env = try makeSuspendedFixture()

    // when
    let failed = try env.runs.failRunStalePolicy(
      runId: env.runId,
      sessionId: env.sessionId,
      now: Date()
    )

    // then — run FAILED, and an approvalDenied/stale_policy audit rode the same transaction (§6.5)
    #expect(failed)
    #expect(try runState(env.queue, env.runId) == RunState.failed.rawValue)
    let auditDecision = try env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT decision FROM audit_events WHERE action = ? AND run_id = ?",
        arguments: [AuditAction.approvalDenied.rawValue, env.runId]
      )
    }
    #expect(auditDecision == ApprovalDecision.stalePolicy.rawValue)
  }
}
