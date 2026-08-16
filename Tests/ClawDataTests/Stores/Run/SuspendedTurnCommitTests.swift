import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct SuspendedTurnCommitTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let sessionId: Int64
    let runId: Int64
  }

  private func makeRunningFixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: "tg:dm:7",
        chatId: 7,
        userId: 7,
        text: "write the plan",
        isEdited: false,
        ts: Date()
      )
    )
    let runs = RunStoreGRDB(writer: queue)
    let runId = try #require(claim.runId)
    _ = try #require(try runs.pickUp(runId: runId, now: Date()))
    return Fixture(queue: queue, sessionId: try #require(claim.sessionId), runId: runId)
  }

  private func makeCommit(_ fixture: Fixture) -> SuspendedTurnCommit {
    let recorded = RecordedToolAction(
      tool: "file_write",
      canonicalArgsJSON: #"{"content":"hi","path":"notes/plan.md"}"#,
      argsHash: "hash16",
      canonicalTarget: "/workspace/notes/plan.md",
      reason: .askTier,
      presentation: ToolApprovalPresentation(
        blastRadius: "create, 2 B",
        contentPreview: "hi",
        warnings: []
      )
    )
    let buttonChunk = OutboxChunk(
      stepIndex: 0,
      chatId: 7,
      payload: "Approve writing /workspace/notes/plan.md?",
      payloadHash: "hash",
      approvalId: nil,
      replyMarkup: #"{"inline_keyboard":[[{"text":"Approve","callback_data":"apr:n0:y"}]]}"#
    )
    return SuspendedTurnCommit(
      assistantContent: "Let me save that.",
      toolCallsJSON: #"[{"id":"w1","name":"file_write","arguments":"{}"}]"#,
      completedObservations: [],
      pending: PendingToolAction(toolCallId: "w1", recorded: recorded),
      ownerUserId: 7,
      nonce: "n0",
      promptChunks: [buttonChunk],
      setTainted: false,
      setPrivateData: true,
      expiresTs: Date().addingTimeInterval(3600)
    )
  }

  private func count(_ queue: DatabaseQueue, _ sql: String) throws -> Int {
    try queue.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
  }

  @Test func suspendCommitPersistsTheWholeCheckpointInOneTransaction() throws {
    // given
    let fixture = try makeRunningFixture()
    let runs = RunStoreGRDB(writer: fixture.queue)

    // when
    let receipt = try runs.commitSuspendedTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      commit: makeCommit(fixture),
      now: Date()
    )

    // then — run suspended, approval PENDING, placeholder pinned, audit + prompt landed
    let runState = try fixture.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM runs WHERE id = ?",
        arguments: [fixture.runId]
      )
    }
    #expect(runState == RunState.awaitingApproval.rawValue)

    let approval = try fixture.queue.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT * FROM approvals WHERE id = ?",
        arguments: [receipt.approvalId]
      )
    }
    #expect(approval?["state"] == ApprovalState.pending.rawValue)
    #expect(approval?["tool"] == "file_write")
    #expect(approval?["nonce"] == "n0")
    #expect(approval?["reason"] == ApprovalReason.askTier.rawValue)
    #expect((approval?["observation_message_id"] as Int64?) == receipt.observationMessageId)

    let placeholder = try fixture.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [receipt.observationMessageId]
      )
    }
    #expect(placeholder == "awaiting owner approval")

    #expect(
      try count(
        fixture.queue,
        "SELECT COUNT(*) FROM messages WHERE role = 'assistant' AND tool_calls IS NOT NULL"
      ) == 1
    )
    #expect(
      try count(
        fixture.queue,
        "SELECT COUNT(*) FROM audit_events WHERE action = 'approval_requested'"
      ) == 1
    )
    #expect(
      try count(
        fixture.queue,
        "SELECT COUNT(*) FROM outbound_deliveries WHERE approval_id = \(receipt.approvalId)"
      ) == 1
    )
    // The suspend commit persists NO usage row — the suspending round was already debited mid-loop,
    // so a second write here would double the budget and the §6.3 resume carry-over.
    #expect(try count(fixture.queue, "SELECT COUNT(*) FROM provider_usage") == 0)
    // §4.5: the private-data flag rides the suspend commit from day one (D6).
    let hasPrivate = try fixture.queue.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT has_private_data FROM sessions WHERE id = ?",
        arguments: [fixture.sessionId]
      )
    }
    #expect(hasPrivate == true)
  }

  @Test func aWriteFaultRollsBackTheEntireCheckpoint() throws {
    // given — the fault seam throws just before the commit returns (still inside the txn)
    let fixture = try makeRunningFixture()
    struct InjectedFault: Error {}
    let runs = RunStoreGRDB(
      writer: fixture.queue,
      suspendCommitFault: { throw InjectedFault() }
    )

    // when / then — the whole checkpoint rolls back (the fault surfaces classified at the seam)
    #expect(throws: StoreError.self) {
      _ = try runs.commitSuspendedTurn(
        runId: fixture.runId,
        sessionId: fixture.sessionId,
        commit: makeCommit(fixture),
        now: Date()
      )
    }

    let runState = try fixture.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM runs WHERE id = ?",
        arguments: [fixture.runId]
      )
    }
    #expect(runState == RunState.running.rawValue)
    #expect(try count(fixture.queue, "SELECT COUNT(*) FROM approvals") == 0)
    #expect(try count(fixture.queue, "SELECT COUNT(*) FROM messages WHERE role = 'tool'") == 0)
    #expect(
      try count(
        fixture.queue,
        "SELECT COUNT(*) FROM messages WHERE role = 'assistant' AND tool_calls IS NOT NULL"
      ) == 0
    )
    #expect(
      try count(
        fixture.queue,
        "SELECT COUNT(*) FROM audit_events WHERE action = 'approval_requested'"
      ) == 0
    )
    #expect(try count(fixture.queue, "SELECT COUNT(*) FROM outbound_deliveries") == 0)
  }
}

// MARK: - Provider Replay State

extension SuspendedTurnCommitTests {
  /// Deliberately not valid UTF-8: a seam that stringified the blob would mangle it rather than
  /// round-trip it.
  static let anchorState = ProviderExchangeState(
    issuer: "openai-chatgpt-responses-v1:suspend",
    payload: Data([0x00, 0xC3, 0x28, 0xFF])
  )

  // The lossy conversion is the point here: the failable initializer the rule prefers returns nil
  // for these bytes, which would assert nothing at all.
  // swiftlint:disable optional_data_string_conversion

  /// The payload as a leak would actually expose it. Searching audit or prompt text for the raw
  /// bytes can never fail — a `String`'s UTF-8 view cannot emit `0xFF` — so non-exposure is
  /// asserted against the lossy form a stringifying seam really produces.
  static let anchorPayloadAsLossyText = String(decoding: anchorState.payload, as: UTF8.self)

  // swiftlint:enable optional_data_string_conversion

  private func statefulCommit(_ fixture: Fixture) -> SuspendedTurnCommit {
    let base = makeCommit(fixture)
    return SuspendedTurnCommit(
      assistantContent: base.assistantContent,
      toolCallsJSON: base.toolCallsJSON,
      completedObservations: [ToolObservationRow(toolCallId: "w0", content: "already ran")],
      pending: base.pending,
      ownerUserId: base.ownerUserId,
      nonce: base.nonce,
      promptChunks: base.promptChunks,
      setTainted: base.setTainted,
      setPrivateData: base.setPrivateData,
      providerState: Self.anchorState,
      expiresTs: base.expiresTs
    )
  }

  @Test func theSuspendCommitPersistsTheAnchorStateWithTheCheckpoint() throws {
    // given
    let fixture = try makeRunningFixture()
    let runs = RunStoreGRDB(writer: fixture.queue)

    // when
    _ = try runs.commitSuspendedTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      commit: statefulCommit(fixture),
      now: Date()
    )

    // then — the checkpoint and the state its anchor was minted with land in one transaction
    let anchor = try #require(
      try fixture.queue.read { db in
        try Row.fetchOne(
          db,
          sql: """
            SELECT provider_state_issuer, provider_state FROM messages
            WHERE run_id = ? AND role = ?
            """,
          arguments: [fixture.runId, MessageRole.assistant.rawValue]
        )
      }
    )
    #expect(anchor["provider_state_issuer"] as String? == Self.anchorState.issuer)
    #expect(anchor["provider_state"] as Data? == Self.anchorState.payload)
  }

  @Test func providerStateNeverReachesTheAuditTrailOrTheApprovalPrompt() throws {
    // given — the suspend commit is the one store path that writes an audit row and an owner-facing
    // prompt in the same transaction as an anchor's state
    let fixture = try makeRunningFixture()
    let runs = RunStoreGRDB(writer: fixture.queue)

    // when
    _ = try runs.commitSuspendedTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      commit: statefulCommit(fixture),
      now: Date()
    )

    // then — both surfaces exist and neither holds the issuer or the payload
    let auditRows = try fixture.queue.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM audit_events").map { row in "\(row)" }
    }
    let prompts = try fixture.queue.read { db in
      try String.fetchAll(db, sql: "SELECT payload FROM outbound_deliveries")
    }
    #expect(auditRows.isEmpty == false)
    #expect(prompts.isEmpty == false)
    for text in auditRows + prompts {
      #expect(text.contains(Self.anchorState.issuer) == false)
      #expect(text.contains(Self.anchorPayloadAsLossyText) == false)
    }
  }

  @Test func theResumedContextLoadsTheSuspendedAnchorStateAndNoOtherRow() throws {
    // given — the checkpoint a resume reads back before its next provider call
    let fixture = try makeRunningFixture()
    let runs = RunStoreGRDB(writer: fixture.queue)
    let receipt = try runs.commitSuspendedTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      commit: statefulCommit(fixture),
      now: Date()
    )

    // when — resume binds context to the filled observation row
    let history = try SessionMessageStoreGRDB(writer: fixture.queue).loadContextSnapshot(
      sessionId: fixture.sessionId,
      throughMessageId: receipt.observationMessageId,
      limit: 50
    ).history

    // then — the parked anchor carries its state; the completed and placeholder rows carry none
    #expect(history.map(\.role) == [.user, .assistant, .tool, .tool])
    #expect(history[1].providerState == Self.anchorState)
    #expect(history.filter { message in message.providerState != nil }.count == 1)
  }
}
