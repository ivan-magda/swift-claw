import ClawCore
import Foundation
import Testing

@testable import ClawData

@Suite struct ResetTests {
  @Test func firstResetRaisesTheExactBarrierAndInvalidatesOnlyTheJobScope() throws {
    // given
    let fixture = try ResetFixture.make()
    let stable = try fixture.installStableLessons(["Keep reset-secret-lesson out of receipts."])
    try fixture.setFeedbackRevision(7)
    let trialIds = try fixture.seedOpenAndDrainingTrials(base: stable.digest)
    try fixture.clearTrialPointer()
    let otherJobId = try fixture.createOtherJob()
    try fixture.seedFeedbackControls(otherJobId: otherJobId)
    try fixture.seedOperations(otherJobId: otherJobId)
    let before = try fixture.state()

    // when
    let confirmed = try fixture.env.learning.applyReset(
      updateId: 9_001,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )

    // then — closing only the convenience pointer, current epoch, or current feedback rows leaves
    // an independently live path behind; the receipt also has to identify every operation class.
    let receipt = try #require(confirmed.appliedReceipt)
    let after = try fixture.state()
    #expect(confirmed.newlyClaimed)
    #expect(receipt.inputs.oldEpoch == before.epoch)
    #expect(receipt.inputs.oldStableDigest == stable.digest)
    #expect(receipt.inputs.oldStableRevision == before.stableRevision)
    #expect(receipt.inputs.feedbackRevisionAtCut == FeedbackRevision(7))
    #expect(receipt.inputs.priorOpenTrialId == nil)
    #expect(receipt.result.newEpoch == before.epoch.next())
    #expect(receipt.result.newStableRevision == before.stableRevision.next())
    #expect(receipt.result.emptyStableDigest == LessonSet.empty(jobId: fixture.env.jobId).digest)
    #expect(receipt.result.closedTrials.map(\.trialId) == trialIds)
    #expect(receipt.result.invalidatedTargetCount == 2)
    #expect(receipt.result.invalidatedChallengeCount == 2)
    #expect(receipt.result.staleNoCallOperationIds.map(\.rawValue) == ["op-claimed", "op-pending"])
    #expect(receipt.result.inFlightOperationIds.map(\.rawValue) == ["op-started"])
    #expect(after.epoch == before.epoch.next())
    #expect(after.stableDigest == LessonSet.empty(jobId: fixture.env.jobId).digest)
    #expect(after.stableRevision == before.stableRevision.next())
    #expect(after.feedbackRevision == FeedbackRevision(7))
    #expect(after.openTrialId == nil)
    #expect(try fixture.closedTrialIds() == trialIds)
    #expect(
      try fixture.closedTrialReasons()
        == Array(repeating: LearningTrialCloseReason.learningReset.rawValue, count: 2)
    )
    #expect(try fixture.unconsumedTargetCount(jobId: fixture.env.jobId) == 0)
    #expect(
      try fixture.targetConsumptionEpochs(jobId: fixture.env.jobId)
        == Array(repeating: EpochSecondCodec.epoch(fixture.env.now), count: 2)
    )
    #expect(try fixture.unconsumedTargetCount(jobId: otherJobId) == 1)
    #expect(try fixture.liveChallengeCount(jobId: fixture.env.jobId) == 0)
    #expect(
      try fixture.challengeConsumptionEpochs(jobId: fixture.env.jobId)
        == Array(repeating: EpochSecondCodec.epoch(fixture.env.now), count: 2)
    )
    #expect(try fixture.unconsumedSupersededChallengeCount() == 1)
    #expect(try fixture.liveChallengeCount(jobId: otherJobId) == 1)
    #expect(try fixture.operation("op-pending") == .staleNoCall)
    #expect(try fixture.operation("op-claimed") == .staleNoCall)
    #expect(try fixture.operation("op-started") == .started)
    #expect(try fixture.operation("op-other") == .claimed)

    let audit = try fixture.resetAudit()
    #expect(audit.actor == AuditActor.owner.rawValue)
    #expect(audit.action == AuditAction.learningReset.rawValue)
    #expect(audit.tool == "/learning reset")
    #expect(audit.decision == "applied")
    #expect(audit.resultSize == 0)
    #expect(audit.runId == nil)
    #expect(audit.sessionId == fixture.env.sessionId)
    let auditArguments = try JSONDecoder().decode(
      ResetAuditArguments.self,
      from: Data(audit.args.utf8)
    )
    #expect(auditArguments.decisionId == receipt.decisionId)
    #expect(auditArguments.kind == ResetReceipt.kind)
    #expect(auditArguments.jobId == receipt.jobId)
    #expect(auditArguments.algorithm == receipt.algorithm)
    #expect(auditArguments.decidedAt == EpochSecondCodec.epoch(receipt.decidedAt))
    #expect(auditArguments.inputs == receipt.inputs)
    #expect(auditArguments.result == receipt.result)
    let auditObject = try #require(
      JSONSerialization.jsonObject(with: Data(audit.args.utf8)) as? [String: Any]
    )
    #expect(
      Set(auditObject.keys)
        == ["algorithm", "decided_at", "decision_id", "inputs", "job_id", "kind", "result"]
    )
    #expect(audit.args.contains("reset-secret-lesson") == false)
    #expect(audit.args.contains("target-secret-nonce") == false)
    #expect(audit.args.contains("provider-secret-call") == false)
    let replay = try fixture.env.learning.applyReset(
      updateId: 9_018,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )
    #expect(replay.alreadyResetReceipt == receipt)
    #expect(try fixture.resetAuditCount() == 1)
  }

  @Test(arguments: ResetEmptyCollision.allCases)
  func canonicalEmptyCollisionRollsBackTheConfirmationClaim(
    _ collision: ResetEmptyCollision
  ) throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    try fixture.corruptCanonicalEmpty(collision)
    let before = try fixture.state()

    // when
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.applyReset(
        updateId: 9_002,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      )
    }

    // then — omitting this field's exact check silently blesses a noncanonical empty-set
    // identity.
    #expect(try fixture.state() == before)
    #expect(try fixture.processed(updateId: 9_002) == false)
    #expect(try fixture.resetDecisionCount() == 0)
  }

  @Test func unreadableLiveTrialIdentityRollsBackTheBarrierAndClaim() throws {
    // given
    let fixture = try ResetFixture.make()
    let stable = try fixture.installStableLessons(["Keep the state when identity is corrupt."])
    let trialIds = try fixture.seedOpenAndDrainingTrials(base: stable.digest)
    try fixture.corruptFirstLiveTrialBaseDigest()
    let before = try fixture.state()

    // when
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.applyReset(
        updateId: 9_020,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      )
    }

    // then — accepting an unreadable identity would write a receipt that cannot truthfully name
    // the historical trial closed by the barrier.
    #expect(try fixture.state() == before)
    #expect(try fixture.liveTrialIds() == trialIds)
    #expect(try fixture.processed(updateId: 9_020) == false)
    #expect(try fixture.resetDecisionCount() == 0)
    #expect(try fixture.resetAuditCount() == 0)
  }

  @Test(arguments: ResetStartedOperationCorruption.allCases)
  func unreadableStartedOperationRollsBackTheBarrierAndClaim(
    _ corruption: ResetStartedOperationCorruption
  ) throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    let otherJobId = try fixture.createOtherJob()
    try fixture.seedOperations(otherJobId: otherJobId)
    try fixture.corruptStartedOperation(corruption)
    let stateBefore = try fixture.state()
    let pendingBefore = try fixture.operation("op-pending")
    let claimedBefore = try fixture.operation("op-claimed")
    let startedBefore = try fixture.operation("op-started")
    let otherBefore = try fixture.operation("op-other")

    // when
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.applyReset(
        updateId: 9_024,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      )
    }

    // then — accepting any incomplete started-call reservation makes the receipt promise a
    // usage-only finish that the operation lifecycle cannot safely perform.
    #expect(try fixture.state() == stateBefore)
    #expect(try fixture.operation("op-pending") == pendingBefore)
    #expect(try fixture.operation("op-claimed") == claimedBefore)
    #expect(try fixture.operation("op-started") == startedBefore)
    #expect(try fixture.operation("op-other") == otherBefore)
    #expect(try fixture.processed(updateId: 9_024) == false)
    #expect(try fixture.resetDecisionCount() == 0)
    #expect(try fixture.resetAuditCount() == 0)
  }

  @Test func unreadableReceiptNamedStartedOperationRollsBackReplayClaim() throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    let otherJobId = try fixture.createOtherJob()
    try fixture.seedOperations(otherJobId: otherJobId)
    _ = try fixture.env.learning.applyReset(
      updateId: 9_025,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )
    try fixture.corruptStartedOperation(.missingProviderCallID)
    let stateBefore = try fixture.state()
    let startedBefore = try fixture.operation("op-started")

    // when
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.applyReset(
        updateId: 9_026,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      )
    }

    // then — clean replay must revalidate a still-started receipt row, while terminal late-result
    // rows remain covered by the separate usage-only settlement test.
    #expect(try fixture.state() == stateBefore)
    #expect(try fixture.operation("op-started") == startedBefore)
    #expect(try fixture.processed(updateId: 9_026) == false)
    #expect(try fixture.resetDecisionCount() == 1)
    #expect(try fixture.resetAuditCount() == 1)
  }

  @Test func ownerViewRejectsResetReceiptWhoseStartedCallIdentityIsUnreadable() throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    let otherJobId = try fixture.createOtherJob()
    try fixture.seedOperations(otherJobId: otherJobId)
    _ = try fixture.env.learning.applyReset(
      updateId: 9_027,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )
    let readable = try #require(
      try fixture.env.learning.learningView(jobId: fixture.env.jobId).onlyReadable
    )
    guard case .learningReset(_, let result) = readable.lastDecision?.detail else {
      Issue.record("expected a readable reset receipt")
      return
    }
    #expect(
      result.inFlightOperationIds == [LearningOperationID(rawValue: "op-started")]
    )
    try fixture.corruptStartedOperation(.missingProviderCallID)
    let before = try fixture.durableProjection()

    // when
    let view = try fixture.env.learning.learningView(jobId: fixture.env.jobId)
    let after = try fixture.durableProjection()

    // then — bypassing started-reservation validation in the shared receipt matcher survives the
    // effective-reset and clean-replay tests because neither calls the owner view after corruption.
    #expect(view.isOnlyUnreadable)
    #expect(after == before)
  }

  @Test func resetClearsTheConvenienceTrialPointer() throws {
    // given
    let fixture = try ResetFixture.make()
    let stable = try fixture.installStableLessons(["Pointer fixture."])
    let trialIds = try fixture.seedOpenAndDrainingTrials(base: stable.digest)
    #expect(try fixture.state().openTrialId == trialIds.first)

    // when
    _ = try fixture.env.learning.applyReset(
      updateId: 9_021,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )

    // then — closing the authoritative rows without clearing the denormalized pointer leaves a
    // stale owner-facing state identity.
    #expect(try fixture.state().openTrialId == nil)
  }

  @Test func transportReplayReturnsBeforeReadingResetState() throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    _ = try fixture.env.learning.applyReset(
      updateId: 9_003,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )
    try fixture.dropLearningStateTable()

    // when
    let duplicate = try fixture.env.learning.applyReset(
      updateId: 9_003,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )

    // then — reading the job or receipt before the claim would fail on the dropped table.
    #expect(duplicate == .duplicate)
  }

  @Test func cleanRepeatReplaysTheExactBarrier() throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    let first = try fixture.env.learning.applyReset(
      updateId: 9_004,
      jobId: fixture.env.jobId,
      now: fixture.env.now.addingTimeInterval(0.75)
    )
    let firstReceipt = try #require(first.appliedReceipt)

    // when
    let cleanRepeat = try fixture.env.learning.applyReset(
      updateId: 9_005,
      jobId: fixture.env.jobId,
      now: fixture.env.now.addingTimeInterval(1)
    )

    // then — always advancing for a fresh update would duplicate the barrier despite no new
    // activity or live effect.
    #expect(cleanRepeat.alreadyResetReceipt == firstReceipt)
    #expect(try fixture.resetDecisionCount() == 1)
    #expect(try fixture.resetAuditCount() == 1)
  }

  @Test(arguments: ResetCurrentEpochActivity.allCases)
  func everyCurrentEpochActivitySourceMakesTheNextResetEffective(
    _ activity: ResetCurrentEpochActivity
  ) throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    let first = try #require(
      try fixture.env.learning.applyReset(
        updateId: 9_100,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      ).appliedReceipt
    )
    try fixture.seedCurrentEpochActivity(activity)

    // when
    let next = try fixture.env.learning.applyReset(
      updateId: 9_101,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )

    // then — each source is isolated from the other ten, so removing its own gate survives no
    // independent source barrier and would incorrectly replay the prior reset.
    #expect(next.appliedReceipt?.result.newEpoch == first.result.newEpoch.next())
  }

  @Test(arguments: ResetDirtyEffect.allCases)
  func everyDirtyOldEpochEffectMakesTheNextResetEffective(_ effect: ResetDirtyEffect) throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    let first = try #require(
      try fixture.env.learning.applyReset(
        updateId: 9_110,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      ).appliedReceipt
    )
    try fixture.seedDirtyOldEpochEffect(effect)

    // when
    let next = try fixture.env.learning.applyReset(
      updateId: 9_111,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )

    // then — none of these rows are current-epoch activity, so only its dedicated clean-repeat
    // guard can prevent a false replay. A third reset proves the effective barrier either removed
    // the live effect or recorded the in-flight exception truthfully.
    let nextReceipt = try #require(next.appliedReceipt)
    #expect(nextReceipt.result.newEpoch == first.result.newEpoch.next())
    let clean = try fixture.env.learning.applyReset(
      updateId: 9_112,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )
    #expect(clean.alreadyResetReceipt == nextReceipt)
  }

  @Test func missingAndUnarmedJobsClaimWithoutInventingLearningState() throws {
    // given
    let fixture = try ResetFixture.make()

    // when
    let missing = try fixture.env.learning.applyReset(
      updateId: 9_007,
      jobId: 99_999,
      now: fixture.env.now
    )

    // then — returning a semantic outcome before the durable claim permits endless redelivery.
    #expect(missing.newlyClaimed)
    #expect(missing.outcome == .notFound)
    let afterMissing = try fixture.absenceProjection()
    #expect(
      afterMissing.processedUpdates
        == [.init(updateId: 9_007, claimedAt: fixture.env.now)]
    )
    #expect(afterMissing.learningStateCount == 0)
    #expect(afterMissing.lessonSetCount == 0)
    #expect(afterMissing.resetDecisionCount == 0)
    #expect(afterMissing.resetAuditCount == 0)

    // when
    let missingReplay = try fixture.env.learning.applyReset(
      updateId: 9_007,
      jobId: 99_999,
      now: fixture.env.now
    )

    // then
    #expect(missingReplay.newlyClaimed == false)
    #expect(missingReplay.outcome == nil)
    #expect(try fixture.absenceProjection() == afterMissing)

    // when
    let unarmed = try fixture.env.learning.applyReset(
      updateId: 9_008,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )

    // then — the reset port claims but must not arm a job merely to report an outcome.
    #expect(unarmed.newlyClaimed)
    #expect(unarmed.outcome == .unarmed)
    let afterUnarmed = try fixture.absenceProjection()
    #expect(
      afterUnarmed.processedUpdates
        == [
          .init(updateId: 9_007, claimedAt: fixture.env.now),
          .init(updateId: 9_008, claimedAt: fixture.env.now),
        ]
    )
    #expect(afterUnarmed.learningStateCount == 0)
    #expect(afterUnarmed.lessonSetCount == 0)
    #expect(afterUnarmed.resetDecisionCount == 0)
    #expect(afterUnarmed.resetAuditCount == 0)

    // when
    let unarmedReplay = try fixture.env.learning.applyReset(
      updateId: 9_008,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )

    // then
    #expect(unarmedReplay.newlyClaimed == false)
    #expect(unarmedReplay.outcome == nil)
    #expect(try fixture.absenceProjection() == afterUnarmed)
  }

  @Test func cancelledJobWithRetainedStateRemainsResettable() throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    try fixture.env.cancelJob()

    // when
    let confirmed = try fixture.env.learning.applyReset(
      updateId: 9_009,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )

    // then — gating on active schedule status strands retained derived state after cancellation.
    #expect(confirmed.appliedReceipt != nil)
    #expect(try fixture.state().epoch == LearningEpoch(2))
  }

  @Test func finalAuditFailureRollsBackEveryResetEffectAndClaim() throws {
    // given
    let fixture = try ResetFixture.make()
    let stable = try fixture.installStableLessons(["Keep this until the transaction commits."])
    let trials = try fixture.seedOpenAndDrainingTrials(base: stable.digest)
    try fixture.failResetAudit()
    let before = try fixture.state()

    // when
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.applyReset(
        updateId: 9_010,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      )
    }

    // then — a reset decision or update claim committed before the audit cannot be retried
    // safely.
    #expect(try fixture.state() == before)
    #expect(try fixture.liveTrialIds() == trials)
    #expect(try fixture.processed(updateId: 9_010) == false)
    #expect(try fixture.resetDecisionCount() == 0)
    try fixture.allowResetAudit()
    #expect(
      try fixture.env.learning.applyReset(
        updateId: 9_010,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      ).appliedReceipt != nil
    )
  }

  @Test func lateEvaluatorResultClosesAndChargesWithoutPersistingItsProduct() throws {
    // given
    let fixture = try ResetFixture.make()
    let evidence = try fixture.env.sealedEvidence()
    let started = try fixture.env.startedOperation(fixture.env.evaluatorKey(for: evidence))
    let reset = try #require(
      try fixture.env.learning.applyReset(
        updateId: 9_011,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      ).appliedReceipt
    )
    let result = fixture.env.result(
      for: started.id,
      evaluation: fixture.env.verdict(outcome: .reusableIssue)
    )

    // when
    let committed = try fixture.env.learning.finishOperation(result, now: fixture.env.now)
    let duplicate = try fixture.env.learning.finishOperation(result, now: fixture.env.now)

    // then — moving the epoch fence before usage loses real spend; omitting it stores stale
    // truth.
    #expect(committed)
    #expect(duplicate == false)
    #expect(try fixture.env.operationState(started.id) == .succeeded)
    #expect(try fixture.env.learningUsage(operationId: started.id).count == 1)
    #expect(try fixture.env.learning.evaluation(runId: evidence.runId) == nil)
    let repeatReset = try fixture.env.learning.applyReset(
      updateId: 9_019,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )
    #expect(repeatReset.alreadyResetReceipt == reset)
  }

  @Test func finishBeforeResetKeepsHistoricalProductAndResetStillApplies() throws {
    // given
    let fixture = try ResetFixture.make()
    let evidence = try fixture.env.sealedEvidence()
    let started = try fixture.env.startedOperation(fixture.env.evaluatorKey(for: evidence))
    _ = try fixture.env.learning.finishOperation(
      fixture.env.result(for: started.id, evaluation: fixture.env.verdict()),
      now: fixture.env.now
    )

    // when
    let reset = try fixture.env.learning.applyReset(
      updateId: 9_012,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )

    // then — reset is a barrier, not a history purge.
    #expect(reset.appliedReceipt != nil)
    #expect(try fixture.env.learning.evaluation(runId: evidence.runId) != nil)
    #expect(try fixture.env.learningUsage(operationId: started.id).count == 1)
  }

  @Test func oldBindingStaysPinnedAndNextFireUsesTheEmptyNewEpoch() throws {
    // given
    let fixture = try ResetFixture.make()
    let stable = try fixture.installStableLessons(["Use this only before reset."])
    let oldRun = try fixture.env.runningBoundRun()
    let oldBinding = try #require(try fixture.env.learning.binding(runId: oldRun))
    _ = try fixture.env.runs.commitAssistantTurn(
      fixture.env.assistantTurn(runId: oldRun),
      now: fixture.env.now
    )

    // when
    let reset = try #require(
      try fixture.env.learning.applyReset(
        updateId: 9_013,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      ).appliedReceipt
    )
    let newRun = try fixture.env.pendingBoundRun()

    // then — retargeting the old row rewrites what that run actually saw.
    #expect(try fixture.env.learning.binding(runId: oldRun) == oldBinding)
    #expect(oldBinding.effectiveDigest == stable.digest)
    let newBinding = try #require(try fixture.env.learning.binding(runId: newRun))
    #expect(newBinding.epoch == reset.result.newEpoch)
    #expect(newBinding.stableDigest == reset.result.emptyStableDigest)
    #expect(newBinding.effectiveDigest == reset.result.emptyStableDigest)
  }

  @Test func resetSeparatesNeverAdmittedCandidateFromAdmittedReplay() throws {
    // given — a persisted candidate that has never opened a trial
    let staleFixture = try AdmissionStoreFixture.make()
    defer { staleFixture.remove() }
    let staleCandidate = try staleFixture.persistedCandidate()
    _ = try staleFixture.env.learning.applyReset(
      updateId: 9_014,
      jobId: staleFixture.env.jobId,
      now: staleFixture.env.now
    )

    // when
    let staleAdmission = try staleFixture.env.learning.admitCandidate(
      digest: staleCandidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: staleFixture.env.now
    )

    // then
    #expect(staleAdmission == .rejected(.staleEpoch))

    // given — an already-admitted candidate has an immutable idempotency receipt.
    let replayFixture = try AdmissionStoreFixture.make()
    defer { replayFixture.remove() }
    let admittedCandidate = try replayFixture.persistedCandidate()
    let admitted = try replayFixture.env.learning.admitCandidate(
      digest: admittedCandidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: replayFixture.env.now
    )
    let admittedReceipt = try #require(admitted.admissionReceipt)
    _ = try replayFixture.env.learning.applyReset(
      updateId: 9_015,
      jobId: replayFixture.env.jobId,
      now: replayFixture.env.now
    )

    // when
    let replay = try replayFixture.env.learning.admitCandidate(
      digest: admittedCandidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: replayFixture.env.now
    )

    // then — replaying the old receipt must not reopen the reset-closed trial.
    #expect(replay.admissionReceipt == admittedReceipt)
    #expect(try replayFixture.env.learning.openTrial(jobId: replayFixture.env.jobId) == nil)
    #expect(
      try replayFixture.trial(admittedReceipt.trialId).state
        == LearningTrialState.closed.rawValue
    )
  }

  @Test(arguments: ResetReceiptCorruption.allCases)
  func resetDecisionIsImmediatelyReadableAndMalformedReplayRaisesAFreshBarrier(
    _ corruption: ResetReceiptCorruption
  ) throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    let first = try #require(
      try fixture.env.learning.applyReset(
        updateId: 9_016,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      ).appliedReceipt
    )

    // when
    let view = try #require(
      try fixture.env.learning.learningView(jobId: fixture.env.jobId).onlyReadable
    )

    // then — an unknown reset decision kind would make the successful reset unreadable.
    guard case .learningReset(let inputs, let result) = view.lastDecision?.detail else {
      Issue.record("expected a typed reset decision")
      return
    }
    #expect(inputs == first.inputs)
    #expect(result == first.result)

    // when
    try fixture.corruptResetResult(corruption)
    #expect(try fixture.env.learning.learningView(jobId: fixture.env.jobId).isOnlyUnreadable)
    let repaired = try fixture.env.learning.applyReset(
      updateId: 9_017,
      jobId: fixture.env.jobId,
      now: fixture.env.now.addingTimeInterval(1)
    )

    // then — malformed current receipt is not a clean-repeat proof.
    #expect(repaired.appliedReceipt?.result.newEpoch == first.result.newEpoch.next())
    #expect(try fixture.env.learning.learningView(jobId: fixture.env.jobId).onlyReadable != nil)
  }

  @Test func ambiguousCurrentResetReceiptsRaiseAFreshBarrier() throws {
    // given
    let fixture = try ResetFixture.make()
    _ = try fixture.env.learning.armJob(jobId: fixture.env.jobId, now: fixture.env.now)
    let first = try #require(
      try fixture.env.learning.applyReset(
        updateId: 9_022,
        jobId: fixture.env.jobId,
        now: fixture.env.now
      ).appliedReceipt
    )
    try fixture.duplicateCurrentResetDecision()

    // when
    let repaired = try fixture.env.learning.applyReset(
      updateId: 9_023,
      jobId: fixture.env.jobId,
      now: fixture.env.now
    )

    // then — choosing either of two otherwise valid rows would turn ambiguous history into a
    // false clean replay.
    #expect(repaired.appliedReceipt?.result.newEpoch == first.result.newEpoch.next())
    #expect(try fixture.resetDecisionCount() == 3)
    #expect(try fixture.resetAuditCount() == 2)
  }
}

private extension ConfirmedLearningResetResult {
  var appliedReceipt: ResetReceipt? {
    guard case .applied(let receipt) = outcome else {
      return nil
    }
    return receipt
  }

  var alreadyResetReceipt: ResetReceipt? {
    guard case .alreadyReset(let receipt) = outcome else {
      return nil
    }
    return receipt
  }
}

private struct ResetAuditArguments: Decodable {
  let decisionId: Int64
  let kind: String
  let jobId: Int64
  let algorithm: LearningAlgorithm
  let decidedAt: Int64
  let inputs: LearningResetDecisionInputs
  let result: LearningResetDecisionResult

  enum CodingKeys: String, CodingKey {
    case decisionId = "decision_id"
    case kind
    case jobId = "job_id"
    case algorithm
    case decidedAt = "decided_at"
    case inputs
    case result
  }
}

private extension AdmissionOutcome {
  var admissionReceipt: AdmissionReceipt? {
    guard case .admitted(let receipt) = self else {
      return nil
    }
    return receipt
  }
}

private extension Array where Element == JobLearningView {
  var onlyReadable: ReadableJobLearningView? {
    guard count == 1, case .readable(let view) = self[0] else {
      return nil
    }
    return view
  }

  var isOnlyUnreadable: Bool {
    guard count == 1, case .unreadable = self[0] else {
      return false
    }
    return true
  }
}
