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
    #expect(rendered.contains("assignments: 1 of 3"))
    #expect(rendered.contains("assignment outcomes: 1 unresolved"))
    #expect(rendered.contains("decision result trial: 41"))
    #expect(rendered.contains("decision result generation: 2"))
    #expect(rendered.contains("  1. Keep facts exact."))
    #expect(rendered.contains("  2. Preserve order."))
    #expect(rendered.contains("warning: stored trial pointer does not match the live trial"))

    // when
    let listed = LearningSurface.render([.readable(view)], style: .list)

    // then — omitting warnings from the compact projection hides a known integrity mismatch.
    #expect(listed.contains("warning"))
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
      counts: LearningTrialCounts(consumed: 1, maximum: 3, unresolved: 1),
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
