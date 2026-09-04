import ClawCore
import ClawData
import Foundation
import GRDB
import Testing

@testable import ClawGateway

@Suite struct LearningNoticeTests {
  @Test func reviewTargetsExactEvaluationsWithDistinctNoncesAndStatefulCandidateActions() throws {
    // given
    let candidate = try ReviewFixture.candidate(evaluationCount: 5)
    let admitted = LearningNotices(
      learning: try ReviewFixture.inMemoryStore(),
      poke: {},
      nonceGenerator: ReviewNonceSequence().next,
      chunkLimit: 10_000
    )
    let awaiting = LearningNotices(
      learning: try ReviewFixture.inMemoryStore(),
      poke: {},
      nonceGenerator: ReviewNonceSequence().next,
      chunkLimit: 10_000
    )

    // when
    let admittedNotice = try admitted.reviewNotice(
      candidate: candidate,
      state: .admitted,
      ownerUserId: 42,
      chatId: 777,
      now: ReviewFixture.now
    )
    let awaitingNotice = try awaiting.reviewNotice(
      candidate: candidate,
      state: .awaitingApproval,
      ownerUserId: 42,
      chatId: 777,
      now: ReviewFixture.now
    )

    // then — sharing an evaluation nonce or offering approve on an admitted row misbinds taps.
    #expect(admittedNotice.targets.count == 6)
    #expect(Set(admittedNotice.targets.map(\.nonce)).count == 6)
    #expect(
      admittedNotice.targets.allSatisfy { target in
        target.expiresAt == ReviewFixture.now.addingTimeInterval(EvidenceWindow.maximumAge)
      }
    )
    #expect(admittedNotice.targets.first?.allowedActions == [.candidateReject, .candidateEdit])
    #expect(
      awaitingNotice.targets.first?.allowedActions
        == [.candidateApprove, .candidateReject, .candidateEdit]
    )
    #expect(
      admittedNotice.targets.dropFirst().map(\.subjectDigest)
        == candidate.manifest.evaluations.map { source in source.digest.rawValue }
    )
    #expect(
      admittedNotice.targets.dropFirst().allSatisfy { target in
        target.allowedActions == [.evaluationConfirm, .evaluationDispute]
      }
    )
    let markup = try #require(admittedNotice.chunks.last?.replyMarkup)
    let labels = try ReviewFixture.buttonLabels(markup)
    for runId in [41, 44, 47, 50, 53] {
      #expect(labels.contains("Eval #\(runId) correct"))
      #expect(labels.contains("Eval #\(runId) wrong"))
    }
  }

  @Test func aCandidateWithMoreThanFiveEvaluationsHasNoReviewCarrier() throws {
    // given
    let candidate = try ReviewFixture.candidate(evaluationCount: 6)
    let notices = LearningNotices(
      learning: try ReviewFixture.inMemoryStore(),
      poke: {},
      nonceGenerator: ReviewNonceSequence().next,
      chunkLimit: 10_000
    )

    // when / then — accepting a sixth evaluation exposes a seventh feedback capability.
    #expect(throws: LearningReviewError.invalidCandidate) {
      _ = try notices.reviewNotice(
        candidate: candidate,
        state: .admitted,
        ownerUserId: 42,
        chatId: 777,
        now: ReviewFixture.now
      )
    }
  }

  @Test func multipartReviewPlacesMarkupOnlyOnTheFinalRunlessChunk() throws {
    // given
    let candidate = try ReviewFixture.candidate(evaluationCount: 2)
    let notices = LearningNotices(
      learning: try ReviewFixture.inMemoryStore(),
      poke: {},
      nonceGenerator: ReviewNonceSequence().next,
      chunkLimit: 35
    )

    // when
    let notice = try notices.reviewNotice(
      candidate: candidate,
      state: .admitted,
      ownerUserId: 42,
      chatId: 777,
      now: ReviewFixture.now
    )

    // then — putting markup on an earlier part makes a partial notice actionable.
    #expect(notice.chunks.count > 1)
    #expect(notice.chunks.dropLast().allSatisfy { chunk in chunk.replyMarkup == nil })
    let markup = try #require(notice.chunks.last?.replyMarkup)
    let markupObject = try JSONSerialization.jsonObject(with: Data(markup.utf8))
    #expect(markupObject is [String: Any])
    #expect(notice.chunks.allSatisfy { chunk in chunk.subjectDigest == notice.subjectDigest })
  }

  @Test func enqueuePokesExactlyOnceAfterNewCommitAndNeverOnReplayOrFailure() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let learning = ScheduledLearningStoreGRDB(writer: queue)
    let jobId = try ReviewFixture.armJob(queue: queue)
    let candidate = try ReviewFixture.candidate(jobId: jobId, evaluationCount: 2)
    let other = try ReviewFixture.candidate(jobId: jobId, evaluationCount: 1, suffix: "other")
    let recording = RecordingLearningStore(
      base: learning,
      recordsReviewCommits: true,
      failingReviewCandidate: other.digest
    )
    let pokes = PokeRecorder()
    let notices = LearningNotices(
      learning: recording,
      poke: pokes.poke,
      nonceGenerator: ReviewNonceSequence().next,
      chunkLimit: 10_000
    )

    // when
    let inserted = try notices.enqueueReview(
      candidate: candidate,
      state: .admitted,
      ownerUserId: 42,
      chatId: 777,
      now: ReviewFixture.now
    )
    let replay = try notices.enqueueReview(
      candidate: candidate,
      state: .admitted,
      ownerUserId: 42,
      chatId: 777,
      now: ReviewFixture.now
    )
    #expect(throws: StoreError.self) {
      _ = try notices.enqueueReview(
        candidate: other,
        state: .admitted,
        ownerUserId: 42,
        chatId: 777,
        now: ReviewFixture.now
      )
    }

    // then — poking before/after replay or after failure produces spurious dispatcher drains.
    #expect(inserted)
    #expect(replay == false)
    #expect(pokes.count == 1)
  }

  @Test func committedReviewReplayAfterStateMovementNeverPokesAgain() async throws {
    // given
    let env = try ReflectionRunEnvironment.make()
    await env.runner.runReflection(trigger: env.trigger, now: env.now)
    let candidate = try #require(try env.candidate())
    let pokes = PokeRecorder()
    let notices = LearningNotices(
      learning: env.learning,
      poke: pokes.poke,
      nonceGenerator: ReviewNonceSequence().next,
      chunkLimit: 10_000
    )
    #expect(
      try notices.enqueueReview(
        candidate: candidate,
        state: .admitted,
        ownerUserId: 777,
        chatId: 777,
        now: env.now
      )
    )
    let targets = try env.rowCount("feedback_targets")
    let chunks = try env.rowCount("outbound_deliveries")
    try env.learningStateFeedbackRevision(FeedbackRevision(1))
    let replayTime = env.now.addingTimeInterval(60)

    // when
    let replay = try notices.enqueueReview(
      candidate: candidate,
      state: .admitted,
      ownerUserId: 777,
      chatId: 777,
      now: replayTime
    )

    // then — regenerated nonces do not turn the same stable committed delivery into new work,
    // even though the mutable admission authority has since moved.
    #expect(replay == false)
    #expect(pokes.count == 1)
    #expect(try env.rowCount("feedback_targets") == targets)
    #expect(try env.rowCount("outbound_deliveries") == chunks)
  }
}

private final class ReviewNonceSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return "nonce-\(value)"
  }
}

private final class PokeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedCount
  }

  func poke() {
    lock.lock()
    storedCount += 1
    lock.unlock()
  }
}

private enum ReviewFixture {
  static let now = Date(timeIntervalSince1970: 1_782_000_600)

  static func inMemoryStore() throws -> ScheduledLearningStoreGRDB {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return ScheduledLearningStoreGRDB(writer: queue)
  }

  static func armJob(queue: DatabaseQueue) throws -> Int64 {
    let jobs = ScheduledJobStoreGRDB(writer: queue, learningEnabled: true)
    let job = try jobs.create(
      NewScheduledJob(
        ownerChatId: 777,
        label: "review",
        prompt: "Review this task",
        recurrence: nil,
        timezone: "UTC",
        nextOccurrence: now
      ),
      now: now
    )
    _ = try ScheduledLearningStoreGRDB(writer: queue).armJob(jobId: job.id, now: now)
    return job.id
  }

  static func candidate(
    jobId: Int64 = 41,
    evaluationCount: Int,
    suffix: String = "base"
  ) throws -> CandidateArtifact {
    let base = LessonSet.empty(jobId: jobId)
    let replacement = try LessonSet.canonical(
      jobId: jobId,
      lessons: ["Report every material change for review \(suffix)."]
    )
    let evidence = (0..<evaluationCount).map { index in
      let runId = Int64(41 + index * 3)
      return CandidateEvidenceSource(
        runId: runId,
        digest: EvidenceDigest(rawValue: "evidence-\(suffix)-\(index)"),
        evaluationDigest: EvaluationDigest(rawValue: "evaluation-\(suffix)-\(index)"),
        evaluationRequired: true
      )
    }
    let manifest = CandidateSourceManifest(
      origin: .reflection,
      algorithm: .v1,
      jobId: jobId,
      epoch: LearningEpoch(1),
      triggerDigest: TriggerDigest(rawValue: "trigger-\(suffix)"),
      triggerReason: .recurringIssue,
      qualifyingIssueCodes: ["material.missed"],
      operationId: LearningOperationID(rawValue: "operation-\(suffix)"),
      carrierDigest: CarrierDigest(rawValue: "carrier-\(suffix)"),
      resultDigest: ReflectionResultDigest(rawValue: "result-\(suffix)"),
      baseDigest: base.digest,
      baseRevision: StableRevision(0),
      feedbackRevision: FeedbackRevision(0),
      evidence: evidence,
      evaluations: evidence.map { source in
        CandidateEvaluationSource(runId: source.runId, digest: source.evaluationDigest)
      },
      feedback: [],
      predecessorCandidate: nil,
      predecessorFeedback: nil
    )
    return try CandidateArtifact(replacement: replacement, manifest: manifest)
  }

  static func buttonLabels(_ markup: String) throws -> [String] {
    guard
      let object = try JSONSerialization.jsonObject(with: Data(markup.utf8))
        as? [String: Any],
      let rows = object["inline_keyboard"] as? [[Any]]
    else {
      throw LearningReviewError.invalidCandidate
    }
    return rows.flatMap { row in
      row.compactMap { button in
        (button as? [String: Any])?["text"] as? String
      }
    }
  }
}
