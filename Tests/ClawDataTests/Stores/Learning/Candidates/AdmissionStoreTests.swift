import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct AdmissionStoreTests {
  @Test func persistedArtifactOpensExactlyOneEmptyTrialAndChangesNoStableOrSpendState() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let before = try fixture.env.currentLearningState()
    let usage = try fixture.env.countRows(in: "provider_usage")
    let candidates = try fixture.env.countRows(in: "learning_candidates")

    // when
    let outcome = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — reinserting the artifact, assigning eagerly, changing the stable set, or charging
    // admission would each survive the Task 12 persistence test but violate this transaction.
    guard case .admitted(let receipt) = outcome else {
      Issue.record("expected the current reflector candidate to be admitted")
      return
    }
    let row = try fixture.trial(receipt.trialId)
    #expect(row.candidate == artifact.digest.rawValue)
    #expect(row.admittedAt == EpochSecondCodec.epoch(fixture.env.now))
    #expect(row.cohortCutoff == row.admittedAt)
    #expect(
      row.assignmentDeadline
        == EpochSecondCodec.epoch(fixture.env.now) + 2_592_000
    )
    #expect(
      row.decisionDeadline
        == EpochSecondCodec.epoch(fixture.env.now) + 3_196_800
    )
    #expect(row.maximumAssignments == 3)
    #expect(row.consumedAssignments == 0)
    #expect(row.state == LearningTrialState.open.rawValue)
    #expect(try fixture.env.countRows(in: "learning_candidates") == candidates)
    #expect(try fixture.env.countRows(in: "trial_assignments") == 0)
    #expect(try fixture.env.countRows(in: "provider_usage") == usage)
    #expect(try fixture.env.countRows(in: "learning_decisions") == 1)
    #expect(try fixture.admissionAuditCount() == 1)
    let after = try fixture.env.currentLearningState()
    #expect(after.stableDigest == before.stableDigest)
    #expect(after.stableRevision == before.stableRevision)
    #expect(after.openTrialId == receipt.trialId)
  }

  @Test func drainingTrialBlocksAdmissionEvenWhenConveniencePointerIsNil() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    try fixture.insertCompetingDrainingTrial(from: artifact)

    // when
    let outcome = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — consulting open_trial_id or only state=open would open a second live experiment.
    #expect(outcome == .rejected(.trialAlreadyLive))
    #expect(try fixture.env.currentLearningState().openTrialId == nil)
    #expect(try fixture.env.countRows(in: "learning_trials") == 1)
  }

  @Test func feedbackCutoffAdvancingMakesTheArtifactStaleWithoutRebindingIt() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    try fixture.env.advanceFeedbackRevision()

    // when
    let outcome = try fixture.env.learning.admitCandidate(
      digest: artifact.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — silently freezing the newer revision would change immutable source identity.
    #expect(outcome == .rejected(.staleFeedbackRevision))
    #expect(try fixture.env.learning.candidateArtifact(digest: artifact.digest) == artifact)
    #expect(try fixture.env.countRows(in: "learning_trials") == 0)
  }

  @Test func replayAndConcurrentAdmissionReturnOneDurableOutcome() async throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    let learning = fixture.env.learning
    let now = fixture.env.now

    // when
    let outcomes = try await withThrowingTaskGroup(of: AdmissionOutcome.self) { group in
      for _ in 0..<8 {
        group.addTask {
          try learning.admitCandidate(
            digest: artifact.digest,
            redactor: SecretRedactor(secretValues: []),
            now: now
          )
        }
      }
      var values: [AdmissionOutcome] = []
      for try await value in group {
        values.append(value)
      }
      return values
    }

    // then — removing writer serialization or replay detection duplicates a trial or receipt.
    let receipts = outcomes.compactMap(\.admissionReceipt)
    #expect(receipts.count == 8)
    #expect(receipts.allSatisfy { receipt in receipt == receipts.first })
    #expect(try fixture.env.countRows(in: "learning_trials") == 1)
    #expect(try fixture.env.countRows(in: "learning_decisions") == 1)
    #expect(try fixture.admissionAuditCount() == 1)
  }

  @Test func approvalCreatesOneSuccessorAndAdmitsItThroughTheCommonGates() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateApprove
    )
    let approval = CandidateApproval(
      predecessorDigest: predecessor.digest,
      feedbackEventId: control.eventId
    )

    // when
    let first = try fixture.env.learning.approveCandidate(
      approval,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    _ = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: "unrelated-after-approval",
      signal: .candidateReject
    )
    let replay = try fixture.env.learning.approveCandidate(
      approval,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — replay resolves the immutable successor even after unrelated feedback advances.
    let firstReceipt = try #require(first.admissionReceipt)
    #expect(replay.admissionReceipt == firstReceipt)
    let successor = try #require(try fixture.candidate(for: firstReceipt.candidateDigest))
    #expect(successor.digest != predecessor.digest)
    #expect(successor.replacement == predecessor.replacement)
    #expect(successor.manifest.origin == .ownerApproval)
    #expect(successor.manifest.predecessorCandidate == predecessor.digest)
    #expect(successor.manifest.predecessorFeedback == control)
    #expect(try fixture.env.countRows(in: "learning_candidates") == 2)
    #expect(try fixture.env.countRows(in: "learning_trials") == 1)
  }

  @Test func supersededManifestFeedbackMakesApprovalStaleWithoutRebinding() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let (predecessor, frozenSource) = try fixture.persistedCandidateWithFeedback()
    _ = try fixture.env.appendFeedback(
      subjectKind: frozenSource.subjectKind,
      subjectDigest: frozenSource.subjectDigest,
      signal: .evaluationConfirm,
      supersedes: frozenSource.eventId
    )
    let approvalSource = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateApprove
    )

    // when
    let outcome = try fixture.env.learning.approveCandidate(
      CandidateApproval(
        predecessorDigest: predecessor.digest,
        feedbackEventId: approvalSource.eventId
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — rebinding the frozen source list would manufacture a different candidate history.
    #expect(outcome == .rejected(.sourceBindingsChanged))
    #expect(try fixture.env.countRows(in: "learning_candidates") == 1)
    #expect(try fixture.env.countRows(in: "learning_trials") == 0)
    #expect(try fixture.env.learning.candidateArtifact(digest: predecessor.digest) == predecessor)
  }

  @Test func editVetoesTheOldTrialAndPersistsOnlyAnAwaitingSuccessor() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: predecessor.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let oldTrial = try #require(admitted.admissionReceipt).trialId
    let editedLesson = "Keep the exact owner-edited instruction."
    let payloadText = #"{"lessons":["\#(editedLesson)"]}"#
    let payload = Data(payloadText.utf8)
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: payloadText
    )

    // when
    let outcome = try fixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: control.eventId,
        payload: payload
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — admitting the edit or inheriting approval would expose unapproved owner bytes.
    guard case .awaitingApproval(let successor) = outcome else {
      Issue.record("expected an awaiting edit successor")
      return
    }
    #expect(successor.replacement.lessons == [editedLesson])
    #expect(successor.manifest.origin == .ownerEdit)
    #expect(successor.manifest.predecessorCandidate == predecessor.digest)
    #expect(successor.manifest.predecessorFeedback == control)
    #expect(try fixture.trial(oldTrial).state == LearningTrialState.fellBack.rawValue)
    #expect(try fixture.env.terminalDecisionCount() == 1)
    #expect(try fixture.env.learning.openTrial(jobId: fixture.env.jobId) == nil)
    #expect(try fixture.env.countRows(in: "learning_trials") == 1)
    #expect(try fixture.env.countRows(in: "learning_candidates") == 2)
  }

  @Test func invalidOrSecretEditBytesNeverReachCandidateOrLessonRows() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let payload = Data(#"{"lessons":["loaded-secret"]}"#.utf8)
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: #"{"lessons":["loaded-secret"]}"#
    )
    let candidateCount = try fixture.env.countRows(in: "learning_candidates")
    let lessonCount = try fixture.env.countRows(in: "lesson_sets")

    // when
    let outcome = try fixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: control.eventId,
        payload: payload
      ),
      redactor: SecretRedactor(secretValues: ["loaded-secret"]),
      now: fixture.env.now
    )

    // then — validating after either insert would durably copy the loaded credential.
    #expect(outcome == .rejected(.secretLeak))
    #expect(try fixture.env.countRows(in: "learning_candidates") == candidateCount)
    #expect(try fixture.env.countRows(in: "lesson_sets") == lessonCount)
  }

  @Test func lateAuditFailureRollsBackTrialPointerAndReceipt() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let artifact = try fixture.persistedCandidate()
    try fixture.failAdmissionAudit()

    // when
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.admitCandidate(
        digest: artifact.digest,
        redactor: SecretRedactor(secretValues: []),
        now: fixture.env.now
      )
    }

    // then — a transaction ending before audit would strand a partially admitted candidate.
    #expect(try fixture.env.countRows(in: "learning_trials") == 0)
    #expect(try fixture.env.countRows(in: "learning_decisions") == 0)
    #expect(try fixture.env.currentLearningState().openTrialId == nil)
  }

  @Test func lateAdmissionFailureAlsoRollsBackAnApprovalSuccessor() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateApprove
    )
    try fixture.failAdmissionAudit()

    // when
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.approveCandidate(
        CandidateApproval(
          predecessorDigest: predecessor.digest,
          feedbackEventId: control.eventId
        ),
        redactor: SecretRedactor(secretValues: []),
        now: fixture.env.now
      )
    }

    // then — a nested successor write must share the trial/receipt/audit rollback boundary.
    #expect(try fixture.env.countRows(in: "learning_candidates") == 1)
    #expect(try fixture.env.countRows(in: "learning_trials") == 0)
    #expect(try fixture.env.countRows(in: "learning_decisions") == 0)
  }

  @Test func candidateReviewCommitIsAtomicAndIdempotent() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let now = fixture.env.now
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: now
    )
    let review = fixture.review(candidate: candidate, state: .admitted, now: now)
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")

    // when
    let inserted = try fixture.env.learning.commitCandidateReview(review, now: now)
    let replay = try fixture.env.learning.commitCandidateReview(
      fixture.review(candidate: candidate, state: .admitted, now: now, nonceSuffix: "replay"),
      now: now
    )

    // then — inserting targets before replay detection creates orphan nonces on every retry.
    #expect(inserted)
    #expect(replay == false)
    #expect(try fixture.env.countRows(in: "feedback_targets") == review.targets.count)
    #expect(try fixture.env.countRows(in: "outbound_deliveries") == deliveries + 1)
    let delivery = try fixture.reviewDelivery()
    #expect(
      delivery.key == OutboxDedupKey.make(subjectDigest: review.subjectDigest, ordinal: 0)
    )
    #expect(delivery.runId == nil)
    #expect(delivery.source == DeliverySource.learning.rawValue)
  }

  @Test func reviewTargetFailureRollsBackEveryRunlessChunk() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    try fixture.failReviewTarget()
    let review = fixture.review(
      candidate: candidate,
      state: .admitted,
      now: fixture.env.now
    )
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")

    // when / then — committing the outbox before targets would leave a live button with no nonce.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now)
    }
    #expect(try fixture.env.countRows(in: "feedback_targets") == 0)
    #expect(try fixture.env.countRows(in: "outbound_deliveries") == deliveries)
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
