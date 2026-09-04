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

    // when / then — removing the exact subject-kind comparison must not fall through to the
    // generic target writer, and removing the nonempty-payload guard must not accept an empty body
    // merely because its hash matches. Every malformed carrier is rejected at this boundary.
    #expect(throws: StoreError.unexpected("candidate review carrier is inconsistent")) {
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

  @Test func committedReviewReplayPrecedesLaterMutableAuthorityChecks() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let first = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)
    #expect(try fixture.env.learning.commitCandidateReview(first, now: fixture.env.now))
    let snapshot = try fixture.reviewSnapshot()
    try fixture.env.advanceFeedbackRevision()
    let replayTime = fixture.env.now.addingTimeInterval(60)
    let replay = fixture.review(
      candidate: candidate,
      state: .admitted,
      now: replayTime,
      nonceSuffix: "regenerated"
    )

    // when
    let inserted = try fixture.env.learning.commitCandidateReview(replay, now: replayTime)

    // then — validating mutable state before the stable first-chunk identity turns a durable
    // replay into an error and can tempt callers to regenerate orphan target nonces.
    #expect(inserted == false)
    #expect(try fixture.reviewSnapshot() == snapshot)
  }

  @Test(arguments: CommittedReviewCorruption.allCases)
  func partialCommittedReviewFailsClosed(_ corruption: CommittedReviewCorruption) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let review = fixture.multipartReview(candidate: candidate, now: fixture.env.now)
    #expect(try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now))
    try fixture.corruptCommittedReview(corruption, candidate: candidate)
    let snapshot = try fixture.reviewSnapshot()

    // when / then — trusting only the first stable delivery key would hide a missing target or
    // final chunk as a successful replay instead of failing the corrupt atomic record closed.
    #expect(throws: StoreError.self) {
      _ = try fixture.env.learning.commitCandidateReview(review, now: fixture.env.now)
    }
    #expect(try fixture.reviewSnapshot() == snapshot)
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
  case wrongSubjectKind
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
  case emptyChunk
  case nonfinalMarkup
  case missingFinalMarkup
}

enum CommittedReviewCorruption: CaseIterable, Sendable {
  case target
  case finalChunk
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
  func multipartReview(candidate: CandidateArtifact, now: Date) -> CandidateReviewNotice {
    let review = review(candidate: candidate, state: .admitted, now: now)
    let first = "Review this candidate, part one."
    let final = "Review this candidate, part two."
    return CandidateReviewNotice(
      candidateDigest: review.candidateDigest,
      state: review.state,
      subjectDigest: review.subjectDigest,
      targets: review.targets,
      chunks: [
        LearningNoticeChunk(
          subjectDigest: review.subjectDigest,
          ordinal: 0,
          chatId: 777,
          payload: first,
          payloadHash: ContentHash.fnv1a(first),
          replyMarkup: nil
        ),
        LearningNoticeChunk(
          subjectDigest: review.subjectDigest,
          ordinal: 1,
          chatId: 777,
          payload: final,
          payloadHash: ContentHash.fnv1a(final),
          replyMarkup: "{}"
        ),
      ]
    )
  }

  func corruptCommittedReview(
    _ corruption: CommittedReviewCorruption,
    candidate: CandidateArtifact
  ) throws {
    try env.queue.write { db in
      switch corruption {
      case .target:
        try db.execute(
          sql: "DELETE FROM feedback_targets WHERE subject_kind = ? AND subject_digest = ?",
          arguments: [FeedbackSubjectKind.candidate.rawValue, candidate.digest.rawValue]
        )
      case .finalChunk:
        try db.execute(
          sql: "DELETE FROM outbound_deliveries WHERE dedup_key = ?",
          arguments: [
            OutboxDedupKey.make(
              subjectDigest: CandidateReviewIdentity.digest(candidateDigest: candidate.digest),
              ordinal: 1
            )
          ]
        )
      }
    }
  }

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
    case .wrongSubjectKind:
      targets[0] = replacing(targets[0], subjectKind: .evaluation)
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
    case .emptyChunk:
      chunks[0] = replacing(
        chunks[0],
        payload: "",
        payloadHash: ContentHash.fnv1a("")
      )
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
    subjectKind: FeedbackSubjectKind? = nil,
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
      subjectKind: subjectKind ?? target.subjectKind,
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
    payload: String? = nil,
    payloadHash: String? = nil,
    replyMarkup: String? = "{}"
  ) -> LearningNoticeChunk {
    LearningNoticeChunk(
      subjectDigest: subjectDigest ?? chunk.subjectDigest,
      ordinal: ordinal ?? chunk.ordinal,
      chatId: chatId ?? chunk.chatId,
      payload: payload ?? chunk.payload,
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

  struct ReviewSnapshot: Equatable {
    let targets: [String]
    let chunks: [String]
  }

  func reviewSnapshot() throws -> ReviewSnapshot {
    try env.queue.read { db in
      let targets = try Row.fetchAll(
        db,
        sql: """
          SELECT nonce, subject_kind, subject_digest, allowed_actions
          FROM feedback_targets ORDER BY nonce
          """
      ).map { row in
        let nonce: String = row["nonce"]
        let kind: String = row["subject_kind"]
        let digest: String = row["subject_digest"]
        let actions: String = row["allowed_actions"]
        return [nonce, kind, digest, actions].joined(separator: "|")
      }
      let chunks = try Row.fetchAll(
        db,
        sql: """
          SELECT dedup_key, step_index, payload, payload_hash, reply_markup
          FROM outbound_deliveries WHERE delivery_source = ? ORDER BY step_index
          """,
        arguments: [DeliverySource.learning.rawValue]
      ).map { row in
        let key: String = row["dedup_key"]
        let ordinal: Int = row["step_index"]
        let payload: String = row["payload"]
        let hash: String = row["payload_hash"]
        let markup: String? = row["reply_markup"]
        return [key, String(ordinal), payload, hash, markup ?? "nil"].joined(separator: "|")
      }
      return ReviewSnapshot(targets: targets, chunks: chunks)
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
