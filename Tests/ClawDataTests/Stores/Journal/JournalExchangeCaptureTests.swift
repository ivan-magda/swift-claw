import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct JournalExchangeCaptureTests {
  @Test
  func onlyBoundDoneExchangeQueuesOnce() throws {
    // given
    let fixture = try JournalExchangeFixture()
    let first = try fixture.admit(updateID: 1, text: "original task")
    let queued = try fixture.admit(updateID: 2, text: "later queued task")
    let runID = try #require(first.runID)
    _ = try fixture.runs.pickUp(runID: runID, now: fixture.now)
    let input = try #require(try fixture.runs.journalExchangeInput(runID: runID))
    let source = try fixture.source(input: input, reply: "completed answer")
    let turn = fixture.turn(input: input, runID: runID, source: source)
    let parked = try fixture.suspend(runID: runID, sessionID: input.sessionID)
    #expect(try fixture.runs.commitAssistantTurn(turn, now: fixture.now) == .ignored)
    #expect(try fixture.sourceIDs().isEmpty)
    #expect(
      try fixture.runs.claimApprovedExecution(
        runID: runID,
        observationMessageID: parked.observationMessageID,
        notResumableObservationContent: "obsolete",
        now: fixture.now
      ) == .committed
    )

    // when
    #expect(try fixture.runs.commitAssistantTurn(turn, now: fixture.now) == .committed)
    #expect(try fixture.runs.commitAssistantTurn(turn, now: fixture.now) == .ignored)
    _ = try fixture.commands.applyNew(
      updateID: 3,
      sessionKey: fixture.sessionKey,
      journalScope: fixture.scope,
      now: fixture.now
    )
    let queuedRunID = try #require(queued.runID)
    let queuedInput = try #require(try fixture.runs.journalExchangeInput(runID: queuedRunID))
    _ = try fixture.runs.commitAssistantTurn(
      fixture.turn(
        input: queuedInput,
        runID: queuedRunID,
        source: fixture.source(input: queuedInput, reply: "obsolete answer")
      ),
      now: fixture.now
    )

    // then
    #expect(input.ownerText == "original task")
    #expect(input.triggerMessageID == first.triggerMessageID)
    #expect(try fixture.sourceIDs() == [source.id])
    #expect(try fixture.state(runID: runID) == RunState.done.rawValue)
    #expect(try fixture.outbox.pendingOutbound().map(\.payload) == ["completed answer"])
  }

  @Test
  func captureFailurePreservesPrimaryCommit() throws {
    // given
    let fixture = try JournalExchangeFixture()
    let claim = try fixture.admit(updateID: 1, text: "task")
    let runID = try #require(claim.runID)
    _ = try fixture.runs.pickUp(runID: runID, now: fixture.now)
    let input = try #require(try fixture.runs.journalExchangeInput(runID: runID))
    let source = try fixture.source(input: input, reply: "completed answer")
    try fixture.queue.write { db in
      try db.execute(
        sql: """
          CREATE TEMP TRIGGER reject_journal BEFORE INSERT ON journal_sources
          BEGIN SELECT RAISE(ABORT, 'private fixture text'); END
          """
      )
    }

    // when
    let outcome = try fixture.runs.commitAssistantTurn(
      fixture.turn(input: input, runID: runID, source: source),
      now: fixture.now
    )

    // then
    #expect(outcome == .committed)
    #expect(try fixture.state(runID: runID) == RunState.done.rawValue)
    #expect(try fixture.outbox.pendingOutbound().map(\.payload) == ["completed answer"])
    #expect(try fixture.sourceIDs().isEmpty)
    let status = try JournalStoreGRDB(writer: fixture.queue).status(
      ownerUserID: 42,
      now: fixture.now
    )
    #expect(status.skippedCount == 1)
    #expect(status.lastRedactedError?.contains("private fixture text") != true)
  }
}

struct JournalExchangeFixture {
  let queue: DatabaseQueue
  let sessions: SessionMessageStoreGRDB
  let runs: RunStoreGRDB
  let commands: CommandStoreGRDB
  let outbox: OutboxStoreGRDB
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let scope = JournalScope(ownerUserID: 42, timeZoneID: "UTC")
  let sessionKey = SessionKey.telegramDM(chatID: 42)

  init() throws {
    queue = try TestDatabase.make()
    sessions = SessionMessageStoreGRDB(writer: queue)
    runs = RunStoreGRDB(writer: queue)
    commands = CommandStoreGRDB(writer: queue)
    outbox = OutboxStoreGRDB(writer: queue)
  }

  func admit(updateID: Int64, text: String) throws -> ClaimResult {
    try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: updateID,
        sessionKey: sessionKey,
        chatID: 42,
        userID: 42,
        text: text,
        isEdited: false,
        journalAdmission: JournalExchangeAdmission(
          scope: scope,
          sourceTimestamp: now,
          sourceDay: JournalDay.containing(now, timeZone: .gmt)
        ),
        ts: now
      )
    )
  }

  func source(input: JournalExchangeInput, reply: String) throws -> JournalSource {
    try JournalSource(
      id: "message:\(input.triggerMessageID)",
      scope: input.admission.scope,
      sessionID: input.sessionID,
      occurredAt: input.admission.sourceTimestamp,
      day: input.admission.sourceDay,
      ownerText: input.ownerText,
      assistantText: reply,
      supportingProposal: try input.supportingProposal.map {
        try JournalProposal(sourceID: $0.sourceID, text: $0.text)
      }
    )
  }

  func turn(input: JournalExchangeInput, runID: Int64, source: JournalSource) -> AssistantTurn {
    AssistantTurn(
      runID: runID,
      sessionID: input.sessionID,
      chatID: 42,
      content: source.assistantText,
      usage: makeProviderUsage(runID: runID, sessionID: input.sessionID),
      chunks: [
        OutboxChunk(
          stepIndex: 0,
          chatID: 42,
          payload: source.assistantText,
          payloadHash: source.id
        ),
      ],
      journalCapture: .source(source)
    )
  }

  func suspend(runID: Int64, sessionID: Int64) throws -> SuspendedCommitReceipt {
    let recorded = RecordedToolAction(
      tool: "file_write",
      canonicalArgsJSON: "{}",
      argsHash: "fixture",
      canonicalTarget: "/workspace/plan.md",
      reason: .askTier,
      presentation: ToolApprovalPresentation(
        blastRadius: "create",
        contentPreview: "",
        warnings: []
      )
    )
    return try runs.commitSuspendedTurn(
      runID: runID,
      sessionID: sessionID,
      commit: SuspendedTurnCommit(
        assistantContent: "Save plan",
        toolCallsJSON: "[]",
        completedObservations: [],
        pending: PendingToolAction(toolCallID: "write", recorded: recorded),
        ownerUserID: 42,
        nonce: "journal-fixture",
        promptChunks: [],
        setTainted: false,
        setPrivateData: false,
        expiresTs: now.addingTimeInterval(3600)
      ),
      now: now
    )
  }

  func sourceIDs() throws -> [String] {
    try queue.read { db in
      try String.fetchAll(db, sql: "SELECT source_id FROM journal_sources ORDER BY source_id")
    }
  }

  func state(runID: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runID])
    }
  }
}
