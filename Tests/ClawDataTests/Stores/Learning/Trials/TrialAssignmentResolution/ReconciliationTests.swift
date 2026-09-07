import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

extension TrialAssignmentResolutionTests {
  @Test(arguments: LiveTrialStateDrift.allCases)
  func recomputeRejectsSameEpochLiveTrialStateDrift(_ drift: LiveTrialStateDrift) throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    try env.apply(drift)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when / then — omitting the current-state strict decode accepts same-epoch live drift.
    #expect {
      _ = try env.learning.recomputeAssignment(runId: sealed.runId, now: env.now)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
    #expect(try env.assignmentCacheSnapshot(runId: sealed.runId) == cacheBefore)
  }

  @Test(arguments: LiveTrialStateDrift.allCases)
  func reconcileRejectsSameEpochLiveTrialStateDrift(_ drift: LiveTrialStateDrift) throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let identity = try #require(try env.learning.liveTrialIdentities().first)
    try env.apply(drift)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when / then — omitting reconciliation's strict current-state decode accepts live drift.
    #expect {
      _ = try env.learning.reconcileTrial(identity, now: env.now)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
    #expect(try env.assignmentCacheSnapshot(runId: sealed.runId) == cacheBefore)
  }

  @Test func publicRecomputeDistinguishesMissingStaleAndFutureAssignments() throws {
    // given
    let missing = try trialEnvironment()
    let stale = try trialEnvironment()
    let staleRun = try stale.settledBoundRun()
    try stale.advanceJobEpoch()
    let future = try trialEnvironment()
    let futureRun = try future.settledBoundRun()
    try future.queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET learning_epoch = 0 WHERE job_id = ?",
        arguments: [future.jobId]
      )
    }

    // when / then
    #expect(
      try missing.learning.recomputeAssignment(runId: 999_999, now: missing.now) == .notAssigned
    )
    #expect(try stale.learning.recomputeAssignment(runId: staleRun, now: stale.now) == .stale)
    #expect {
      _ = try future.learning.recomputeAssignment(runId: futureRun, now: future.now)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
  }

  @Test func liveTrialIdentitiesAreStrictSortedAndRejectMultiplicity() throws {
    // given — insert the larger job first so row-id order differs from the public sort order.
    let env = try BoundRunEnvironment.make()
    let secondJob = try env.jobs.create(
      NewScheduledJob(
        ownerChatId: 777,
        label: "second trial",
        prompt: "Summarize the second archive",
        recurrence: nil,
        timezone: "Europe/Berlin",
        nextOccurrence: env.now
      ),
      now: env.now
    )
    let second = try env.installTrial(jobId: secondJob.id)
    let first = try env.installTrial(jobId: env.jobId)

    // when
    let identities = try env.learning.liveTrialIdentities()

    // then
    #expect(identities == [first, second])

    // given — v13 normally prevents this; removing the index exposes the defensive scan.
    try env.insertDuplicateLiveTrial(jobId: env.jobId)

    // when / then — choosing the first row would starve one live trial indefinitely.
    #expect {
      _ = try env.learning.liveTrialIdentities()
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
  }

  @Test func liveTrialIdentitiesRejectUnreadableAuthoritativeSource() throws {
    // given
    let env = try trialEnvironment()
    try env.queue.write { db in
      try db.execute(sql: "UPDATE learning_candidates SET base_revision = 99")
    }

    // when / then — validating only four scalar columns would enqueue this corrupt trial.
    #expect {
      _ = try env.learning.liveTrialIdentities()
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
  }

  @Test(arguments: TrialSnapshotCorruption.allCases)
  func trialSnapshotRejectsCountAndForeignAssignmentMismatch(
    _ corruption: TrialSnapshotCorruption
  ) throws {
    // given
    let env = try trialEnvironment()
    let runId = try env.settledBoundRun()
    let identity = try #require(try env.learning.liveTrialIdentities().first)
    try env.apply(corruption, runId: runId, trialId: identity.trialId)

    // when / then
    #expect {
      _ = try env.learning.reconcileTrial(identity, now: env.now)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
  }

  @Test func repeatedReconciliationPreservesResolvedTimestampAndReturnsStaleAfterEpochChange()
    throws
  {
    // given
    let env = try trialEnvironment()
    let evidence = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: evidence))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let identity = try #require(try env.learning.liveTrialIdentities().first)
    let resolvedAt = try env.assignment(runId: evidence.runId)?.resolvedAt

    // when
    let first = try env.learning.reconcileTrial(identity, now: env.now.addingTimeInterval(20))
    let second = try env.learning.reconcileTrial(identity, now: env.now.addingTimeInterval(40))

    // then — identical projection work writes neither a new timestamp nor another drain.
    guard
      case .reconciled(let firstPass) = first,
      case .reconciled(let secondPass) = second
    else {
      Issue.record("expected two live reconciliation results")
      return
    }
    #expect(firstPass.didDrain == false)
    #expect(secondPass.didDrain == false)
    #expect(try env.assignment(runId: evidence.runId)?.resolvedAt == resolvedAt)

    // when
    try env.advanceJobEpoch()

    // then
    #expect(try env.learning.reconcileTrial(identity, now: env.now) == .stale)
  }
}
