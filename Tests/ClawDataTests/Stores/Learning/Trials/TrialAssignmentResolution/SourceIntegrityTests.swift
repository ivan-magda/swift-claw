import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

extension TrialAssignmentResolutionTests {
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
}
