import ClawCore
import ClawTestSupport
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

  @Test func lateUsageRemainsWritableUntilTheLaneFinalizer() throws {
    // given — a persisted interruption with a provider call still in flight
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()

    try env.seedDeferredCancellation(runId: runId)

    // when — the in-flight call returns
    let lateUsage = try env.runs.commitAssistantTurn(env.assistantTurn(runId: runId), now: env.now)

    // then — the usage survives without freezing evidence
    let receipt = try #require(try TestLearningFixtures(writer: env.queue).settlement(runId: runId))
    #expect(receipt.settledAt == nil)
    #expect(lateUsage == .usageRecordedAfterTerminal)

    // when — the lane finalizer runs
    let settled = try env.learning.settleFromLane(runId: runId, now: env.now)

    // then
    #expect(settled)
    #expect(try env.settledAt(runId: runId) == env.now)
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
    #expect(try TestLearningFixtures(writer: env.queue).settlement(runId: unboundRunId) == nil)
  }

  @Test func usageIsRefusedOnceTheRunIsSettled() throws {
    // given — a cancelled run whose lane tail already froze its evidence
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    try env.seedDeferredCancellation(runId: runId)
    _ = try env.learning.settleFromLane(runId: runId, now: env.now)

    // when — a straggling provider call tries to debit against frozen evidence
    let lateUsage = try env.runs.commitAssistantTurn(env.assistantTurn(runId: runId), now: env.now)

    // then
    #expect(lateUsage == .ignored)
    #expect(try env.usageRowCount(runId: runId) == 0)
  }

  @Test func bootReconciliationSettlesWhatACrashLeftUnsettled() throws {
    // given — a persisted interruption whose lane tail never ran before the process died
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    try env.seedDeferredCancellation(runId: runId)

    // when
    let bootedAt = env.now.addingTimeInterval(3_600)
    _ = try env.runs.reconcileRunsAtBoot(
      now: bootedAt,
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )

    // then — the crash backstop settles it without disturbing the cause the cancellation stored
    let receipt = try #require(try TestLearningFixtures(writer: env.queue).settlement(runId: runId))
    #expect(receipt.terminalCause == .ownerCancelled)
    #expect(receipt.settledAt == bootedAt)
  }

  @Test func theBackstopDatesADamagedReceiptByTheRunsOwnLastTransition() throws {
    // given — a bound run that ended hours ago and lost its receipt (damaged, or pre-receipt)
    let env = try BoundRunEnvironment.make()
    let runId = try env.runningBoundRun()
    let endedAt = env.now.addingTimeInterval(120)
    _ = try env.runs.commitAssistantTurn(env.assistantTurn(runId: runId), now: endedAt)
    try env.forgetReceipt(runId: runId)

    // when — the daemon restarts long afterwards
    let bootedAt = endedAt.addingTimeInterval(30 * 3_600)
    _ = try env.runs.reconcileRunsAtBoot(
      now: bootedAt,
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )

    // then — `unknown` is honest about the cause, but the instant must be the run's own, or every
    // restart would re-date a stale run into the evidence-age window
    let receipt = try #require(try TestLearningFixtures(writer: env.queue).settlement(runId: runId))
    #expect(receipt.terminalCause == .unknown)
    #expect(receipt.terminalAt == endedAt)
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
    let beforeResolution = try #require(
      try TestLearningFixtures(writer: env.queue).settlement(runId: claimed.runId)
    )
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
    #expect(try TestLearningFixtures(writer: env.queue).settlement(runId: parked.runId) == nil)
  }
}

// MARK: - Row Reads

private extension BoundRunEnvironment {
  /// Drops a terminal receipt the way a pre-receipt build or a damaged row leaves the table: the
  /// run is bound and terminal, but `run_settlements` has nothing for it.
  func forgetReceipt(runId: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "DELETE FROM run_settlements WHERE run_id = ?",
        arguments: [runId]
      )
    }
  }

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
