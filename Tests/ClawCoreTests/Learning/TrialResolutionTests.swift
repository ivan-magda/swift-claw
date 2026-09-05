import ClawCore
import Foundation
import Testing

@Suite struct TrialResolutionTests {
  @Test func assignmentAcceptanceUsesOccurrenceAndProcessingClocks() {
    // given
    let admittedAt = Date(timeIntervalSince1970: 1_000)
    let trial = fixtureTrial(admittedAt: admittedAt)

    // when / then
    #expect(
      trial.acceptsAssignment(
        occurrenceAt: admittedAt,
        now: admittedAt.addingTimeInterval(1)
      )
    )
    #expect(
      trial.acceptsAssignment(
        occurrenceAt: admittedAt.addingTimeInterval(-1),
        now: admittedAt.addingTimeInterval(1)
      ) == false
    )
    #expect(
      trial.acceptsAssignment(
        occurrenceAt: admittedAt,
        now: trial.assignmentDeadline
      ) == false
    )
  }

  @Test func twoPositivesWaitForTheLastUnresolvedAssignment() {
    // given
    let trial = fixtureTrial(consumed: 3)
    let assignments = [
      fixtureAssignment(runId: 1, outcome: .positive),
      fixtureAssignment(runId: 2, outcome: .positive),
      fixtureAssignment(runId: 3),
    ]

    // when
    let decision = TrialPolicy.decide(trial: trial, assignments: assignments, now: trial.admittedAt)

    // then
    #expect(decision == .closeAssignment(reason: .assignmentLimit))
  }

  @Test func negativeAndHardVetoPrecedeUnresolvedAndPositiveInputs() {
    // given
    let trial = fixtureTrial(consumed: 3, hardVetoes: [.staleControlState])
    let assignments = [
      fixtureAssignment(runId: 1, outcome: .positive),
      fixtureAssignment(runId: 2, outcome: .negative(issueCodes: ["bad"])),
      fixtureAssignment(runId: 3),
    ]

    // when
    let withVeto = TrialPolicy.decide(
      trial: trial,
      assignments: assignments,
      now: trial.decisionDeadline
    )
    let withoutVeto = TrialPolicy.decide(
      trial: fixtureTrial(consumed: 3),
      assignments: assignments,
      now: trial.decisionDeadline
    )

    // then
    #expect(withVeto == .fallback(reason: .hardVeto))
    #expect(withoutVeto == .fallback(reason: .negativeOutcome))
  }

  @Test func assignmentHardVetoPrecedesAnOtherwisePromotableCohort() {
    // given
    let trial = fixtureTrial(consumed: 2)
    let assignments = [
      fixtureAssignment(runId: 1, outcome: .positive),
      fixtureAssignment(
        runId: 2,
        outcome: .positive,
        hardVetoes: [.ownerDependencyRejected]
      ),
    ]

    // when
    let decision = TrialPolicy.decide(trial: trial, assignments: assignments, now: trial.admittedAt)

    // then — checking only candidate-level vetoes would promote this exact assignment cohort.
    #expect(decision == .fallback(reason: .hardVeto))
  }

  @Test func decisionDeadlinePreservesIncompleteWithoutPersistingNeutral() {
    // given
    let trial = fixtureTrial(consumed: 1)
    let assignments = [fixtureAssignment(runId: 1)]

    // when
    let before = TrialPolicy.decide(
      trial: trial,
      assignments: assignments,
      now: trial.admittedAt
    )
    let atDeadline = TrialPolicy.decide(
      trial: trial,
      assignments: assignments,
      now: trial.decisionDeadline
    )

    // then
    #expect(before == .wait)
    #expect(atDeadline == .fallback(reason: .decisionDeadlineIncomplete))
    #expect(assignments[0].resolvedEvidence == nil)
  }

  @Test func alreadyDrainingUnresolvedTrialWaitsWithoutInventingACloseReason() {
    // given
    let trial = fixtureTrial(consumed: 3, state: .draining)
    let assignments = [
      fixtureAssignment(runId: 1, outcome: .positive),
      fixtureAssignment(runId: 2, outcome: .positive),
      fixtureAssignment(runId: 3),
    ]

    // when
    let decision = TrialPolicy.decide(trial: trial, assignments: assignments, now: trial.admittedAt)

    // then
    #expect(decision == .wait)
  }

  @Test func emptyAndAllNeutralCohortsFallbackWhenAssignmentCloses() {
    // given
    let empty = fixtureTrial(consumed: 0)
    let neutral = fixtureTrial(consumed: 3)

    // when
    let emptyDecision = TrialPolicy.decide(
      trial: empty,
      assignments: [],
      now: empty.assignmentDeadline
    )
    let neutralDecision = TrialPolicy.decide(
      trial: neutral,
      assignments: [
        fixtureAssignment(runId: 1, outcome: .neutral),
        fixtureAssignment(runId: 2, outcome: .neutral),
        fixtureAssignment(runId: 3, outcome: .neutral),
      ],
      now: neutral.admittedAt
    )

    // then
    #expect(emptyDecision == .fallback(reason: .insufficientSupport))
    #expect(neutralDecision == .fallback(reason: .insufficientSupport))
  }

  @Test func oneOrTwoNeutralOutcomesConsumeExposureWithoutClosingIt() {
    // given
    let one = fixtureTrial(consumed: 1)
    let two = fixtureTrial(consumed: 2)

    // when
    let oneDecision = TrialPolicy.decide(
      trial: one,
      assignments: [fixtureAssignment(runId: 1, outcome: .neutral)],
      now: one.admittedAt
    )
    let twoDecision = TrialPolicy.decide(
      trial: two,
      assignments: [
        fixtureAssignment(runId: 1, outcome: .neutral),
        fixtureAssignment(runId: 2, outcome: .neutral),
      ],
      now: two.admittedAt
    )

    // then — excluding neutral rows from exposure would close or over-assign this cohort.
    #expect(oneDecision == .wait)
    #expect(twoDecision == .wait)
  }

  @Test func assignmentBoundsUseEqualityAndLimitWinsWhenBothAreReached() {
    // given
    let atDeadline = fixtureTrial(consumed: 1)
    let atBoth = fixtureTrial(consumed: 3)
    let unresolved = [fixtureAssignment(runId: 1)]

    // when
    let deadlineDecision = TrialPolicy.decide(
      trial: atDeadline,
      assignments: unresolved,
      now: atDeadline.assignmentDeadline
    )
    let bothDecision = TrialPolicy.decide(
      trial: atBoth,
      assignments: [
        fixtureAssignment(runId: 1),
        fixtureAssignment(runId: 2),
        fixtureAssignment(runId: 3),
      ],
      now: atBoth.assignmentDeadline
    )

    // then — `>` misses equality, and deadline-first changes the stable typed reason at capacity.
    #expect(deadlineDecision == .closeAssignment(reason: .assignmentDeadline))
    #expect(bothDecision == .closeAssignment(reason: .assignmentLimit))
  }

  @Test func twoResolvedPositivesPromoteOnlyAfterTheWholeCohortResolves() {
    // given
    let trial = fixtureTrial(consumed: 2)
    let assignments = [
      fixtureAssignment(runId: 1, outcome: .positive),
      fixtureAssignment(runId: 2, outcome: .positive),
    ]

    // when
    let decision = TrialPolicy.decide(trial: trial, assignments: assignments, now: trial.admittedAt)

    // then
    #expect(decision == .promote)
  }

  @Test func onePositiveDoesNotMeetTheTwoRunPromotionThreshold() {
    // given
    let trial = fixtureTrial(consumed: 3)
    let assignments = [
      fixtureAssignment(runId: 1, outcome: .positive),
      fixtureAssignment(runId: 2, outcome: .neutral),
      fixtureAssignment(runId: 3, outcome: .neutral),
    ]

    // when
    let decision = TrialPolicy.decide(trial: trial, assignments: assignments, now: trial.admittedAt)

    // then — counting any positive as sufficient support would promote this closed cohort.
    #expect(decision == .fallback(reason: .insufficientSupport))
  }

  @Test func resolvedEvidenceDerivesOneCanonicalOutcomeShape() {
    // given
    let resolved = ResolvedRunEvidence(
      effective: ResolvedOutcome(
        outcome: .negative(issueCodes: ["b", "a"]),
        ownerConfirmed: true,
        evaluationRequired: true,
        hardVetoes: [.criticalOrRegressionReceipt]
      ),
      evaluationDigest: EvaluationDigest(rawValue: String(repeating: "a", count: 64)),
      correctionEventDigest: nil,
      effectiveFeedbackRevision: FeedbackRevision(4)
    )

    // when / then
    #expect(resolved.outcome == .negative)
    #expect(resolved.issueCodes == ["b", "a"])
    #expect(resolved.evaluationRequired)
    #expect(resolved.ownerConfirmed)
    #expect(resolved.hardVetoes == [.criticalOrRegressionReceipt])
  }
}

// MARK: - Fixtures

private func fixtureTrial(
  admittedAt: Date = Date(timeIntervalSince1970: 1_000),
  consumed: Int = 0,
  state: LearningTrialState = .open,
  hardVetoes: Set<HardVeto> = []
) -> LearningTrial {
  LearningTrial(
    identity: LearningTrialIdentity(
      trialId: 11,
      jobId: 7,
      epoch: LearningEpoch(2),
      generation: 3
    ),
    baseDigest: LessonSetDigest(rawValue: String(repeating: "a", count: 64)),
    baseRevision: StableRevision(4),
    candidateDigest: CandidateDigest(rawValue: String(repeating: "b", count: 64)),
    replacementDigest: LessonSetDigest(rawValue: String(repeating: "c", count: 64)),
    algorithm: .v1,
    admittedAt: admittedAt,
    cohortCutoff: admittedAt,
    maxAssignments: TrialAdmissionPolicy.maximumAssignments,
    consumedAssignments: consumed,
    assignmentDeadline: admittedAt.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow),
    decisionDeadline: admittedAt.addingTimeInterval(TrialAdmissionPolicy.decisionWindow),
    state: state,
    hardVetoes: hardVetoes
  )
}

private func fixtureAssignment(
  runId: Int64,
  outcome: EffectiveOutcome? = nil,
  hardVetoes: Set<HardVeto> = []
) -> TrialAssignment {
  let evidence = outcome.map { outcome in
    ResolvedRunEvidence(
      effective: ResolvedOutcome(
        outcome: outcome,
        ownerConfirmed: false,
        evaluationRequired: true,
        hardVetoes: hardVetoes
      ),
      evaluationDigest: EvaluationDigest(rawValue: String(repeating: "d", count: 64)),
      correctionEventDigest: nil,
      effectiveFeedbackRevision: FeedbackRevision(0)
    )
  }
  return TrialAssignment(
    identity: TrialAssignmentIdentity(trial: fixtureTrial().identity, runId: runId),
    assignedAt: Date(timeIntervalSince1970: 1_001),
    state: evidence == nil ? .learningOutcomeUnresolved : .learningOutcomeResolved,
    resolvedEvidence: evidence,
    resolvedAt: evidence == nil ? nil : Date(timeIntervalSince1970: 1_002)
  )
}
