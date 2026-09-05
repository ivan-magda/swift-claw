import ClawCore
import Foundation
import GRDB

// MARK: - Candidate Decisions

extension ScheduledLearningStoreGRDB {
  public func admitCandidate(
    digest: CandidateDigest,
    redactor: SecretRedactor,
    now: Date
  ) throws(StoreError) -> AdmissionOutcome {
    try database.writeMapping { db in
      guard let artifact = try Self.readCandidateArtifact(db, digest: digest) else {
        return .rejected(.sourceBindingsChanged)
      }
      return try Self.admit(db, artifact: artifact, redactor: redactor, now: now)
    }
  }

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

// MARK: - Common Admission

private extension ScheduledLearningStoreGRDB {
  enum AdmissionPlan {
    case replay(AdmissionReceipt)
    case awaitingApproval
    case insert(job: AdmissionJob, generation: Int)
    case rejected(AdmissionRejection)
  }

  static func admit(
    _ db: Database,
    artifact: CandidateArtifact,
    redactor: SecretRedactor,
    now: Date
  ) throws -> AdmissionOutcome {
    let plan = try planAdmission(db, artifact: artifact, persisted: true, redactor: redactor)
    return try executeAdmission(db, artifact: artifact, plan: plan, now: now)
  }

  static func planAdmission(
    _ db: Database,
    artifact: CandidateArtifact,
    persisted: Bool,
    redactor: SecretRedactor,
    permittedLiveCandidate: CandidateDigest? = nil,
    requiresSupport: Bool = true,
    permitsClosedReplacement: Bool = false
  ) throws -> AdmissionPlan {
    if persisted {
      guard
        let exact = try readCandidateArtifact(db, digest: artifact.digest),
        exact == artifact
      else {
        throw StoreError.unexpected("candidate changed during admission reload")
      }
    }
    if let existing = try trialRow(db, candidate: artifact.digest) {
      return .replay(try admissionReceipt(db, artifact: artifact, trial: existing))
    }
    guard try admissionDecisionExists(db, artifact: artifact) == false else {
      throw StoreError.unexpected("candidate admission decision has no matching trial")
    }
    guard
      let state = try readState(db, jobId: artifact.manifest.jobId),
      let job = try admissionJob(db, jobId: artifact.manifest.jobId)
    else {
      return .rejected(.jobNotRepeatable)
    }
    let live = try liveTrial(db, jobId: artifact.manifest.jobId)
    let hasCompetingLiveTrial =
      live.map { trial in
        trial.candidateDigest != permittedLiveCandidate
      } ?? false
    let sourcesCurrent = try sourceBindingsAreCurrent(db, artifact: artifact, state: state)
    let vetoes = try hardVetoes(db, artifact: artifact)
    let context = AdmissionValidationContext(
      currentState: state,
      jobHasRecurrence: job.hasRecurrence,
      jobStatus: job.status,
      hasLiveTrial: hasCompetingLiveTrial,
      sourceBindingsAreCurrent: sourcesCurrent,
      hardVetoes: vetoes,
      replacementAlreadyClosed: try replacementWasClosed(db, artifact: artifact),
      support: support(for: artifact),
      requiresSupport: requiresSupport,
      permitsClosedReplacement: permitsClosedReplacement,
      redactor: redactor
    )
    if let rejection = AdmissionValidator.validate(candidate: artifact, context: context) {
      return .rejected(rejection)
    }
    guard artifact.manifest.origin != .ownerEdit else {
      return .awaitingApproval
    }
    return .insert(job: job, generation: try nextGeneration(db, artifact: artifact))
  }

  static func executeAdmission(
    _ db: Database,
    artifact: CandidateArtifact,
    plan: AdmissionPlan,
    now: Date
  ) throws -> AdmissionOutcome {
    switch plan {
    case .replay(let receipt):
      return .admitted(receipt)
    case .awaitingApproval:
      return .awaitingApproval(artifact)
    case .insert(let job, let generation):
      return .admitted(
        try insertTrial(db, artifact: artifact, job: job, generation: generation, now: now)
      )
    case .rejected(let rejection):
      return .rejected(rejection)
    }
  }

  static func outcome(for plan: AdmissionPlan, artifact: CandidateArtifact) -> AdmissionOutcome {
    switch plan {
    case .replay(let receipt):
      return .admitted(receipt)
    case .awaitingApproval:
      return .awaitingApproval(artifact)
    case .rejected(let rejection):
      return .rejected(rejection)
    case .insert:
      return .rejected(.sourceBindingsChanged)
    }
  }

  static func insertTrial(
    _ db: Database,
    artifact: CandidateArtifact,
    job: AdmissionJob,
    generation: Int,
    now: Date
  ) throws -> AdmissionReceipt {
    try db.execute(
      sql: """
        INSERT INTO learning_trials(job_id, learning_epoch, base_digest, candidate_digest,
          generation, admitted_at, assignment_deadline, decision_deadline, max_assignments,
          consumed_assignments, cohort_cutoff, state, algorithm)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
        """,
      arguments: [
        artifact.manifest.jobId,
        artifact.manifest.epoch.value,
        artifact.manifest.baseDigest.rawValue,
        artifact.digest.rawValue,
        generation,
        EpochSecondCodec.epoch(now),
        EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow)),
        EpochSecondCodec.epoch(now.addingTimeInterval(TrialAdmissionPolicy.decisionWindow)),
        TrialAdmissionPolicy.maximumAssignments,
        EpochSecondCodec.epoch(now),
        LearningTrialState.open.rawValue,
        artifact.manifest.algorithm.rawValue,
      ]
    )
    let receipt = AdmissionReceipt(
      candidateDigest: artifact.digest,
      replacementDigest: artifact.replacement.digest,
      trialId: db.lastInsertedRowID,
      generation: generation
    )
    try db.execute(
      sql: """
        UPDATE job_learning_state SET open_trial_id = ?
        WHERE job_id = ? AND learning_epoch = ?
        """,
      arguments: [receipt.trialId, artifact.manifest.jobId, artifact.manifest.epoch.value]
    )
    try insertAdmissionReceipt(db, artifact: artifact, receipt: receipt, now: now)
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .system,
        action: .learningCandidateAdmitted,
        decision: "admitted",
        sessionId: job.sessionId,
        ts: now
      )
    )
    return receipt
  }

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

  static func support(for artifact: CandidateArtifact) -> AdmissionSupport? {
    switch artifact.manifest.origin {
    case .reflection:
      switch artifact.manifest.triggerReason {
      case .recurringIssue: .recurringIssue
      case .ownerCorrection: .ownerCorrection
      }
    case .ownerApproval:
      .ownerApproval
    case .ownerEdit:
      nil
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

  static func nextGeneration(_ db: Database, artifact: CandidateArtifact) throws -> Int {
    let latest =
      try Int.fetchOne(
        db,
        sql: """
          SELECT MAX(generation) FROM learning_trials
          WHERE job_id = ? AND learning_epoch = ?
          """,
        arguments: [artifact.manifest.jobId, artifact.manifest.epoch.value]
      ) ?? 0
    return latest + 1
  }

  static func replacementWasClosed(_ db: Database, artifact: CandidateArtifact) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(
          SELECT 1 FROM learning_trials AS trial
          JOIN learning_candidates AS candidate
            ON candidate.candidate_digest = trial.candidate_digest
          WHERE trial.job_id = ? AND trial.learning_epoch = ? AND trial.base_digest = ?
            AND candidate.replacement_digest = ? AND trial.algorithm = ?
            AND trial.state NOT IN (?, ?)
        )
        """,
      arguments: [
        artifact.manifest.jobId,
        artifact.manifest.epoch.value,
        artifact.manifest.baseDigest.rawValue,
        artifact.replacement.digest.rawValue,
        artifact.manifest.algorithm.rawValue,
        LearningTrialState.open.rawValue,
        LearningTrialState.draining.rawValue,
      ]
    ) ?? false
  }

  static func insertAdmissionReceipt(
    _ db: Database,
    artifact: CandidateArtifact,
    receipt: AdmissionReceipt,
    now: Date
  ) throws {
    try insertDecision(
      db,
      kind: AdmissionReceipt.kind,
      jobId: artifact.manifest.jobId,
      epoch: artifact.manifest.epoch,
      inputs: AdmissionDecisionInputs(candidateDigest: artifact.digest),
      result: receipt,
      algorithm: artifact.manifest.algorithm,
      now: now
    )
  }
}
