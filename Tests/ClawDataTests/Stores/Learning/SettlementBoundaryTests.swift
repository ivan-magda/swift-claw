import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

/// `settled_at` freezes a bound run's evidence, so it may only be written where a later primary
/// fact is impossible. Terminal and settled are separate invariants: merging them on the paths
/// below would either lose a late fact or admit one against frozen evidence.
@Suite struct SettlementBoundaryTests {
  @Test func aCompletedCommitSettlesWithItsTerminalRow() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()

    // when — every primary fact of a DONE turn commits in this one transaction
    let result = try env.runs.commitAssistantTurn(env.assistantTurn(runId: runId), now: env.now)

    // then
    #expect(result == .committed)
    #expect(try env.settledAt(runId: runId) == env.now)
  }

  @Test func aFailedCommitSettlesWithItsTerminalRow() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()

    // when
    let turn = env.degradedTurn(runId: runId, cause: .providerFailure)
    let result = try env.runs.commitDegradedTurn(turn, now: env.now)

    // then
    #expect(result == .committed)
    #expect(try env.settledAt(runId: runId) == env.now)
  }

  @Test func cancellationDefersSettlementUntilTheLaneFinalizer() throws {
    // given — a bound run with a provider call still in flight
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()

    // when — the owner cancels, then the in-flight call returns
    _ = try env.runs.cancelActiveRun(sessionId: env.sessionId, reason: .cancelled, now: env.now)
    let lateUsage = try env.runs.commitAssistantTurn(env.assistantTurn(runId: runId), now: env.now)

    // then — the cause is recorded and the usage survives, but the evidence is not frozen yet
    let receipt = try #require(try env.learning.settlement(runId: runId))
    #expect(receipt.terminalCause == .ownerCancelled)
    #expect(receipt.settledAt == nil)
    #expect(lateUsage == .usageRecordedAfterTerminal)

    // when — the lane finalizer runs
    let settled = try env.learning.settleFromLane(runId: runId, now: env.now)

    // then
    #expect(settled)
    #expect(try env.settledAt(runId: runId) == env.now)
  }

  @Test func supersessionDefersSettlementTheSameWay() throws {
    // given
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()

    // when — `/new` wins the state while the round is still in flight
    _ = try env.runs.supersedeSessionRuns(sessionId: env.sessionId, now: env.now)

    // then
    let receipt = try #require(try env.learning.settlement(runId: runId))
    #expect(receipt.terminalCause == .superseded)
    #expect(receipt.settledAt == nil)
  }

  @Test func settlingFromTheLaneIsIdempotentAndNeverInventsAReceipt() throws {
    // given — a run already settled by its own DONE commit, and an unbound run beside it
    let env = try BoundRunEnvironment.make()
    let doneRunId = try env.runningBoundRun()
    _ = try env.runs.commitAssistantTurn(env.assistantTurn(runId: doneRunId), now: env.now)
    let unboundRunId = try env.unboundRun()

    // when — the lane tail fires for both
    let resettled = try env.learning.settleFromLane(
      runId: doneRunId,
      now: env.now.addingTimeInterval(60)
    )
    let inventedForUnbound = try env.learning.settleFromLane(runId: unboundRunId, now: env.now)

    // then — the commit's own instant stands, and an unbound run stays out of the loop entirely
    #expect(resettled == false)
    #expect(inventedForUnbound == false)
    #expect(try env.settledAt(runId: doneRunId) == env.now)
    #expect(try env.learning.settlement(runId: unboundRunId) == nil)
  }

  @Test func usageIsRefusedOnceTheRunIsSettled() throws {
    // given — a cancelled run whose lane tail already froze its evidence
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    _ = try env.runs.cancelActiveRun(sessionId: env.sessionId, reason: .cancelled, now: env.now)
    _ = try env.learning.settleFromLane(runId: runId, now: env.now)

    // when — a straggling provider call tries to debit against frozen evidence
    let lateUsage = try env.runs.commitAssistantTurn(env.assistantTurn(runId: runId), now: env.now)

    // then
    #expect(lateUsage == .ignored)
    #expect(try env.usageRowCount(runId: runId) == 0)
  }

  @Test func bootReconciliationSettlesWhatACrashLeftUnsettled() throws {
    // given — a run cancelled by `/stop` whose lane tail never ran before the process died
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    _ = try env.runs.cancelActiveRun(sessionId: env.sessionId, reason: .cancelled, now: env.now)

    // when
    let bootedAt = env.now.addingTimeInterval(3_600)
    _ = try env.runs.reconcileRunsAtBoot(
      now: bootedAt,
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )

    // then — the crash backstop settles it without disturbing the cause the cancellation stored
    let receipt = try #require(try env.learning.settlement(runId: runId))
    #expect(receipt.terminalCause == .ownerCancelled)
    #expect(receipt.settledAt == bootedAt)
  }

  @Test func bootReconciliationLeavesTheApprovalCrashWindowUnsettled() throws {
    // given — an approved-and-claimed run whose placeholder observation is still unresolved
    let env = try BoundRunEnvironment.make()
    let claimed = try env.claimedApprovalCrashWindow()

    // when — the orphan sweep fails it, then the claimed-window settlement resolves the placeholder
    _ = try env.runs.reconcileRunsAtBoot(
      now: env.now,
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )
    let beforeResolution = try #require(try env.learning.settlement(runId: claimed.runId))
    _ = try env.runs.settleClaimedApprovalAtBoot(
      runId: claimed.runId,
      observationMessageId: claimed.observationMessageId,
      observationContent: "the action may have run",
      noticeChatId: 777,
      noticeText: "notice",
      now: env.now
    )

    // then — the placeholder was a primary fact still owed, so only its resolution may settle
    #expect(beforeResolution.settledAt == nil)
    #expect(try env.settledAt(runId: claimed.runId) == env.now)
  }

  @Test func bootReconciliationExcludesARunAReparkedLaneStillOwns() throws {
    // given — a bound run parked on an unexpired approval, which boot re-parks onto a live lane
    let env = try BoundRunEnvironment.make()
    let parked = try env.suspendedApproval()

    // when
    _ = try env.runs.reconcileRunsAtBoot(
      now: env.now,
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )

    // then — the run is still live, so nothing about it is terminal or frozen
    #expect(try env.learning.settlement(runId: parked.runId) == nil)
  }
}

// MARK: - Row Reads

private extension BoundRunEnvironment {
  func usageRowCount(runId: Int64) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM provider_usage WHERE run_id = ?",
        arguments: [runId]
      ) ?? -1
    }
  }
}
