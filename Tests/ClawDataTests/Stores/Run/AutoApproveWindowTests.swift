import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct AutoApproveWindowTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let sessionId: Int64
    let runIds: [Int64]
  }

  private static let now = Date(timeIntervalSince1970: 1_700_000_000)

  /// Two runs in one session, so "scoped to one run" is observable rather than asserted.
  private func fixture(runCount: Int = 2) throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    var sessionId: Int64?
    var runIds: [Int64] = []
    for index in 0..<runCount {
      let claim = try sessions.claimAndPersistInbound(
        InboundMessage(
          updateId: Int64(index + 1),
          sessionKey: SessionKey.telegramDM(chatId: 42),
          chatId: 42,
          userId: 42,
          text: "run \(index)",
          isEdited: false,
          ts: Self.now
        )
      )
      sessionId = claim.sessionId
      runIds.append(try #require(claim.runId))
    }
    return Fixture(
      queue: queue,
      runs: RunStoreGRDB(writer: queue),
      sessionId: try #require(sessionId),
      runIds: runIds
    )
  }

  @Test func openingTheWindowRoundTripsAndLeavesOtherRunsClosed() throws {
    // given
    let env = try fixture()

    // when
    let opened = try env.runs.openAutoApproveWindow(runId: env.runIds[0], now: Self.now)

    // then — the flag belongs to the run it was opened on, not the session
    #expect(opened)
    #expect(try env.runs.isAutoApproveWindowOpen(runId: env.runIds[0]))
    #expect(try env.runs.isAutoApproveWindowOpen(runId: env.runIds[1]) == false)
  }

  @Test func reopeningAnOpenWindowIsIdempotent() throws {
    // given
    let env = try fixture(runCount: 1)
    _ = try env.runs.openAutoApproveWindow(runId: env.runIds[0], now: Self.now)

    // when — the owner taps the turn-scoped button on a second prompt in the same turn
    let reopened = try env.runs.openAutoApproveWindow(runId: env.runIds[0], now: Self.now)

    // then
    #expect(reopened)
    #expect(try env.runs.isAutoApproveWindowOpen(runId: env.runIds[0]))
  }

  @Test func aTerminatedRunReadsClosedAndRefusesToReopen() throws {
    // given — an open window on the turn the session is running
    let env = try fixture(runCount: 1)
    let runId = env.runIds[0]
    _ = try env.runs.pickUp(runId: runId, now: Self.now)
    _ = try env.runs.openAutoApproveWindow(runId: runId, now: Self.now)

    // when — `/stop` ends the turn
    let cancelled = try env.runs.cancelActiveRun(
      sessionId: env.sessionId,
      reason: .cancelled,
      now: Self.now
    )

    // then — the window cannot outlive the turn, nor be reopened on the finished run
    #expect(cancelled == runId)
    #expect(try env.runs.isAutoApproveWindowOpen(runId: runId) == false)
    #expect(try env.runs.openAutoApproveWindow(runId: runId, now: Self.now) == false)
  }

  @Test func anUnknownRunReadsClosed() throws {
    // given
    let env = try fixture(runCount: 1)

    // when / then
    #expect(try env.runs.isAutoApproveWindowOpen(runId: 9_999) == false)
    #expect(try env.runs.openAutoApproveWindow(runId: 9_999, now: Self.now) == false)
  }
}
