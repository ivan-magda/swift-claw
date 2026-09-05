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
