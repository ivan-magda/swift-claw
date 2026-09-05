import Foundation
import Testing

@testable import ClawCore

@Suite struct AdmissionTests {
  @Test func currentBindingsAndSupportGatesFireIndependently() throws {
    // given
    let fixture = try AdmissionFixture.make()
    let cases: [(AdmissionRejection, AdmissionValidationContext)] = [
      (.jobNotRepeatable, fixture.context(jobHasRecurrence: false)),
      (.jobNotRepeatable, fixture.context(jobStatus: .cancelled)),
      (.staleEpoch, fixture.context(epoch: fixture.epoch.next())),
      (.staleBaseDigest, fixture.context(stableDigest: fixture.replacement.digest)),
      (.staleBaseRevision, fixture.context(stableRevision: fixture.baseRevision.next())),
      (
        .staleFeedbackRevision,
        fixture.context(feedbackRevision: fixture.feedbackRevision.next())
      ),
      (.trialAlreadyLive, fixture.context(hasLiveTrial: true)),
      (.sourceBindingsChanged, fixture.context(sourceBindingsAreCurrent: false)),
      (
        .hardVeto(.ownerDependencyRejected),
        fixture.context(hardVetoes: [.ownerDependencyRejected])
      ),
      (.replacementAlreadyClosed, fixture.context(replacementAlreadyClosed: true)),
      (.supportUnavailable, fixture.context(support: nil)),
    ]

    // when / then
    for (expected, context) in cases {
      #expect(
        AdmissionValidator.validate(candidate: fixture.candidate, context: context) == expected
      )
    }
  }

  @Test func activeAndPausedRecurringJobsAreBothAdmissible() throws {
    // given
    let fixture = try AdmissionFixture.make()

    // when
    let active = AdmissionValidator.validate(
      candidate: fixture.candidate,
      context: fixture.context(jobStatus: .active)
    )
    let paused = AdmissionValidator.validate(
      candidate: fixture.candidate,
      context: fixture.context(jobStatus: .paused)
    )

    // then
    #expect(active == nil)
    #expect(paused == nil)
  }

  @Test func aNoOpReplacementIsIndependentOfClosedReplacementHistory() throws {
    // given
    let fixture = try AdmissionFixture.make(baseLessons: ["Use exact evidence."])
    let noOp = try fixture.candidate(replacement: fixture.base)

    // when
    let rejection = AdmissionValidator.validate(
      candidate: noOp,
      context: fixture.context(stableDigest: fixture.base.digest)
    )

    // then
    #expect(rejection == .noOpReplacement)
  }

  @Test func approvalExceptionPermitsOnlyClosedHistoryAndNeverANoOp() throws {
    // given
    let fixture = try AdmissionFixture.make(baseLessons: ["Keep the stable lesson."])
    let noOp = try fixture.candidate(replacement: fixture.base)

    // when
    let closedApproval = AdmissionValidator.validate(
      candidate: fixture.candidate,
      context: fixture.context(
        replacementAlreadyClosed: true,
        permitsClosedReplacement: true
      )
    )
    let noOpApproval = AdmissionValidator.validate(
      candidate: noOp,
      context: fixture.context(
        stableDigest: fixture.base.digest,
        replacementAlreadyClosed: true,
        permitsClosedReplacement: true
      )
    )

    // then — a broad approval bypass would also admit the stable lesson set.
    #expect(closedApproval == nil)
    #expect(noOpApproval == .noOpReplacement)
  }

  @Test func benignAuthorityWordsAreNeverPolicyOperands() throws {
    // given
    let lessons = [
      "Mention /tmp/report.txt only as an example path.",
      "Explain why https://example.com is a URL.",
      "Describe the command `git status` without executing it.",
    ]

    // when
    let result = AdmissionValidator.validatedReplacement(
      jobId: 41,
      lessons: lessons,
      redactor: SecretRedactor(secretValues: ["actual-loaded-secret"])
    )

    // then
    #expect(try result.get().lessons == lessons)
  }

  @Test func exactLoadedSecretLeakIsRejectedBeforeCanonicalBytesPersist() {
    // given
    let secret = "credential-with-quote-\"-and-newline\nvalue"

    // when
    let result = AdmissionValidator.validatedReplacement(
      jobId: 41,
      lessons: ["Never print \(secret) to the owner."],
      redactor: SecretRedactor(secretValues: [secret])
    )

    // then
    #expect(result == .failure(.secretLeak))
  }

  @Test func lessonSetFailuresRemainTypedAtTheAdmissionBoundary() {
    // given
    let cases: [([String], AdmissionRejection)] = [
      ([""], .lessonSet(.emptyLesson(index: 0))),
      (["same", "same"], .lessonSet(.duplicateLesson(index: 1))),
      (["a", "b", "c", "d"], .lessonSet(.tooManyLessons(count: 4))),
      (["tab\tis-control"], .lessonSet(.disallowedCharacter(index: 0, scalar: "\t"))),
    ]

    // when / then
    for (lessons, expected) in cases {
      let result = AdmissionValidator.validatedReplacement(
        jobId: 41,
        lessons: lessons,
        redactor: SecretRedactor(secretValues: [])
      )
      #expect(result == .failure(expected))
    }
  }

  @Test func approvalAndEditSuccessorsCarryClosedImmutableProvenance() throws {
    // given
    let fixture = try AdmissionFixture.make()
    let approval = fixture.control(.candidateApprove, eventId: 70, revision: 4)
    let editedReplacement = try AdmissionValidator.validatedReplacement(
      jobId: fixture.jobId,
      lessons: [],
      redactor: SecretRedactor(secretValues: [])
    ).get()

    // when
    let approved = try CandidateSuccessorRules.approval(
      predecessor: fixture.candidate,
      control: approval,
      feedbackRevision: FeedbackRevision(4),
      effectiveFeedback: fixture.candidate.manifest.feedback
    )
    let edit = fixture.control(
      .candidateEdit,
      subjectDigest: approved.digest.rawValue,
      eventId: 71,
      revision: 5
    )
    let edited = try CandidateSuccessorRules.edit(
      predecessor: approved,
      replacement: editedReplacement,
      control: edit,
      feedbackRevision: FeedbackRevision(5),
      effectiveFeedback: fixture.candidate.manifest.feedback
    )

    // then
    #expect(approved.replacement == fixture.candidate.replacement)
    #expect(approved.digest != fixture.candidate.digest)
    #expect(approved.manifest.origin == .ownerApproval)
    #expect(approved.manifest.predecessorCandidate == fixture.candidate.digest)
    #expect(approved.manifest.predecessorFeedback == approval)
    #expect(approved.manifest.feedbackRevision == FeedbackRevision(4))
    #expect(approved.manifest.triggerDigest == fixture.candidate.manifest.triggerDigest)
    #expect(approved.manifest.operationId == fixture.candidate.manifest.operationId)
    #expect(approved.manifest.carrierDigest == fixture.candidate.manifest.carrierDigest)
    #expect(approved.manifest.resultDigest == fixture.candidate.manifest.resultDigest)
    #expect(approved.manifest.baseDigest == fixture.candidate.manifest.baseDigest)
    #expect(approved.manifest.baseRevision == fixture.candidate.manifest.baseRevision)
    #expect(approved.manifest.evidence == fixture.candidate.manifest.evidence)
    #expect(approved.manifest.evaluations == fixture.candidate.manifest.evaluations)
    #expect(edited.replacement.lessons.isEmpty)
    #expect(edited.replacement.digest != approved.replacement.digest)
    #expect(edited.digest != approved.digest)
    #expect(edited.manifest.origin == .ownerEdit)
    #expect(edited.manifest.predecessorCandidate == approved.digest)
    #expect(edited.manifest.predecessorFeedback == edit)
    #expect(edited.manifest.predecessorFeedback?.signal == .candidateEdit)
    #expect(edited.manifest.feedback == fixture.candidate.manifest.feedback)
  }

  @Test func successorRulesRejectWrongSubjectAndUnchangedEdit() throws {
    // given
    let fixture = try AdmissionFixture.make()
    let wrongSubject = CandidateFeedbackSource(
      eventId: 70,
      digest: FeedbackEventDigest(rawValue: "feedback-70"),
      revision: FeedbackRevision(4),
      subjectKind: .candidate,
      subjectDigest: "another-candidate",
      signal: .candidateApprove
    )
    let edit = fixture.control(.candidateEdit, eventId: 71, revision: 5)

    // when / then
    #expect(throws: AdmissionRejection.invalidOwnerControl) {
      _ = try CandidateSuccessorRules.approval(
        predecessor: fixture.candidate,
        control: wrongSubject,
        feedbackRevision: FeedbackRevision(4),
        effectiveFeedback: []
      )
    }
    #expect(throws: AdmissionRejection.unchangedEdit) {
      _ = try CandidateSuccessorRules.edit(
        predecessor: fixture.candidate,
        replacement: fixture.replacement,
        control: edit,
        feedbackRevision: FeedbackRevision(5),
        effectiveFeedback: []
      )
    }
  }

  @Test func anEffectiveDelayedControlFreezesTheCurrentRevision() throws {
    // given
    let fixture = try AdmissionFixture.make()
    let approval = fixture.control(.candidateApprove, eventId: 70, revision: 4)

    // when
    let successor = try CandidateSuccessorRules.approval(
      predecessor: fixture.candidate,
      control: approval,
      feedbackRevision: FeedbackRevision(6),
      effectiveFeedback: fixture.candidate.manifest.feedback
    )

    // then — requiring the control revision itself to equal the current cutoff rejects an
    // unsuperseded approval merely because unrelated feedback arrived before processing.
    #expect(successor.manifest.feedbackRevision == FeedbackRevision(6))
    #expect(successor.manifest.predecessorFeedback == approval)
  }

  @Test func v1TrialConstantsArePinnedIndependently() {
    // given / when / then — deriving the expected values from EvidenceWindow or the production
    // deadline expressions would let an algorithm-version change pass unnoticed.
    #expect(TrialAdmissionPolicy.assignmentWindow == 2_592_000)
    #expect(TrialAdmissionPolicy.decisionWindow == 3_196_800)
    #expect(TrialAdmissionPolicy.maximumAssignments == 3)
  }

  @Test func editPayloadIsTheExactClosedObjectAndAllowsEmptyReplacement() throws {
    // given
    let valid = Data(#"{"lessons":[]}"#.utf8)
    let invalid = [
      Data(#"{"schema_version":1,"lessons":[]}"#.utf8),
      Data(#"{"lessons":[],"authority":"approve"}"#.utf8),
      Data(#"{"lessons":"none"}"#.utf8),
    ]

    // when
    let lessons = CandidateEditPayload.decode(valid)

    // then
    #expect(lessons == [])
    for payload in invalid {
      #expect(CandidateEditPayload.decode(payload) == nil)
    }
  }
}

private struct AdmissionFixture {
  let jobId: Int64
  let epoch: LearningEpoch
  let baseRevision: StableRevision
  let feedbackRevision: FeedbackRevision
  let base: LessonSet
  let replacement: LessonSet
  let candidate: CandidateArtifact

  static func make(
    baseLessons: [String] = []
  ) throws -> AdmissionFixture {
    let jobId: Int64 = 41
    let epoch = LearningEpoch(1)
    let baseRevision = StableRevision(2)
    let feedbackRevision = FeedbackRevision(3)
    let base = try LessonSet.canonical(jobId: jobId, lessons: baseLessons)
    let replacement = try LessonSet.canonical(
      jobId: jobId,
      lessons: ["Report only material changes."]
    )
    let evidence = CandidateEvidenceSource(
      runId: 101,
      digest: EvidenceDigest(rawValue: "evidence-101"),
      evaluationDigest: EvaluationDigest(rawValue: "evaluation-101"),
      evaluationRequired: true
    )
    let manifest = CandidateSourceManifest(
      origin: .reflection,
      algorithm: .v1,
      jobId: jobId,
      epoch: epoch,
      triggerDigest: TriggerDigest(rawValue: "trigger"),
      triggerReason: .recurringIssue,
      qualifyingIssueCodes: ["material.missed"],
      operationId: LearningOperationID(rawValue: "operation"),
      carrierDigest: CarrierDigest(rawValue: "carrier"),
      resultDigest: ReflectionResultDigest(rawValue: "result"),
      baseDigest: base.digest,
      baseRevision: baseRevision,
      feedbackRevision: feedbackRevision,
      evidence: [evidence],
      evaluations: [
        CandidateEvaluationSource(runId: evidence.runId, digest: evidence.evaluationDigest)
      ],
      feedback: [],
      predecessorCandidate: nil,
      predecessorFeedback: nil
    )
    return AdmissionFixture(
      jobId: jobId,
      epoch: epoch,
      baseRevision: baseRevision,
      feedbackRevision: feedbackRevision,
      base: base,
      replacement: replacement,
      candidate: try CandidateArtifact(replacement: replacement, manifest: manifest)
    )
  }

  func candidate(replacement: LessonSet) throws -> CandidateArtifact {
    let source = candidate.manifest
    return try CandidateArtifact(
      replacement: replacement,
      manifest: CandidateSourceManifest(
        origin: source.origin,
        algorithm: source.algorithm,
        jobId: source.jobId,
        epoch: source.epoch,
        triggerDigest: source.triggerDigest,
        triggerReason: source.triggerReason,
        qualifyingIssueCodes: source.qualifyingIssueCodes,
        operationId: source.operationId,
        carrierDigest: source.carrierDigest,
        resultDigest: source.resultDigest,
        baseDigest: source.baseDigest,
        baseRevision: source.baseRevision,
        feedbackRevision: source.feedbackRevision,
        evidence: source.evidence,
        evaluations: source.evaluations,
        feedback: source.feedback,
        predecessorCandidate: source.predecessorCandidate,
        predecessorFeedback: source.predecessorFeedback
      )
    )
  }

  func context(
    jobHasRecurrence: Bool = true,
    jobStatus: ScheduledJobStatus = .active,
    epoch: LearningEpoch? = nil,
    stableDigest: LessonSetDigest? = nil,
    stableRevision: StableRevision? = nil,
    feedbackRevision: FeedbackRevision? = nil,
    hasLiveTrial: Bool = false,
    sourceBindingsAreCurrent: Bool = true,
    hardVetoes: Set<HardVeto> = [],
    replacementAlreadyClosed: Bool = false,
    support: AdmissionSupport? = .recurringIssue,
    permitsClosedReplacement: Bool = false
  ) -> AdmissionValidationContext {
    AdmissionValidationContext(
      currentState: JobLearningState(
        jobId: jobId,
        epoch: epoch ?? self.epoch,
        stableDigest: stableDigest ?? base.digest,
        stableRevision: stableRevision ?? baseRevision,
        openTrialId: nil,
        feedbackRevision: feedbackRevision ?? self.feedbackRevision
      ),
      jobHasRecurrence: jobHasRecurrence,
      jobStatus: jobStatus,
      hasLiveTrial: hasLiveTrial,
      sourceBindingsAreCurrent: sourceBindingsAreCurrent,
      hardVetoes: hardVetoes,
      replacementAlreadyClosed: replacementAlreadyClosed,
      support: support,
      permitsClosedReplacement: permitsClosedReplacement,
      redactor: SecretRedactor(secretValues: [])
    )
  }

  func control(
    _ signal: OwnerSignal,
    subjectDigest: String? = nil,
    eventId: Int64,
    revision: Int64
  ) -> CandidateFeedbackSource {
    CandidateFeedbackSource(
      eventId: eventId,
      digest: FeedbackEventDigest(rawValue: "feedback-\(eventId)"),
      revision: FeedbackRevision(revision),
      subjectKind: .candidate,
      subjectDigest: subjectDigest ?? candidate.digest.rawValue,
      signal: signal
    )
  }
}
