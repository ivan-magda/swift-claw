import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

/// Spec §1 done-when — the survival / expiry / `/stop`//`new` bullets. A pending approval survives a
/// process restart (buttons still resolve, a plain message still queues FIFO behind it, an expired
/// one sweeps to DENY→FAILED at boot), the expiry ticker resolves silence to EXPIRED→DENY, and
/// `/stop`//`new` resolve a parked approval with no orphan — including after a restart. Every clause
/// asserts on persisted rows only.
@Suite(.serialized) struct ApprovalDoneWhenTests {
  // MARK: - Fixture

  /// Models a `kill -TERM` + reboot: a fresh harness over the SAME DB file AND the same workspace
  /// disk, then boot reconciliation re-parks a waiter on every unexpired AWAITING_APPROVAL lane
  /// (§5.5/§7). The default script feeds the ONE continuation round-trip an approve-after-restart
  /// consumes; deny/expiry paths ignore it.
  private func restart(
    _ first: SC3Harness,
    scripts: [[ChatResponse]] = [[okResponse(content: "Saved the plan.")]]
  ) async throws -> SC3Harness {
    let harness = try makeSC3Harness(
      scripts: scripts,
      httpResponses: [:],
      databasePath: first.databasePath,
      workspaceRoot: first.workspaceRoot
    )
    await harness.runBootReconciliation()
    return harness
  }

  private func noOrphanPendingApproval(databasePath: String) throws -> Bool {
    try fetchApprovals(databasePath: databasePath).contains { row in
      row.state == ApprovalState.pending.rawValue
    } == false
  }

  private func armSessionPrivateData(databasePath: String, sessionId: Int64) throws {
    let pool = try ClawDatabase.makePool(path: databasePath)
    try pool.write { database in
      try database.execute(
        sql: "UPDATE sessions SET has_private_data = 1 WHERE id = ?",
        arguments: [sessionId]
      )
    }
  }

  // MARK: - Restart survival

  @Test func restartThenOwnerCallbackStillResolves() async throws {
    // given — a suspended approval, then a restart whose boot reconciliation re-parks the waiter
    let (first, approval) = try await suspendFileWrite()
    let restarted = try await restart(first)

    // when — the owner taps Approve on the RESTARTED process
    _ = await restarted.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 7, data: approveData(approval.nonce))
    )

    // then — the boot-parked waiter resumes: the recorded bytes land, run → DONE, row → APPROVED
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        FileManager.default.fileExists(atPath: approval.canonicalTarget)
      }
    )
    #expect(
      try String(contentsOfFile: approval.canonicalTarget, encoding: .utf8) == "hello fabric"
    )
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try runState(databasePath: restarted.databasePath, runId: approval.runId)
          == RunState.done.rawValue
      }
    )
    #expect(
      try fetchApprovals(databasePath: restarted.databasePath).map(\.state)
        == [ApprovalState.approved.rawValue]
    )
  }

  @Test func restartWhileASecondApprovalIsParkedDoesNotReplayTheFirst() async throws {
    // given — one run, two sequential ask-tier writes: approve #1, the resumed turn proposes #2
    // and parks again. Approval #1 is APPROVED with its observation filled; only #2 is unresolved.
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(
              id: "w1",
              name: "file_write",
              argumentsJSON: #"{"path":"notes/plan.md","content":"hello fabric"}"#
            )
          ]),
          toolCallResponse([
            ToolCall(
              id: "w2",
              name: "file_write",
              argumentsJSON: #"{"path":"notes/second.md","content":"second file"}"#
            )
          ]),
        ]
      ],
      httpResponses: [:]
    )
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write both"))
    let firstApproval = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(id: 2, from: 7, data: approveData(firstApproval.nonce))
    )
    let approvals = try #require(
      await pollUntil(timeout: .seconds(10)) {
        let rows = try fetchApprovals(databasePath: harness.databasePath)
        return rows.count == 2 ? rows : nil
      }
    )
    #expect(
      approvals.map(\.state)
        == [ApprovalState.approved.rawValue, ApprovalState.pending.rawValue]
    )
    let secondApproval = approvals[1]
    // The owner edits the first file while approval #2 sits parked across the restart.
    try Data("owner edited since".utf8).write(
      to: URL(fileURLWithPath: firstApproval.canonicalTarget)
    )

    // when — restart + boot reconciliation while #2 is parked
    let restarted = try await restart(
      harness,
      scripts: [[okResponse(content: "Both written.")]]
    )

    // then — boot must NOT replay resolved approval #1: the run stays parked for #2, and the
    // owner's edit survives (a replay would re-execute the recorded rename over it)
    #expect(
      try runState(databasePath: restarted.databasePath, runId: firstApproval.runId)
        == RunState.awaitingApproval.rawValue
    )
    #expect(
      try String(contentsOfFile: firstApproval.canonicalTarget, encoding: .utf8)
        == "owner edited since"
    )

    // when — the owner approves #2 on the restarted process
    _ = await restarted.router.handle(
      rawUpdate: callbackUpdate(id: 3, from: 7, data: approveData(secondApproval.nonce))
    )

    // then — #2 executes and the run completes (the old replay flipped the run RUNNING at boot,
    // which swallowed this approval as a duplicate and left the run stuck)
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        FileManager.default.fileExists(atPath: secondApproval.canonicalTarget)
      }
    )
    #expect(
      try String(contentsOfFile: secondApproval.canonicalTarget, encoding: .utf8) == "second file"
    )
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try runState(databasePath: restarted.databasePath, runId: firstApproval.runId)
          == RunState.done.rawValue
      }
    )
    #expect(
      try String(contentsOfFile: firstApproval.canonicalTarget, encoding: .utf8)
        == "owner edited since"
    )
    #expect(
      try fetchApprovals(databasePath: restarted.databasePath).map(\.state)
        == [ApprovalState.approved.rawValue, ApprovalState.approved.rawValue]
    )
  }

  @Test func restartThenPlainMessageQueuesFIFOBehindTheParkedApproval() async throws {
    // given — a suspended approval that survives a restart
    let (first, approval) = try await suspendFileWrite()
    let restarted = try await restart(first)

    // when — a plain message arrives while the approval is parked
    _ = await restarted.router.handle(
      rawUpdate: textUpdate(id: 2, from: 7, text: "are you there?")
    )

    // then — it QUEUES behind (§5.1 FIFO): it neither supersedes nor resolves the approval. The
    // suspended run stays AWAITING_APPROVAL, the row stays PENDING, and the plain message persists
    // as a second PENDING run parked behind the held lane. (Assert the resolved effect, not the
    // interleaving — testing-harness map §5.5.)
    let states = try #require(
      await pollUntil(timeout: .seconds(10)) {
        let observed = try runStates(databasePath: restarted.databasePath)
        return observed.count == 2 ? observed : nil
      }
    )
    #expect(states == [RunState.awaitingApproval.rawValue, RunState.pending.rawValue])
    #expect(
      try fetchApprovals(databasePath: restarted.databasePath).map(\.state)
        == [ApprovalState.pending.rawValue]
    )
    #expect(
      try runState(databasePath: restarted.databasePath, runId: approval.runId)
        == RunState.awaitingApproval.rawValue
    )
  }

  @Test func restartThenExpiredRowSweepsToDenyFailed() async throws {
    // given — the deadline has passed before the restart
    let (first, approval) = try await suspendFileWrite()
    try tamperApproval(
      databasePath: first.databasePath,
      id: approval.id,
      column: "expires_ts",
      value: Int64(1)  // epoch seconds — the store's on-disk timestamp encoding
    )

    // when — boot reconciliation runs on the restarted process
    let restarted = try await restart(first)

    // then — the expired PENDING row sweeps to EXPIRED → run FAILED, audited expired; no write
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: restarted.databasePath).first?.state
          == ApprovalState.expired.rawValue
      }
    )
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try runState(databasePath: restarted.databasePath, runId: approval.runId)
          == RunState.failed.rawValue
      }
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let audits = try restarted.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.expired.rawValue
      }
    )
  }

  // MARK: - Expiry ticker

  @Test func expiryTickerResolvesSilenceToExpiredThenDeny() async throws {
    // given — a suspended approval with a live parked waiter on the lane
    let (harness, approval) = try await suspendFileWrite()

    // when — the expiry ticker fires ONCE with a clock past the deadline (SchedulerService's
    // one-tick-then-throw shape: no real clock, no real sleep — testing-harness map §8)
    let ticker = ApprovalExpiryService(
      approvals: harness.stores.approvals,
      coordinator: harness.coordinator,
      now: { Date(timeIntervalSinceNow: 100_000) },
      clock: ScriptedClock { _ in throw CancellationError() },
      logger: TestLog.silent
    )
    try? await ticker.run()

    // then — the swept row resolves EXPIRED and the parked waiter fails the run (EXPIRED → DENY)
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first?.state
          == ApprovalState.expired.rawValue
      }
    )
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try runState(databasePath: harness.databasePath, runId: approval.runId)
          == RunState.failed.rawValue
      }
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let audits = try harness.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.expired.rawValue
      }
    )
  }

  // MARK: - /stop and /new resolution (no orphan)

  @Test func stopResolvesTheParkedApprovalWithNoOrphan() async throws {
    // given
    let (harness, approval) = try await suspendFileWrite()

    // when — /stop
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "/stop"))

    // then — approval → REJECTED (decision cancelled), run → CANCELLED, no orphan PENDING row,
    // no write
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first?.state
          == ApprovalState.rejected.rawValue
      }
    )
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try runState(databasePath: harness.databasePath, runId: approval.runId)
          == RunState.cancelled.rawValue
      }
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let audits = try harness.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.cancelled.rawValue
      }
    )
    #expect(try noOrphanPendingApproval(databasePath: harness.databasePath))
  }

  @Test func newResolvesTheParkedApprovalAndClearsPrivateData() async throws {
    // given — the persisted private-data flag armed (the §12 over-cap flag /new must clear)
    let (harness, approval) = try await suspendFileWrite()
    let sessionId = try harness.sessionId()
    try armSessionPrivateData(databasePath: harness.databasePath, sessionId: sessionId)

    // when — /new
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "/new"))

    // then — approval → REJECTED (decision superseded), run → SUPERSEDED, no orphan, flag cleared
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first?.state
          == ApprovalState.rejected.rawValue
      }
    )
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try runState(databasePath: harness.databasePath, runId: approval.runId)
          == RunState.superseded.rawValue
      }
    )
    #expect(
      try sessionFlags(databasePath: harness.databasePath, sessionId: sessionId).hasPrivateData
        == false
    )
    let audits = try harness.auditRows()
    #expect(
      audits.contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.superseded.rawValue
      }
    )
    #expect(try noOrphanPendingApproval(databasePath: harness.databasePath))
  }

  @Test func stopResolvesTheParkedApprovalAfterRestart() async throws {
    // given — a suspended approval that survives a restart (re-parked waiter is the live task)
    let (first, approval) = try await suspendFileWrite()
    let restarted = try await restart(first)

    // when — /stop on the RESTARTED process resolves through the boot-parked waiter
    _ = await restarted.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "/stop"))

    // then — identical to the pre-restart path: REJECTED (cancelled), run CANCELLED, no orphan
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: restarted.databasePath).first?.state
          == ApprovalState.rejected.rawValue
      }
    )
    _ = try #require(
      await pollUntilTrue(timeout: .seconds(10)) {
        try runState(databasePath: restarted.databasePath, runId: approval.runId)
          == RunState.cancelled.rawValue
      }
    )
    #expect(try noOrphanPendingApproval(databasePath: restarted.databasePath))
  }
}
