import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

/// §4.5 SET leg: `has_private_data` is persisted on EVERY commit path — completed, degraded/failed,
/// and the cancelled-arbitration branch — in the same transaction as the state change, mirroring
/// sticky taint exactly.
@Suite
struct PrivateDataLifecycleTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB

    let sessionID: Int64
    let runID: Int64
  }

  private func fixture() throws -> Fixture {
    let queue = try TestDatabase.make()
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: 7),
        chatID: 7,
        userID: 7,
        text: "hi",
        isEdited: false,
        ts: Date(timeIntervalSince1970: 1_750_000_000)
      )
    )
    return Fixture(
      queue: queue,
      runs: RunStoreGRDB(writer: queue),
      sessionID: try #require(claim.sessionID),
      runID: try #require(claim.runID)
    )
  }

  private func usage(runID: Int64, sessionID: Int64) -> ProviderUsage {
    makeProviderUsage(
      runID: runID,
      sessionID: sessionID,
      completionTokens: 20,
      isEstimated: true,
      ts: Date(timeIntervalSince1970: 1_750_000_000)
    )
  }

  private func hasPrivateData(_ queue: DatabaseQueue, sessionID: Int64) throws -> Bool {
    try queue.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT has_private_data FROM sessions WHERE id = ?",
        arguments: [sessionID]
      ) ?? false
    }
  }

  @Test
  func completedTurnPersistsThePrivateDataFlag() throws {
    // given — a RUNNING run whose turn touched private data
    let fixture = try fixture()
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try fixture.runs.pickUp(runID: fixture.runID, policyVersion: "0123456789abcdef", now: now)

    // when
    let result = try fixture.runs.commitAssistantTurn(
      AssistantTurn(
        runID: fixture.runID,
        sessionID: fixture.sessionID,
        chatID: 7,
        content: "done",
        usage: usage(runID: fixture.runID, sessionID: fixture.sessionID),
        chunks: [],
        setTainted: false,
        setPrivateData: true
      ),
      now: now
    )

    // then
    #expect(result == .committed)
    #expect(try hasPrivateData(fixture.queue, sessionID: fixture.sessionID))
  }

  @Test
  func completedTurnLeavesTheFlagOffWhenNoPrivateData() throws {
    // given
    let fixture = try fixture()
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try fixture.runs.pickUp(runID: fixture.runID, policyVersion: "0123456789abcdef", now: now)

    // when
    _ = try fixture.runs.commitAssistantTurn(
      AssistantTurn(
        runID: fixture.runID,
        sessionID: fixture.sessionID,
        chatID: 7,
        content: "done",
        usage: usage(runID: fixture.runID, sessionID: fixture.sessionID),
        chunks: [],
        setPrivateData: false
      ),
      now: now
    )

    // then — the flag never arms itself
    #expect(try hasPrivateData(fixture.queue, sessionID: fixture.sessionID) == false)
  }

  @Test
  func degradedFailedTurnPersistsThePrivateDataFlag() throws {
    // given — the failure path must persist the flag too (taint parity §4.5)
    let fixture = try fixture()
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try fixture.runs.pickUp(runID: fixture.runID, policyVersion: "0123456789abcdef", now: now)

    // when
    let result = try fixture.runs.commitDegradedTurn(
      DegradedTurn(
        runID: fixture.runID,
        sessionID: fixture.sessionID,
        chatID: 7,
        usage: nil,
        chunk: OutboxChunk(stepIndex: 0, chatID: 7, payload: "degraded", payloadHash: "h"),
        setTainted: false,
        setPrivateData: true,
        cause: .providerFailure
      ),
      now: now
    )

    // then — run FAILED, flag still set
    #expect(result == .committed)
    #expect(try hasPrivateData(fixture.queue, sessionID: fixture.sessionID))
  }

  @Test
  func commitLosingToCancellationStillPersistsThePrivateDataFlag() throws {
    // given — a run cancelled out from under a completing turn: the flag rides the cancelled
    // arbitration branch exactly like taint (RunStoreGRDB L70/L149)
    let fixture = try fixture()
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try fixture.runs.pickUp(runID: fixture.runID, policyVersion: "0123456789abcdef", now: now)
    _ = try CommandStoreGRDB(writer: fixture.queue).applyStop(
      updateID: 100,
      sessionKey: SessionKey.telegramDM(chatID: 7),
      now: now
    )

    // when — the model reply lands after /stop already cancelled the run
    let result = try fixture.runs.commitAssistantTurn(
      AssistantTurn(
        runID: fixture.runID,
        sessionID: fixture.sessionID,
        chatID: 7,
        content: "late",
        usage: usage(runID: fixture.runID, sessionID: fixture.sessionID),
        chunks: [],
        setPrivateData: true
      ),
      now: now
    )

    // then — the commit is not .committed (lost arbitration) but the sticky flag still persists
    #expect(result != .committed)
    #expect(try hasPrivateData(fixture.queue, sessionID: fixture.sessionID))
  }
}
