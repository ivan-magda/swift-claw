import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct AwaitingApprovalSeamTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB

    let sessionId: Int64
    let runId: Int64
  }

  /// One run suspended to AWAITING_APPROVAL through the real reducer (pickUp → suspend).
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
    try queue.write { db in
      _ = try RunStoreGRDB.transitionRun(db, runId: runId, event: .suspendForApproval, now: Date())
    }
    return Fixture(
      queue: queue,
      runs: runs,
      sessionId: sessionId,
      runId: runId
    )
  }

  private func runState(_ queue: DatabaseQueue, runId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
    }
  }

  @Test func stopCancelsASuspendedRun() throws {
    // given
    let env = try makeSuspendedFixture()

    // when — /stop's single-run path (cancelActiveRun → fetchActiveRunId)
    let cancelled = try env.runs.cancelActiveRun(
      sessionId: env.sessionId,
      reason: .cancelled,
      now: Date()
    )

    // then — without the widened predicate, /stop silently skips the suspended run (§4.2)
    #expect(cancelled == env.runId)
    #expect(try runState(env.queue, runId: env.runId) == RunState.cancelled.rawValue)
  }

  @Test func newSupersedesASuspendedRun() throws {
    // given
    let env = try makeSuspendedFixture()

    // when — /new's plural path (supersedeSessionRuns → terminateActiveRuns)
    let superseded = try env.runs.supersedeSessionRuns(sessionId: env.sessionId, now: Date())

    // then
    #expect(superseded == [env.runId])
    #expect(try runState(env.queue, runId: env.runId) == RunState.superseded.rawValue)
  }

  @Test func runsHealthCountsASuspendedRunAsInFlight() throws {
    // given
    let env = try makeSuspendedFixture()

    // when
    let health = try env.runs.runsHealth(now: Date())

    // then — a parked lane is live capacity; doctor must see it (spec §4.2)
    #expect(health.inFlight == 1)
    #expect(health.oldestRunAgeSeconds != nil)
  }

  @Test func assistantCommitOnASuspendedRunLosesArbitration() throws {
    // given
    let env = try makeSuspendedFixture()
    let turn = AssistantTurn(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      content: "late reply",
      usage: ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-late"),
        runId: env.runId,
        sessionId: env.sessionId,
        model: "m",
        promptTokens: 1,
        completionTokens: 1,
        costUSD: 0,
        costSource: .heuristic,
        isEstimated: true,
        ts: Date()
      ),
      chunks: []
    )

    // when
    let result = try env.runs.commitAssistantTurn(turn, now: Date())

    // then — same as terminal states: the suspended run owns no commit (spec §4.2); no
    // assistant row lands and the state is untouched
    #expect(result == .ignored)
    #expect(try runState(env.queue, runId: env.runId) == RunState.awaitingApproval.rawValue)
    let assistantRows = try env.queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND role = 'assistant'",
        arguments: [env.runId]
      )
    }
    #expect(assistantRows == 0)
  }

  @Test func degradedCommitOnASuspendedRunLosesArbitration() throws {
    // given
    let env = try makeSuspendedFixture()
    let turn = DegradedTurn(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: 7,
      usage: nil,
      chunk: OutboxChunk(stepIndex: 0, chatId: 7, payload: "degraded", payloadHash: "h")
    )

    // when
    let result = try env.runs.commitDegradedTurn(turn, now: Date())

    // then
    #expect(result == .ignored)
    #expect(try runState(env.queue, runId: env.runId) == RunState.awaitingApproval.rawValue)
  }
}
