import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct TrialAssignmentResolutionTests {
  @Test func primarySettledUnevaluatedAssignmentsDrainAtLimitButDoNotFallback() throws {
    // given
    let env = try trialEnvironment()
    var runIds: [Int64] = []
    for _ in 0..<TrialAdmissionPolicy.maximumAssignments {
      runIds.append(try env.settledBoundRun())
    }
    let identity = try #require(try env.learning.liveTrialIdentities().first)

    // when
    let result = try env.learning.reconcileTrial(identity, now: env.now)

    // then — primary settlement is not a learning outcome and cannot become neutral support.
    guard case .reconciled(let reconciliation) = result else {
      Issue.record("expected live reconciliation")
      return
    }
    #expect(reconciliation.decision == .wait)
    #expect(reconciliation.didDrain == false)
    #expect(
      reconciliation.assignments.map(\.state) == Array(repeating: .primaryRunSettled, count: 3)
    )
    #expect(reconciliation.assignments.allSatisfy { $0.resolvedEvidence == nil })
    #expect(try env.trialState(trialId: identity.trialId) == .draining)
    #expect(Set(runIds) == Set(reconciliation.assignments.map(\.identity.runId)))
  }

  @Test func sealClaimAndPermanentFailureAdvanceExactStatesInTheirTransactions() throws {
    // given
    let env = try trialEnvironment()
    let runId = try env.settledBoundRun()
    #expect(try env.assignmentState(runId: runId) == .created)

    // when — sealing is settled but has no evaluator operation yet
    let sealed = try env.seal(runId: runId)

    // then
    #expect(try env.assignmentState(runId: runId) == .primaryRunSettled)

    // when — a claim creates the live resolution event
    let claim = try env.claim(env.evaluatorKey(for: sealed))

    // then
    #expect(try env.assignmentState(runId: runId) == .learningOutcomeUnresolved)

    // when — privacy permanently refuses that evaluator call
    let denied = env.authorization(
      for: claim,
      carrier: CarrierAuthorization(
        sourceDigest: claim.key.sourceDigest,
        digest: CarrierDigest(rawValue: "denied"),
        isPermitted: false
      )
    )
    #expect(try env.learning.authorizeAndStartOperation(denied, now: env.now) != .superseded)

    // then
    #expect(try env.assignmentState(runId: runId) == .learningOutcomeResolved)
    let assignment = try #require(try env.assignment(runId: runId))
    #expect(assignment.state == .learningOutcomeResolved)
    #expect(assignment.resolvedEvidence?.outcome == .neutral)
    #expect(assignment.resolvedEvidence?.evaluationRequired == false)
  }

  @Test func evaluationCommitPersistsExactCurrentResolutionAtomically() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let claim = try env.startedOperation(env.evaluatorKey(for: sealed))

    // when
    let committed = try env.learning.finishOperation(
      env.result(
        for: claim.id,
        evaluation: env.verdict(outcome: .noIssue, issueCodes: [])
      ),
      now: env.now.addingTimeInterval(1)
    )

    // then
    #expect(committed)
    let assignment = try #require(try env.assignment(runId: sealed.runId))
    #expect(assignment.state == .learningOutcomeResolved)
    #expect(assignment.resolvedEvidence?.outcome == .positive)
    #expect(assignment.resolvedEvidence?.evaluationDigest != nil)
    #expect(assignment.resolvedAt == env.now.addingTimeInterval(1))
  }

  @Test func feedbackBeforeEvaluationDoesNotCreateAFifthResolutionEvent() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let target = env.runFeedbackTarget(runId: sealed.runId, signal: .resultUseful)
    try env.learning.createTargets([target], chunks: [], now: env.now)

    // when
    let outcome = try env.learning.consumeAndAppendEvent(
      FeedbackTap(
        nonce: target.nonce,
        signal: .resultUseful,
        ownerUserId: target.ownerUserId,
        chatId: target.chatId,
        transportUpdateId: 1
      ),
      now: env.now.addingTimeInterval(1)
    )

    // then
    guard case .recorded = outcome else {
      Issue.record("expected recorded feedback")
      return
    }
    let assignment = try #require(try env.assignment(runId: sealed.runId))
    #expect(assignment.state == .primaryRunSettled)
    #expect(assignment.resolvedEvidence == nil)
  }

  @Test func terminallyIneligibleSealResolvesNeutralWithoutEvaluationDependency() throws {
    // given
    let env = try trialEnvironment()

    // when
    let sealed = try env.ineligibleSealedEvidence()

    // then
    let assignment = try #require(try env.assignment(runId: sealed.runId))
    #expect(assignment.state == .learningOutcomeResolved)
    #expect(assignment.resolvedEvidence?.outcome == .neutral)
    #expect(assignment.resolvedEvidence?.evaluationRequired == false)
  }

  @Test func tombstoneSealResolvesNeutralAndAlreadySealedRepairsLaggingCache() throws {
    // given
    let env = try trialEnvironment()
    let runId = try env.settledBoundRun()
    try env.queue.write { db in
      try db.execute(
        sql: "DELETE FROM run_compatibility WHERE run_id = ?",
        arguments: [runId]
      )
    }

    // when — a missing frozen surface creates a terminal ineligible receipt.
    let first = try env.learning.sealEvidence(runId: runId, now: env.now)

    // then
    #expect(first == .excluded(.compatibilityUnavailable))
    #expect(try env.assignmentState(runId: runId) == .learningOutcomeResolved)
    #expect(try env.assignment(runId: runId)?.resolvedEvidence?.outcome == .neutral)

    // given — simulate the crash-era lag that the already-sealed branch must repair.
    try env.resetAssignmentCache(runId: runId, state: .created)

    // when
    let second = try env.learning.sealEvidence(
      runId: runId,
      now: env.now.addingTimeInterval(1)
    )

    // then — returning early without the backstop leaves this cache permanently stale.
    #expect(second == .alreadySealed)
    #expect(try env.assignmentState(runId: runId) == .learningOutcomeResolved)
    #expect(try env.assignment(runId: runId)?.resolvedEvidence?.outcome == .neutral)
  }

  @Test func interruptedEvaluatorRemainsUnresolved() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    _ = try env.startedOperation(env.evaluatorKey(for: sealed))

    // when
    _ = try env.learning.reconcileOperationsAtBoot(now: env.now.addingTimeInterval(1))

    // then
    let assignment = try #require(try env.assignment(runId: sealed.runId))
    #expect(assignment.state == .learningOutcomeUnresolved)
    #expect(assignment.resolvedEvidence == nil)
  }

  @Test func bootProjectsClaimedAndStartedAttemptsAsUnresolvedAfterRecovery() throws {
    // given
    let claimed = try trialEnvironment()
    let claimedEvidence = try claimed.sealedTrialEvidence()
    _ = try claimed.claim(claimed.evaluatorKey(for: claimedEvidence))
    try claimed.resetAssignmentCache(runId: claimedEvidence.runId, state: .primaryRunSettled)

    let started = try trialEnvironment()
    let startedEvidence = try started.sealedTrialEvidence()
    _ = try started.startedOperation(started.evaluatorKey(for: startedEvidence))
    try started.resetAssignmentCache(runId: startedEvidence.runId, state: .primaryRunSettled)

    // when
    _ = try claimed.learning.reconcileOperationsAtBoot(now: claimed.now.addingTimeInterval(1))
    _ = try started.learning.reconcileOperationsAtBoot(now: started.now.addingTimeInterval(1))

    // then — pending and interrupted-unknown are distinct operation states but neither settles
    // learning quality as neutral.
    #expect(try claimed.assignmentState(runId: claimedEvidence.runId) == .learningOutcomeUnresolved)
    #expect(try started.assignmentState(runId: startedEvidence.runId) == .learningOutcomeUnresolved)
  }

  @Test func reclaimAndStartRepairTheirAssignmentInsideTheOperationTransaction() throws {
    // given — a boot-recovered claim is pending, while a fresh claim has not started its call.
    let reclaiming = try trialEnvironment()
    let reclaimedEvidence = try reclaiming.sealedTrialEvidence()
    let reclaimedKey = reclaiming.evaluatorKey(for: reclaimedEvidence)
    _ = try reclaiming.claim(reclaimedKey)
    _ = try reclaiming.learning.reconcileOperationsAtBoot(now: reclaiming.now)
    try reclaiming.resetAssignmentCache(
      runId: reclaimedEvidence.runId,
      state: .primaryRunSettled
    )

    let starting = try trialEnvironment()
    let startedEvidence = try starting.sealedTrialEvidence()
    let claim = try starting.claim(starting.evaluatorKey(for: startedEvidence))
    try starting.resetAssignmentCache(runId: startedEvidence.runId, state: .primaryRunSettled)

    // when
    _ = try reclaiming.claim(reclaimedKey)
    _ = try starting.learning.authorizeAndStartOperation(
      starting.authorization(for: claim),
      now: starting.now
    )

    // then — omitting either hook leaves its deliberately lagging cache at primary-settled.
    #expect(
      try reclaiming.assignmentState(runId: reclaimedEvidence.runId)
        == .learningOutcomeUnresolved
    )
    #expect(
      try starting.assignmentState(runId: startedEvidence.runId)
        == .learningOutcomeUnresolved
    )
  }

  @Test func terminalProviderFailureResolvesNeutralWithoutEvaluationDependency() throws {
    // given
    let env = try trialEnvironment()
    let evidence = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: evidence))

    // when
    _ = try env.learning.finishOperation(
      env.result(for: operation.id, failure: .providerTerminal),
      now: env.now.addingTimeInterval(1)
    )

    // then — permanent failure closes learning quality without fabricating an evaluator verdict.
    let assignment = try #require(try env.assignment(runId: evidence.runId))
    #expect(assignment.resolvedEvidence?.outcome == .neutral)
    #expect(assignment.resolvedEvidence?.evaluationDigest == nil)
    #expect(assignment.resolvedEvidence?.evaluationRequired == false)
  }

  func trialEnvironment() throws -> BoundRunEnvironment {
    let env = try BoundRunEnvironment.make()
    try env.installTrial()
    return env
  }
}

struct AssignmentCacheSnapshot: Equatable {
  let values: [DatabaseValue]
}

// MARK: - Assignment Reads

extension BoundRunEnvironment {
  func assignmentCacheSnapshot(runId: Int64) throws -> AssignmentCacheSnapshot {
    let columns = [
      "run_id", "trial_id", "job_id", "learning_epoch", "trial_generation", "assigned_at",
      "state", "outcome", "issue_codes", "evaluation_digest", "evaluation_required",
      "effective_feedback_revision", "resolved_at",
    ]
    return try queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM trial_assignments WHERE run_id = ?",
          arguments: [runId]
        )
      else {
        throw StoreError.unexpected("fixture assignment is missing")
      }
      return AssignmentCacheSnapshot(
        values: columns.map { column in
          row[column] as DatabaseValue
        }
      )
    }
  }
}
