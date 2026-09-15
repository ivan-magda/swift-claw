import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

extension TrialAssignmentResolutionTests {
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
    case .claim: operation = nil
    case .start, .denial, .bootClaimed: operation = try env.claim(key)
    case .bootStarted: operation = try env.startedOperation(key)
    }
    try env.corruptAssignmentGeneration(runID: evidence.runID)

    // when / then
    #expect {
      switch fault {
      case .claim: _ = try env.learning.claimOperation(key, now: env.now)
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
      case .bootClaimed, .bootStarted: _ = try env.learning.reconcileOperationsAtBoot(now: env.now)
      }
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }

    switch fault {
    case .claim: #expect(try env.countRows(in: "learning_operations") == 0)
    case .start, .denial, .bootClaimed:
      #expect(try env.operationState(try #require(operation).id) == .claimed)
    case .bootStarted: #expect(try env.operationState(try #require(operation).id) == .started)
    }
  }

  @Test
  func evidenceRecomputeFailureRollsBackReceiptVersionsAndCache() throws {
    // given
    let env = try trialEnvironment()
    let runID = try env.settledBoundRun()
    try env.corruptAssignmentGeneration(runID: runID)
    let versionsBefore = try env.sealingVersionSnapshot(runID: runID)

    // when
    #expect {
      _ = try env.learning.sealEvidence(runID: runID, now: env.now)
    } throws: { error in
      guard case StoreError.unexpected = error else {
        return false
      }
      return true
    }

    // then — a post-commit hook would leave an authoritative receipt behind a rejected cache.
    #expect(try env.learning.evidence(runID: runID) == nil)
    #expect(try env.assignmentState(runID: runID) == .created)
    #expect(try env.sealingVersionSnapshot(runID: runID) == versionsBefore)
  }

  @Test
  func recomputeFailureRollsBackOperationUsageEvaluationAndCache() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    try env.corruptAssignmentGeneration(runID: sealed.runID)

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
    #expect(try env.learningUsage(operationID: operation.id).isEmpty)
    #expect(try env.learning.evaluation(runID: sealed.runID) == nil)
    #expect(try env.assignmentState(runID: sealed.runID) == .learningOutcomeUnresolved)
  }

  @Test
  func feedbackRecomputeFailureRollsBackTargetRevisionEventAndCache() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let target = env.runFeedbackTarget(runID: sealed.runID, signal: .resultNotUseful)
    try TestLearningFixtures(writer: env.queue).seedTargets([target])
    try env.corruptAssignmentGeneration(runID: sealed.runID)
    let cacheBefore = try env.assignmentCacheSnapshot(runID: sealed.runID)

    // when
    #expect {
      _ = try env.learning.consumeAndAppendEvent(
        env.feedbackTap(target, updateID: 7),
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
    #expect(try env.assignmentCacheSnapshot(runID: sealed.runID) == cacheBefore)
  }

  @Test
  func correctionRecomputeFailureRollsBackChallengeRevisionEventAndAudit() throws {
    // given
    let env = try trialEnvironment()
    let sealed = try env.sealedTrialEvidence()
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(env.result(for: operation.id), now: env.now)
    let target = env.runFeedbackTarget(runID: sealed.runID, signal: .resultCorrection)
    try TestLearningFixtures(writer: env.queue).seedTargets([target])
    let opened = try env.learning.consumeAndOpenChallenge(
      env.feedbackTap(target, updateID: 8),
      prompt: env.challengePrompt(target),
      now: env.now
    )
    guard case .challengeOpened(let challenge) = opened else {
      Issue.record("expected correction challenge")
      return
    }
    let auditCount = try env.learningAuditCount()
    try env.corruptAssignmentGeneration(runID: sealed.runID)

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
    let live = try env.learning.liveChallenge(ownerUserID: 42, chatID: 777)
    #expect(live?.id == challenge.id)
    #expect(live?.consumedAt == nil)
    #expect(try env.currentLearningState().feedbackRevision == FeedbackRevision(0))
    #expect(try env.feedbackEventCount() == 0)
    #expect(try env.learningAuditCount() == auditCount)
  }

  @Test
  func evaluationAndFeedbackWritersConvergeInBothCommitOrders() throws {
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
      runID: firstEvidence.runID,
      signal: .resultNotUseful,
      updateID: 9
    )

    let feedbackFirst = try trialEnvironment()
    let secondEvidence = try feedbackFirst.sealedTrialEvidence()
    try feedbackFirst.recordRunFeedback(
      runID: secondEvidence.runID,
      signal: .resultNotUseful,
      updateID: 10
    )
    let secondOperation = try feedbackFirst.startedOperation(
      feedbackFirst.evaluatorKey(for: secondEvidence)
    )

    // when
    _ = try feedbackFirst.learning.finishOperation(
      feedbackFirst.result(for: secondOperation.id),
      now: feedbackFirst.now
    )
    let first = try #require(try evaluationFirst.assignment(runID: firstEvidence.runID))
    let second = try #require(try feedbackFirst.assignment(runID: secondEvidence.runID))

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

enum OperationProjectionFault: CaseIterable {
  case claim
  case start
  case denial
  case bootClaimed
  case bootStarted
}

private struct SealingVersionSnapshot: Equatable {
  let evidenceSchemaVersion: Int?
  let classifierVersion: String?
}

// MARK: - Assignment Reads

private extension BoundRunEnvironment {
  func sealingVersionSnapshot(runID: Int64) throws -> SealingVersionSnapshot {
    try queue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
          SELECT evidence_schema_version, classifier_version
          FROM run_compatibility WHERE run_id = ?
          """,
          arguments: [runID]
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
}
