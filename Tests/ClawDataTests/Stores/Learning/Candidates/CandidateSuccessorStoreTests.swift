import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct CandidateSuccessorStoreTests {
  @Test(arguments: ApprovalRejectionScenario.allCases)
  func normalApprovalRejectionLeavesNoOrphanSuccessor(
    _ scenario: ApprovalRejectionScenario
  ) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate(lessons: scenario.lessons)
    try fixture.arrangeApprovalRejection(scenario, predecessor: predecessor)
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateApprove
    )
    let before = try fixture.rowCounts()

    // when
    let outcome = try fixture.env.learning.approveCandidate(
      CandidateApproval(
        predecessorDigest: predecessor.digest,
        feedbackEventId: control.eventId
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — inserting the successor before a normal common-policy rejection commits an orphan.
    #expect(outcome == .rejected(scenario.expected))
    #expect(try fixture.rowCounts() == before)
  }

  @Test func approvalOfExactCurrentPredecessorMayReuseAClosedReplacement() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    try fixture.insertClosedReplacementTrial(from: predecessor)
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateApprove
    )
    let before = try fixture.rowCounts()

    // when
    let outcome = try fixture.env.learning.approveCandidate(
      CandidateApproval(
        predecessorDigest: predecessor.digest,
        feedbackEventId: control.eventId
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — treating approval as a retry of the terminal trial rejects the one canonical
    // exception: the exact unadmitted predecessor is superseded by its single approval successor.
    let receipt = try #require(outcome.admissionReceipt)
    let successor = try #require(try fixture.candidate(for: receipt.candidateDigest))
    #expect(successor.replacement == predecessor.replacement)
    #expect(successor.manifest.predecessorCandidate == predecessor.digest)
    #expect(successor.manifest.predecessorFeedback == control)
    #expect(try fixture.rowCounts().lessons == before.lessons)
    #expect(try fixture.rowCounts().candidates == before.candidates + 1)
    #expect(try fixture.rowCounts().trials == before.trials + 1)
    #expect(try fixture.rowCounts().decisions == before.decisions + 1)
    #expect(try fixture.rowCounts().audits == before.audits + 1)
    #expect(try fixture.env.currentLearningState().openTrialId == receipt.trialId)
    #expect(try fixture.successorCount(of: predecessor.digest) == 1)
  }

  @Test func editToStableRejectsWithoutClosingThePredecessorTrial() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let admission = try fixture.env.learning.admitCandidate(
      digest: predecessor.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let trialId = try #require(admission.admissionReceipt).trialId
    let payload = #"{"lessons":[]}"#
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: payload
    )
    let before = try fixture.rowCounts()

    // when
    let outcome = try fixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: control.eventId,
        payload: Data(payload.utf8)
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — owner edit bypasses support only; skipping the no-op gate would persist a successor
    // and fall back the still-authoritative predecessor trial.
    #expect(outcome == .rejected(.noOpReplacement))
    #expect(try fixture.rowCounts() == before)
    #expect(try fixture.trial(trialId).state == LearningTrialState.open.rawValue)
    #expect(try fixture.env.currentLearningState().openTrialId == trialId)
  }

  @Test func editToPreviouslyClosedReplacementPreservesThePredecessorTrial() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let admission = try fixture.env.learning.admitCandidate(
      digest: predecessor.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let trialId = try #require(admission.admissionReceipt).trialId
    let closedLessons = ["Use the exact previously closed replacement."]
    try fixture.insertClosedReplacementTrial(from: predecessor, lessons: closedLessons)
    let payload = #"{"lessons":["Use the exact previously closed replacement."]}"#
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: payload
    )
    let before = try fixture.rowCounts()

    // when
    let outcome = try fixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: control.eventId,
        payload: Data(payload.utf8)
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — reusing the approval exception for edits would reopen a failed lesson set and close
    // the unrelated live predecessor trial.
    #expect(outcome == .rejected(.replacementAlreadyClosed))
    #expect(try fixture.rowCounts() == before)
    #expect(try fixture.trial(trialId).state == LearningTrialState.open.rawValue)
    #expect(try fixture.env.currentLearningState().openTrialId == trialId)
  }

  @Test func delayedEffectiveApprovalFreezesTheCurrentFeedbackRevision() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateApprove
    )
    _ = try fixture.appendUnrelatedFeedback()

    // when
    let outcome = try fixture.env.learning.approveCandidate(
      CandidateApproval(
        predecessorDigest: predecessor.digest,
        feedbackEventId: control.eventId
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — unrelated feedback may advance the cutoff without superseding this exact control.
    let receipt = try #require(outcome.admissionReceipt)
    let successor = try #require(try fixture.candidate(for: receipt.candidateDigest))
    #expect(successor.manifest.predecessorFeedback == control)
    #expect(successor.manifest.feedbackRevision == FeedbackRevision(2))
  }

  @Test func delayedEffectiveEditFreezesTheCurrentFeedbackRevision() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let payload = #"{"lessons":["Keep only owner-confirmed changes."]}"#
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: payload
    )
    _ = try fixture.appendUnrelatedFeedback()

    // when
    let outcome = try fixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: control.eventId,
        payload: Data(payload.utf8)
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — exact unsuperseded edit control stays valid at a later unrelated cutoff.
    guard case .awaitingApproval(let successor) = outcome else {
      Issue.record("expected a delayed edit successor")
      return
    }
    #expect(successor.manifest.predecessorFeedback == control)
    #expect(successor.manifest.feedbackRevision == FeedbackRevision(2))
  }

  @Test(arguments: PersistedControlCorruption.allCases)
  func persistedOwnerApprovalRequiresItsExactEffectiveControl(
    _ corruption: PersistedControlCorruption
  ) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let successor = try fixture.persistForgedApproval(
      predecessor: predecessor,
      corruption: corruption
    )
    let before = try fixture.rowCounts()

    // when
    let outcome = try fixture.env.learning.admitCandidate(
      digest: successor.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — a persisted origin tag alone is never owner-approval support.
    #expect(outcome == .rejected(.sourceBindingsChanged))
    #expect(try fixture.rowCounts() == before)
  }

  @Test func anEditReplayReturnsTheSameAwaitingArtifactAndWritesNothing() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let payload = #"{"lessons":["Keep only verified material changes."]}"#
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: payload
    )
    let edit = CandidateEdit(
      predecessorDigest: predecessor.digest,
      feedbackEventId: control.eventId,
      payload: Data(payload.utf8)
    )
    let first = try fixture.env.learning.editCandidate(
      edit,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let afterFirst = try fixture.rowCounts()
    _ = try fixture.appendUnrelatedFeedback()

    // when
    let replay = try fixture.env.learning.editCandidate(
      edit,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now.addingTimeInterval(60)
    )

    // then — later unrelated feedback never changes or duplicates the immutable edit successor.
    #expect(replay.awaitingArtifact == first.awaitingArtifact)
    #expect(try fixture.rowCounts() == afterFirst)
  }

  @Test func anApprovedEditRevalidatesItsCompletePredecessorChain() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let editPayload = #"{"lessons":["Keep only verified changes from the owner."]}"#
    let editControl = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: editPayload
    )
    let edit = try fixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: editControl.eventId,
        payload: Data(editPayload.utf8)
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let edited = try #require(edit.awaitingArtifact)
    let approval = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: edited.digest.rawValue,
      signal: .candidateApprove
    )

    // when
    let outcome = try fixture.env.learning.approveCandidate(
      CandidateApproval(
        predecessorDigest: edited.digest,
        feedbackEventId: approval.eventId
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — validating only the immediate origin would not prove the inherited root provenance.
    let receipt = try #require(outcome.admissionReceipt)
    let admitted = try #require(try fixture.candidate(for: receipt.candidateDigest))
    #expect(admitted.manifest.predecessorCandidate == edited.digest)
    #expect(admitted.manifest.predecessorFeedback == approval)
    #expect(try fixture.env.countRows(in: "learning_candidates") == 3)
    #expect(try fixture.env.countRows(in: "learning_trials") == 1)
  }

  @Test func longSuccessorChainValidatesThroughThePublicStoreWithoutADepthLimit() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    var current = try fixture.persistedCandidate()

    // when
    for index in 0..<24 {
      let lesson = "Keep exact owner revision \(index)."
      let payload = #"{"lessons":["\#(lesson)"]}"#
      let editControl = try fixture.env.appendFeedback(
        subjectKind: .candidate,
        subjectDigest: current.digest.rawValue,
        signal: .candidateEdit,
        payload: payload
      )
      let edit = try fixture.env.learning.editCandidate(
        CandidateEdit(
          predecessorDigest: current.digest,
          feedbackEventId: editControl.eventId,
          payload: Data(payload.utf8)
        ),
        redactor: SecretRedactor(secretValues: []),
        now: fixture.env.now
      )
      let edited = try #require(edit.awaitingArtifact)
      let approvalControl = try fixture.env.appendFeedback(
        subjectKind: .candidate,
        subjectDigest: edited.digest.rawValue,
        signal: .candidateApprove
      )
      let approval = try fixture.env.learning.approveCandidate(
        CandidateApproval(
          predecessorDigest: edited.digest,
          feedbackEventId: approvalControl.eventId
        ),
        redactor: SecretRedactor(secretValues: []),
        now: fixture.env.now
      )
      let receipt = try #require(approval.admissionReceipt)
      current = try #require(try fixture.candidate(for: receipt.candidateDigest))
    }

    // then — recursive validation or a defensive ancestry cap can reject a valid durable tip;
    // every hop must instead be gathered once and validated root-to-tip with cycle detection.
    #expect(try fixture.env.countRows(in: "learning_candidates") == 49)
    #expect(try fixture.successorCount(of: current.digest) == 0)
    #expect(
      try fixture.env.learning.openTrial(jobId: fixture.env.jobId)?.candidateDigest
        == current.digest
    )
  }

  @Test func approvalOfAnEditRequiresItsInheritedRootPredecessor() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let editPayload = #"{"lessons":["Keep the durable owner correction."]}"#
    let editControl = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: editPayload
    )
    let edit = try fixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: editControl.eventId,
        payload: Data(editPayload.utf8)
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let edited = try #require(edit.awaitingArtifact)
    try fixture.env.queue.write { db in
      try db.execute(
        sql: "DELETE FROM learning_candidates WHERE candidate_digest = ?",
        arguments: [predecessor.digest.rawValue]
      )
    }
    let approval = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: edited.digest.rawValue,
      signal: .candidateApprove
    )
    let before = try fixture.rowCounts()

    // when
    let outcome = try fixture.env.learning.approveCandidate(
      CandidateApproval(
        predecessorDigest: edited.digest,
        feedbackEventId: approval.eventId
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — validating only the immediate edit row would convert broken ancestry into support.
    #expect(outcome == .rejected(.sourceBindingsChanged))
    #expect(try fixture.rowCounts() == before)
  }

  @Test func approvalOfAnEditRevalidatesTheInheritedRootOperation() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let editPayload = #"{"lessons":["Keep the exact root provenance."]}"#
    let editControl = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: editPayload
    )
    let edit = try fixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: editControl.eventId,
        payload: Data(editPayload.utf8)
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )
    let edited = try #require(edit.awaitingArtifact)
    try fixture.env.queue.write { db in
      try db.execute(
        sql: "UPDATE learning_operations SET carrier_digest = ? WHERE operation_id = ?",
        arguments: ["tampered-carrier", predecessor.manifest.operationId.rawValue]
      )
    }
    let approval = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: edited.digest.rawValue,
      signal: .candidateApprove
    )
    let before = try fixture.rowCounts()

    // when
    let outcome = try fixture.env.learning.approveCandidate(
      CandidateApproval(
        predecessorDigest: edited.digest,
        feedbackEventId: approval.eventId
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — traversing identities without validating the root operation accepts forged ancestry.
    #expect(outcome == .rejected(.sourceBindingsChanged))
    #expect(try fixture.rowCounts() == before)
  }

  @Test func persistedOwnerEditMustMatchItsExactControlPayload() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let payload = #"{"lessons":["The control payload replacement."]}"#
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: payload
    )
    let replacement = try LessonSet.canonical(
      jobId: fixture.env.jobId,
      lessons: ["A different persisted replacement."]
    )
    let source = predecessor.manifest
    let forged = try CandidateArtifact(
      replacement: replacement,
      manifest: CandidateSourceManifest(
        origin: .ownerEdit,
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
        feedbackRevision: control.revision,
        evidence: source.evidence,
        evaluations: source.evaluations,
        feedback: source.feedback,
        predecessorCandidate: predecessor.digest,
        predecessorFeedback: control
      )
    )
    try fixture.env.queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(
        db,
        artifact: forged,
        lessonSource: .ownerEdit,
        now: fixture.env.now
      )
    }
    let before = try fixture.rowCounts()

    // when
    let outcome = try fixture.env.learning.admitCandidate(
      digest: forged.digest,
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — the persisted replacement cannot diverge from the exact closed edit-event JSON.
    #expect(outcome == .rejected(.sourceBindingsChanged))
    #expect(try fixture.rowCounts() == before)
  }

  @Test(arguments: InvalidEditPayload.allCases)
  func invalidNonSecretEditPayloadNeverPersists(_ invalid: InvalidEditPayload) throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    let predecessor = try fixture.persistedCandidate()
    let control = try fixture.env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: predecessor.digest.rawValue,
      signal: .candidateEdit,
      payload: invalid.payload
    )
    let before = try fixture.rowCounts()

    // when
    let outcome = try fixture.env.learning.editCandidate(
      CandidateEdit(
        predecessorDigest: predecessor.digest,
        feedbackEventId: control.eventId,
        payload: Data(invalid.payload.utf8)
      ),
      redactor: SecretRedactor(secretValues: []),
      now: fixture.env.now
    )

    // then — the persistence seam must reject malformed/unknown/invalid lesson bytes before write.
    #expect(outcome == .rejected(invalid.expected))
    #expect(try fixture.rowCounts() == before)
  }
}

enum ApprovalRejectionScenario: CaseIterable, Sendable {
  case competingTrial
  case noOp

  var lessons: [String] {
    self == .noOp ? [] : ["Report only material changes."]
  }

  var expected: AdmissionRejection {
    switch self {
    case .competingTrial:
      .trialAlreadyLive
    case .noOp:
      .noOpReplacement
    }
  }
}

enum PersistedControlCorruption: CaseIterable, Sendable {
  case missingEvent
  case wrongDigest
  case wrongSubject
  case wrongSignal
  case payloadOnApproval
  case nonOwner
  case superseded
  case missingPredecessor
}

enum InvalidEditPayload: CaseIterable, Sendable {
  case malformedJSON
  case unknownKey
  case invalidLesson

  var payload: String {
    switch self {
    case .malformedJSON:
      #"{"lessons":["unfinished"]"#
    case .unknownKey:
      #"{"lessons":[],"authority":"approve"}"#
    case .invalidLesson:
      #"{"lessons":[""]}"#
    }
  }

  var expected: AdmissionRejection {
    switch self {
    case .malformedJSON, .unknownKey:
      .invalidOwnerControl
    case .invalidLesson:
      .lessonSet(.emptyLesson(index: 0))
    }
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

private extension AdmissionStoreFixture {
  func arrangeApprovalRejection(
    _ scenario: ApprovalRejectionScenario,
    predecessor: CandidateArtifact
  ) throws {
    switch scenario {
    case .competingTrial:
      try insertCompetingDrainingTrial(from: predecessor)
    case .noOp:
      break
    }
  }

  func appendUnrelatedFeedback() throws -> CandidateFeedbackSource {
    try env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest: "unrelated-candidate",
      signal: .candidateReject
    )
  }

  func insertClosedReplacementTrial(from predecessor: CandidateArtifact) throws {
    try insertClosedReplacementTrial(from: predecessor, replacement: predecessor.replacement)
  }

  func insertClosedReplacementTrial(
    from predecessor: CandidateArtifact,
    lessons: [String]
  ) throws {
    try insertClosedReplacementTrial(
      from: predecessor,
      replacement: LessonSet.canonical(jobId: predecessor.manifest.jobId, lessons: lessons)
    )
  }

  func insertClosedReplacementTrial(
    from predecessor: CandidateArtifact,
    replacement: LessonSet
  ) throws {
    let source = predecessor.manifest
    let alternateManifest = CandidateSourceManifest(
      origin: source.origin,
      algorithm: source.algorithm,
      jobId: source.jobId,
      epoch: source.epoch,
      triggerDigest: source.triggerDigest,
      triggerReason: source.triggerReason,
      qualifyingIssueCodes: source.qualifyingIssueCodes,
      operationId: source.operationId,
      carrierDigest: source.carrierDigest,
      resultDigest: ReflectionResultDigest(rawValue: "closed-result"),
      baseDigest: source.baseDigest,
      baseRevision: source.baseRevision,
      feedbackRevision: source.feedbackRevision,
      evidence: source.evidence,
      evaluations: source.evaluations,
      feedback: source.feedback,
      predecessorCandidate: nil,
      predecessorFeedback: nil
    )
    let closed = try CandidateArtifact(
      replacement: replacement,
      manifest: alternateManifest
    )
    try env.queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(db, artifact: closed, now: env.now)
      try db.execute(
        sql: """
          INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
            generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
            consumed_assignments, cohort_cutoff, state, algorithm)
          VALUES (?, ?, ?, ?, 1, ?, ?, ?, 3, 0, ?, ?, ?)
          """,
        arguments: [
          env.jobId,
          source.epoch.value,
          source.baseDigest.rawValue,
          closed.digest.rawValue,
          EpochSecondCodec.epoch(env.now),
          EpochSecondCodec.epoch(env.now) + 2_592_000,
          EpochSecondCodec.epoch(env.now) + 3_196_800,
          EpochSecondCodec.epoch(env.now),
          LearningTrialState.closed.rawValue,
          LearningAlgorithm.v1.rawValue,
        ]
      )
    }
  }

  func successorCount(of predecessor: CandidateDigest) throws -> Int {
    try env.queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM learning_candidates WHERE predecessor_digest = ?",
        arguments: [predecessor.rawValue]
      ) ?? -1
    }
  }

  func persistForgedApproval(
    predecessor: CandidateArtifact,
    corruption: PersistedControlCorruption
  ) throws -> CandidateArtifact {
    var control = try env.appendFeedback(
      subjectKind: .candidate,
      subjectDigest:
        corruption == .wrongSubject ? "another-candidate" : predecessor.digest.rawValue,
      signal: corruption == .wrongSignal ? .candidateReject : .candidateApprove,
      payload: corruption == .payloadOnApproval ? "unexpected" : nil
    )
    if corruption == .wrongDigest {
      control = CandidateFeedbackSource(
        eventId: control.eventId,
        digest: FeedbackEventDigest(rawValue: "tampered-feedback-digest"),
        revision: control.revision,
        subjectKind: control.subjectKind,
        subjectDigest: control.subjectDigest,
        signal: control.signal
      )
    }
    if corruption == .superseded {
      _ = try env.appendFeedback(
        subjectKind: .candidate,
        subjectDigest: predecessor.digest.rawValue,
        signal: .candidateReject,
        supersedes: control.eventId
      )
    }
    let state = try env.currentLearningState()
    let source = predecessor.manifest
    let manifest = CandidateSourceManifest(
      origin: .ownerApproval,
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
      feedbackRevision: state.feedbackRevision,
      evidence: source.evidence,
      evaluations: source.evaluations,
      feedback: source.feedback,
      predecessorCandidate:
        corruption == .missingPredecessor
        ? CandidateDigest(rawValue: "missing-predecessor") : predecessor.digest,
      predecessorFeedback: control
    )
    let successor = try CandidateArtifact(
      replacement: predecessor.replacement,
      manifest: manifest
    )
    try env.queue.write { db in
      try ScheduledLearningStoreGRDB.recordCandidateArtifact(
        db,
        artifact: successor,
        now: env.now
      )
      if corruption == .missingEvent {
        try db.execute(
          sql: "DELETE FROM feedback_events WHERE event_id = ?",
          arguments: [control.eventId]
        )
      }
      if corruption == .nonOwner {
        try db.execute(
          sql: "UPDATE feedback_events SET actor = ? WHERE event_id = ?",
          arguments: [AuditActor.system.rawValue, control.eventId]
        )
      }
    }
    return successor
  }
}
