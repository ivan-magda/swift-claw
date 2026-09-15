import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct AwaitingApprovalSeamTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB

    let sessionID: Int64
    let runID: Int64
  }

  /// One run suspended to AWAITING_APPROVAL through the real reducer (pickUp → suspend).
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
    try queue.write { db in
      _ = try RunStoreGRDB.transitionRun(
        db,
        runID: runID,
        event: .suspendForApproval,
        now: Date(),
        terminal: nil
      )
    }
    return Fixture(queue: queue, runs: runs, sessionID: sessionID, runID: runID)
  }

  private func runState(_ queue: DatabaseQueue, runID: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runID])
    }
  }

  @Test
  func runsHealthCountsASuspendedRunAsInFlight() throws {
    // given
    let env = try makeSuspendedFixture()

    // when
    let health = try env.runs.runsHealth(now: Date())

    // then — a parked lane is live capacity; doctor must see it (spec §4.2)
    #expect(health.inFlight == 1)
    #expect(health.oldestRunAgeSeconds != nil)
  }

  @Test
  func assistantCommitOnASuspendedRunLosesArbitration() throws {
    // given
    let env = try makeSuspendedFixture()
    let turn = AssistantTurn(
      runID: env.runID,
      sessionID: env.sessionID,
      chatID: 7,
      content: "late reply",
      usage: ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-late"),
        runID: env.runID,
        sessionID: env.sessionID,
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
    #expect(try runState(env.queue, runID: env.runID) == RunState.awaitingApproval.rawValue)
    let assistantRows = try env.queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND role = 'assistant'",
        arguments: [env.runID]
      )
    }
    #expect(assistantRows == 0)
  }

  @Test
  func degradedCommitOnASuspendedRunLosesArbitration() throws {
    // given
    let env = try makeSuspendedFixture()
    let turn = DegradedTurn(
      runID: env.runID,
      sessionID: env.sessionID,
      chatID: 7,
      usage: nil,
      chunk: OutboxChunk(stepIndex: 0, chatID: 7, payload: "degraded", payloadHash: "h"),
      cause: .providerFailure
    )

    // when
    let result = try env.runs.commitDegradedTurn(turn, now: Date())

    // then
    #expect(result == .ignored)
    #expect(try runState(env.queue, runID: env.runID) == RunState.awaitingApproval.rawValue)
  }
}
