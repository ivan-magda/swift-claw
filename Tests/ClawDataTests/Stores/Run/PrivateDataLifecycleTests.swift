import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

/// §4.5 SET leg: `has_private_data` is persisted on EVERY commit path — completed, degraded/failed,
/// and the cancelled-arbitration branch — in the same transaction as the state change, mirroring
/// sticky taint exactly.
@Suite struct PrivateDataLifecycleTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let sessions: SessionMessageStoreGRDB
    let runs: RunStoreGRDB

    let sessionId: Int64
    let runId: Int64
  }

  private func fixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 7),
        chatId: 7,
        userId: 7,
        text: "hi",
        isEdited: false,
        ts: Date(timeIntervalSince1970: 1_750_000_000)
      )
    )
    return Fixture(
      queue: queue,
      sessions: sessions,
      runs: RunStoreGRDB(writer: queue),
      sessionId: try #require(claim.sessionId),
      runId: try #require(claim.runId)
    )
  }

  private func usage(runId: Int64, sessionId: Int64) -> ProviderUsage {
    ProviderUsage(
      runId: runId,
      sessionId: sessionId,
      model: "m",
      promptTokens: 10,
      completionTokens: 20,
      costUSD: 0.001,
      costSource: .heuristic,
      isEstimated: true,
      ts: Date(timeIntervalSince1970: 1_750_000_000)
    )
  }

  private func hasPrivateData(_ queue: DatabaseQueue, sessionId: Int64) throws -> Bool {
    try queue.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT has_private_data FROM sessions WHERE id = ?",
        arguments: [sessionId]
      ) ?? false
    }
  }

  @Test func completedTurnPersistsThePrivateDataFlag() throws {
    // given — a RUNNING run whose turn touched private data
    let fixture = try fixture()
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try fixture.runs.pickUp(runId: fixture.runId, policyVersion: "0123456789abcdef", now: now)

    // when
    let result = try fixture.runs.commitAssistantTurn(
      AssistantTurn(
        runId: fixture.runId,
        sessionId: fixture.sessionId,
        chatId: 7,
        content: "done",
        usage: usage(runId: fixture.runId, sessionId: fixture.sessionId),
        chunks: [],
        setTainted: false,
        setPrivateData: true
      ),
      now: now
    )

    // then
    #expect(result == .committed)
    #expect(try hasPrivateData(fixture.queue, sessionId: fixture.sessionId))
  }

  @Test func completedTurnLeavesTheFlagOffWhenNoPrivateData() throws {
    // given
    let fixture = try fixture()
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try fixture.runs.pickUp(runId: fixture.runId, policyVersion: "0123456789abcdef", now: now)

    // when
    _ = try fixture.runs.commitAssistantTurn(
      AssistantTurn(
        runId: fixture.runId,
        sessionId: fixture.sessionId,
        chatId: 7,
        content: "done",
        usage: usage(runId: fixture.runId, sessionId: fixture.sessionId),
        chunks: [],
        setPrivateData: false
      ),
      now: now
    )

    // then — the flag never arms itself
    #expect(try hasPrivateData(fixture.queue, sessionId: fixture.sessionId) == false)
  }

  @Test func degradedFailedTurnPersistsThePrivateDataFlag() throws {
    // given — the failure path must persist the flag too (taint parity §4.5)
    let fixture = try fixture()
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try fixture.runs.pickUp(runId: fixture.runId, policyVersion: "0123456789abcdef", now: now)

    // when
    let result = try fixture.runs.commitDegradedTurn(
      DegradedTurn(
        runId: fixture.runId,
        sessionId: fixture.sessionId,
        chatId: 7,
        usage: nil,
        chunk: OutboxChunk(stepIndex: 0, chatId: 7, payload: "degraded", payloadHash: "h"),
        setTainted: false,
        setPrivateData: true
      ),
      now: now
    )

    // then — run FAILED, flag still set
    #expect(result == .committed)
    #expect(try hasPrivateData(fixture.queue, sessionId: fixture.sessionId))
  }

  @Test func commitLosingToCancellationStillPersistsThePrivateDataFlag() throws {
    // given — a run cancelled out from under a completing turn: the flag rides the cancelled
    // arbitration branch exactly like taint (RunStoreGRDB L70/L149)
    let fixture = try fixture()
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try fixture.runs.pickUp(runId: fixture.runId, policyVersion: "0123456789abcdef", now: now)
    _ = try fixture.runs.cancelActiveRun(sessionId: fixture.sessionId, reason: .cancelled, now: now)

    // when — the model reply lands after /stop already cancelled the run
    let result = try fixture.runs.commitAssistantTurn(
      AssistantTurn(
        runId: fixture.runId,
        sessionId: fixture.sessionId,
        chatId: 7,
        content: "late",
        usage: usage(runId: fixture.runId, sessionId: fixture.sessionId),
        chunks: [],
        setPrivateData: true
      ),
      now: now
    )

    // then — the commit is not .committed (lost arbitration) but the sticky flag still persists
    #expect(result != .committed)
    #expect(try hasPrivateData(fixture.queue, sessionId: fixture.sessionId))
  }
}
