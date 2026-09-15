import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct TrialAssignmentResolutionTests {
  @Test
  func primarySettledUnevaluatedAssignmentsDrainAtLimitButDoNotFallback() throws {
    // given
    let env = try trialEnvironment()
    var runIDs: [Int64] = []
    for _ in 0..<TrialAdmissionPolicy.maximumAssignments {
      runIDs.append(try env.settledBoundRun())
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
    #expect(
      reconciliation.assignments.allSatisfy {
        $0.resolvedEvidence == nil
      }
    )
    #expect(try env.trialState(trialID: identity.trialID) == .draining)
    #expect(Set(runIDs) == Set(reconciliation.assignments.map(\.identity.runID)))
  }

  @Test
  func sealClaimAndPermanentFailureAdvanceExactStatesInTheirTransactions() throws {
    // given
    let env = try trialEnvironment()
    let runID = try env.settledBoundRun()
    #expect(try env.assignmentState(runID: runID) == .created)

    // when — sealing is settled but has no evaluator operation yet
    let sealed = try env.seal(runID: runID)

    // then
    #expect(try env.assignmentState(runID: runID) == .primaryRunSettled)

    // when — a claim creates the live resolution event
    let claim = try env.claim(env.evaluatorKey(for: sealed))

    // then
    #expect(try env.assignmentState(runID: runID) == .learningOutcomeUnresolved)

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
    #expect(try env.assignmentState(runID: runID) == .learningOutcomeResolved)
    let assignment = try #require(try env.assignment(runID: runID))
    #expect(assignment.state == .learningOutcomeResolved)
    #expect(assignment.resolvedEvidence?.outcome == .neutral)
    #expect(assignment.resolvedEvidence?.evaluationRequired == false)
  }

  @Test
  func evaluationCommitPersistsExactCurrentResolutionAtomically() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let claim = try env.startedOperation(env.evaluatorKey(for: sealed))

    // when
    let committed = try env.learning.finishOperation(
      env.result(for: claim.id, evaluation: env.verdict(outcome: .noIssue, issueCodes: [])),
      now: env.now.addingTimeInterval(1)
    )

    // then
    #expect(committed)
    let assignment = try #require(try env.assignment(runID: sealed.runID))
    #expect(assignment.state == .learningOutcomeResolved)
    #expect(assignment.resolvedEvidence?.outcome == .positive)
    #expect(assignment.resolvedEvidence?.evaluationDigest != nil)
    #expect(assignment.resolvedAt == env.now.addingTimeInterval(1))
  }

  @Test
  func feedbackBeforeEvaluationDoesNotCreateAFifthResolutionEvent() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let target = env.runFeedbackTarget(runID: sealed.runID, signal: .resultUseful)
    try TestLearningFixtures(writer: env.queue).seedTargets([target])

    // when
    let outcome = try env.learning.consumeAndAppendEvent(
      FeedbackTap(
        nonce: target.nonce,
        signal: .resultUseful,
        ownerUserID: target.ownerUserID,
        chatID: target.chatID,
        transportUpdateID: 1
      ),
      now: env.now.addingTimeInterval(1)
    )

    // then
    guard case .recorded = outcome else {
      Issue.record("expected recorded feedback")
      return
    }
    let assignment = try #require(try env.assignment(runID: sealed.runID))
    #expect(assignment.state == .primaryRunSettled)
    #expect(assignment.resolvedEvidence == nil)
  }

  @Test
  func terminallyIneligibleSealResolvesNeutralWithoutEvaluationDependency() throws {
    // given
    let env = try trialEnvironment()

    // when
    let sealed = try env.ineligibleSealedEvidence()

    // then
    let assignment = try #require(try env.assignment(runID: sealed.runID))
    #expect(assignment.state == .learningOutcomeResolved)
    #expect(assignment.resolvedEvidence?.outcome == .neutral)
    #expect(assignment.resolvedEvidence?.evaluationRequired == false)
  }

  @Test
  func tombstoneSealResolvesNeutralAndAlreadySealedRepairsLaggingCache() throws {
    // given
    let env = try trialEnvironment()
    let runID = try env.settledBoundRun()
    try env.queue.write { db in
      try db.execute(sql: "DELETE FROM run_compatibility WHERE run_id = ?", arguments: [runID])
    }

    // when — a missing frozen surface creates a terminal ineligible receipt.
    let first = try env.learning.sealEvidence(runID: runID, now: env.now)

    // then
    #expect(first == .excluded(.compatibilityUnavailable))
    #expect(try env.assignmentState(runID: runID) == .learningOutcomeResolved)
    #expect(try env.assignment(runID: runID)?.resolvedEvidence?.outcome == .neutral)

    // given — simulate the crash-era lag that the already-sealed branch must repair.
    try env.resetAssignmentCache(runID: runID, state: .created)

    // when
    let second = try env.learning.sealEvidence(runID: runID, now: env.now.addingTimeInterval(1))

    // then — returning early without the backstop leaves this cache permanently stale.
    #expect(second == .alreadySealed)
    #expect(try env.assignmentState(runID: runID) == .learningOutcomeResolved)
    #expect(try env.assignment(runID: runID)?.resolvedEvidence?.outcome == .neutral)
  }

  @Test
  func interruptedEvaluatorRemainsUnresolved() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    _ = try env.startedOperation(env.evaluatorKey(for: sealed))

    // when
    _ = try env.learning.reconcileOperationsAtBoot(now: env.now.addingTimeInterval(1))

    // then
    let assignment = try #require(try env.assignment(runID: sealed.runID))
    #expect(assignment.state == .learningOutcomeUnresolved)
    #expect(assignment.resolvedEvidence == nil)
  }

  @Test
  func bootProjectsClaimedAndStartedAttemptsAsUnresolvedAfterRecovery() throws {
    // given
    let claimed = try trialEnvironment()
    let claimedEvidence = try claimed.sealedTrialEvidence()
    _ = try claimed.claim(claimed.evaluatorKey(for: claimedEvidence))
    try claimed.resetAssignmentCache(runID: claimedEvidence.runID, state: .primaryRunSettled)

    let started = try trialEnvironment()
    let startedEvidence = try started.sealedTrialEvidence()
    _ = try started.startedOperation(started.evaluatorKey(for: startedEvidence))
    try started.resetAssignmentCache(runID: startedEvidence.runID, state: .primaryRunSettled)

    // when
    _ = try claimed.learning.reconcileOperationsAtBoot(now: claimed.now.addingTimeInterval(1))
    _ = try started.learning.reconcileOperationsAtBoot(now: started.now.addingTimeInterval(1))

    // then — pending and interrupted-unknown are distinct operation states but neither settles
    // learning quality as neutral.
    #expect(try claimed.assignmentState(runID: claimedEvidence.runID) == .learningOutcomeUnresolved)
    #expect(try started.assignmentState(runID: startedEvidence.runID) == .learningOutcomeUnresolved)
  }

  @Test
  func reclaimAndStartRepairTheirAssignmentInsideTheOperationTransaction() throws {
    // given — a boot-recovered claim is pending, while a fresh claim has not started its call.
    let reclaiming = try trialEnvironment()
    let reclaimedEvidence = try reclaiming.sealedTrialEvidence()
    let reclaimedKey = reclaiming.evaluatorKey(for: reclaimedEvidence)
    _ = try reclaiming.claim(reclaimedKey)
    _ = try reclaiming.learning.reconcileOperationsAtBoot(now: reclaiming.now)
    try reclaiming.resetAssignmentCache(runID: reclaimedEvidence.runID, state: .primaryRunSettled)

    let starting = try trialEnvironment()
    let startedEvidence = try starting.sealedTrialEvidence()
    let claim = try starting.claim(starting.evaluatorKey(for: startedEvidence))
    try starting.resetAssignmentCache(runID: startedEvidence.runID, state: .primaryRunSettled)

    // when
    _ = try reclaiming.claim(reclaimedKey)
    _ = try starting.learning.authorizeAndStartOperation(
      starting.authorization(for: claim),
      now: starting.now
    )

    // then — omitting either hook leaves its deliberately lagging cache at primary-settled.
    #expect(
      try reclaiming.assignmentState(runID: reclaimedEvidence.runID) == .learningOutcomeUnresolved
    )
    #expect(
      try starting.assignmentState(runID: startedEvidence.runID) == .learningOutcomeUnresolved
    )
  }

  @Test
  func terminalProviderFailureResolvesNeutralWithoutEvaluationDependency() throws {
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
    let assignment = try #require(try env.assignment(runID: evidence.runID))
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

struct AssignmentCacheSnapshot: Equatable { let values: [DatabaseValue] }

// MARK: - Assignment Reads

extension BoundRunEnvironment {
  func assignmentCacheSnapshot(runID: Int64) throws -> AssignmentCacheSnapshot {
    let columns = [
      "run_id",
      "trial_id",
      "job_id",
      "learning_epoch",
      "trial_generation",
      "assigned_at",
      "state",
      "outcome",
      "issue_codes",
      "evaluation_digest",
      "evaluation_required",
      "effective_feedback_revision",
      "resolved_at",
    ]
    return try queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM trial_assignments WHERE run_id = ?",
          arguments: [runID]
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
