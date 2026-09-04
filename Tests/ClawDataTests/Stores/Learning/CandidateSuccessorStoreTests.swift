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
    defer { fixture.remove() }
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

  @Test func delayedEffectiveApprovalFreezesTheCurrentFeedbackRevision() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
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
    defer { fixture.remove() }
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
    defer { fixture.remove() }
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
    defer { fixture.remove() }
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
    defer { fixture.remove() }
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

  @Test func approvalOfAnEditRequiresItsInheritedRootPredecessor() throws {
    // given
    let fixture = try AdmissionStoreFixture.make()
    defer { fixture.remove() }
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
    defer { fixture.remove() }
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
    defer { fixture.remove() }
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
    defer { fixture.remove() }
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
  case closedReplacement

  var lessons: [String] {
    self == .noOp ? [] : ["Report only material changes."]
  }

  var expected: AdmissionRejection {
    switch self {
    case .competingTrial:
      .trialAlreadyLive
    case .noOp:
      .noOpReplacement
    case .closedReplacement:
      .replacementAlreadyClosed
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
    case .closedReplacement:
      try insertClosedReplacementTrial(from: predecessor)
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
      replacement: predecessor.replacement,
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
