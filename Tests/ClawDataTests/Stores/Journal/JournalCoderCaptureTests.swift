import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct JournalCoderCaptureTests {
  @Test(arguments: [false, true])
  func coderCompletionUsesSelectedResultAfterReset(admittedEnabled: Bool) throws {
    // given
    let fixture = try CoderStoreFixture()
    let scope = JournalScope(ownerUserID: fixture.origin.requesterUserID, timeZoneID: "UTC")
    let id = UUID()
    let admission = try fixture.store.admit(
      id: id,
      prepared: fixture.prepared,
      origin: fixture.origin,
      maxConcurrentJobs: 4,
      journalScope: admittedEnabled ? scope : nil,
      now: fixture.now
    )
    guard case .admitted(let job) = admission else {
      Issue.record("Fixture did not admit the job")
      return
    }
    #expect(job.journalScope == (admittedEnabled ? scope : nil))
    _ = try fixture.store.markRunning(id: id, now: fixture.now)
    _ = try CommandStoreGRDB(writer: fixture.queue).applyNew(
      updateID: 2,
      sessionKey: SessionKey.telegramDM(chatID: fixture.origin.chatID),
      journalScope: scope,
      now: fixture.now
    )
    _ = try fixture.store.requestCancellation(id: id, now: fixture.now)
    let completedAt = fixture.now.addingTimeInterval(60)
    let selected = CoderStoreFixture.result(state: .cancelled)
    let source = try JournalSource(
      id: "coder:\(id.uuidString)",
      scope: scope,
      sessionID: fixture.origin.sessionID,
      occurredAt: completedAt,
      day: JournalDay.containing(completedAt, timeZone: .gmt),
      ownerText: fixture.prepared.request.task ?? "",
      assistantText: selected.summary,
      coderJobID: id,
      evidence: [
        JournalEvidence(outcome: .coder(selected.state), jobID: id, name: "Coder terminal state"),
      ]
    )

    // when
    let stale = try fixture.store.complete(
      id: id,
      expectedState: .running,
      result: CoderStoreFixture.result(),
      chunks: [],
      releaseReservation: false,
      journalSource: source,
      now: completedAt
    )
    guard case .stateChanged = stale else {
      Issue.record("Cancellation did not win the compare-and-swap")
      return
    }
    let outcome = try fixture.store.complete(
      id: id,
      expectedState: .stopping,
      result: selected,
      chunks: [],
      releaseReservation: false,
      journalSource: source,
      now: completedAt
    )
    try fixture.store.releaseResolvedReservation(id: id, now: completedAt.addingTimeInterval(900))
    _ = try fixture.store.complete(
      id: id,
      expectedState: .stopping,
      result: selected,
      chunks: [],
      releaseReservation: true,
      journalSource: source,
      now: completedAt.addingTimeInterval(900)
    )

    // then
    #expect(outcome == .committed)
    let sources = try fixture.queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM journal_sources").map(JournalStoreGRDB.decodeSource)
    }
    #expect(sources.count == (admittedEnabled ? 1 : 0))
    if admittedEnabled {
      let captured = try #require(sources.first)
      #expect(captured.occurredAt == completedAt)
      #expect(captured.assistantText.contains(selected.summary))
      #expect(captured.evidence.first?.outcome == .coder(.cancelled))
    }
    let terminalAt = try fixture.queue.read { db in
      try Date.fetchOne(
        db,
        sql: "SELECT journal_terminal_ts FROM coder_jobs WHERE id = ?",
        arguments: [id.uuidString]
      )
    }
    #expect(terminalAt == completedAt)
  }
}
