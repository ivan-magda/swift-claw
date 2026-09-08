import ClawCore
import Foundation
import GRDB

// MARK: - Owner Decisions

extension ScheduledLearningStoreGRDB {
  public func approveCandidate(
    _ approval: CandidateApproval,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome {
    try database.writeMapping { db in
      guard
        let predecessor = try Self.readCandidateArtifact(
          db,
          digest: approval.predecessorDigest
        )
      else {
        return .rejected(.invalidOwnerControl)
      }
      if try Self.trialRow(db, candidate: predecessor.digest) != nil {
        return .rejected(.invalidOwnerControl)
      }
      guard let state = try Self.readState(db, jobId: predecessor.manifest.jobId) else {
        return .rejected(.invalidOwnerControl)
      }
      guard try Self.sourceBindingsAreCurrent(db, artifact: predecessor, state: state) else {
        return .rejected(.sourceBindingsChanged)
      }
      guard
        let control = try Self.candidateControl(
          db,
          eventId: approval.feedbackEventId,
          candidate: predecessor,
          signal: .candidateApprove,
          expectedPayload: nil
        ),
        control.revision <= state.feedbackRevision,
        let preparation = try Self.currentPreparation(db, artifact: predecessor, state: state)
      else {
        return .rejected(.invalidOwnerControl)
      }
      if let existing = try Self.existingSuccessor(
        db,
        predecessor: predecessor.digest,
        control: control,
        origin: .ownerApproval
      ) {
        guard
          try Self.onlySuccessor(db, predecessor: predecessor.digest, is: existing.digest),
          try Self.sourceBindingsAreCurrent(db, artifact: existing, state: state)
        else {
          return .rejected(.invalidOwnerControl)
        }
        return try Self.admit(db, artifact: existing, redactor: redactor, now: now)
      }
      let successor: CandidateArtifact
      do {
        successor = try CandidateSuccessorRules.approval(
          predecessor: predecessor,
          control: control,
          feedbackRevision: state.feedbackRevision,
          effectiveFeedback: preparation.feedbackSources
        )
      } catch let rejection as AdmissionRejection {
        return .rejected(rejection)
      } catch {
        throw StoreError.unexpected("approval successor construction failed")
      }
      if let existing = try Self.readCandidateArtifact(db, digest: successor.digest) {
        guard
          existing == successor,
          try Self.onlySuccessor(db, predecessor: predecessor.digest, is: successor.digest)
        else {
          return .rejected(.invalidOwnerControl)
        }
        return try Self.admit(db, artifact: existing, redactor: redactor, now: now)
      }
      guard try Self.hasSuccessor(db, predecessor: predecessor.digest) == false else {
        return .rejected(.invalidOwnerControl)
      }
      let plan = try Self.planAdmission(
        db,
        artifact: successor,
        persisted: false,
        redactor: redactor,
        permitsClosedReplacement: true
      )
      guard case .insert = plan else {
        return Self.outcome(for: plan, artifact: successor)
      }
      try Self.recordCandidateArtifact(db, artifact: successor, now: now)
      return try Self.executeAdmission(db, artifact: successor, plan: plan, now: now)
    }
  }

  public func editCandidate(
    _ edit: CandidateEdit,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome {
    try database.writeMapping { db in
      guard let context = try Self.editContext(db, edit: edit) else {
        return .rejected(.invalidOwnerControl)
      }
      let replacement: LessonSet
      switch AdmissionValidator.validatedReplacement(
        jobId: context.predecessor.manifest.jobId,
        lessons: context.lessons,
        redactor: redactor
      ) {
      case .success(let set):
        replacement = set
      case .failure(let rejection):
        return .rejected(rejection)
      }
      if let existing = try Self.existingSuccessor(
        db,
        predecessor: context.predecessor.digest,
        control: context.control,
        origin: .ownerEdit
      ) {
        guard
          try Self.onlySuccessor(
            db,
            predecessor: context.predecessor.digest,
            is: existing.digest
          ),
          try Self.sourceBindingsAreCurrent(db, artifact: existing, state: context.state),
          try Self.trialRow(db, candidate: existing.digest) == nil,
          Self.contentRejection(existing, redactor: redactor) == nil
        else {
          return .rejected(.invalidOwnerControl)
        }
        return .awaitingApproval(existing)
      }
      guard
        try Self.sourceBindingsAreCurrent(
          db,
          artifact: context.predecessor,
          state: context.state
        ),
        let preparation = try Self.currentPreparation(
          db,
          artifact: context.predecessor,
          state: context.state
        )
      else {
        return .rejected(.sourceBindingsChanged)
      }
      let successor: CandidateArtifact
      do {
        successor = try CandidateSuccessorRules.edit(
          predecessor: context.predecessor,
          replacement: replacement,
          control: context.control,
          feedbackRevision: context.state.feedbackRevision,
          effectiveFeedback: preparation.feedbackSources
        )
      } catch let rejection as AdmissionRejection {
        return .rejected(rejection)
      } catch {
        throw StoreError.unexpected("edit successor construction failed")
      }
      if let existing = try Self.readCandidateArtifact(db, digest: successor.digest) {
        guard
          existing == successor,
          try Self.onlySuccessor(
            db,
            predecessor: context.predecessor.digest,
            is: successor.digest
          ),
          try Self.sourceBindingsAreCurrent(db, artifact: existing, state: context.state),
          try Self.trialRow(db, candidate: existing.digest) == nil
        else {
          return .rejected(.invalidOwnerControl)
        }
        return .awaitingApproval(existing)
      }
      guard try Self.hasSuccessor(db, predecessor: context.predecessor.digest) == false else {
        return .rejected(.invalidOwnerControl)
      }
      let plan = try Self.planAdmission(
        db,
        artifact: successor,
        persisted: false,
        redactor: redactor,
        permittedLiveCandidate: context.predecessor.digest,
        requiresSupport: false
      )
      guard case .awaitingApproval = plan else {
        return Self.outcome(for: plan, artifact: successor)
      }
      _ = try Self.closeCandidateTrial(db, candidate: context.predecessor, now: now)
      try Self.recordCandidateArtifact(
        db,
        artifact: successor,
        lessonSource: .ownerEdit,
        now: now
      )
      return Self.outcome(for: plan, artifact: successor)
    }
  }
}

// MARK: - Decision Inputs

private extension ScheduledLearningStoreGRDB {
  struct EditContext {
    let predecessor: CandidateArtifact
    let state: JobLearningState
    let control: CandidateFeedbackSource
    let lessons: [String]
  }

  static func editContext(_ db: Database, edit: CandidateEdit) throws -> EditContext? {
    guard
      let predecessor = try readCandidateArtifact(db, digest: edit.predecessorDigest),
      let state = try readState(db, jobId: predecessor.manifest.jobId),
      let control = try candidateControl(
        db,
        eventId: edit.feedbackEventId,
        candidate: predecessor,
        signal: .candidateEdit,
        expectedPayload: edit.payload
      ),
      control.revision <= state.feedbackRevision,
      let lessons = CandidateEditPayload.decode(edit.payload)
    else {
      return nil
    }
    return EditContext(
      predecessor: predecessor,
      state: state,
      control: control,
      lessons: lessons
    )
  }
}

// MARK: - Successor Validation

private extension ScheduledLearningStoreGRDB {
  static func contentRejection(
    _ artifact: CandidateArtifact,
    redactor: SecretRedactor
  ) -> AdmissionRejection? {
    switch AdmissionValidator.validatedReplacement(
      jobId: artifact.manifest.jobId,
      lessons: artifact.replacement.lessons,
      redactor: redactor
    ) {
    case .success(let replacement):
      return replacement == artifact.replacement ? nil : .sourceBindingsChanged
    case .failure(let rejection):
      return rejection
    }
  }

  static func onlySuccessor(
    _ db: Database,
    predecessor: CandidateDigest,
    is expected: CandidateDigest
  ) throws -> Bool {
    let digests = try String.fetchAll(
      db,
      sql: "SELECT candidate_digest FROM learning_candidates WHERE predecessor_digest = ?",
      arguments: [predecessor.rawValue]
    )
    return digests == [expected.rawValue]
  }
}
