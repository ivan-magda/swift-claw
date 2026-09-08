import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct LearningSurfaceTests {
  @Test func detailKeepsDistinctIdentitiesAndBothDeadlines() throws {
    // given
    let view = try learningDetailView()
    let assignmentDeadline = Date(timeIntervalSince1970: 1_782_086_400)
    let decisionDeadline = Date(timeIntervalSince1970: 1_782_172_800)

    // when
    let rendered = LearningSurface.render([.readable(view)])

    // then — swapping digest fields or dropping the second deadline loses distinct stored facts.
    #expect(rendered.contains("candidate digest: \(Self.candidate.rawValue)"))
    #expect(rendered.contains("trial base digest: \(Self.base.rawValue)"))
    #expect(
      rendered.contains("replacement digest: \(view.liveTrial?.replacementDigest.rawValue ?? "")")
    )
    #expect(rendered.contains(assignmentDeadline.wallClockMinute(in: Self.zone)))
    #expect(rendered.contains(decisionDeadline.wallClockMinute(in: Self.zone)))
    #expect(rendered.contains("assignments: 10 of 12"))
    #expect(
      rendered.contains("assignment outcomes: 1 positive, 2 negative, 3 neutral, 4 unresolved")
    )
    #expect(rendered.contains("decision result trial: 41"))
    #expect(rendered.contains("decision result generation: 2"))
    #expect(rendered.contains("  1. Keep facts exact."))
    #expect(rendered.contains("  2. Preserve order."))
    #expect(rendered.contains("warning: stored trial pointer does not match the live trial"))

    // when
    let listed = LearningSurface.render([.readable(view)], style: .list)

    // then — omitting warnings from the compact projection hides a known integrity mismatch.
    #expect(listed.contains("warning"))
    #expect(
      listed.contains("assignment outcomes: 1 positive, 2 negative, 3 neutral, 4 unresolved")
    )
  }

  @Test func unreadableAndUnarmedStatesDoNotInventLearningFacts() {
    // given
    let identity = LearningJobIdentity(
      jobId: 8,
      label: "unarmed",
      status: .paused,
      timezone: "Europe/Berlin"
    )
    let unreadable = UnreadableLearningJob(jobId: 9, validatedLabel: nil)

    // when
    let unarmedText = LearningSurface.render([.unarmed(identity)])
    let unreadableText = LearningSurface.render([.unreadable(unreadable)])

    // then — rendering either as a canonical empty stable state would invent an epoch and lessons.
    #expect(unarmedText.contains("learning state: not created"))
    #expect(unarmedText.contains("learning epoch") == false)
    #expect(unreadableText.contains("learning state: unreadable"))
    #expect(unreadableText.contains("unknown label"))
  }

  @Test func listPreservesStoreOrderAndKeepsUnreadableRowsVisible() throws {
    // given
    let readable = try learningDetailView()
    let unreadable = UnreadableLearningJob(jobId: 72, validatedLabel: "damaged")

    // when
    let rendered = LearningSurface.render(
      [.readable(readable), .unreadable(unreadable)],
      style: .list
    )

    // then — filtering semantic corruption hides an armed job from the owner.
    let lines = rendered.split(separator: "\n")
    #expect(lines.first?.hasPrefix("7 · digest") == true)
    #expect(lines.last?.hasPrefix("72 · damaged · learning state unreadable") == true)
  }

  @Test func resetDecisionRendersOnlySafeBarrierFactsAndCounts() {
    // given
    let empty = LessonSet.empty(jobId: 7)
    let inputs = LearningResetDecisionInputs(
      oldEpoch: LearningEpoch(3),
      oldStableDigest: Self.base,
      oldStableRevision: StableRevision(6),
      feedbackRevisionAtCut: FeedbackRevision(9),
      priorOpenTrialId: 41
    )
    let result = LearningResetDecisionResult(
      newEpoch: LearningEpoch(4),
      emptyStableDigest: empty.digest,
      newStableRevision: StableRevision(7),
      closedTrials: [
        ResetTrialIdentity(
          trialId: 41,
          jobId: 7,
          epoch: LearningEpoch(3),
          generation: 2,
          baseDigest: Self.base,
          candidateDigest: Self.candidate,
          algorithm: .v1
        )
      ],
      invalidatedTargetCount: 5,
      invalidatedChallengeCount: 2,
      staleNoCallOperationIds: [LearningOperationID(rawValue: "opaque-stale-id")],
      inFlightOperationIds: [LearningOperationID(rawValue: "opaque-flight-id")]
    )
    let view = ReadableJobLearningView(
      job: LearningJobIdentity(
        jobId: 7,
        label: "digest",
        status: .active,
        timezone: Self.zone.identifier
      ),
      epoch: result.newEpoch,
      stableRevision: result.newStableRevision,
      stableLessons: empty,
      liveTrial: nil,
      lastDecision: LearningDecisionView(
        decisionId: 14,
        jobId: 7,
        epoch: result.newEpoch,
        algorithm: .v1,
        decidedAt: Date(timeIntervalSince1970: 1_782_000_600),
        detail: .learningReset(inputs: inputs, result: result)
      ),
      warnings: []
    )

    // when
    let rendered = LearningSurface.render([.readable(view)])

    // then — rendering raw receipt identities would expose opaque operation ids without adding
    // owner value; the category counts and epoch transition are the useful safe projection.
    #expect(rendered.contains("decision kind: \(ResetReceipt.kind)"))
    #expect(rendered.contains("reset old epoch: 3"))
    #expect(rendered.contains("reset new epoch: 4"))
    #expect(rendered.contains("reset old stable digest: \(Self.base.rawValue)"))
    #expect(rendered.contains("reset empty stable digest: \(empty.digest.rawValue)"))
    #expect(rendered.contains("reset old stable revision: 6"))
    #expect(rendered.contains("reset new stable revision: 7"))
    #expect(rendered.contains("reset feedback revision: 9"))
    #expect(rendered.contains("reset prior live trial: 41"))
    #expect(rendered.contains("reset closed trials: 1"))
    #expect(rendered.contains("reset invalidated targets: 5"))
    #expect(rendered.contains("reset invalidated challenges: 2"))
    #expect(rendered.contains("reset abandoned calls: 1"))
    #expect(rendered.contains("reset in-flight calls: 1"))
    #expect(rendered.contains("opaque-stale-id") == false)
    #expect(rendered.contains("opaque-flight-id") == false)
  }
}

private extension LearningSurfaceTests {
  static let base = LessonSetDigest(rawValue: String(repeating: "a", count: 64))
  static let candidate = CandidateDigest(rawValue: String(repeating: "b", count: 64))
  static let replacement = LessonSetDigest(rawValue: String(repeating: "c", count: 64))
  static let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt

  func learningDetailView() throws -> ReadableJobLearningView {
    let lessons = try LessonSet.canonical(
      jobId: 7,
      lessons: ["Keep facts exact.", "Preserve order."]
    )
    let trial = LearningTrialView(
      trialId: 41,
      epoch: LearningEpoch(3),
      generation: 2,
      state: .draining,
      candidateDigest: Self.candidate,
      baseDigest: Self.base,
      baseRevision: StableRevision(6),
      replacementDigest: Self.replacement,
      counts: LearningTrialCounts(
        consumed: 10,
        maximum: 12,
        positive: 1,
        negative: 2,
        neutral: 3,
        unresolved: 4
      ),
      assignmentDeadline: Date(timeIntervalSince1970: 1_782_086_400),
      decisionDeadline: Date(timeIntervalSince1970: 1_782_172_800)
    )
    let receipt = AdmissionReceipt(
      candidateDigest: Self.candidate,
      replacementDigest: Self.replacement,
      trialId: 41,
      generation: 2
    )
    let decision = LearningDecisionView(
      decisionId: 13,
      jobId: 7,
      epoch: LearningEpoch(3),
      algorithm: .v1,
      decidedAt: Date(timeIntervalSince1970: 1_782_000_600),
      detail: .candidateAdmission(
        inputs: AdmissionDecisionInputs(candidateDigest: Self.candidate),
        result: receipt
      )
    )
    return ReadableJobLearningView(
      job: LearningJobIdentity(
        jobId: 7,
        label: "digest",
        status: .active,
        timezone: Self.zone.identifier
      ),
      epoch: LearningEpoch(3),
      stableRevision: StableRevision(6),
      stableLessons: lessons,
      liveTrial: trial,
      lastDecision: decision,
      warnings: [.trialPointerMismatch]
    )
  }
}
