import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ApprovedResumeStoreTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let runs: RunStoreGRDB
    let sessionId: Int64
    let runId: Int64
    let observationMessageId: Int64
  }

  private static let placeholder = "awaiting owner approval"

  /// A run suspended to AWAITING_APPROVAL through the real reducer, with an assistant anchor and a
  /// placeholder observation row persisted (the shape Task 14's `commitSuspendedTurn` leaves).
  private func makeSuspendedFixture(
    claimedFillFault: @escaping @Sendable () throws -> Void = {}
  ) throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 7),
        chatId: 7,
        userId: 7,
        text: "remember the plan",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    let runs = RunStoreGRDB(
      writer: queue,
      suspendCommitFault: {},
      claimedFillFault: claimedFillFault
    )
    _ = try #require(try runs.pickUp(runId: runId, now: Date()))

    let observationMessageId = try queue.write { db -> Int64 in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_calls)
          VALUES (?, ?, 'assistant', '', 'trusted', ?, '[{"id":"c1","name":"file_write","arguments":"{}"}]')
          """,
        arguments: [sessionId, runId, Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', ?, 'untrusted', ?, 'c1')
          """,
        arguments: [sessionId, runId, Self.placeholder, Date()]
      )
      let messageId = db.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(db, runId: runId, event: .suspendForApproval, now: Date())
      return messageId
    }

    return Fixture(
      queue: queue,
      runs: runs,
      sessionId: sessionId,
      runId: runId,
      observationMessageId: observationMessageId
    )
  }

  private func runState(_ queue: DatabaseQueue, _ runId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
    }
  }

  private func messageContent(_ queue: DatabaseQueue, _ messageId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT content FROM messages WHERE id = ?",
        arguments: [messageId]
      )
    }
  }

  private func sessionFlags(_ env: Fixture) throws -> (tainted: Bool, privateData: Bool) {
    try env.queue.read { db in
      let row = try #require(
        try Row.fetchOne(
          db,
          sql: "SELECT tainted, has_private_data FROM sessions WHERE id = ?",
          arguments: [env.sessionId]
        )
      )
      return (row["tainted"], row["has_private_data"])
    }
  }

  private func toolAuditRows(_ env: Fixture) throws -> [Row] {
    try env.queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT actor, action, tool, args_redacted, result_size, decision, run_id, session_id, ts
          FROM audit_events
          WHERE run_id = ? AND action = ?
          ORDER BY id
          """,
        arguments: [env.runId, AuditAction.toolCall.rawValue]
      )
    }
  }

  private func fill(
    _ env: Fixture,
    content: String,
    status: ToolObservationStatus = .ok,
    setTainted: Bool = false,
    setPrivateData: Bool = false,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws {
    try env.runs.fillClaimedObservation(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      fill: ClaimedObservationFill(
        content: content,
        status: status,
        setTainted: setTainted,
        setPrivateData: setPrivateData,
        audit: ApprovedExecutionAudit(
          tool: "file_write",
          argsRedacted: #"{"path":"plan.md"}"#
        ),
        now: now
      )
    )
  }

  @Test func claimApprovedExecutionFlipsTheRunAndLeavesThePlaceholder() throws {
    // given
    let env = try makeSuspendedFixture()

    // when — the claim is the pre-execution half: it must NOT touch the observation
    let claim = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )

    // then — the run is RUNNING (so /stop can no longer cancel-race the external write) and the
    // placeholder still awaits the real result
    #expect(claim == .committed)
    #expect(try runState(env.queue, env.runId) == RunState.running.rawValue)
    #expect(try messageContent(env.queue, env.observationMessageId) == Self.placeholder)
  }

  @Test func claimApprovedExecutionOnACancelledRunFillsTheCancellationNote() throws {
    // given — /stop cancelled the run after the Approve callback CAS'd the row APPROVED
    let env = try makeSuspendedFixture()
    try env.queue.write { db in
      _ = try RunStoreGRDB.transitionRun(db, runId: env.runId, event: .cancel, now: Date())
    }

    // when
    let claim = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "The session was stopped before this action ran.",
      now: Date()
    )

    // then — no claim (the caller must not execute), the run stays terminal, and the placeholder
    // is resolved in the SAME transaction so history never dangles
    #expect(claim == .runNotResumable)
    #expect(try runState(env.queue, env.runId) == RunState.cancelled.rawValue)
    #expect(
      try messageContent(env.queue, env.observationMessageId)
        == "The session was stopped before this action ran."
    )
  }

  @Test func claimApprovedExecutionAfterTheObservationResolvedIsAlreadyResumed() throws {
    // given — a first claim + fill completed the resume
    let env = try makeSuspendedFixture()
    _ = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )
    try fill(env, content: "first")

    // when — a duplicate signal replays the claim against the filled observation
    let replay = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )

    // then — recognized as already executed, nothing overwritten
    #expect(replay == .alreadyResumed)
    #expect(try messageContent(env.queue, env.observationMessageId) == "first")
  }

  private func outboxPayloads(_ queue: DatabaseQueue, _ runId: Int64) throws -> [String] {
    try queue.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT payload FROM outbound_deliveries
          WHERE run_id = ? AND status = 'PENDING' ORDER BY step_index
          """,
        arguments: [runId]
      )
    }
  }

  @Test func settleClaimedApprovalAtBootFailsTheRunFillsAndNotifies() throws {
    // given — the claim committed (run RUNNING) and the process died before the result record
    let env = try makeSuspendedFixture()
    _ = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )

    // when
    let outcome = try env.runs.settleClaimedApprovalAtBoot(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      observationContent: "Outcome unknown; the daemon restarted mid-action.",
      noticeChatId: 7,
      noticeText: "I restarted while running an approved action.",
      now: Date()
    )

    // then — one fused txn: run FAILED, placeholder resolved truthfully, owner notice enqueued
    #expect(outcome == .settled)
    #expect(try runState(env.queue, env.runId) == RunState.failed.rawValue)
    #expect(
      try messageContent(env.queue, env.observationMessageId)
        == "Outcome unknown; the daemon restarted mid-action."
    )
    #expect(
      try outboxPayloads(env.queue, env.runId) == ["I restarted while running an approved action."]
    )
  }

  @Test func settleClaimedApprovalAtBootOnAnOrphanFailedRunStillFillsAndNotifies() throws {
    // given — the boot orphan sweep already failed the claimed run before the approval reconciler
    let env = try makeSuspendedFixture()
    _ = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )
    try env.queue.write { db in
      _ = try RunStoreGRDB.transitionRun(db, runId: env.runId, event: .fail, now: Date())
    }

    // when
    let outcome = try env.runs.settleClaimedApprovalAtBoot(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      observationContent: "Outcome unknown.",
      noticeChatId: 7,
      noticeText: "Please verify the action.",
      now: Date()
    )

    // then — the sweep's transition stands; fill + notice still land
    #expect(outcome == .settled)
    #expect(try runState(env.queue, env.runId) == RunState.failed.rawValue)
    #expect(try messageContent(env.queue, env.observationMessageId) == "Outcome unknown.")
    #expect(try outboxPayloads(env.queue, env.runId) == ["Please verify the action."])
  }

  @Test func settleClaimedApprovalAtBootLeavesAnAwaitingRunForTheReplayBelt() throws {
    // given — no claim committed: the §6.5 crash window (granted before the crash, never executed)
    let env = try makeSuspendedFixture()

    // when
    let outcome = try env.runs.settleClaimedApprovalAtBoot(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      observationContent: "Outcome unknown.",
      noticeChatId: 7,
      noticeText: "Please verify the action.",
      now: Date()
    )

    // then — nothing written: the caller re-parks the waiter to replay the recorded action
    #expect(outcome == .reparkForReplay)
    #expect(try runState(env.queue, env.runId) == RunState.awaitingApproval.rawValue)
    #expect(try messageContent(env.queue, env.observationMessageId) == Self.placeholder)
    #expect(try outboxPayloads(env.queue, env.runId).isEmpty)
  }

  @Test func settleClaimedApprovalAtBootIsANoOpOnceTheObservationResolved() throws {
    // given — the resume completed before the restart; the observation holds the real result
    let env = try makeSuspendedFixture()
    _ = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )
    try fill(env, content: "Wrote 12 B.")

    // when
    let outcome = try env.runs.settleClaimedApprovalAtBoot(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      observationContent: "Outcome unknown.",
      noticeChatId: 7,
      noticeText: "Please verify the action.",
      now: Date()
    )

    // then — the recorded result is never overwritten and no notice is sent
    #expect(outcome == .alreadyResolved)
    #expect(try messageContent(env.queue, env.observationMessageId) == "Wrote 12 B.")
    #expect(try outboxPayloads(env.queue, env.runId).isEmpty)
  }

  @Test func applyApprovedMemoryWriteFusesTheInsertWithTheObservationFill() throws {
    // given
    let env = try makeSuspendedFixture()
    let item = NewMemoryItem(text: "the plan is ready", kind: .project, sessionId: env.sessionId)

    // when
    let result = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved to memory as project.",
      audit: ApprovedExecutionAudit(
        tool: "memory_write",
        argsRedacted: #"{"kind":"project","text":"[REDACTED]"}"#
      ),
      notResumableObservationContent: "stopped",
      now: Date()
    )

    // then — one fused transaction: memory row inserted, observation filled, run RUNNING
    #expect(result == .committed)
    let memoryCount = try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items")
    }
    #expect(memoryCount == 1)
    #expect(
      try messageContent(env.queue, env.observationMessageId) == "Saved to memory as project."
    )
    #expect(try runState(env.queue, env.runId) == RunState.running.rawValue)
    let audits = try toolAuditRows(env)
    #expect(audits.count == 1)
    #expect(audits[0]["tool"] == "memory_write")
    #expect(audits[0]["decision"] == ToolObservationStatus.ok.rawValue)
  }

  @Test func applyApprovedMemoryWriteIsExactlyOnce() throws {
    // given — the fused write already committed once
    let env = try makeSuspendedFixture()
    let item = NewMemoryItem(text: "remember me once", kind: .user, sessionId: env.sessionId)
    _ = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved.",
      audit: ApprovedExecutionAudit(tool: "memory_write", argsRedacted: "[REDACTED]"),
      notResumableObservationContent: "stopped",
      now: Date()
    )

    // when — re-running the fused method after the observation is filled
    let second = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved again.",
      audit: ApprovedExecutionAudit(tool: "memory_write", argsRedacted: "[REDACTED]"),
      notResumableObservationContent: "stopped",
      now: Date()
    )

    // then — the placeholder guard means NO second memory row (§6.3 exactly-once)
    #expect(second == .alreadyResumed)
    let memoryCount = try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items")
    }
    #expect(memoryCount == 1)
  }

  @Test func applyApprovedMemoryWriteOnACancelledRunFillsTheCancellationNote() throws {
    // given — /stop drove the run terminal after the approve CAS
    let env = try makeSuspendedFixture()
    try env.queue.write { db in
      _ = try RunStoreGRDB.transitionRun(db, runId: env.runId, event: .cancel, now: Date())
    }
    let item = NewMemoryItem(text: "never stored", kind: .user, sessionId: env.sessionId)

    // when
    let claim = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved.",
      audit: ApprovedExecutionAudit(tool: "memory_write", argsRedacted: "[REDACTED]"),
      notResumableObservationContent: "The session was stopped before this action ran.",
      now: Date()
    )

    // then — no insert, the run stays terminal, and the placeholder resolves truthfully
    #expect(claim == .runNotResumable)
    let memoryCount = try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items")
    }
    #expect(memoryCount == 0)
    #expect(try runState(env.queue, env.runId) == RunState.cancelled.rawValue)
    #expect(
      try messageContent(env.queue, env.observationMessageId)
        == "The session was stopped before this action ran."
    )
  }

  /// Re-suspends the fixture's run on a SECOND placeholder (the multi-suspend shape: approve #1,
  /// resume, propose another gated call) and returns the new placeholder's message id.
  private func suspendAgain(_ env: Fixture) throws -> Int64 {
    try env.queue.write { db -> Int64 in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', ?, 'untrusted', ?, 'c2')
          """,
        arguments: [env.sessionId, env.runId, Self.placeholder, Date()]
      )
      let messageId = db.lastInsertedRowID
      _ = try RunStoreGRDB.transitionRun(
        db,
        runId: env.runId,
        event: .suspendForApproval,
        now: Date()
      )
      return messageId
    }
  }

  @Test func replayAfterASecondSuspendIsIgnoredAndLeavesTheRunParked() throws {
    // given — approval #1 fully resumed, then the run suspends again on approval #2: the run is
    // AWAITING_APPROVAL once more, so the AWAITING→RUNNING flip alone would let a boot replay of
    // #1 commit and steal #2's park
    let env = try makeSuspendedFixture()
    _ = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )
    try fill(env, content: "first")
    let secondPlaceholderId = try suspendAgain(env)

    // when — a boot replay re-runs approval #1's claim against its already-filled observation
    let replay = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )

    // then — recognized as executed: run STILL parked for #2, #1's observation untouched, #2's
    // placeholder intact
    #expect(replay == .alreadyResumed)
    #expect(try runState(env.queue, env.runId) == RunState.awaitingApproval.rawValue)
    #expect(try messageContent(env.queue, env.observationMessageId) == "first")
    #expect(try messageContent(env.queue, secondPlaceholderId) == Self.placeholder)
  }

  @Test func memoryWriteReplayAfterASecondSuspendIsIgnoredAndLeavesTheRunParked() throws {
    // given — the fused memory write committed once, then the run suspends again
    let env = try makeSuspendedFixture()
    let item = NewMemoryItem(text: "the plan is ready", kind: .project, sessionId: env.sessionId)
    _ = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved.",
      audit: ApprovedExecutionAudit(tool: "memory_write", argsRedacted: "[REDACTED]"),
      notResumableObservationContent: "stopped",
      now: Date()
    )
    _ = try suspendAgain(env)

    // when — a boot replay re-runs the fused write for the resolved approval
    let replay = try env.runs.applyApprovedMemoryWrite(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      item: item,
      observationContent: "Saved again.",
      audit: ApprovedExecutionAudit(tool: "memory_write", argsRedacted: "[REDACTED]"),
      notResumableObservationContent: "stopped",
      now: Date()
    )

    // then — recognized as executed: no second memory row, run still parked for the new approval
    #expect(replay == .alreadyResumed)
    #expect(try runState(env.queue, env.runId) == RunState.awaitingApproval.rawValue)
    let memoryCount = try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items")
    }
    #expect(memoryCount == 1)
  }

  @Test func resumeUsageDerivesCountersFromPersistedRows() throws {
    // given — the fixture already has one assistant row and one tool row; add usage + a second
    // assistant/tool pair so the counts and sums are unambiguous (D4)
    let env = try makeSuspendedFixture()
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_calls)
          VALUES (?, ?, 'assistant', '', 'trusted', ?, '[]')
          """,
        arguments: [env.sessionId, env.runId, Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', 'obs', 'untrusted', ?, 'c2')
          """,
        arguments: [env.sessionId, env.runId, Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
            cost_usd, cost_source, is_estimated, ts, provider_call_id)
          VALUES (?, ?, 'm', 100, 20, 0.03, 'price_file', 0, ?, 'call-round-1')
          """,
        arguments: [env.runId, env.sessionId, Date()]
      )
      try db.execute(
        sql: """
          INSERT INTO provider_usage(run_id, session_id, model, prompt_tokens, completion_tokens,
            cost_usd, cost_source, is_estimated, ts, provider_call_id)
          VALUES (?, ?, 'm', 50, 10, 0.01, 'price_file', 0, ?, 'call-round-2')
          """,
        arguments: [env.runId, env.sessionId, Date()]
      )
    }

    // when
    let usage = try env.runs.resumeUsage(runId: env.runId)

    // then — 2 assistant rounds, 2 tool calls, 180 tokens, $0.04
    #expect(usage.rounds == 2)
    #expect(usage.toolCalls == 2)
    #expect(usage.tokens == 180)
    #expect(usage.costUSD == 0.04)
  }

  @Test func runOriginReadsTheRunsColumn() throws {
    // given
    let env = try makeSuspendedFixture()

    // when / then — resume reads origin without re-picking-up the run
    #expect(try env.runs.runOrigin(runId: env.runId) == .interactive)
    #expect(try env.runs.runOrigin(runId: 9999) == nil)
  }

  @Test func failRunStalePolicyFailsTheRunFillsTheObservationAndAuditsTheDenial() throws {
    // given
    let env = try makeSuspendedFixture()

    // when
    let failed = try env.runs.failRunStalePolicy(
      runId: env.runId,
      sessionId: env.sessionId,
      observationMessageId: env.observationMessageId,
      observationContent: "The approval was voided because the policy changed before it ran.",
      now: Date()
    )

    // then — one txn: run FAILED, the placeholder resolved (a dangling "awaiting owner approval"
    // would both mislead later turns and false-trigger the boot claimed-window settlement), and
    // the approvalDenied/stale_policy audit
    #expect(failed)
    #expect(try runState(env.queue, env.runId) == RunState.failed.rawValue)
    #expect(
      try messageContent(env.queue, env.observationMessageId)
        == "The approval was voided because the policy changed before it ran."
    )
    let auditDecision = try env.queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT decision FROM audit_events WHERE action = ? AND run_id = ?",
        arguments: [AuditAction.approvalDenied.rawValue, env.runId]
      )
    }
    #expect(auditDecision == ApprovalDecision.stalePolicy.rawValue)
  }

  @Test func typedFillUpdatesObservationFlagsAndAuditInOneCommit() throws {
    // given
    let env = try makeSuspendedFixture()
    _ = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )
    let committedAt = Date(timeIntervalSince1970: 1_700_000_123)

    // when
    try fill(
      env,
      content: "sandbox output",
      status: .blockedArgs,
      setTainted: true,
      setPrivateData: true,
      now: committedAt
    )

    // then
    #expect(try messageContent(env.queue, env.observationMessageId) == "sandbox output")
    let flags = try sessionFlags(env)
    #expect(flags.tainted)
    #expect(flags.privateData)
    let audits = try toolAuditRows(env)
    #expect(audits.count == 1)
    #expect(audits[0]["actor"] == AuditActor.assistant.rawValue)
    #expect(audits[0]["tool"] == "file_write")
    #expect(audits[0]["args_redacted"] == #"{"path":"plan.md"}"#)
    #expect(audits[0]["result_size"] == Data("sandbox output".utf8).count)
    #expect(audits[0]["decision"] == ToolObservationStatus.blockedArgs.rawValue)
    #expect(audits[0]["run_id"] == env.runId)
    #expect(audits[0]["session_id"] == env.sessionId)
    let auditTimestamp: Date = audits[0]["ts"]
    #expect(auditTimestamp == committedAt)
  }

  @Test func cancelledRunStillCommitsProvenanceFromACompletedAction() throws {
    // given: the action claimed RUNNING, then /stop won while it executed
    let env = try makeSuspendedFixture()
    _ = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )
    _ = try env.runs.cancelActiveRun(
      sessionId: env.sessionId,
      reason: .cancelled,
      now: Date()
    )

    // when
    try fill(env, content: "completed before cancellation", setTainted: true, setPrivateData: true)

    // then
    #expect(try runState(env.queue, env.runId) == RunState.cancelled.rawValue)
    #expect(try sessionFlags(env).tainted)
    #expect(try sessionFlags(env).privateData)
    #expect(try toolAuditRows(env).count == 1)
  }

  @Test func supersededRunFillsAndAuditsWithoutRetainingOldWindowProvenance() throws {
    // given: the action claimed RUNNING, then /new superseded and detainted the window
    let env = try makeSuspendedFixture()
    _ = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )
    _ = try env.runs.supersedeSessionRuns(sessionId: env.sessionId, now: Date())

    // when
    try fill(env, content: "old-window output", setTainted: true, setPrivateData: true)

    // then: old transcript/audit remain truthful; the fresh window stays clean
    #expect(try runState(env.queue, env.runId) == RunState.superseded.rawValue)
    #expect(try messageContent(env.queue, env.observationMessageId) == "old-window output")
    #expect(try sessionFlags(env).tainted == false)
    #expect(try sessionFlags(env).privateData == false)
    #expect(try toolAuditRows(env).count == 1)
  }

  @Test func fillFaultRollsBackContentFlagsAndAuditTogether() throws {
    // given
    let env = try makeSuspendedFixture(claimedFillFault: {
      throw StoreError.unexpected("claimed fill fault")
    })
    _ = try env.runs.claimApprovedExecution(
      runId: env.runId,
      observationMessageId: env.observationMessageId,
      notResumableObservationContent: "stopped",
      now: Date()
    )

    // when / then
    #expect(throws: StoreError.unexpected("claimed fill fault")) {
      try fill(env, content: "must roll back", setTainted: true, setPrivateData: true)
    }
    #expect(try messageContent(env.queue, env.observationMessageId) == Self.placeholder)
    #expect(try sessionFlags(env).tainted == false)
    #expect(try sessionFlags(env).privateData == false)
    #expect(try toolAuditRows(env).isEmpty)
  }

  @Test func memoryFillFaultRollsBackClaimItemObservationAndAuditTogether() throws {
    // given
    let env = try makeSuspendedFixture(claimedFillFault: {
      throw StoreError.unexpected("claimed fill fault")
    })
    let item = NewMemoryItem(text: "must not persist", kind: .project, sessionId: env.sessionId)

    // when / then
    #expect(throws: StoreError.unexpected("claimed fill fault")) {
      try env.runs.applyApprovedMemoryWrite(
        runId: env.runId,
        observationMessageId: env.observationMessageId,
        item: item,
        observationContent: "must roll back",
        audit: ApprovedExecutionAudit(tool: "memory_write", argsRedacted: "[REDACTED]"),
        notResumableObservationContent: "stopped",
        now: Date()
      )
    }
    let memoryCount = try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items")
    }
    #expect(memoryCount == 0)
    #expect(try runState(env.queue, env.runId) == RunState.awaitingApproval.rawValue)
    #expect(try messageContent(env.queue, env.observationMessageId) == Self.placeholder)
    #expect(try toolAuditRows(env).isEmpty)
  }
}
