import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct CandidateReviewStoreTests {
  @Test(arguments: ReviewCarrierMutation.allCases)
  func fabricatedReviewCapabilitiesAreRejectedAtomically(
    _ mutation: ReviewCarrierMutation
  ) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let valid = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)
    let forged = fixture.mutate(valid, mutation: mutation)
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")

    // when / then — no caller-supplied action, evaluation order, expiry, identity, or chunk shape
    // may create a capability that the current candidate does not authorize.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(forged, now: fixture.env.now)
    }
    #expect(try fixture.env.countRows(in: "feedback_targets") == 0)
    #expect(try fixture.env.countRows(in: "outbound_deliveries") == deliveries)
  }

  @Test func reviewStateIsDerivedFromTheAuthoritativeLiveTrial() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    let admitted = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let receipt = try #require(admitted.admissionReceipt)
    let wrongState = fixture.review(
      candidate: candidate,
      state: .awaitingApproval,
      now: fixture.env.now
    )
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")

    // when / then — passed state cannot grant Approve for an already-admitted candidate.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(wrongState, now: fixture.env.now)
    }
    try fixture.setTrialStateForReview(receipt.trialId, state: .closed)
    let terminal = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(terminal, now: fixture.env.now)
    }
    #expect(try fixture.env.countRows(in: "feedback_targets") == 0)
    #expect(try fixture.env.countRows(in: "outbound_deliveries") == deliveries)
  }

  @Test func admittedReviewRequiresTheExactImmutableReceipt() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let review = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")
    try fixture.env.queue.write { db in
      try db.execute(
        sql: "UPDATE learning_decisions SET result = ? WHERE kind = ?",
        arguments: [#"{"candidate_digest":"wrong"}"#, AdmissionReceipt.kind]
      )
    }

    // when / then — a trial row alone cannot authorize an admitted review.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now)
    }
    #expect(try fixture.env.countRows(in: "feedback_targets") == 0)
    #expect(try fixture.env.countRows(in: "outbound_deliveries") == deliveries)
  }

  @Test func onlyACurrentUnadmittedOwnerEditCanUseAwaitingApprovalState() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let predecessor = try fixture.persistedCandidate()
    let payload = #"{"lessons":["Keep owner-confirmed material changes only."]}"#
    let editControl = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: payload
    )
    let editedOutcome = try fixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: editControl.eventId,
        payload: Data(payload.utf8)
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let edited = try #require(editedOutcome.awaitingArtifact)
    let review = fixture.review(
      candidate: edited,
      state: .awaitingApproval,
      now: fixture.env.now
    )
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")

    // when
    let inserted = try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now)

    // then — accepting any unadmitted origin would expose Approve on a raw reflection artifact.
    #expect(inserted)
    #expect(try fixture.env.countRows(in: "feedback_targets") == review.targets.count)
    #expect(
      try fixture.env.countRows(in: "outbound_deliveries") == deliveries + review.chunks.count
    )
  }

  @Test func rawAndSupersededCandidatesCannotExposeAwaitingApproval() throws {
    // given
    let rawFixture = try AdmissionStoreFixture.make()
    defer { rawFixture.remove() }
    let raw = try rawFixture.persistedCandidate()
    let rawReview = rawFixture.review(
      candidate: raw,
      state: .awaitingApproval,
      now: rawFixture.env.now
    )

    let supersededFixture = try AdmissionStoreFixture.make()
    defer { supersededFixture.remove() }
    let predecessor = try supersededFixture.persistedCandidate()
    let payload = #"{"lessons":["Keep the approved owner edit."]}"#
    let editControl = try supersededFixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: payload
    )
    let editedOutcome = try supersededFixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: editControl.eventId,
        payload: Data(payload.utf8)
      ),
      redactor: SecretRedactor(secretValues: []),
      now: supersededFixture.env.now
    )
    let edited = try #require(editedOutcome.awaitingArtifact)
    let approval = try supersededFixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: edited.digest.rawValue,
      signal: .candidateApprove
    )
    _ = try supersededFixture.env.learning.approveCandidate(
      CandidateApproval(
        predecessorDigest: edited.digest,
        feedbackEventId: approval.eventId
      ),
      redactor: SecretRedactor(secretValues: []),
      now: supersededFixture.env.now
    )
    let supersededReview = supersededFixture.review(
      candidate: edited,
      state: .awaitingApproval,
      now: supersededFixture.env.now
    )

    // when / then — unadmitted is not enough: awaiting authority belongs only to the live edit tip.
    #expect(throws: StoreError.self) {
      _ = try rawFixture.env.learning.commitCandidateReview(rawReview, now: rawFixture.env.now)
    }
    #expect(throws: StoreError.self) {
      _ = try supersededFixture.env.learning.commitCandidateReview(
        supersededReview,
        now: supersededFixture.env.now
      )
    }
    #expect(try rawFixture.env.countRows(in: "feedback_targets") == 0)
    #expect(try supersededFixture.env.countRows(in: "feedback_targets") == 0)
  }

  @Test func pausedRecurringJobCanCommitItsCurrentAdmittedReview() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    try fixture.env.queue.write { db in
      try db.execute(
        sql: "UPDATE scheduled_jobs SET status = ? WHERE id = ?",
        arguments: [ScheduledJobStatus.paused.rawValue, fixture.env.jobId]
      )
    }
    let review = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)

    // when
    let inserted = try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now)

    // then — paused keeps owner review authority just as it keeps admission authority.
    #expect(inserted)
    #expect(try fixture.env.countRows(in: "feedback_targets") == review.targets.count)
  }

  @Test func reviewCommitClosesStateAndSourceRacesBeforeWriting() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let review = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")
    try fixture.env.advanceFeedbackRevision()

    // when / then — validating before the transaction would commit a stale keyboard after a race.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now)
    }
    #expect(try fixture.env.countRows(in: "feedback_targets") == 0)
    #expect(try fixture.env.countRows(in: "outbound_deliveries") == deliveries)
  }

  @Test(arguments: ReviewStateMutation.allCases)
  func reviewCommitRequiresEveryCurrentStateBinding(_ mutation: ReviewStateMutation) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let review = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")
    try fixture.mutateReviewState(mutation, replacement: candidate.replacement.digest)

    // when / then — a pre-transaction state snapshot would authorize a stale keyboard.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now)
    }
    #expect(try fixture.env.countRows(in: "feedback_targets") == 0)
    #expect(try fixture.env.countRows(in: "outbound_deliveries") == deliveries)
  }

  @Test func reviewCommitRevalidatesThePersistedSourceRows() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let review = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")
    try fixture.env.queue.write { db in
      try db.execute(
        sql: "DELETE FROM learning_evaluations WHERE evaluation_digest = ?",
        arguments: [candidate.manifest.evaluations[0].digest.rawValue]
      )
    }

    // when / then — matching revisions cannot substitute for the exact durable source graph.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now)
    }
    #expect(try fixture.env.countRows(in: "feedback_targets") == 0)
    #expect(try fixture.env.countRows(in: "outbound_deliveries") == deliveries)
  }

  @Test func reviewCommitRevalidatesAnExactCandidateHardVeto() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let review = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")
    _ = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: candidate.digest.rawValue,
      signal: .candidateReject
    )
    try fixture.env.queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET feedback_revision = 0 WHERE job_id = ?",
        arguments: [fixture.env.jobId]
      )
    }

    // when / then — a current-looking revision cannot erase an authoritative exact veto.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now)
    }
    #expect(try fixture.env.countRows(in: "feedback_targets") == 0)
    #expect(try fixture.env.countRows(in: "outbound_deliveries") == deliveries)
  }

  @Test(arguments: ReviewJobMutation.allCases)
  func cancelledOrNonrepeatableJobsCannotCommitAReview(_ mutation: ReviewJobMutation) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let review = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)
    let deliveries = try fixture.env.countRows(in: "outbound_deliveries")
    try fixture.mutateReviewJob(mutation)

    // when / then — delivery authority comes from the current job row, not the stale carrier.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now)
    }
    #expect(try fixture.env.countRows(in: "feedback_targets") == 0)
    #expect(try fixture.env.countRows(in: "outbound_deliveries") == deliveries)
  }
}

enum ReviewCarrierMutation: CaseIterable, Sendable {
  case wrongPassedCandidate
  case wrongCandidateAction
  case wrongCandidateSubject
  case swappedEvaluations
  case extraTarget
  case overLimitTargets
  case wrongTargetJob
  case wrongTargetEpoch
  case duplicateNonce
  case emptyNonce
  case wrongExpiry
  case wrongOwner
  case wrongChat
  case wrongChunkSubject
  case wrongChunkOrdinal
  case wrongChunkChat
  case wrongChunkHash
  case nonfinalMarkup
  case missingFinalMarkup
}

enum ReviewJobMutation: CaseIterable, Sendable {
  case cancelled
  case nonrepeatable
}

enum ReviewStateMutation: CaseIterable, Sendable {
  case epoch
  case baseDigest
  case baseRevision
  case feedbackRevision
}

private extension AdmissionOutcome {
  var admissionReceipt: AdmissionReceipt? {
    guard case .admitted(let receipt) = self else {
      return nil
    }
    return receipt
  }

  var awaitingArtifact: CandidateArtifact? {
    guard case .awaitingApproval(let artifact) = self else {
      return nil
    }
    return artifact
  }
}

private extension AdmissionStoreFixture {
  func mutateReviewState(
    _ mutation: ReviewStateMutation,
    replacement: LessonSetDigest
  ) throws {
    try env.queue.write { db in
      switch mutation {
      case .epoch:
        try db.execute(
          sql: "UPDATE job_learning_state SET learning_epoch = 2 WHERE job_id = ?",
          arguments: [env.jobId]
        )
      case .baseDigest:
        try db.execute(
          sql: "UPDATE job_learning_state SET stable_lesson_set_digest = ? WHERE job_id = ?",
          arguments: [replacement.rawValue, env.jobId]
        )
      case .baseRevision:
        try db.execute(
          sql: "UPDATE job_learning_state SET stable_revision = 1 WHERE job_id = ?",
          arguments: [env.jobId]
        )
      case .feedbackRevision:
        try db.execute(
          sql: "UPDATE job_learning_state SET feedback_revision = 1 WHERE job_id = ?",
          arguments: [env.jobId]
        )
      }
    }
  }

  func mutate(
    _ review: CandidateReviewNotice,
    mutation: ReviewCarrierMutation
  ) -> CandidateReviewNotice {
    var targets = review.targets
    var chunks = review.chunks
    switch mutation {
    case .wrongPassedCandidate:
      return CandidateReviewNotice(
        candidateDigest: CandidateDigest(rawValue: "another-candidate"),
        state: review.state,
        subjectDigest: review.subjectDigest,
        targets: targets,
        chunks: chunks
      )
    case .wrongCandidateAction:
      targets[0] = replacing(targets[0], actions: [.candidateApprove])
    case .wrongCandidateSubject:
      targets[0] = replacing(targets[0], subjectDigest: "another-candidate")
    case .swappedEvaluations:
      targets.swapAt(1, 2)
    case .extraTarget:
      targets.append(
        replacing(targets[1], nonce: "extra-target", subjectDigest: "extra-evaluation")
      )
    case .overLimitTargets:
      while targets.count < 7 {
        targets.append(
          replacing(
            targets[1],
            nonce: "extra-target-\(targets.count)",
            subjectDigest: "extra-evaluation-\(targets.count)"
          )
        )
      }
    case .wrongTargetJob:
      targets[0] = replacing(targets[0], jobId: targets[0].jobId + 1)
    case .wrongTargetEpoch:
      targets[0] = replacing(targets[0], epoch: LearningEpoch(99))
    case .duplicateNonce:
      targets[1] = replacing(targets[1], nonce: targets[0].nonce)
    case .emptyNonce:
      targets[0] = replacing(targets[0], nonce: "")
    case .wrongExpiry:
      targets[0] = replacing(
        targets[0],
        expiresAt: targets[0].expiresAt.addingTimeInterval(1)
      )
    case .wrongOwner:
      targets[0] = replacing(targets[0], ownerUserId: 999)
    case .wrongChat:
      targets[0] = replacing(targets[0], chatId: 999)
    case .wrongChunkSubject:
      chunks[0] = replacing(chunks[0], subjectDigest: "another-review")
    case .wrongChunkOrdinal:
      chunks[0] = replacing(chunks[0], ordinal: 1)
    case .wrongChunkChat:
      chunks[0] = replacing(chunks[0], chatId: chunks[0].chatId + 1)
    case .wrongChunkHash:
      chunks[0] = replacing(chunks[0], payloadHash: "wrong-hash")
    case .nonfinalMarkup:
      chunks = [
        chunks[0],
        replacing(chunks[0], ordinal: 1, replyMarkup: "{}"),
      ]
    case .missingFinalMarkup:
      chunks[0] = replacing(chunks[0], replyMarkup: nil)
    }
    return CandidateReviewNotice(
      candidateDigest: review.candidateDigest,
      state: review.state,
      subjectDigest: review.subjectDigest,
      targets: targets,
      chunks: chunks
    )
  }

  func replacing(
    _ target: NewFeedbackTarget,
    nonce: String? = nil,
    jobId: Int64? = nil,
    epoch: LearningEpoch? = nil,
    subjectDigest: String? = nil,
    actions: [OwnerSignal]? = nil,
    ownerUserId: Int64? = nil,
    chatId: Int64? = nil,
    expiresAt: Date? = nil
  ) -> NewFeedbackTarget {
    NewFeedbackTarget(
      nonce: nonce ?? target.nonce,
      jobId: jobId ?? target.jobId,
      epoch: epoch ?? target.epoch,
      subjectKind: target.subjectKind,
      subjectDigest: subjectDigest ?? target.subjectDigest,
      allowedActions: actions ?? target.allowedActions,
      ownerUserId: ownerUserId ?? target.ownerUserId,
      chatId: chatId ?? target.chatId,
      expiresAt: expiresAt ?? target.expiresAt
    )
  }

  func replacing(
    _ chunk: LearningNoticeChunk,
    subjectDigest: String? = nil,
    ordinal: Int? = nil,
    chatId: Int64? = nil,
    payloadHash: String? = nil,
    replyMarkup: String? = "{}"
  ) -> LearningNoticeChunk {
    LearningNoticeChunk(
      subjectDigest: subjectDigest ?? chunk.subjectDigest,
      ordinal: ordinal ?? chunk.ordinal,
      chatId: chatId ?? chunk.chatId,
      payload: chunk.payload,
      payloadHash: payloadHash ?? chunk.payloadHash,
      replyMarkup: replyMarkup
    )
  }

  func setTrialStateForReview(_ id: Int64, state: LearningTrialState) throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE learning_trials SET state = ? WHERE trial_id = ?",
        arguments: [state.rawValue, id]
      )
    }
  }

  func mutateReviewJob(_ mutation: ReviewJobMutation) throws {
    try env.queue.write { db in
      switch mutation {
      case .cancelled:
        try db.execute(
          sql: "UPDATE scheduled_jobs SET status = ? WHERE id = ?",
          arguments: [ScheduledJobStatus.cancelled.rawValue, env.jobId]
        )
      case .nonrepeatable:
        try db.execute(
          sql: "UPDATE scheduled_jobs SET recurrence = NULL WHERE id = ?",
          arguments: [env.jobId]
        )
      }
    }
  }
}
