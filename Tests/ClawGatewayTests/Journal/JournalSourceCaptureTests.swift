import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite
struct JournalSourceCaptureTests {
  @Test
  func captureRedactsBeforePersistableBounds() throws {
    // given
    let secret = "sensitive-boundary-secret"
    let text = String(repeating: "x", count: 1_325) + secret + String(repeating: "y", count: 9_000)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let scope = JournalScope(ownerUserID: 42, timeZoneID: "UTC")
    let input = JournalExchangeInput(
      admission: JournalExchangeAdmission(
        scope: scope,
        sourceTimestamp: now,
        sourceDay: JournalDay.containing(now, timeZone: .gmt)
      ),
      sessionID: 1,
      triggerMessageID: 2,
      ownerText: text,
      supportingProposal: JournalExchangeInput.Proposal(
        sourceID: "message:1",
        text: String(repeating: "x", count: 660) + secret + String(repeating: "y", count: 9_000)
      )
    )
    let capture = JournalSourceCapture(
      policy: JournalPolicy(enabled: true, ownerUserID: 42, timeZoneID: "UTC"),
      redact: SecretRedactor(secretValues: [secret]).redact
    )

    // when
    let outcome = try #require(capture.exchange(input: input, reply: text, evidence: []))
    guard case .source(let source) = outcome else {
      Issue.record("Expected a prepared source")
      return
    }
    let serialized = try #require(String(data: JSONEncoder().encode(source), encoding: .utf8))

    // then
    #expect(source.ownerText.count <= JournalLimits.ownerTextGraphemes)
    #expect(source.assistantText.count <= JournalLimits.assistantTextGraphemes)
    #expect(!serialized.contains(secret))
    #expect(!serialized.contains("sensi"))
    #expect(try #require(source.supportingProposal).text.count <= JournalLimits.proposalGraphemes)
    #expect(source.occurredAt == now)
    #expect(source.ownerText.hasSuffix(String(repeating: "y", count: 100)))
  }

  @Test(arguments: [false, true])
  func coderCompletionUsesSelectedResultAfterReset(completionEnabled: Bool) async throws {
    // given
    let fixture = try CoderServiceFixture()
    defer {
      fixture.cleanup()
    }
    let completedAt = Date(timeIntervalSince1970: 1_800_000_100)
    let capture = JournalSourceCapture(
      policy: JournalPolicy(enabled: completionEnabled, ownerUserID: 7, timeZoneID: "UTC"),
      redact: {
        $0
      }
    )
    let service = CoderServiceFixture.makeService(
      store: fixture.store,
      backend: fixture.backend,
      preparer: fixture.preparer,
      inspector: fixture.inspector,
      root: fixture.root,
      limit: 1,
      finished: fixture.jobFinished,
      redactor: {
        $0
      },
      journalCapture: capture,
      now: {
        completedAt
      }
    )
    let context = fixture.ownerContext
    let origin = CoderOrigin(
      runID: context.runID,
      sessionID: context.sessionID,
      requesterUserID: 7,
      chatID: 7,
      toolCallID: context.toolCallID,
      approvalID: try #require(context.approvalID)
    )
    let id = UUID()
    _ = try fixture.store.admit(
      id: id,
      prepared: fixture.prepared,
      origin: origin,
      maxConcurrentJobs: 1,
      journalScope: JournalScope(ownerUserID: 7, timeZoneID: "UTC"),
      now: completedAt
    )
    _ = try fixture.store.markRunning(id: id, now: completedAt)
    _ = try CommandStoreGRDB(writer: fixture.queue).applyNew(
      updateID: 2,
      sessionKey: SessionKey.telegramDM(chatID: 7),
      journalScope: JournalScope(ownerUserID: 7, timeZoneID: "UTC"),
      now: completedAt
    )
    _ = try fixture.store.requestCancellation(id: id, now: completedAt)

    // when
    try await service.complete(id: id, result: CoderServiceFixture.result(), recovering: false)
    try fixture.store.releaseResolvedReservation(id: id, now: completedAt.addingTimeInterval(900))

    // then
    let result = try #require(try fixture.store.job(id: id)?.result)
    #expect(result.state == .cancelled)
    let payloads = try await fixture.queue.read { db in
      try Data.fetchAll(db, sql: "SELECT payload FROM journal_sources")
    }
    #expect(payloads.count == (completionEnabled ? 1 : 0))
    if completionEnabled {
      let payload = try #require(payloads.first)
      let source = try JSONDecoder().decode(JournalSource.self, from: payload)
      #expect(source.occurredAt == completedAt)
      #expect(source.assistantText == result.summary)
      #expect(source.evidence.first?.outcome == .coder(.cancelled))
    }
  }

  @Test(arguments: [false, true])
  func oversizedPreparationRecordsDurableSkip(coder: Bool) async throws {
    // given
    let now = Date(timeIntervalSince1970: 1_800_000_100)
    let grapheme = "x" + String(repeating: "\u{0301}", count: 40)
    let reply = String(repeating: grapheme, count: JournalLimits.ownerTextGraphemes)
    #expect(reply.count <= JournalLimits.assistantTextGraphemes)
    #expect(reply.utf8.count > JournalLimits.storedSourceBytes)
    let queue: DatabaseQueue
    let ownerID: Int64
    var cleanup: (() -> Void)?
    defer {
      cleanup?()
    }

    // when
    if coder {
      let fixture = try CoderServiceFixture()
      queue = fixture.queue
      ownerID = 7
      cleanup = fixture.cleanup
      let capture = JournalSourceCapture(
        policy: JournalPolicy(enabled: true, ownerUserID: ownerID, timeZoneID: "UTC"),
        redact: {
          $0
        }
      )
      let service = CoderServiceFixture.makeService(
        store: fixture.store,
        backend: fixture.backend,
        preparer: fixture.preparer,
        inspector: fixture.inspector,
        root: fixture.root,
        limit: 1,
        finished: fixture.jobFinished,
        redactor: {
          $0
        },
        journalCapture: capture,
        now: {
          now
        }
      )
      let context = fixture.ownerContext
      let id = UUID()
      _ = try fixture.store.admit(
        id: id,
        prepared: fixture.prepared,
        origin: CoderOrigin(
          runID: context.runID,
          sessionID: context.sessionID,
          requesterUserID: ownerID,
          chatID: ownerID,
          toolCallID: context.toolCallID,
          approvalID: try #require(context.approvalID)
        ),
        maxConcurrentJobs: 1,
        journalScope: JournalScope(ownerUserID: ownerID, timeZoneID: "UTC"),
        now: now
      )
      _ = try fixture.store.markRunning(id: id, now: now)
      let result = CoderServiceFixture.result(summary: reply)
      try await service.complete(id: id, result: result, recovering: false)
      try await service.complete(id: id, result: result, recovering: false)
      #expect(try fixture.store.job(id: id)?.state == .succeeded)
      #expect(try fixture.reports().isEmpty == false)
    } else {
      queue = try TestDatabase.make()
      ownerID = 42
      let scope = JournalScope(ownerUserID: ownerID, timeZoneID: "UTC")
      let sessions = SessionMessageStoreGRDB(writer: queue)
      let runs = RunStoreGRDB(writer: queue)
      let claim = try sessions.claimAndPersistInbound(
        InboundMessage(
          updateID: 1,
          sessionKey: SessionKey.telegramDM(chatID: ownerID),
          chatID: ownerID,
          userID: ownerID,
          text: "ordinary task",
          isEdited: false,
          journalAdmission: JournalExchangeAdmission(
            scope: scope,
            sourceTimestamp: now,
            sourceDay: JournalDay.containing(now, timeZone: .gmt)
          ),
          ts: now
        )
      )
      let runID = try #require(claim.runID)
      _ = try runs.pickUp(runID: runID, now: now)
      let input = try #require(try runs.journalExchangeInput(runID: runID))
      let capture = JournalSourceCapture(
        policy: JournalPolicy(enabled: true, ownerUserID: ownerID, timeZoneID: "UTC"),
        redact: {
          $0
        }
      )
      let turn = AssistantTurn(
        runID: runID,
        sessionID: input.sessionID,
        chatID: ownerID,
        content: reply,
        usage: usageFixture(sessionID: input.sessionID, runID: runID),
        chunks: [
          OutboxChunk(
            stepIndex: 0,
            chatID: ownerID,
            payload: "ordinary reply",
            payloadHash: "receipt"
          ),
        ],
        journalCapture: capture.exchange(input: input, reply: reply, evidence: [])
      )
      #expect(try runs.commitAssistantTurn(turn, now: now) == .committed)
      #expect(try runs.commitAssistantTurn(turn, now: now) == .ignored)
      #expect(
        try OutboxStoreGRDB(writer: queue).pendingOutbound().map(\.payload) == ["ordinary reply"]
      )
    }

    // then
    let status = try JournalStoreGRDB(writer: queue).status(ownerUserID: ownerID, now: now)
    #expect(status.pendingCount == 0)
    #expect(status.skippedCount == 1)
    #expect(status.lastOutcome == .skipped(redactedReason: "Journal source preparation failed"))
    #expect(status.lastRedactedError == "Journal source preparation failed")
    #expect(status.lastRedactedError?.contains("ordinary task") != true)
  }

}
