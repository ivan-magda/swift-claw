import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

/// The outbox `dedup_key` is `runId:stepIndex` under INSERT OR IGNORE, so every enqueue after the
/// first in one run MUST extend the run's delivery sequence — a raw-step collision is a SILENT
/// drop (no error, no row, the owner never hears). These pin the step-base shift at each commit
/// that can follow a §5.3 suspend prompt (enqueued at step 0): the resumed turn's reply, the
/// degraded resume's reply, and a SECOND suspend prompt in the same run.
@Suite struct OutboxStepSequenceTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let approvals: ApprovalStoreGRDB
    let sessionId: Int64
    let runId: Int64
  }

  private struct OutboxSnapshot: Equatable {
    let stepIndex: Int
    let payload: String
    let approvalId: Int64?
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
    return Fixture(
      queue: queue,
      runs: runs,
      approvals: ApprovalStoreGRDB(writer: queue),
      sessionId: try #require(claim.sessionId),
      runId: runId
    )
  }

  /// A minimal §5.3 checkpoint whose args-hash is CONSISTENT with its canonical args, so the
  /// approve CAS (§6.2 step 5) accepts it and the run can resume for a follow-up commit.
  private func makeSuspendCommit(nonce: String, promptPayload: String) -> SuspendedTurnCommit {
    let canonicalArgsJSON = #"{"content":"hi","path":"notes/plan.md"}"#
    let recorded = RecordedToolAction(
      tool: "file_write",
      canonicalArgsJSON: canonicalArgsJSON,
      argsHash: ApprovalArgsHash.sha256Hex(canonicalArgsJSON),
      canonicalTarget: "/workspace/notes/plan.md",
      reason: .askTier,
      presentation: ToolApprovalPresentation(
        blastRadius: "create, 2 B",
        contentPreview: "hi",
        warnings: []
      )
    )
    return SuspendedTurnCommit(
      assistantContent: "Let me save that.",
      toolCallsJSON: #"[{"id":"w1","name":"file_write","arguments":"{}"}]"#,
      completedObservations: [],
      pending: PendingToolAction(toolCallId: "w1", recorded: recorded),
      ownerUserId: 7,
      nonce: nonce,
      promptChunks: [
        OutboxChunk(
          stepIndex: 0,
          chatId: 7,
          payload: promptPayload,
          payloadHash: "hash-\(nonce)",
          approvalId: nil,
          replyMarkup: #"{"inline_keyboard":[]}"#
        )
      ],
      setTainted: false,
      setPrivateData: false,
      expiresTs: Date().addingTimeInterval(3600)
    )
  }

  /// Suspends the run once (prompt at step 0), approves the row, and resumes the run to RUNNING —
  /// the state every "commit after a suspend" scenario starts from.
  private func suspendApproveResume(
    _ fixture: Fixture,
    nonce: String
  ) throws -> SuspendedCommitReceipt {
    let receipt = try fixture.runs.commitSuspendedTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      commit: makeSuspendCommit(nonce: nonce, promptPayload: "prompt \(nonce)"),
      now: Date()
    )
    // policy_version is unstamped in this fixture, so the stored version is "".
    let outcome = try fixture.approvals.approve(
      id: receipt.approvalId,
      currentPolicyVersion: "",
      now: Date()
    )
    guard case .approved = outcome else {
      throw StoreError.unexpected("fixture approve CAS did not apply: \(outcome)")
    }
    let resumed = try fixture.runs.completeApprovedObservation(
      runId: fixture.runId,
      observationMessageId: receipt.observationMessageId,
      content: "wrote it",
      now: Date()
    )
    guard resumed == .committed else {
      throw StoreError.unexpected("fixture resume did not commit: \(resumed)")
    }
    return receipt
  }

  private func outboxRows(_ queue: DatabaseQueue) throws -> [OutboxSnapshot] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT step_index, payload, approval_id FROM outbound_deliveries ORDER BY step_index
          """
      ).map { row in
        OutboxSnapshot(
          stepIndex: row["step_index"],
          payload: row["payload"],
          approvalId: row["approval_id"]
        )
      }
    }
  }

  private func makeUsage(_ fixture: Fixture) -> ProviderUsage {
    ProviderUsage(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      model: "test-model",
      promptTokens: 10,
      completionTokens: 5,
      costUSD: 0.001,
      costSource: .heuristic,
      isEstimated: false,
      ts: Date()
    )
  }

  @Test func aSecondSuspendInTheSameRunLandsItsPromptPastTheFirst() throws {
    // given — suspend #1 parked its prompt at step 0, the owner approved, the run resumed
    let fixture = try makeRunningFixture()
    _ = try suspendApproveResume(fixture, nonce: "n1")

    // when — the resumed turn proposes a second gated action in the SAME run
    let second = try fixture.runs.commitSuspendedTurn(
      runId: fixture.runId,
      sessionId: fixture.sessionId,
      commit: makeSuspendCommit(nonce: "n2", promptPayload: "prompt n2"),
      now: Date()
    )

    // then — the second prompt row EXISTS (not dropped by the first prompt's dedup key), linked
    // to the second approval, at the next step of the run's delivery sequence
    let rows = try outboxRows(fixture.queue)
    #expect(rows.count == 2)
    #expect(
      rows.contains(
        OutboxSnapshot(stepIndex: 1, payload: "prompt n2", approvalId: second.approvalId)
      )
    )
  }

  @Test func aResumedTurnsReplyChunksExtendTheDeliverySequence() throws {
    // given — the run's approval prompt already occupies step 0
    let fixture = try makeRunningFixture()
    _ = try suspendApproveResume(fixture, nonce: "n1")

    // when — the resumed turn completes with a two-chunk reply (raw steps 0 and 1)
    let committed = try fixture.runs.commitAssistantTurn(
      AssistantTurn(
        runId: fixture.runId,
        sessionId: fixture.sessionId,
        chatId: 7,
        content: "reply one\nreply two",
        usage: makeUsage(fixture),
        chunks: [
          OutboxChunk(stepIndex: 0, chatId: 7, payload: "reply one", payloadHash: "r1"),
          OutboxChunk(stepIndex: 1, chatId: 7, payload: "reply two", payloadHash: "r2"),
        ]
      ),
      now: Date()
    )

    // then — both reply rows landed past the prompt, in order
    #expect(committed == .committed)
    let rows = try outboxRows(fixture.queue)
    #expect(rows.count == 3)
    #expect(rows.contains(OutboxSnapshot(stepIndex: 1, payload: "reply one", approvalId: nil)))
    #expect(rows.contains(OutboxSnapshot(stepIndex: 2, payload: "reply two", approvalId: nil)))
  }

  @Test func theBootCrashNoticeExtendsTheDeliverySequence() throws {
    // given — the run suspended (prompt at step 0), resumed to RUNNING, then the process crashed
    let fixture = try makeRunningFixture()
    _ = try suspendApproveResume(fixture, nonce: "n1")

    // when — boot reconciliation fails the RUNNING orphan and enqueues its crash notice
    let replies = try fixture.runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "the process restarted",
      heartbeatNoticeChatId: nil
    )

    // then — the notice landed PAST the prompt (not silently dropped by the step-0 dedup key)
    #expect(replies.map(\.runId) == [fixture.runId])
    let rows = try outboxRows(fixture.queue)
    #expect(rows.count == 2)
    #expect(
      rows.contains(
        OutboxSnapshot(stepIndex: 1, payload: "the process restarted", approvalId: nil)
      )
    )
  }

  @Test func aDegradedResumeReplyExtendsTheDeliverySequence() throws {
    // given — the run's approval prompt already occupies step 0
    let fixture = try makeRunningFixture()
    _ = try suspendApproveResume(fixture, nonce: "n1")

    // when — the resumed turn degrades with its single owner-facing reply (raw step 0)
    let committed = try fixture.runs.commitDegradedTurn(
      DegradedTurn(
        runId: fixture.runId,
        sessionId: fixture.sessionId,
        chatId: 7,
        usage: nil,
        chunk: OutboxChunk(stepIndex: 0, chatId: 7, payload: "degraded reply", payloadHash: "d1")
      ),
      now: Date()
    )

    // then — the degradation reply landed past the prompt, not silently dropped
    #expect(committed == .committed)
    let rows = try outboxRows(fixture.queue)
    #expect(rows.count == 2)
    #expect(rows.contains(OutboxSnapshot(stepIndex: 1, payload: "degraded reply", approvalId: nil)))
  }
}
