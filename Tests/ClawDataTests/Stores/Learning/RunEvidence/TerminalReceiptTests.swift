import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

/// Every legal terminal transition of a bound run records why it ended, in the transaction that
/// won the state. The cause is always the one the commit carrier supplied — never reconstructed
/// from `RunState`, which cannot tell a task failure apart from a provider, policy or approval one.
@Suite struct TerminalReceiptTests {
  @Test func eachTerminalPathRecordsItsOwnCause() throws {
    // given
    let env = try BoundRunEnvironment.make()

    // when / then — one bound run per terminal path, each asserting its own cause
    #expect(try env.causeAfterCompletion() == .taskCompleted)
    #expect(try env.causeAfterDegradation(cause: .providerFailure) == .providerFailure)
    #expect(try env.causeAfterFailure(cause: .storageFailure) == .storageFailure)
    #expect(try env.causeAfterCancellation() == .ownerCancelled)
    #expect(try env.causeAfterSupersession() == .superseded)
    #expect(try env.causeAfterBootReconciliation() == .incomplete)
  }

  @Test func aTerminalReceiptRecordsTheWinningStateAndInstant() throws {
    // given — a bound run about to be cancelled at a known instant
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    let cancelledAt = env.now.addingTimeInterval(90)

    // when
    _ = try env.runs.cancelActiveRun(
      sessionId: env.sessionId,
      reason: .cancelled,
      now: cancelledAt
    )

    // then — the receipt names the state the transition won, not the state the run started in
    let receipt = try #require(try env.learning.settlement(runId: runId))
    #expect(receipt.runId == runId)
    #expect(receipt.winningState == .cancelled)
    #expect(receipt.terminalAt == cancelledAt)
  }

  @Test func anUnboundRunRecordsNoReceiptAtAll() throws {
    // given — a run created without a learning binding (a heartbeat, or a pre-upgrade run)
    let env = try BoundRunEnvironment.make()
    let runId = try env.unboundRun()

    // when
    try env.runs.failRun(runId: runId, cause: .providerFailure, now: env.now)

    // then
    #expect(try env.learning.settlement(runId: runId) == nil)
    #expect(try env.settlementRowCount() == 0)
  }

  @Test func aDisarmedDaemonWritesNoTerminalReceipt() throws {
    // given — CLAW_LEARNING_ENABLED unset, so the fire binds nothing
    let env = try BoundRunEnvironment.make(learningEnabled: false)
    let runId = try env.runningBoundRun()

    // when
    _ = try env.runs.commitAssistantTurn(env.assistantTurn(runId: runId), now: env.now)

    // then
    #expect(try env.settlementRowCount() == 0)
  }

  @Test func theApprovalCrashWindowKeepsTheCauseItsResolutionStored() throws {
    // given — a bound run whose approval was granted and claimed before the process died
    let env = try BoundRunEnvironment.make()
    let claimed = try env.claimedApprovalCrashWindow()

    // when — the boot sweep fails the orphan, then the claimed-window settlement resolves it
    _ = try env.runs.reconcileRunsAtBoot(
      now: env.now,
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )
    let afterReconcile = try #require(try env.learning.settlement(runId: claimed.runId))
    let outcome = try env.runs.settleClaimedApprovalAtBoot(
      runId: claimed.runId,
      observationMessageId: claimed.observationMessageId,
      observationContent: "the action may have run",
      noticeChatId: 777,
      noticeText: "notice",
      now: env.now
    )

    // then — the cause the reconciling transaction stored survives; nothing recomputes it
    #expect(outcome == .settled)
    #expect(afterReconcile.terminalCause == .approvalUnresolved)
    let receipt = try #require(try env.learning.settlement(runId: claimed.runId))
    #expect(receipt.terminalCause == .approvalUnresolved)
    #expect(receipt.winningState == .failed)
  }

  @Test func aDeniedApprovalRecordsItsOwnCauseRatherThanAPlainFailure() throws {
    // given — a bound run parked on an approval the owner is about to reject
    let env = try BoundRunEnvironment.make()
    let claimed = try env.suspendedApproval()

    // when
    let result = try env.runs.resolveDeniedObservation(
      runId: claimed.runId,
      observationMessageId: claimed.observationMessageId,
      content: "denied by owner",
      cancel: nil,
      now: env.now
    )

    // then — FAILED alone could not tell this apart from a provider outage
    #expect(result == .committed)
    let receipt = try #require(try env.learning.settlement(runId: claimed.runId))
    #expect(receipt.terminalCause == .approvalDenied)
  }
}

// MARK: - Terminal Paths

private extension BoundRunEnvironment {
  func causeAfterCompletion() throws -> TerminalCause? {
    let runId = try runningBoundRun()
    _ = try runs.commitAssistantTurn(assistantTurn(runId: runId), now: now)
    return try learning.settlement(runId: runId)?.terminalCause
  }

  func causeAfterDegradation(cause: TerminalCause) throws -> TerminalCause? {
    let runId = try runningBoundRun()
    _ = try runs.commitDegradedTurn(degradedTurn(runId: runId, cause: cause), now: now)
    return try learning.settlement(runId: runId)?.terminalCause
  }

  func causeAfterFailure(cause: TerminalCause) throws -> TerminalCause? {
    let runId = try runningBoundRun()
    try runs.failRun(runId: runId, cause: cause, now: now)
    return try learning.settlement(runId: runId)?.terminalCause
  }

  func causeAfterCancellation() throws -> TerminalCause? {
    let runId = try runningBoundRun()
    _ = try runs.cancelActiveRun(sessionId: sessionId, reason: .cancelled, now: now)
    return try learning.settlement(runId: runId)?.terminalCause
  }

  func causeAfterSupersession() throws -> TerminalCause? {
    let runId = try runningBoundRun()
    _ = try runs.supersedeSessionRuns(sessionId: sessionId, now: now)
    return try learning.settlement(runId: runId)?.terminalCause
  }

  func causeAfterBootReconciliation() throws -> TerminalCause? {
    let runId = try runningBoundRun()
    _ = try runs.reconcileRunsAtBoot(
      now: now,
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )
    return try learning.settlement(runId: runId)?.terminalCause
  }
}
