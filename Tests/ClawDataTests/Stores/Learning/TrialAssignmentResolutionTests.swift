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

  @Test(arguments: OperationProjectionFault.allCases)
  func operationProjectionFailureRollsBackEveryHookedLifecycleWrite(
    _ fault: OperationProjectionFault
  ) throws {
    // given
    let env = try trialEnvironment()
    let evidence = try env.sealedTrialEvidence()
    let key = env.evaluatorKey(for: evidence)
    let operation: ClaimedOperation?
    switch fault {
    case .claim:
      operation = nil
    case .start, .denial, .bootClaimed:
      operation = try env.claim(key)
    case .bootStarted:
      operation = try env.startedOperation(key)
    }
    try env.corruptAssignmentGeneration(runId: evidence.runId)

    // when / then
    #expect {
      switch fault {
      case .claim:
        _ = try env.learning.claimOperation(key, now: env.now)
      case .start:
        _ = try env.learning.authorizeAndStartOperation(
          env.authorization(for: try #require(operation)),
          now: env.now
        )
      case .denial:
        let claim = try #require(operation)
        _ = try env.learning.authorizeAndStartOperation(
          env.authorization(
            for: claim,
            carrier: CarrierAuthorization(
              sourceDigest: claim.key.sourceDigest,
              digest: CarrierDigest(rawValue: "denied"),
              isPermitted: false
            )
          ),
          now: env.now
        )
      case .bootClaimed, .bootStarted:
        _ = try env.learning.reconcileOperationsAtBoot(now: env.now)
      }
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }

    switch fault {
    case .claim:
      #expect(try env.countRows(in: "learning_operations") == 0)
    case .start, .denial, .bootClaimed:
      #expect(try env.operationState(try #require(operation).id) == .claimed)
    case .bootStarted:
      #expect(try env.operationState(try #require(operation).id) == .started)
    }
  }

  @Test(arguments: AssignmentIdentityCorruption.allCases)
  func recomputeRequiresTheFivePartAssignmentIdentity(
    _ corruption: AssignmentIdentityCorruption
  ) throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    try env.apply(corruption, runId: sealed.runId)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when / then — removing any binding or assignment identity predicate admits its own case.
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

  @Test(arguments: EvaluationCorruption.allCases)
  func succeededEvaluatorRequiresOneExactEvaluation(
    _ corruption: EvaluationCorruption
  ) throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let claim = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: claim.id), now: env.now)
    try env.apply(corruption, runId: sealed.runId)

    // when / then
    #expect {
      _ = try env.learning.recomputeAssignment(runId: sealed.runId, now: env.now)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
  }

  @Test(arguments: EvaluatorSourceCorruption.allCases)
  func evaluatorSourceRequiresOneConsistentOperationAndEvaluationState(
    _ corruption: EvaluatorSourceCorruption
  ) throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    try env.resetAssignmentCache(runId: sealed.runId, state: .primaryRunSettled)
    try env.apply(corruption, operationId: operation.id, runId: sealed.runId)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when / then — removing independent evaluation counting or state-shape validation admits
    // the matching impossible source combination.
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

  @Test func supersededEvaluatorAttemptMustBeInterrupted() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let first = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.reconcileOperationsAtBoot(now: env.now)
    let second = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: second.id), now: env.now)
    try env.resetAssignmentCache(runId: sealed.runId, state: .primaryRunSettled)
    try env.replaceInterruptedOperationWithFailed(first.id)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when / then — accepting a non-interrupted predecessor loses the retry lineage invariant.
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

  @Test(arguments: EvidenceReceiptCorruption.allCases)
  func evidenceReceiptCorruptionFailsBeforeAssignmentCacheRepair(
    _ corruption: EvidenceReceiptCorruption
  ) throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    try env.apply(corruption, runId: sealed.runId)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when / then — removing receipt shape, canonical-payload, or digest validation admits the
    // matching corruption through both public readers.
    #expect {
      _ = try env.learning.evidence(runId: sealed.runId)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }
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

  @Test func eligibleReceiptMayLoseItsPayloadAfterRetention() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    try env.removeEvidencePayload(runId: sealed.runId)

    // when
    let retained = try #require(try env.learning.evidence(runId: sealed.runId))
    let recomputed = try env.learning.recomputeAssignment(runId: sealed.runId, now: env.now)

    // then — requiring payload bytes for every eligible receipt breaks compact retention.
    #expect(retained.eligibility == .eligibleTaskEvidence)
    #expect(retained.payload == nil)
    guard case .unchanged(let assignment) = recomputed else {
      Issue.record("expected unchanged retained assignment")
      return
    }
    #expect(assignment.state == .primaryRunSettled)
  }

  @Test func relevantFeedbackRefreshesRevisionAndTimestampEvenWhenOutcomeStaysPositive() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let before = try #require(try env.assignment(runId: sealed.runId))
    let digest = try #require(before.resolvedEvidence?.evaluationDigest)
    let target = env.evaluationFeedbackTarget(
      digest: digest,
      signal: .evaluationConfirm
    )
    try env.learning.createTargets([target], chunks: [], now: env.now)
    let feedbackAt = env.now.addingTimeInterval(7)

    // when
    let result = try env.learning.consumeAndAppendEvent(
      env.feedbackTap(target, updateId: 11),
      now: feedbackAt
    )

    // then — owner confirmation changes provenance, even though positive remains positive.
    guard case .recorded = result else {
      Issue.record("expected recorded confirmation")
      return
    }
    let after = try #require(try env.assignment(runId: sealed.runId))
    #expect(after.resolvedEvidence?.outcome == .positive)
    #expect(after.resolvedEvidence?.ownerConfirmed == true)
    #expect(after.resolvedEvidence?.effectiveFeedbackRevision == FeedbackRevision(1))
    #expect(before.resolvedAt == env.now)
    #expect(after.resolvedAt == feedbackAt)
  }

  @Test func unrelatedFeedbackDoesNotRewriteAResolvedAssignmentCache() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let before = try env.assignmentCacheSnapshot(runId: sealed.runId)
    _ = try env.appendFeedback(
      subjectKind: .run,
      subjectDigest: "999999",
      signal: .resultUseful
    )

    // when
    let recomputed = try env.learning.recomputeAssignment(
      runId: sealed.runId,
      now: env.now.addingTimeInterval(20)
    )
    let after = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // then — a job-wide revision alone is not a reason to rewrite unrelated provenance.
    guard case .unchanged(let assignment) = recomputed else {
      Issue.record("expected unchanged assignment")
      return
    }
    #expect(after == before)
    #expect(assignment.resolvedEvidence?.effectiveFeedbackRevision == FeedbackRevision(0))
    #expect(try env.currentLearningState().feedbackRevision == FeedbackRevision(1))
  }

  @Test func assignmentCacheCannotNameAFutureFeedbackRevision() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    try env.setAssignmentFeedbackRevision(runId: sealed.runId, revision: 99)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when / then — removing the cached-revision upper bound manufactures future provenance.
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

  @Test func assignmentProjectionCannotConsumeAFutureFeedbackEvent() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    try env.recordRunFeedback(
      runId: sealed.runId,
      signal: .resultNotUseful,
      updateId: 18
    )
    try env.setCurrentFeedbackRevision(0)
    try env.resetAssignmentCache(runId: sealed.runId, state: .primaryRunSettled)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when / then — removing the source-revision upper bound consumes a future event.
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

  @Test func terminallyIneligibleEvidenceIgnoresResultFeedbackAsQualityEvidence() throws {
    // given
    let env = try trialEnvironment()
    let evidence = try env.ineligibleSealedEvidence()

    // when
    try env.recordRunFeedback(
      runId: evidence.runId,
      signal: .resultUseful,
      updateId: 12
    )

    // then — feedback cannot convert a technical exclusion into positive support.
    let assignment = try #require(try env.assignment(runId: evidence.runId))
    #expect(assignment.resolvedEvidence?.outcome == .neutral)
    #expect(assignment.resolvedEvidence?.evaluationRequired == false)
  }

  @Test func disputeWithdrawsOnlyEvaluationDependentSupport() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(
      env.result(
        for: operation.id,
        evaluation: env.verdict(outcome: .reusableIssue, issueCodes: ["wrong_fact"])
      ),
      now: env.now
    )
    let evaluated = try #require(try env.assignment(runId: sealed.runId))
    let digest = try #require(evaluated.resolvedEvidence?.evaluationDigest)
    let dispute = env.evaluationFeedbackTarget(digest: digest, signal: .evaluationDispute)
    let useful = env.runFeedbackTarget(runId: sealed.runId, signal: .resultUseful)
    try env.learning.createTargets([dispute, useful], chunks: [], now: env.now)

    // when — first remove evaluator support, then add independent run-result support.
    _ = try env.learning.consumeAndAppendEvent(
      env.feedbackTap(dispute, updateId: 13),
      now: env.now.addingTimeInterval(1)
    )
    let disputed = try #require(try env.assignment(runId: sealed.runId))
    _ = try env.learning.consumeAndAppendEvent(
      env.feedbackTap(useful, updateId: 14),
      now: env.now.addingTimeInterval(2)
    )

    // then
    #expect(disputed.resolvedEvidence?.outcome == .neutral)
    #expect(disputed.resolvedEvidence?.evaluationRequired == true)
    #expect(disputed.resolvedEvidence?.hardVetoes == [.ownerDependencyRejected])
    let independent = try #require(try env.assignment(runId: sealed.runId))
    #expect(independent.resolvedEvidence?.outcome == .positive)
    #expect(independent.resolvedEvidence?.evaluationRequired == false)
    #expect(independent.resolvedEvidence?.hardVetoes.isEmpty == true)
  }

  @Test func runCorrectionRecomputesInsideTheChallengeTransaction() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let target = env.runFeedbackTarget(runId: sealed.runId, signal: .resultCorrection)
    try env.learning.createTargets([target], chunks: [], now: env.now)
    let opened = try env.learning.consumeAndOpenChallenge(
      env.feedbackTap(target, updateId: 16),
      prompt: env.challengePrompt(target),
      now: env.now
    )
    guard case .challengeOpened(let challenge) = opened else {
      Issue.record("expected correction challenge")
      return
    }
    let correctedAt = env.now.addingTimeInterval(1)

    // when
    _ = try env.learning.consumeChallenge(
      id: challenge.id,
      payload: "Use the corrected source.",
      now: correctedAt
    )

    // then — appending only the event leaves the cached positive assignment unchanged.
    let assignment = try #require(try env.assignment(runId: sealed.runId))
    #expect(assignment.resolvedEvidence?.outcome == .negative)
    #expect(assignment.resolvedEvidence?.correctionEventDigest != nil)
    #expect(assignment.resolvedEvidence?.effectiveFeedbackRevision == FeedbackRevision(1))
    #expect(assignment.resolvedAt == correctedAt)
  }

  @Test func sameEpochLateResultRefreshesCacheWithoutReopeningTerminalTrial() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    let trial = try #require(try env.learning.openTrial(jobId: env.jobId))
    let reject = env.candidateFeedbackTarget(
      digest: trial.candidateDigest,
      signal: .candidateReject
    )
    try env.learning.createTargets([reject], chunks: [], now: env.now)
    _ = try env.learning.consumeAndAppendEvent(
      env.feedbackTap(reject, updateId: 15),
      now: env.now.addingTimeInterval(1)
    )
    let terminalState = try env.currentLearningState()
    #expect(try env.trialState(trialId: trial.trialId) == .fellBack)

    // when
    let finishedAt = env.now.addingTimeInterval(2)
    _ = try env.learning.finishOperation(
      env.result(for: operation.id),
      now: finishedAt
    )

    // then — the current-epoch product may repair history but cannot apply Task 17 transitions.
    let refreshed = try env.rawResolvedAssignment(runId: sealed.runId)
    #expect(refreshed.state == .learningOutcomeResolved)
    #expect(refreshed.outcome == .positive)
    #expect(refreshed.evaluationDigest == refreshed.sourceEvaluationDigest)
    #expect(refreshed.evaluationDigest != nil)
    #expect(refreshed.feedbackRevision == terminalState.feedbackRevision)
    #expect(refreshed.resolvedAt == finishedAt)
    #expect(try env.trialState(trialId: trial.trialId) == .fellBack)
    #expect(try env.currentLearningState() == terminalState)
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

  @Test func evidenceRecomputeFailureRollsBackReceiptVersionsAndCache() throws {
    // given
    let env = try trialEnvironment()
    let runId = try env.settledBoundRun()
    try env.corruptAssignmentGeneration(runId: runId)
    let versionsBefore = try env.sealingVersionSnapshot(runId: runId)

    // when
    #expect {
      _ = try env.learning.sealEvidence(runId: runId, now: env.now)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }

    // then — a post-commit hook would leave an authoritative receipt behind a rejected cache.
    #expect(try env.learning.evidence(runId: runId) == nil)
    #expect(try env.assignmentState(runId: runId) == .created)
    #expect(try env.sealingVersionSnapshot(runId: runId) == versionsBefore)
  }

  @Test func recomputeFailureRollsBackOperationUsageEvaluationAndCache() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    try env.corruptAssignmentGeneration(runId: sealed.runId)

    // when
    #expect {
      _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }

    // then — evaluation and spend cannot commit ahead of the exact assignment projection.
    #expect(try env.operationState(operation.id) == .started)
    #expect(try env.learningUsage(operationId: operation.id).isEmpty)
    #expect(try env.learning.evaluation(runId: sealed.runId) == nil)
    #expect(try env.assignmentState(runId: sealed.runId) == .learningOutcomeUnresolved)
  }

  @Test func feedbackRecomputeFailureRollsBackTargetRevisionEventAndCache() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let target = env.runFeedbackTarget(runId: sealed.runId, signal: .resultNotUseful)
    try env.learning.createTargets([target], chunks: [], now: env.now)
    try env.corruptAssignmentGeneration(runId: sealed.runId)
    let cacheBefore = try env.assignmentCacheSnapshot(runId: sealed.runId)

    // when
    #expect {
      _ = try env.learning.consumeAndAppendEvent(
        env.feedbackTap(target, updateId: 7),
        now: env.now.addingTimeInterval(1)
      )
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }

    // then — target consumption and owner history are in the same transaction as projection.
    #expect(try env.learning.feedbackTarget(nonce: target.nonce)?.consumedAt == nil)
    #expect(try env.currentLearningState().feedbackRevision == FeedbackRevision(0))
    #expect(try env.feedbackEventCount() == 0)
    #expect(try env.assignmentCacheSnapshot(runId: sealed.runId) == cacheBefore)
  }

  @Test func correctionRecomputeFailureRollsBackChallengeRevisionEventAndAudit() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let target = env.runFeedbackTarget(runId: sealed.runId, signal: .resultCorrection)
    try env.learning.createTargets([target], chunks: [], now: env.now)
    let opened = try env.learning.consumeAndOpenChallenge(
      env.feedbackTap(target, updateId: 8),
      prompt: env.challengePrompt(target),
      now: env.now
    )
    guard case .challengeOpened(let challenge) = opened else {
      Issue.record("expected correction challenge")
      return
    }
    let auditCount = try env.learningAuditCount()
    try env.corruptAssignmentGeneration(runId: sealed.runId)

    // when
    #expect {
      _ = try env.learning.consumeChallenge(
        id: challenge.id,
        payload: "Use the corrected source.",
        now: env.now.addingTimeInterval(1)
      )
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }

    // then — challenge payload, consumption, event, revision and audit roll back together.
    let live = try env.learning.liveChallenge(ownerUserId: 42, chatId: 777)
    #expect(live?.id == challenge.id)
    #expect(live?.consumedAt == nil)
    #expect(try env.currentLearningState().feedbackRevision == FeedbackRevision(0))
    #expect(try env.feedbackEventCount() == 0)
    #expect(try env.learningAuditCount() == auditCount)
  }

  @Test func evaluationAndFeedbackWritersConvergeInBothCommitOrders() throws {
    // given
    let evaluationFirst = try trialEnvironment()
    let firstEvidence = try evaluationFirst.sealedTrialEvidence()
    let firstOperation = try evaluationFirst.startedOperation(
      evaluationFirst.evaluatorKey(for: firstEvidence)
    )
    _ = try evaluationFirst.learning.finishOperation(
      evaluationFirst.result(for: firstOperation.id),
      now: evaluationFirst.now
    )
    try evaluationFirst.recordRunFeedback(
      runId: firstEvidence.runId,
      signal: .resultNotUseful,
      updateId: 9
    )

    let feedbackFirst = try trialEnvironment()
    let secondEvidence = try feedbackFirst.sealedTrialEvidence()
    try feedbackFirst.recordRunFeedback(
      runId: secondEvidence.runId,
      signal: .resultNotUseful,
      updateId: 10
    )
    let secondOperation = try feedbackFirst.startedOperation(
      feedbackFirst.evaluatorKey(for: secondEvidence)
    )

    // when
    _ = try feedbackFirst.learning.finishOperation(
      feedbackFirst.result(for: secondOperation.id),
      now: feedbackFirst.now
    )
    let first = try #require(try evaluationFirst.assignment(runId: firstEvidence.runId))
    let second = try #require(try feedbackFirst.assignment(runId: secondEvidence.runId))

    // then — projecting outside either writer makes the last commit order observable.
    #expect(first.resolvedEvidence?.outcome == .negative)
    #expect(second.resolvedEvidence?.outcome == .negative)
    #expect(first.resolvedEvidence?.issueCodes == second.resolvedEvidence?.issueCodes)
    #expect(
      first.resolvedEvidence?.evaluationRequired == second.resolvedEvidence?.evaluationRequired
    )
    #expect(first.resolvedEvidence?.effectiveFeedbackRevision == FeedbackRevision(1))
    #expect(second.resolvedEvidence?.effectiveFeedbackRevision == FeedbackRevision(1))
  }
}

// MARK: - Trial Fixture

private struct SealingVersionSnapshot: Equatable {
  let evidenceSchemaVersion: Int?
  let classifierVersion: String?
}

private struct AssignmentCacheSnapshot: Equatable {
  let values: [DatabaseValue]
}

private struct RawResolvedAssignment {
  let state: TrialAssignmentState
  let outcome: TrialOutcomeKind
  let evaluationDigest: EvaluationDigest?
  let sourceEvaluationDigest: EvaluationDigest?
  let feedbackRevision: FeedbackRevision
  let resolvedAt: Date
}

enum AssignmentIdentityCorruption: CaseIterable {
  case assignmentJob
  case assignmentEpoch
  case assignmentGeneration
  case bindingJob
  case bindingEpoch
  case bindingTrial
  case bindingGeneration
  case bindingStableDigest
  case bindingEffectiveDigest
}

enum LiveTrialStateDrift: CaseIterable {
  case stableDigest
  case stableRevision
}

enum EvaluationCorruption: CaseIterable {
  case missing
  case duplicate
  case digest
  case job
  case epoch
  case evidence
  case outcome
  case issueCodes
  case duplicateIssueCode
  case rubric
  case prompt
  case schema
  case compatibility
  case createdAt
}

enum EvidenceReceiptCorruption: CaseIterable {
  case ineligibleWithPayload
  case eligibleWithExclusion
  case exclusionWithWrongEligibility
  case unknownExclusion
  case payloadStorageClass
  case malformedPayload
  case noncanonicalPayload
  case payloadSchema
  case payloadDigest
  case compactDigest
}

enum EvaluatorSourceCorruption: CaseIterable {
  case orphanEvaluation
  case startedWithEvaluation
  case failedWithEvaluation
  case pendingFailure
  case claimedCallIdentity
  case startedMissingCarrier
  case startedMissingRoute
  case startedMissingProviderCall
  case startedNegativeTokens
  case startedNegativeCost
  case startedClosedReservation
  case succeededFailure
  case succeededMissingCarrier
  case succeededMissingRoute
  case succeededMissingProviderCall
  case succeededNonzeroTokens
  case succeededNonzeroCost
  case succeededMissingReservation
  case succeededOpenReservation
  case failedMissingFailure
  case failedWrongFailure
  case failedNoCallWrongFailure
  case failedNoCallCallIdentity
  case interruptedFailure
  case interruptedOpenReservation
  case unknownFailure
  case job
  case epoch
  case phase
  case sourceDigest
  case keyDigest
  case attemptGeneration
  case supersedes
}

enum TrialSnapshotCorruption: CaseIterable {
  case count
  case assignmentJob
}

enum OperationProjectionFault: CaseIterable {
  case claim
  case start
  case denial
  case bootClaimed
  case bootStarted
}

private func trialEnvironment() throws -> BoundRunEnvironment {
  let env = try BoundRunEnvironment.make()
  try env.installTrial()
  return env
}

extension BoundRunEnvironment {
  func installTrial() throws {
    _ = try installTrial(jobId: jobId)
  }

  @discardableResult
  func installTrial(jobId: Int64) throws -> LearningTrialIdentity {
    let state = try learning.armJob(jobId: jobId, now: now)
    let base = LessonSet.empty(jobId: jobId)
    let replacement = try LessonSet.canonical(
      jobId: jobId,
      lessons: ["Check the archive before answering"]
    )
    let manifest = CandidateSourceManifest(
      origin: .reflection,
      algorithm: .v1,
      jobId: jobId,
      epoch: state.epoch,
      triggerDigest: TriggerDigest(rawValue: SHA256Digest.hex("trial-trigger-\(jobId)")),
      triggerReason: .ownerCorrection,
      qualifyingIssueCodes: [],
      operationId: LearningOperationID(rawValue: "trial-fixture-operation"),
      carrierDigest: CarrierDigest(rawValue: SHA256Digest.hex("trial-carrier-\(jobId)")),
      resultDigest: ReflectionResultDigest(rawValue: SHA256Digest.hex("trial-result-\(jobId)")),
      baseDigest: base.digest,
      baseRevision: state.stableRevision,
      feedbackRevision: state.feedbackRevision,
      evidence: [],
      evaluations: [],
      feedback: [],
      predecessorCandidate: nil,
      predecessorFeedback: nil
    )
    let artifact = try CandidateArtifact(replacement: replacement, manifest: manifest)
    return try queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(db, artifact: artifact, now: now)
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, 1, ?, ?, ?, 3, 0, ?, ?, ?)
          """,
        arguments: [
          jobId,
          state.epoch.value,
          base.digest.rawValue,
          artifact.digest.rawValue,
          EpochSecondCodec.epoch(now),
          EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow)),
          EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.decisionWindow)),
          EpochSecondCodec.epoch(now),
          LearningTrialState.open.rawValue,
          LearningAlgorithm.v1.rawValue,
        ]
      )
      let trialId = db.lastInsertedRowID
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = ? WHERE job_id = ?",
        arguments: [trialId, jobId]
      )
      try ScheduledLearningStoreGRDB.insertDecision(
        db,
        kind: AdmissionReceipt.kind,
        jobId: jobId,
        epoch: state.epoch,
        inputs: AdmissionDecisionInputs(candidateDigest: artifact.digest),
        result: AdmissionReceipt(
          candidateDigest: artifact.digest,
          replacementDigest: replacement.digest,
          trialId: trialId,
          generation: 1
        ),
        algorithm: .v1,
        now: now
      )
      return LearningTrialIdentity(
        trialId: trialId,
        jobId: jobId,
        epoch: state.epoch,
        generation: 1
      )
    }
  }

  func seal(runId: Int64) throws -> SealedEvidence {
    _ = try learning.sealEvidence(runId: runId, now: now)
    return try #require(try learning.evidence(runId: runId))
  }

  func sealedTrialEvidence() throws -> SealedEvidence {
    try seal(runId: settledBoundRun())
  }

  func assignmentState(runId: Int64) throws -> TrialAssignmentState? {
    try queue.read { db in
      let raw = try String.fetchOne(
        db,
        sql: "SELECT state FROM trial_assignments WHERE run_id = ?",
        arguments: [runId]
      )
      return raw.flatMap(TrialAssignmentState.init(rawValue:))
    }
  }

  func assignment(runId: Int64) throws -> TrialAssignment? {
    switch try learning.recomputeAssignment(runId: runId, now: now) {
    case .notAssigned, .stale:
      return nil
    case .unchanged(let assignment), .updated(let assignment):
      return assignment
    }
  }

  func runFeedbackTarget(runId: Int64, signal: OwnerSignal) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: "run-\(runId)-\(signal.rawValue)",
      jobId: jobId,
      epoch: LearningEpoch(1),
      subjectKind: .run,
      subjectDigest: String(runId),
      allowedActions: [signal],
      ownerUserId: 42,
      chatId: 777,
      expiresAt: now.addingTimeInterval(3_600)
    )
  }

  func evaluationFeedbackTarget(
    digest: EvaluationDigest,
    signal: OwnerSignal
  ) -> NewFeedbackTarget {
    feedbackTarget(
      nonce: "evaluation-\(signal.rawValue)",
      kind: .evaluation,
      digest: digest.rawValue,
      signal: signal
    )
  }

  func candidateFeedbackTarget(
    digest: CandidateDigest,
    signal: OwnerSignal
  ) -> NewFeedbackTarget {
    feedbackTarget(
      nonce: "candidate-\(signal.rawValue)",
      kind: .candidate,
      digest: digest.rawValue,
      signal: signal
    )
  }

  func feedbackTap(_ target: NewFeedbackTarget, updateId: Int64) -> FeedbackTap {
    FeedbackTap(
      nonce: target.nonce,
      signal: target.allowedActions[0],
      ownerUserId: target.ownerUserId,
      chatId: target.chatId,
      transportUpdateId: updateId
    )
  }

  func challengePrompt(_ target: NewFeedbackTarget) -> [LearningNoticeChunk] {
    let payload = "Reply with the correction."
    return [
      LearningNoticeChunk(
        subjectDigest: FeedbackChallengeDeliveryIdentity.digest(targetNonce: target.nonce),
        ordinal: 0,
        chatId: target.chatId,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload)
      )
    ]
  }

  func recordRunFeedback(
    runId: Int64,
    signal: OwnerSignal,
    updateId: Int64
  ) throws {
    let target = runFeedbackTarget(runId: runId, signal: signal)
    try learning.createTargets([target], chunks: [], now: now)
    guard
      case .recorded = try learning.consumeAndAppendEvent(
        feedbackTap(target, updateId: updateId),
        now: now.addingTimeInterval(1)
      )
    else {
      throw StoreError.unexpected("fixture feedback was not recorded")
    }
  }

  func corruptAssignmentGeneration(runId: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql:
          "UPDATE trial_assignments SET trial_generation = trial_generation + 1 WHERE run_id = ?",
        arguments: [runId]
      )
    }
  }

  func resetAssignmentCache(
    runId: Int64,
    state: TrialAssignmentState
  ) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          UPDATE trial_assignments
          SET state = ?, outcome = NULL, issue_codes = NULL, evaluation_digest = NULL,
            evaluation_required = 1, effective_feedback_revision = NULL, resolved_at = NULL
          WHERE run_id = ?
          """,
        arguments: [state.rawValue, runId]
      )
    }
  }

  func setAssignmentFeedbackRevision(runId: Int64, revision: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          UPDATE trial_assignments SET effective_feedback_revision = ? WHERE run_id = ?
          """,
        arguments: [revision, runId]
      )
    }
  }

  func setCurrentFeedbackRevision(_ revision: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET feedback_revision = ? WHERE job_id = ?",
        arguments: [revision, jobId]
      )
    }
  }

  func apply(
    _ corruption: AssignmentIdentityCorruption,
    runId: Int64
  ) throws {
    if case .bindingJob = corruption {
      let otherJob = try jobs.create(
        NewScheduledJob(
          ownerChatId: 777,
          label: "foreign binding",
          prompt: "Read a different archive",
          recurrence: nil,
          timezone: "Europe/Berlin",
          nextOccurrence: now
        ),
        now: now
      )
      try queue.write { db in
        try db.execute(
          sql: """
            INSERT INTO lesson_sets(job_id, digest, schema_version, canonical_bytes, source,
              created_at)
            SELECT ?, lesson_sets.digest, lesson_sets.schema_version, lesson_sets.canonical_bytes,
              lesson_sets.source, lesson_sets.created_at
            FROM lesson_sets
            JOIN run_learning_bindings ON run_learning_bindings.effective_digest = lesson_sets.digest
              AND run_learning_bindings.job_id = lesson_sets.job_id
            WHERE run_learning_bindings.run_id = ?
            """,
          arguments: [otherJob.id, runId]
        )
        try db.execute(
          sql: "UPDATE run_learning_bindings SET job_id = ? WHERE run_id = ?",
          arguments: [otherJob.id, runId]
        )
      }
      return
    }
    let mutation: String
    switch corruption {
    case .assignmentJob:
      mutation = "UPDATE trial_assignments SET job_id = job_id + 1 WHERE run_id = ?"
    case .assignmentEpoch:
      mutation = "UPDATE trial_assignments SET learning_epoch = learning_epoch + 1 WHERE run_id = ?"
    case .assignmentGeneration:
      mutation =
        "UPDATE trial_assignments SET trial_generation = trial_generation + 1 WHERE run_id = ?"
    case .bindingJob:
      preconditionFailure("binding job corruption returns after creating its referenced job")
    case .bindingEpoch:
      mutation =
        "UPDATE run_learning_bindings SET learning_epoch = learning_epoch + 1 WHERE run_id = ?"
    case .bindingTrial:
      mutation = "UPDATE run_learning_bindings SET trial_id = trial_id + 1 WHERE run_id = ?"
    case .bindingGeneration:
      mutation =
        "UPDATE run_learning_bindings SET trial_generation = trial_generation + 1 WHERE run_id = ?"
    case .bindingStableDigest:
      mutation =
        "UPDATE run_learning_bindings SET stable_digest = effective_digest WHERE run_id = ?"
    case .bindingEffectiveDigest:
      mutation =
        "UPDATE run_learning_bindings SET effective_digest = stable_digest WHERE run_id = ?"
    }
    try queue.write { db in
      try db.execute(sql: mutation, arguments: [runId])
    }
  }

  func apply(_ drift: LiveTrialStateDrift) throws {
    try queue.write { db in
      switch drift {
      case .stableDigest:
        try db.execute(
          sql: """
            UPDATE job_learning_state
            SET stable_lesson_set_digest = (
              SELECT replacement_digest FROM learning_candidates WHERE job_id = ?
            )
            WHERE job_id = ?
            """,
          arguments: [jobId, jobId]
        )
      case .stableRevision:
        try db.execute(
          sql: """
            UPDATE job_learning_state SET stable_revision = stable_revision + 1 WHERE job_id = ?
            """,
          arguments: [jobId]
        )
      }
    }
  }

  func apply(
    _ corruption: EvaluationCorruption,
    runId: Int64
  ) throws {
    try queue.write { db in
      switch corruption {
      case .missing:
        try db.execute(
          sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
          arguments: [runId]
        )
      case .duplicate:
        try db.execute(
          sql: """
            INSERT INTO learning_evaluations(evaluation_digest, job_id, learning_epoch, run_id,
              evidence_digest, outcome, issue_codes, rubric_version, evaluator_prompt_version,
              evaluator_schema_version, compatibility_digest, created_at)
            SELECT ?, job_id, learning_epoch, run_id, evidence_digest, outcome, issue_codes,
              rubric_version, evaluator_prompt_version, evaluator_schema_version,
              compatibility_digest, created_at
            FROM learning_evaluations WHERE run_id = ?
            """,
          arguments: [String(repeating: "f", count: 64), runId]
        )
      case .digest:
        try updateEvaluation(
          db,
          runId: runId,
          column: "evaluation_digest",
          value: String(repeating: "f", count: 64)
        )
      case .job:
        try updateEvaluation(db, runId: runId, column: "job_id", value: 999)
      case .epoch:
        try updateEvaluation(db, runId: runId, column: "learning_epoch", value: 999)
      case .evidence:
        try updateEvaluation(
          db,
          runId: runId,
          column: "evidence_digest",
          value: String(repeating: "f", count: 64)
        )
      case .outcome:
        try updateEvaluation(db, runId: runId, column: "outcome", value: "unknown")
      case .issueCodes:
        try updateEvaluation(db, runId: runId, column: "issue_codes", value: "[\"z\",\"a\"]")
      case .duplicateIssueCode:
        try updateEvaluation(
          db,
          runId: runId,
          column: "issue_codes",
          value: "[\"duplicate\",\"duplicate\"]"
        )
      case .rubric:
        try updateEvaluation(db, runId: runId, column: "rubric_version", value: "999")
      case .prompt:
        try updateEvaluation(
          db,
          runId: runId,
          column: "evaluator_prompt_version",
          value: "999"
        )
      case .schema:
        try updateEvaluation(
          db,
          runId: runId,
          column: "evaluator_schema_version",
          value: "999"
        )
      case .compatibility:
        try updateEvaluation(
          db,
          runId: runId,
          column: "compatibility_digest",
          value: String(repeating: "f", count: 64)
        )
      case .createdAt:
        try db.execute(
          sql: "UPDATE learning_evaluations SET created_at = X'00' WHERE run_id = ?",
          arguments: [runId]
        )
      }
    }
  }

  func apply(
    _ corruption: EvidenceReceiptCorruption,
    runId: Int64
  ) throws {
    try queue.write { db in
      switch corruption {
      case .ineligibleWithPayload:
        try db.execute(
          sql: "UPDATE learning_evidence SET eligibility = ? WHERE run_id = ?",
          arguments: [LearningEligibility.transientInfrastructureFailure.rawValue, runId]
        )
      case .eligibleWithExclusion:
        try db.execute(
          sql: "UPDATE learning_evidence SET exclusion_reason = ? WHERE run_id = ?",
          arguments: [EvidenceExclusion.staleEpoch.rawValue, runId]
        )
      case .exclusionWithWrongEligibility:
        let eligibility = LearningEligibility.transientInfrastructureFailure
        let digest = SHA256Digest.hex(
          "\(EvidenceLimits.schemaVersion):\(runId):\(eligibility.rawValue)"
        )
        try db.execute(
          sql: """
            UPDATE learning_evidence
            SET payload = NULL, eligibility = ?, exclusion_reason = ?, evidence_digest = ?
            WHERE run_id = ?
            """,
          arguments: [eligibility.rawValue, EvidenceExclusion.staleEpoch.rawValue, digest, runId]
        )
      case .unknownExclusion:
        try db.execute(
          sql: "UPDATE learning_evidence SET exclusion_reason = ? WHERE run_id = ?",
          arguments: ["unknown", runId]
        )
      case .payloadStorageClass:
        try db.execute(
          sql: "UPDATE learning_evidence SET payload = ? WHERE run_id = ?",
          arguments: ["not-a-blob", runId]
        )
      case .malformedPayload:
        try replaceEvidencePayload(db, runId: runId, with: Data("{}".utf8))
      case .noncanonicalPayload:
        var bytes = try evidencePayloadBytes(db, runId: runId)
        bytes.append(0x20)
        try replaceEvidencePayload(db, runId: runId, with: bytes)
      case .payloadSchema:
        let bytes = try evidencePayloadBytes(db, runId: runId)
        guard
          let json = String(data: bytes, encoding: .utf8),
          json.contains(EvidenceLimits.schemaVersion)
        else {
          throw StoreError.unexpected("fixture evidence payload is unreadable")
        }
        let changed = json.replacingOccurrences(
          of: EvidenceLimits.schemaVersion,
          with: "evidence/v2"
        )
        try replaceEvidencePayload(db, runId: runId, with: Data(changed.utf8))
      case .payloadDigest:
        try db.execute(
          sql: "UPDATE learning_evidence SET evidence_digest = ? WHERE run_id = ?",
          arguments: [String(repeating: "f", count: 64), runId]
        )
      case .compactDigest:
        try db.execute(
          sql: """
            UPDATE learning_evidence
            SET payload = NULL, eligibility = ?, exclusion_reason = NULL
            WHERE run_id = ?
            """,
          arguments: [LearningEligibility.insufficientEvidence.rawValue, runId]
        )
      }
    }
  }

  func apply(
    _ corruption: EvaluatorSourceCorruption,
    operationId: LearningOperationID,
    runId: Int64
  ) throws {
    try queue.write { db in
      switch corruption {
      case .orphanEvaluation:
        try db.execute(
          sql: "DELETE FROM learning_operations WHERE operation_id = ?",
          arguments: [operationId.rawValue]
        )
      case .startedWithEvaluation:
        try updateOperation(
          db,
          id: operationId,
          assignments: [
            "state": LearningOperationState.started.rawValue,
            "reservation_state": LearningReservationState.open.rawValue,
            "reserved_tokens": 1,
            "reserved_cost_usd": 1.0,
          ]
        )
      case .failedWithEvaluation:
        try updateOperation(
          db,
          id: operationId,
          assignments: [
            "state": LearningOperationState.failed.rawValue,
            "failure_code": LearningOperationFailure.providerTerminal.rawValue,
          ]
        )
      case .pendingFailure:
        try makeNoCallOperation(
          db,
          id: operationId,
          runId: runId,
          state: .pending,
          failure: .budgetDenied,
          retainEvaluation: false
        )
      case .claimedCallIdentity:
        try db.execute(
          sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
          arguments: [runId]
        )
        try updateOperation(
          db,
          id: operationId,
          assignments: ["state": LearningOperationState.claimed.rawValue]
        )
      case .startedMissingCarrier:
        try db.execute(
          sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
          arguments: [runId]
        )
        try updateOperation(
          db,
          id: operationId,
          assignments: [
            "state": LearningOperationState.started.rawValue,
            "carrier_digest": nil,
            "reservation_state": LearningReservationState.open.rawValue,
          ]
        )
      case .startedMissingRoute:
        try makeStartedOperationCorruption(
          db,
          id: operationId,
          runId: runId,
          assignments: ["route": nil]
        )
      case .startedMissingProviderCall:
        try makeStartedOperationCorruption(
          db,
          id: operationId,
          runId: runId,
          assignments: ["provider_call_id": nil]
        )
      case .startedNegativeTokens:
        try makeStartedOperationCorruption(
          db,
          id: operationId,
          runId: runId,
          assignments: ["reserved_tokens": -1]
        )
      case .startedNegativeCost:
        try makeStartedOperationCorruption(
          db,
          id: operationId,
          runId: runId,
          assignments: ["reserved_cost_usd": -1.0]
        )
      case .startedClosedReservation:
        try db.execute(
          sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
          arguments: [runId]
        )
        try updateOperation(
          db,
          id: operationId,
          assignments: ["state": LearningOperationState.started.rawValue]
        )
      case .succeededFailure:
        try updateOperation(
          db,
          id: operationId,
          assignments: ["failure_code": LearningOperationFailure.providerTerminal.rawValue]
        )
      case .succeededMissingCarrier:
        try updateOperation(db, id: operationId, assignments: ["carrier_digest": nil])
      case .succeededMissingRoute:
        try updateOperation(db, id: operationId, assignments: ["route": nil])
      case .succeededMissingProviderCall:
        try updateOperation(db, id: operationId, assignments: ["provider_call_id": nil])
      case .succeededNonzeroTokens:
        try updateOperation(db, id: operationId, assignments: ["reserved_tokens": 1])
      case .succeededNonzeroCost:
        try updateOperation(db, id: operationId, assignments: ["reserved_cost_usd": 1.0])
      case .succeededMissingReservation:
        try updateOperation(db, id: operationId, assignments: ["reservation_state": nil])
      case .succeededOpenReservation:
        try updateOperation(
          db,
          id: operationId,
          assignments: ["reservation_state": LearningReservationState.open.rawValue]
        )
      case .failedMissingFailure:
        try db.execute(
          sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
          arguments: [runId]
        )
        try updateOperation(
          db,
          id: operationId,
          assignments: [
            "state": LearningOperationState.failed.rawValue,
            "failure_code": nil,
          ]
        )
      case .failedWrongFailure:
        try db.execute(
          sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
          arguments: [runId]
        )
        try updateOperation(
          db,
          id: operationId,
          assignments: [
            "state": LearningOperationState.failed.rawValue,
            "failure_code": LearningOperationFailure.budgetDenied.rawValue,
          ]
        )
      case .failedNoCallWrongFailure:
        try makeNoCallOperation(
          db,
          id: operationId,
          runId: runId,
          state: .failedNoCall,
          failure: .providerTerminal,
          retainEvaluation: false
        )
      case .failedNoCallCallIdentity:
        try db.execute(
          sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
          arguments: [runId]
        )
        try updateOperation(
          db,
          id: operationId,
          assignments: [
            "state": LearningOperationState.failedNoCall.rawValue,
            "failure_code": LearningOperationFailure.budgetDenied.rawValue,
          ]
        )
      case .interruptedFailure:
        try db.execute(
          sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
          arguments: [runId]
        )
        try updateOperation(
          db,
          id: operationId,
          assignments: [
            "state": LearningOperationState.interruptedUnknown.rawValue,
            "failure_code": LearningOperationFailure.providerTerminal.rawValue,
          ]
        )
      case .interruptedOpenReservation:
        try db.execute(
          sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
          arguments: [runId]
        )
        try updateOperation(
          db,
          id: operationId,
          assignments: [
            "state": LearningOperationState.interruptedUnknown.rawValue,
            "reservation_state": LearningReservationState.open.rawValue,
          ]
        )
      case .unknownFailure:
        try db.execute(
          sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
          arguments: [runId]
        )
        try updateOperation(
          db,
          id: operationId,
          assignments: [
            "state": LearningOperationState.failed.rawValue,
            "failure_code": "unknown",
          ]
        )
      case .job:
        try updateOperation(db, id: operationId, assignments: ["job_id": jobId + 1])
      case .epoch:
        try updateOperation(db, id: operationId, assignments: ["learning_epoch": 2])
      case .phase:
        try updateOperation(
          db,
          id: operationId,
          assignments: ["phase": LearningPhase.reflector.rawValue]
        )
      case .sourceDigest:
        try updateOperation(
          db,
          id: operationId,
          assignments: ["source_digest": String(repeating: "f", count: 64)]
        )
      case .keyDigest:
        try updateOperation(
          db,
          id: operationId,
          assignments: ["key_digest": String(repeating: "f", count: 64)]
        )
      case .attemptGeneration:
        try updateOperation(db, id: operationId, assignments: ["attempt_generation": 2])
      case .supersedes:
        try updateOperation(db, id: operationId, assignments: ["supersedes": operationId.rawValue])
      }
    }
  }

  func replaceInterruptedOperationWithFailed(_ id: LearningOperationID) throws {
    try queue.write { db in
      try updateOperation(
        db,
        id: id,
        assignments: [
          "state": LearningOperationState.failed.rawValue,
          "failure_code": LearningOperationFailure.providerTerminal.rawValue,
        ]
      )
    }
  }

  func removeEvidencePayload(runId: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE learning_evidence SET payload = NULL WHERE run_id = ?",
        arguments: [runId]
      )
    }
  }

  func apply(
    _ corruption: TrialSnapshotCorruption,
    runId: Int64,
    trialId: Int64
  ) throws {
    try queue.write { db in
      switch corruption {
      case .count:
        try db.execute(
          sql: "UPDATE learning_trials SET consumed_assignments = 2 WHERE trial_id = ?",
          arguments: [trialId]
        )
      case .assignmentJob:
        try db.execute(
          sql: "UPDATE trial_assignments SET job_id = job_id + 1 WHERE run_id = ?",
          arguments: [runId]
        )
      }
    }
  }

  func insertDuplicateLiveTrial(jobId: Int64) throws {
    try queue.write { db in
      try db.execute(sql: "DROP INDEX idx_learning_trials_live_job")
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, close_reason, algorithm)
          SELECT job_id, learning_epoch, base_digest, candidate_digest, generation + 1,
            admitted_at, assignment_deadline, decision_deadline, max_assignments, 0,
            cohort_cutoff, state, close_reason, algorithm
          FROM learning_trials WHERE job_id = ?
          """,
        arguments: [jobId]
      )
    }
  }

  func trialState(trialId: Int64) throws -> LearningTrialState? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM learning_trials WHERE trial_id = ?",
        arguments: [trialId]
      ).flatMap(LearningTrialState.init(rawValue:))
    }
  }

  fileprivate func sealingVersionSnapshot(runId: Int64) throws -> SealingVersionSnapshot {
    try queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT evidence_schema_version, classifier_version
            FROM run_compatibility WHERE run_id = ?
            """,
          arguments: [runId]
        )
      else {
        throw StoreError.unexpected("fixture compatibility is missing")
      }
      return SealingVersionSnapshot(
        evidenceSchemaVersion: row["evidence_schema_version"],
        classifierVersion: row["classifier_version"]
      )
    }
  }

  fileprivate func assignmentCacheSnapshot(runId: Int64) throws -> AssignmentCacheSnapshot {
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

  fileprivate func rawResolvedAssignment(runId: Int64) throws -> RawResolvedAssignment {
    try queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT assignment.state, assignment.outcome, assignment.evaluation_digest,
              assignment.effective_feedback_revision, assignment.resolved_at,
              evaluation.evaluation_digest AS source_evaluation_digest
            FROM trial_assignments AS assignment
            LEFT JOIN learning_evaluations AS evaluation ON evaluation.run_id = assignment.run_id
            WHERE assignment.run_id = ?
            """,
          arguments: [runId]
        ),
        let stateRaw = SQLiteStoredValue.string(in: row, column: "state"),
        let state = TrialAssignmentState(rawValue: stateRaw),
        let outcomeRaw = SQLiteStoredValue.string(in: row, column: "outcome"),
        let outcome = TrialOutcomeKind(rawValue: outcomeRaw),
        let evaluationRaw = SQLiteStoredValue.nullableString(
          in: row,
          column: "evaluation_digest"
        ),
        let sourceRaw = SQLiteStoredValue.nullableString(
          in: row,
          column: "source_evaluation_digest"
        ),
        let feedbackRaw = SQLiteStoredValue.int64(
          in: row,
          column: "effective_feedback_revision"
        ),
        feedbackRaw >= 0,
        let resolvedRaw = SQLiteStoredValue.int64(in: row, column: "resolved_at"),
        let resolvedAt = EpochSecondCodec.date(fromEpoch: resolvedRaw)
      else {
        throw StoreError.unexpected("fixture assignment cache is not resolved")
      }
      return RawResolvedAssignment(
        state: state,
        outcome: outcome,
        evaluationDigest: evaluationRaw.value.map(EvaluationDigest.init(rawValue:)),
        sourceEvaluationDigest: sourceRaw.value.map(EvaluationDigest.init(rawValue:)),
        feedbackRevision: FeedbackRevision(feedbackRaw),
        resolvedAt: resolvedAt
      )
    }
  }

  func feedbackEventCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feedback_events") ?? -1
    }
  }

  func learningAuditCount() throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM audit_events WHERE action = ?",
        arguments: [AuditAction.learningFeedback.rawValue]
      ) ?? -1
    }
  }

  private func feedbackTarget(
    nonce: String,
    kind: FeedbackSubjectKind,
    digest: String,
    signal: OwnerSignal
  ) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: nonce,
      jobId: jobId,
      epoch: LearningEpoch(1),
      subjectKind: kind,
      subjectDigest: digest,
      allowedActions: [signal],
      ownerUserId: 42,
      chatId: 777,
      expiresAt: now.addingTimeInterval(3_600)
    )
  }

  private func updateEvaluation(
    _ db: Database,
    runId: Int64,
    column: String,
    value: (any DatabaseValueConvertible)?
  ) throws {
    try db.execute(
      sql: "UPDATE learning_evaluations SET \(column) = ? WHERE run_id = ?",
      arguments: [value, runId]
    )
  }

  private func evidencePayloadBytes(_ db: Database, runId: Int64) throws -> Data {
    guard
      let bytes = try Data.fetchOne(
        db,
        sql: "SELECT payload FROM learning_evidence WHERE run_id = ?",
        arguments: [runId]
      )
    else {
      throw StoreError.unexpected("fixture evidence payload is missing")
    }
    return bytes
  }

  private func replaceEvidencePayload(
    _ db: Database,
    runId: Int64,
    with bytes: Data
  ) throws {
    try db.execute(
      sql: "UPDATE learning_evidence SET payload = ?, evidence_digest = ? WHERE run_id = ?",
      arguments: [bytes, SHA256Digest.hex(bytes), runId]
    )
  }

  private func makeNoCallOperation(
    _ db: Database,
    id: LearningOperationID,
    runId: Int64,
    state: LearningOperationState,
    failure: LearningOperationFailure,
    retainEvaluation: Bool
  ) throws {
    if retainEvaluation == false {
      try db.execute(
        sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
        arguments: [runId]
      )
    }
    try updateOperation(
      db,
      id: id,
      assignments: [
        "state": state.rawValue,
        "failure_code": failure.rawValue,
        "carrier_digest": nil,
        "route": nil,
        "provider_call_id": nil,
        "reserved_tokens": 0,
        "reserved_cost_usd": 0.0,
        "reservation_state": LearningReservationState.closed.rawValue,
      ]
    )
  }

  private func makeStartedOperationCorruption(
    _ db: Database,
    id: LearningOperationID,
    runId: Int64,
    assignments: [String: (any DatabaseValueConvertible)?]
  ) throws {
    try db.execute(
      sql: "DELETE FROM learning_evaluations WHERE run_id = ?",
      arguments: [runId]
    )
    var source = assignments
    source["state"] = LearningOperationState.started.rawValue
    source["reservation_state"] =
      source["reservation_state"] ?? LearningReservationState.open.rawValue
    try updateOperation(db, id: id, assignments: source)
  }

  private func updateOperation(
    _ db: Database,
    id: LearningOperationID,
    assignments: [String: (any DatabaseValueConvertible)?]
  ) throws {
    let ordered = assignments.sorted { left, right in
      left.key < right.key
    }
    let columns = ordered.map { assignment in
      "\(assignment.key) = ?"
    }.joined(separator: ", ")
    var arguments = StatementArguments(ordered.map(\.value))
    arguments += [id.rawValue]
    try db.execute(
      sql: "UPDATE learning_operations SET \(columns) WHERE operation_id = ?",
      arguments: arguments
    )
  }
}
