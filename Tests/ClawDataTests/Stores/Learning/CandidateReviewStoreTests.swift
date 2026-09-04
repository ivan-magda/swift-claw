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
    let admitted = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let receipt = try #require(admitted.admissionReceipt)
    let first = fixture.review(candidate: candidate, state: .admitted, now: fixture.env.now)
    #expect(try fixture.env.learning.commitCandidateReview(first, now: fixture.env.now))
    let snapshot = try fixture.reviewSnapshot()
    try fixture.env.advanceFeedbackRevision()
    try fixture.setTrialStateForReview(receipt.trialId, state: .closed)
    try fixture.env.queue.write { db in
      try db.execute(
        sql: """
          UPDATE job_learning_state SET learning_epoch = 2, stable_revision = 1
          WHERE job_id = ?
          """,
        arguments: [fixture.env.jobId]
      )
      try db.execute(
        sql: "UPDATE scheduled_jobs SET status = ? WHERE id = ?",
        arguments: [ScheduledJobStatus.cancelled.rawValue, fixture.env.jobId]
      )
    }
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

  @Test func subsecondReviewCommitReplaysAgainstOneNormalizedDeliveryInstant() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
    let candidate = try fixture.persistedCandidate()
    _ = try fixture.env.learning.admitCandidate(
      digest: candidate.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let wholeSecond = Date(
      timeIntervalSince1970: fixture.env.now.timeIntervalSince1970.rounded(.down)
    )
    let reviewTime = wholeSecond.addingTimeInterval(0.4996)
    let first = fixture.multipartReview(
      candidate: candidate,
      now: reviewTime,
      nonceSuffix: "subsecond-first"
    )
    #expect(try fixture.env.learning.commitCandidateReview(first, now: reviewTime))
    let snapshot = try fixture.reviewSnapshot()
    let replay = fixture.multipartReview(
      candidate: candidate,
      now: reviewTime,
      nonceSuffix: "subsecond-replay"
    )

    // when
    let inserted = try fixture.env.learning.commitCandidateReview(replay, now: reviewTime)

    // then — writing raw `.4996` lets millisecond serialization become `.500`, so replay rounds
    // the delivery up although the integer target expiry rounded the original instant down.
    #expect(inserted == false)
    #expect(
      try fixture.reviewCreatedDates(subjectDigest: first.subjectDigest) == [
        wholeSecond, wholeSecond,
      ]
    )
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

    // when / then — trusting self-consistent subjects or hashes instead of the keyboard's exact
    // nonce-addressed target rows and the replay's immutable chunk bodies hides partial commits.
    #expect(throws: StoreError.unexpected("candidate review replay is incomplete")) {
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
  case wrongTargetJob
  case wrongTargetEpoch
  case duplicateNonce
  case emptyNonce
  case delimiterNonce
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
  case invalidFinalMarkup
}

enum CommittedReviewCorruption: CaseIterable, Sendable {
  case admittedCandidateActions
  case missingEvaluationWithDecoy
  case wrongCallbackNonce
  case missingCallbackNonce
  case wrongCallbackAction
  case wrongCallbackLabel
  case emptyObjectMarkup
  case noncanonicalMarkup
  case missingAdmissionReceipt
  case runId
  case deliverySource
  case missingChunk
  case extraChunk
  case noncontiguousChunk
  case payload
  case payloadHash
  case nonfinalMarkup
  case shiftedTargetExpiry
  case mismatchedChunkCreation
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
  func multipartReview(
    candidate: CandidateArtifact,
    now: Date,
    nonceSuffix: String = "first"
  ) -> CandidateReviewNotice {
    let review = review(
      candidate: candidate,
      state: .admitted,
      now: now,
      nonceSuffix: nonceSuffix
    )
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
          replyMarkup: review.chunks[0].replyMarkup
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
      case .admittedCandidateActions:
        let actions = try #require(
          String(
            data: JSONEncoder().encode(
              [
                OwnerSignal.candidateApprove.rawValue,
                OwnerSignal.candidateReject.rawValue,
                OwnerSignal.candidateEdit.rawValue,
              ]
            ),
            encoding: .utf8
          )
        )
        try db.execute(
          sql: "UPDATE feedback_targets SET allowed_actions = ? WHERE subject_kind = ?",
          arguments: [actions, FeedbackSubjectKind.candidate.rawValue]
        )
        try rewriteCommittedMarkup(db) { rows in
          rows[0] = [
            FeedbackKeyboard.Button(
              text: "Approve",
              nonce: rows[0][0].nonce,
              action: .candidateApprove
            ),
            FeedbackKeyboard.Button(
              text: "Reject",
              nonce: rows[0][0].nonce,
              action: .candidateReject
            ),
            FeedbackKeyboard.Button(
              text: "Edit",
              nonce: rows[0][0].nonce,
              action: .candidateEdit
            ),
          ]
        }
      case .missingEvaluationWithDecoy:
        let markup = try committedMarkup(db)
        let rows = try FeedbackKeyboard.parseMarkup(markup)
        let nonce = rows[1][0].nonce
        try db.execute(
          sql: """
            INSERT INTO feedback_targets(nonce, job_id, learning_epoch, subject_kind,
              subject_digest, allowed_actions, owner_user_id, chat_id, expires_at, consumed_at)
            SELECT ?, job_id, learning_epoch, subject_kind, subject_digest, allowed_actions,
              owner_user_id, chat_id, expires_at, consumed_at
            FROM feedback_targets WHERE nonce = ?
            """,
          arguments: ["decoy-evaluation-target", nonce]
        )
        try db.execute(
          sql: "DELETE FROM feedback_targets WHERE nonce = ?",
          arguments: [nonce]
        )
      case .wrongCallbackNonce:
        try rewriteCommittedMarkup(db) { rows in
          let button = rows[1][0]
          rows[1][0] = FeedbackKeyboard.Button(
            text: button.text,
            nonce: "missing-target-nonce",
            action: button.action
          )
        }
      case .missingCallbackNonce:
        let markup = try committedMarkup(db)
        let rows = try FeedbackKeyboard.parseMarkup(markup)
        let callback = FeedbackKeyboard.callbackData(
          nonce: rows[1][0].nonce,
          action: rows[1][0].action
        )
        try setCommittedMarkup(db, markup.replacingOccurrences(of: callback, with: "fb::ed"))
      case .wrongCallbackAction:
        try rewriteCommittedMarkup(db) { rows in
          let button = rows[1][1]
          rows[1][1] = FeedbackKeyboard.Button(
            text: button.text,
            nonce: button.nonce,
            action: .evaluationConfirm
          )
        }
      case .wrongCallbackLabel:
        try rewriteCommittedMarkup(db) { rows in
          let button = rows[1][1]
          rows[1][1] = FeedbackKeyboard.Button(
            text: "Incorrect evaluation label",
            nonce: button.nonce,
            action: button.action
          )
        }
      case .emptyObjectMarkup:
        try setCommittedMarkup(db, "{}")
      case .noncanonicalMarkup:
        try setCommittedMarkup(db, " \(try committedMarkup(db))")
      case .missingAdmissionReceipt:
        try db.execute(
          sql: "DELETE FROM learning_decisions WHERE kind = ?",
          arguments: [AdmissionReceipt.kind]
        )
      case .runId:
        try db.execute(
          sql: """
            UPDATE outbound_deliveries SET run_id = (SELECT MIN(id) FROM runs)
            WHERE delivery_source = ?
            """,
          arguments: [DeliverySource.learning.rawValue]
        )
      case .deliverySource:
        try db.execute(
          sql: "UPDATE outbound_deliveries SET delivery_source = ? WHERE delivery_source = ?",
          arguments: ["corrupt", DeliverySource.learning.rawValue]
        )
      case .missingChunk:
        try db.execute(
          sql: "DELETE FROM outbound_deliveries WHERE step_index = 1 AND delivery_source = ?",
          arguments: [DeliverySource.learning.rawValue]
        )
      case .extraChunk:
        let subject = CandidateReviewIdentity.digest(candidateDigest: candidate.digest)
        let payload = "Unexpected third chunk."
        let markup = try committedMarkup(db)
        try db.execute(
          sql: "UPDATE outbound_deliveries SET reply_markup = NULL WHERE step_index = 1"
        )
        try db.execute(
          sql: """
            INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
              payload_hash, reply_markup, status, created_ts, delivery_source)
            VALUES(NULL, 2, 777, ?, ?, ?, ?, 'PENDING', ?, ?)
            """,
          arguments: [
            OutboxDedupKey.make(subjectDigest: subject, ordinal: 2),
            payload,
            ContentHash.fnv1a(payload),
            markup,
            env.now,
            DeliverySource.learning.rawValue,
          ]
        )
      case .noncontiguousChunk:
        try db.execute(
          sql: "UPDATE outbound_deliveries SET step_index = 3 WHERE step_index = 1"
        )
      case .payload:
        let payload = "Altered but self-consistent review body."
        try db.execute(
          sql: "UPDATE outbound_deliveries SET payload = ?, payload_hash = ? WHERE step_index = 0",
          arguments: [payload, ContentHash.fnv1a(payload)]
        )
      case .payloadHash:
        try db.execute(
          sql: "UPDATE outbound_deliveries SET payload_hash = ? WHERE step_index = 0",
          arguments: ["wrong-hash"]
        )
      case .nonfinalMarkup:
        let markup = try committedMarkup(db)
        try db.execute(
          sql: "UPDATE outbound_deliveries SET reply_markup = ? WHERE step_index = 0",
          arguments: [markup]
        )
      case .shiftedTargetExpiry:
        try db.execute(sql: "UPDATE feedback_targets SET expires_at = expires_at + 1")
      case .mismatchedChunkCreation:
        try db.execute(
          sql: "UPDATE outbound_deliveries SET created_ts = ? WHERE step_index = 1",
          arguments: [env.now.addingTimeInterval(1)]
        )
      }
    }
  }

  func committedMarkup(_ db: Database) throws -> String {
    let markup: String? = try String.fetchOne(
      db,
      sql: """
        SELECT reply_markup FROM outbound_deliveries
        WHERE delivery_source = ? AND reply_markup IS NOT NULL
        """,
      arguments: [DeliverySource.learning.rawValue]
    )
    return try #require(markup)
  }

  func setCommittedMarkup(_ db: Database, _ markup: String) throws {
    try db.execute(
      sql: "UPDATE outbound_deliveries SET reply_markup = ? WHERE step_index = 1",
      arguments: [markup]
    )
  }

  func rewriteCommittedMarkup(
    _ db: Database,
    mutate: (inout [[FeedbackKeyboard.Button]]) -> Void
  ) throws {
    var rows = try FeedbackKeyboard.parseMarkup(try committedMarkup(db))
    mutate(&rows)
    try setCommittedMarkup(db, try #require(FeedbackKeyboard.markup(rows: rows)))
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
    case .wrongTargetJob:
      targets[0] = replacing(targets[0], jobId: targets[0].jobId + 1)
    case .wrongTargetEpoch:
      targets[0] = replacing(targets[0], epoch: LearningEpoch(99))
    case .duplicateNonce:
      targets[1] = replacing(targets[1], nonce: targets[0].nonce)
    case .emptyNonce:
      targets[0] = replacing(targets[0], nonce: "")
    case .delimiterNonce:
      let validNonce = targets[0].nonce
      let delimiterNonce = "nonce:with-delimiter"
      targets[0] = replacing(targets[0], nonce: delimiterNonce)
      let markup = chunks[0].replyMarkup?.replacingOccurrences(
        of: validNonce,
        with: delimiterNonce
      )
      chunks[0] = replacing(chunks[0], replyMarkup: markup)
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
      let markup = chunks[0].replyMarkup
      chunks = [
        replacing(chunks[0], replyMarkup: markup),
        replacing(chunks[0], ordinal: 1, replyMarkup: markup),
      ]
    case .missingFinalMarkup:
      chunks[0] = replacing(chunks[0], replyMarkup: nil)
    case .invalidFinalMarkup:
      chunks[0] = replacing(chunks[0], replyMarkup: "{}")
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
          SELECT target_id, nonce, job_id, learning_epoch, subject_kind, subject_digest,
            allowed_actions, owner_user_id, chat_id, expires_at, consumed_at
          FROM feedback_targets ORDER BY nonce
          """
      ).map { row in
        let targetId: Int64 = row["target_id"]
        let nonce: String = row["nonce"]
        let jobId: Int64 = row["job_id"]
        let epoch: Int64 = row["learning_epoch"]
        let kind: String = row["subject_kind"]
        let digest: String = row["subject_digest"]
        let actions: String = row["allowed_actions"]
        let owner: Int64 = row["owner_user_id"]
        let chat: Int64 = row["chat_id"]
        let expiry: Int64 = row["expires_at"]
        let consumed: Int64? = row["consumed_at"]
        return [
          String(targetId), nonce, String(jobId), String(epoch), kind, digest, actions,
          String(owner), String(chat), String(expiry), consumed.map(String.init) ?? "nil",
        ].joined(separator: "|")
      }
      let chunks = try Row.fetchAll(
        db,
        sql: """
          SELECT run_id, step_index, chat_id, dedup_key, payload, payload_hash,
            telegram_message_id, status, created_ts, sent_ts, approval_id, reply_markup,
            message_thread_id, reply_to_message_id, delivery_source
          FROM outbound_deliveries ORDER BY dedup_key
          """
      ).map { row in
        let runId: Int64? = row["run_id"]
        let key: String = row["dedup_key"]
        let ordinal: Int = row["step_index"]
        let chatId: Int64 = row["chat_id"]
        let payload: String = row["payload"]
        let hash: String = row["payload_hash"]
        let messageId: Int64? = row["telegram_message_id"]
        let status: String = row["status"]
        let created: DatabaseValue = row["created_ts"]
        let sent: DatabaseValue = row["sent_ts"]
        let approvalId: Int64? = row["approval_id"]
        let markup: String? = row["reply_markup"]
        let threadId: Int64? = row["message_thread_id"]
        let replyId: Int64? = row["reply_to_message_id"]
        let source: String = row["delivery_source"]
        let run = runId.map(String.init) ?? "nil"
        let message = messageId.map(String.init) ?? "nil"
        let approval = approvalId.map(String.init) ?? "nil"
        let thread = threadId.map(String.init) ?? "nil"
        let reply = replyId.map(String.init) ?? "nil"
        return [
          run, String(ordinal), String(chatId), key, payload, hash, message, status,
          String(describing: created), String(describing: sent), approval, markup ?? "nil", thread,
          reply, source,
        ].joined(separator: "|")
      }
      return ReviewSnapshot(targets: targets, chunks: chunks)
    }
  }

  func reviewCreatedDates(subjectDigest: String) throws -> [Date] {
    let prefix = OutboxDedupKey.make(subjectDigest: subjectDigest, ordinal: 0).dropLast()
    return try env.queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT created_ts FROM outbound_deliveries
          WHERE dedup_key GLOB ? ORDER BY step_index
          """,
        arguments: ["\(prefix)*"]
      ).map { row in
        row["created_ts"]
      }
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
