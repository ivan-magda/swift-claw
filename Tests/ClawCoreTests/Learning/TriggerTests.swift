import ClawCore
import Foundation
import Testing

@Suite struct TriggerTests {
  @Test func twoDistinctRunsSharingExactCodesTriggerOnceWithSortedCodes() throws {
    // given
    let window = [
      outcome(runId: 1, codes: ["b", "a", "b"]),
      outcome(runId: 2, codes: ["b", "a"]),
      outcome(runId: 3, codes: ["c"]),
    ]

    // when
    let trigger = LearningTrigger.detect(window: window, corrections: [])

    // then
    let identity = try #require(trigger)
    #expect(identity.issueCodes == ["a", "b"])
    #expect(identity.reason == .recurringIssue)
  }

  @Test func oneRunCountsOnlyOncePerCode() {
    // given
    let window = [outcome(runId: 1, codes: ["a", "a"])]

    // when
    let trigger = LearningTrigger.detect(window: window, corrections: [])

    // then
    #expect(trigger == nil)
  }

  @Test func emptyIssueListsNeverTrigger() {
    // given
    let window = [outcome(runId: 1, codes: []), outcome(runId: 2, codes: [])]

    // when
    let trigger = LearningTrigger.detect(window: window, corrections: [])

    // then
    #expect(trigger == nil)
  }

  @Test func issueCodesCompareByExactEquality() {
    // given
    let window = [outcome(runId: 1, codes: ["issue"]), outcome(runId: 2, codes: ["Issue"])]

    // when
    let trigger = LearningTrigger.detect(window: window, corrections: [])

    // then
    #expect(trigger == nil)
  }

  @Test func canonicallyEquivalentIssueCodesRemainByteDistinct() {
    // given
    let precomposed = "\u{e9}"
    let decomposed = "e\u{301}"
    let window = [
      outcome(runId: 1, codes: [precomposed]),
      outcome(runId: 2, codes: [decomposed]),
    ]

    // when
    let trigger = LearningTrigger.detect(window: window, corrections: [])

    // then
    #expect(trigger == nil)
  }

  @Test func positiveRunDoesNotEraseARecurringCode() throws {
    // given
    let window = [
      outcome(runId: 1, codes: ["a"]),
      outcome(runId: 2, codes: [], outcome: .positive),
      outcome(runId: 3, codes: ["a"]),
    ]

    // when
    let trigger = LearningTrigger.detect(window: window, corrections: [])

    // then
    #expect(try #require(trigger).issueCodes == ["a"])
  }

  @Test func oneOwnerCorrectionTriggersAfterOneEligibleRun() throws {
    // given
    let window = [outcome(runId: 1, codes: [])]

    // when
    let trigger = LearningTrigger.detect(
      window: window,
      corrections: [correction(runId: 1)]
    )

    // then
    #expect(try #require(trigger).reason == .ownerCorrection)
  }

  @Test func correctionForARunOutsideTheWindowDoesNotTrigger() {
    // given
    let window = [outcome(runId: 1, codes: [])]

    // when
    let trigger = LearningTrigger.detect(
      window: window,
      corrections: [correction(runId: 2)]
    )

    // then
    #expect(trigger == nil)
  }

  @Test func noTriggerOpensWhileATrialIsOpen() {
    // given
    let window = [outcome(runId: 1, codes: ["a"]), outcome(runId: 2, codes: ["a"])]

    // when
    let trigger = LearningTrigger.detect(window: window, corrections: [], trialIsOpen: true)

    // then
    #expect(trigger == nil)
  }

  @Test func supersededOwnerCorrectionDoesNotTrigger() {
    // given
    let window = [outcome(runId: 1, codes: [])]
    let superseded = correction(runId: 1)
    let replacement = FeedbackEvent(
      id: 2,
      runId: 1,
      signal: .resultUseful,
      payload: nil,
      revision: FeedbackRevision(3),
      supersedes: superseded.id,
      occurredAt: Date(timeIntervalSince1970: 5_000_001)
    )

    // when
    let trigger = LearningTrigger.detect(
      window: window,
      corrections: [superseded, replacement]
    )

    // then
    #expect(trigger == nil)
  }

  @Test func laterUsefulResultOverridesCorrectionWithoutASupersessionEdge() {
    // given
    let window = [outcome(runId: 1, codes: [])]
    let events = [
      feedback(.resultCorrection, runId: 1, id: 1, revision: 2),
      feedback(.resultUseful, runId: 1, id: 2, revision: 3),
    ]

    // when
    let trigger = LearningTrigger.detect(window: window, corrections: events)

    // then
    #expect(trigger == nil)
  }

  @Test func winningResultIsSelectedIndependentlyForEachEligibleRun() throws {
    // given
    let window = [outcome(runId: 1, codes: []), outcome(runId: 2, codes: [])]
    let events = [
      feedback(.resultCorrection, runId: 1, id: 1, revision: 2),
      feedback(.resultUseful, runId: 2, id: 2, revision: 3),
    ]

    // when
    let trigger = LearningTrigger.detect(window: window, corrections: events)

    // then
    #expect(try #require(trigger).reason == .ownerCorrection)
  }

  @Test func windowKeepsNewestFiveByOccurrenceThenRunId() {
    // given
    let cutoff = Date(timeIntervalSince1970: 3_000_000)
    let evaluations = [
      outcome(
        runId: 9,
        codes: [],
        occurrenceAt: cutoff.addingTimeInterval(-4),
        completedAt: cutoff.addingTimeInterval(-1)
      ),
      outcome(
        runId: 3,
        codes: [],
        occurrenceAt: cutoff.addingTimeInterval(-3),
        completedAt: cutoff.addingTimeInterval(-3)
      ),
      outcome(
        runId: 2,
        codes: [],
        occurrenceAt: cutoff.addingTimeInterval(-3),
        completedAt: cutoff.addingTimeInterval(-2)
      ),
      outcome(
        runId: 8,
        codes: [],
        occurrenceAt: cutoff.addingTimeInterval(-2),
        completedAt: cutoff.addingTimeInterval(-4)
      ),
      outcome(
        runId: 7,
        codes: [],
        occurrenceAt: cutoff.addingTimeInterval(-1),
        completedAt: cutoff.addingTimeInterval(-200)
      ),
      outcome(
        runId: 1,
        codes: [],
        occurrenceAt: cutoff,
        completedAt: cutoff.addingTimeInterval(-100)
      ),
    ]

    // when
    let window = EvidenceWindow.select(
      from: evaluations,
      compatibility: compatibility,
      cutoff: cutoff
    )

    // then
    #expect(window.map(\.runId) == [2, 3, 8, 7, 1])
  }

  @Test func evaluationCompletedAfterTheCutoffIsExcluded() {
    // given
    let cutoff = Date(timeIntervalSince1970: 5_000_000)
    let evaluations = [
      outcome(runId: 1, codes: [], completedAt: cutoff),
      outcome(runId: 2, codes: [], completedAt: cutoff.addingTimeInterval(1)),
    ]

    // when
    let window = EvidenceWindow.select(
      from: evaluations,
      compatibility: compatibility,
      cutoff: cutoff
    )

    // then
    #expect(window.map(\.runId) == [1])
  }

  @Test func evaluationsOlderThanThirtyDaysAreExcluded() {
    // given
    let cutoff = Date(timeIntervalSince1970: 4_000_000)
    let exactlyThirtyDays = cutoff.addingTimeInterval(-EvidenceWindow.maximumAge)
    let evaluations = [
      outcome(runId: 1, codes: [], occurrenceAt: exactlyThirtyDays, completedAt: cutoff),
      outcome(
        runId: 2,
        codes: [],
        occurrenceAt: exactlyThirtyDays.addingTimeInterval(-1),
        completedAt: cutoff
      ),
    ]

    // when
    let window = EvidenceWindow.select(
      from: evaluations,
      compatibility: compatibility,
      cutoff: cutoff
    )

    // then
    #expect(window.map(\.runId) == [1])
  }

  @Test func compatibilityMismatchStartsASeparateWindow() {
    // given
    let cutoff = Date(timeIntervalSince1970: 5_000_000)
    let evaluations = [
      outcome(runId: 1, codes: [], compatibility: compatibility),
      outcome(runId: 2, codes: [], compatibility: CompatibilityDigest(rawValue: "other")),
    ]

    // when
    let window = EvidenceWindow.select(
      from: evaluations,
      compatibility: compatibility,
      cutoff: cutoff
    )

    // then
    #expect(window.map(\.runId) == [1])
  }

  @Test func trialRunsNeverEnterAStableWindow() {
    // given
    let cutoff = Date(timeIntervalSince1970: 5_000_000)
    let evaluations = [
      outcome(runId: 1, codes: [], trialId: nil),
      outcome(runId: 2, codes: [], trialId: 9),
    ]

    // when
    let window = EvidenceWindow.select(
      from: evaluations,
      compatibility: compatibility,
      cutoff: cutoff
    )

    // then
    #expect(window.map(\.runId) == [1])
  }

  @Test func triggerIdentityUsesUnambiguousFieldBoundaries() throws {
    // given
    let firstWindow = [
      outcome(
        runId: 1,
        codes: ["issue"],
        evidenceDigest: EvidenceDigest(rawValue: "left\u{0}edge")
      ),
      outcome(runId: 2, codes: ["issue"], evidenceDigest: EvidenceDigest(rawValue: "right")),
    ]
    let secondWindow = [
      outcome(runId: 1, codes: ["issue"], evidenceDigest: EvidenceDigest(rawValue: "left")),
      outcome(
        runId: 2,
        codes: ["issue"],
        evidenceDigest: EvidenceDigest(rawValue: "edge\u{0}right")
      ),
    ]

    // when
    let first = try #require(LearningTrigger.detect(window: firstWindow, corrections: []))
    let second = try #require(LearningTrigger.detect(window: secondWindow, corrections: []))

    // then
    #expect(first.digest != second.digest)
  }

  @Test func issueCodeMembersUseUnambiguousFieldBoundaries() {
    // given
    let first = identity(issueCodes: ["a\u{0}b", "c"])

    // when
    let shifted = identity(issueCodes: ["a", "b\u{0}c"])

    // then
    #expect(first.digest != shifted.digest)
  }

  @Test func triggerReasonIsDescriptiveRatherThanIdentity() {
    // given
    let recurring = identity(reason: .recurringIssue)

    // when
    let correction = identity(reason: .ownerCorrection)

    // then
    #expect(recurring.digest == correction.digest)
  }

  @Test func triggerIdentityOrdersIssueCodesByRawUTF8() {
    // given
    let precomposed = "\u{e9}"
    let decomposed = "e\u{301}"

    // when
    let trigger = identity(issueCodes: [precomposed, decomposed])

    // then
    #expect(
      trigger.issueCodes.map { code in Array(code.utf8) } == [
        Array(decomposed.utf8),
        Array(precomposed.utf8),
      ]
    )
  }

  @Test func triggerDigestPreservesByteDistinctIssueCodes() {
    // given
    let precomposed = identity(issueCodes: ["\u{e9}"])

    // when
    let decomposed = identity(issueCodes: ["e\u{301}"])

    // then
    #expect(precomposed.digest != decomposed.digest)
  }

  @Test func eachTriggerIdentityInputChangesTheDigest() {
    // given
    let baseline = identity()
    let variants = [
      identity(jobId: 12),
      identity(epoch: LearningEpoch(2)),
      identity(algorithm: LearningAlgorithm(rawValue: "scheduled-learning/v2")),
      identity(stableDigest: LessonSetDigest(rawValue: "stable-v2")),
      identity(evidenceDigests: [EvidenceDigest(rawValue: "evidence-v2")]),
      identity(feedbackRevision: FeedbackRevision(2)),
      identity(issueCodes: ["b"]),
    ]

    // when
    let changedCoordinates = variants.map { variant in
      variant.digest != baseline.digest
    }

    // then
    #expect(changedCoordinates.allSatisfy { $0 })
  }

  @Test func triggerIdentityPreservesEvidenceOrder() {
    // given
    let first = identity(
      evidenceDigests: [EvidenceDigest(rawValue: "one"), EvidenceDigest(rawValue: "two")]
    )

    // when
    let reordered = identity(
      evidenceDigests: [EvidenceDigest(rawValue: "two"), EvidenceDigest(rawValue: "one")]
    )

    // then
    #expect(first.digest != reordered.digest)
  }
}

// MARK: - Fixtures

private let compatibility = CompatibilityDigest(rawValue: "compatible")

// swiftlint:disable:next function_default_parameter_at_end
private func outcome(
  runId: Int64,
  codes: [String],
  outcome: EffectiveOutcome? = nil,
  occurrenceAt: Date = Date(timeIntervalSince1970: 4_999_999),
  completedAt: Date = Date(timeIntervalSince1970: 5_000_000),
  compatibility: CompatibilityDigest = compatibility,
  trialId: Int64? = nil,
  evidenceDigest: EvidenceDigest? = nil
) -> EffectiveEvaluation {
  EffectiveEvaluation(
    runId: runId,
    jobId: 11,
    epoch: LearningEpoch(1),
    stableDigest: LessonSetDigest(rawValue: "stable-v1"),
    evidenceDigest: evidenceDigest ?? EvidenceDigest(rawValue: "evidence-\(runId)"),
    compatibility: compatibility,
    occurrenceAt: occurrenceAt,
    evaluatorCompletedAt: completedAt,
    trialId: trialId,
    outcome: outcome ?? .negative(issueCodes: codes),
    feedbackRevision: FeedbackRevision(1)
  )
}

private func correction(runId: Int64) -> FeedbackEvent {
  feedback(.resultCorrection, runId: runId, id: runId, revision: 2)
}

private func feedback(
  _ signal: OwnerSignal,
  runId: Int64,
  id: Int64,
  revision: Int64
) -> FeedbackEvent {
  FeedbackEvent(
    id: id,
    runId: runId,
    signal: signal,
    payload: signal == .resultCorrection ? "owner correction" : nil,
    revision: FeedbackRevision(revision),
    supersedes: nil,
    occurredAt: Date(timeIntervalSince1970: TimeInterval(revision))
  )
}

// swiftlint:disable:next function_default_parameter_at_end
private func identity(
  jobId: Int64 = 11,
  epoch: LearningEpoch = LearningEpoch(1),
  algorithm: LearningAlgorithm = .v1,
  stableDigest: LessonSetDigest = LessonSetDigest(rawValue: "stable-v1"),
  evidenceDigests: [EvidenceDigest] = [EvidenceDigest(rawValue: "evidence-1")],
  feedbackRevision: FeedbackRevision = FeedbackRevision(1),
  issueCodes: [String] = ["a"],
  reason: LearningTriggerReason = .recurringIssue
) -> TriggerIdentity {
  TriggerIdentity(
    jobId: jobId,
    epoch: epoch,
    algorithm: algorithm,
    stableDigest: stableDigest,
    evidenceDigests: evidenceDigests,
    feedbackRevision: feedbackRevision,
    issueCodes: issueCodes,
    reason: reason
  )
}
