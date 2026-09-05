import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct RollbackTests {
  @Test(arguments: [OwnerSignal.promotionRollback, .candidateReject])
  func ownerTriggers(_ signal: OwnerSignal) throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let promotion = try env.promoteTrial()
    let event = try env.promotionFeedback(promotion, signal: signal)

    // when
    let receipt = try #require(
      try env.learning.rollback(
        .ownerFeedback(promotionId: promotion.decisionId, eventId: event.id),
        now: env.now
      )
    )

    // then
    #expect(receipt.result == .rolledBack)
    #expect(try env.currentLearningState().stableDigest == promotion.inputs.baseDigest)
    #expect(try env.currentLearningState().epoch == promotion.inputs.identity.epoch)
    #expect(try env.learning.currentPromotion(jobId: env.jobId) == nil)
  }

  @Test(arguments: [OwnerSignal.resultNotUseful, .evaluationDispute, .resultCorrection])
  func rediscoveredWithdrawalReusesReceiptAndLaterFeedbackStillRollsBack(_ signal: OwnerSignal)
    throws
  {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    let first = try env.positiveTrialRun()
    let pending = try env.settledBoundRun()
    _ = try env.positiveTrialRun()
    let sealed = try env.seal(runId: pending)
    let operation = try env.startedOperation(env.evaluatorKey(for: sealed))
    _ = try env.learning.finishOperation(
      env.result(for: operation.id, evaluation: env.verdict(outcome: .noIssue, issueCodes: [])),
      now: env.now
    )
    let promotion = try env.promoteTrial()
    let firstEvent = try env.withdrawalFeedback(runId: first, signal: signal, updateId: 901)

    // when — one withdrawal from three supports still leaves two
    let stillSupported = try env.learning.rollback(
      .supportWithdrawal(promotionId: promotion.decisionId, eventId: firstEvent.id),
      now: env.now
    )
    let rediscovered = try env.learning.rollback(
      .supportWithdrawal(promotionId: promotion.decisionId, eventId: firstEvent.id),
      now: env.now
    )
    let secondEvent = try env.withdrawalFeedback(
      runId: pending,
      signal: .resultNotUseful,
      updateId: 902
    )
    let rollback = try env.learning.rollback(
      .supportWithdrawal(promotionId: promotion.decisionId, eventId: secondEvent.id),
      now: env.now
    )

    // then
    #expect(stillSupported?.result == .stale)
    #expect(rediscovered == stillSupported)
    #expect(rollback?.decisionId != stillSupported?.decisionId)
    #expect(rollback?.result == .rolledBack)
    #expect(promotion.cohort.count == 3)
    #expect(try env.currentLearningState().stableDigest == promotion.inputs.baseDigest)
  }

  @Test func laterIssueIsInert() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let promotion = try env.promoteTrial()

    // when
    let later = try env.evaluatedEvidence(issueCode: "later.issue")
    let event = try env.withdrawalFeedback(
      runId: later.evidence.runId,
      signal: .resultNotUseful,
      updateId: 920
    )
    let receipt = try env.learning.rollback(
      .supportWithdrawal(promotionId: promotion.decisionId, eventId: event.id),
      now: env.now
    )

    // then
    #expect(receipt?.result == .stale)
    #expect(try env.learning.currentPromotion(jobId: env.jobId) == promotion)
  }

  @Test func stalePromotion() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let promotion = try env.promoteTrial()
    let fixture = AdmissionStoreFixture(path: "", env: env)
    let next = try fixture.persistedCandidate(lessons: [
      "Compare every material change with the archive."
    ])
    _ = try env.learning.admitCandidate(
      digest: next.digest,
      redactor: SecretRedactor(secretValues: []),
      now: env.now
    )
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    _ = try env.promoteTrial()
    let event = try env.promotionFeedback(promotion, signal: .promotionRollback)
    let before = try env.currentLearningState()

    // when
    let receipt = try env.learning.rollback(
      .ownerFeedback(promotionId: promotion.decisionId, eventId: event.id),
      now: env.now
    )

    // then
    #expect(receipt?.result == .stale)
    #expect(try env.currentLearningState() == before)
  }

  @Test func rollbackClosesATrialDependingOnTheWithdrawnBase() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let promotion = try env.promoteTrial()
    let fixture = AdmissionStoreFixture(path: "", env: env)
    let next = try fixture.persistedCandidate(lessons: ["Consult the complete archive."])
    _ = try env.learning.admitCandidate(
      digest: next.digest,
      redactor: SecretRedactor(secretValues: []),
      now: env.now
    )

    let inFlight = try env.runningBoundRun()

    // when
    let rollback = try env.learning.rollback(
      .safety(
        promotionId: promotion.decisionId,
        receiptDigest: SHA256Digest.hex("bad base"),
        failure: .security
      ),
      now: env.now
    )

    // then
    #expect(rollback?.result == .rolledBack)
    #expect(try env.learning.openTrial(jobId: env.jobId) == nil)
    #expect(try env.learning.binding(runId: inFlight)?.effectiveDigest == next.replacement.digest)
    _ = try env.runs.commitAssistantTurn(env.assistantTurn(runId: inFlight), now: env.now)
    let nextRun = try env.runningBoundRun()
    #expect(
      try env.learning.binding(runId: nextRun)?.effectiveDigest == promotion.inputs.baseDigest
    )
  }

  @Test func hardReceipts() throws {
    // given
    let env = try BoundRunEnvironment.promotionEnvironment()
    _ = try env.positiveTrialRun()
    _ = try env.positiveTrialRun()
    let promotion = try env.promoteTrial()

    // when
    let adapter = try env.learning.rollback(
      .adapter(promotionId: promotion.decisionId, adapterId: "unfrozen", outcome: .critical),
      now: env.now
    )
    let safety = try env.learning.rollback(
      .safety(
        promotionId: promotion.decisionId,
        receiptDigest: SHA256Digest.hex("security receipt"),
        failure: .security
      ),
      now: env.now
    )

    // then
    #expect(adapter?.result == .stale)
    #expect(safety?.result == .rolledBack)
    #expect(try env.currentLearningState().stableDigest == promotion.inputs.baseDigest)
  }
}

extension BoundRunEnvironment {
  func promotionFeedback(_ promotion: DecisionReceipt, signal: OwnerSignal) throws -> FeedbackEvent
  {
    let target = NewFeedbackTarget(
      nonce: "promotion-owner-feedback",
      jobId: jobId,
      epoch: promotion.inputs.identity.epoch,
      subjectKind: signal.feedbackSubjectKind,
      subjectDigest: signal == .promotionRollback
        ? promotion.promotionSubject : promotion.inputs.candidateDigest.rawValue,
      allowedActions: [signal],
      ownerUserId: 42,
      chatId: 777,
      expiresAt: now.addingTimeInterval(3_600)
    )
    try learning.createTargets([target], chunks: [], now: now)
    guard
      case .recorded(let event) = try learning.consumeAndAppendEvent(
        feedbackTap(target, updateId: 900),
        now: now
      )
    else {
      throw StoreError.unexpected("fixture owner trigger was not recorded")
    }
    return event
  }

  func withdrawalFeedback(runId: Int64, signal: OwnerSignal, updateId: Int64) throws
    -> FeedbackEvent
  {
    let target: NewFeedbackTarget
    if signal == .evaluationDispute {
      let assignment = try #require(try assignment(runId: runId))
      let digest = try #require(assignment.resolvedEvidence?.evaluationDigest)
      target = evaluationFeedbackTarget(digest: digest, signal: signal)
    } else {
      target = runFeedbackTarget(runId: runId, signal: signal)
    }
    try learning.createTargets([target], chunks: [], now: now)
    let outcome: FeedbackOutcome
    if signal.opensFeedbackChallenge {
      let opened = try learning.consumeAndOpenChallenge(
        feedbackTap(target, updateId: updateId),
        prompt: challengePrompt(target),
        now: now
      )
      guard case .challengeOpened(let challenge) = opened else {
        throw StoreError.unexpected("fixture correction challenge was not opened")
      }
      outcome = try learning.consumeChallenge(
        id: challenge.id,
        payload: "The answer missed the archive",
        now: now
      )
    } else {
      outcome = try learning.consumeAndAppendEvent(
        feedbackTap(target, updateId: updateId),
        now: now
      )
    }
    guard case .recorded(let event) = outcome else {
      throw StoreError.unexpected("fixture withdrawal was not recorded")
    }
    return event
  }
}
