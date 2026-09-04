import ClawCore
import Foundation
import GRDB

// MARK: - Candidate Decisions

extension ScheduledLearningStoreGRDB {
  public func commitCandidateReview(
    _ review: CandidateReviewNotice,
    now: Date
  ) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try Self.validateReview(review)
      let firstKey = OutboxDedupKey.make(subjectDigest: review.subjectDigest, ordinal: 0)
      let exists =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM outbound_deliveries WHERE dedup_key = ?)",
          arguments: [firstKey]
        ) ?? false
      guard exists == false else {
        return false
      }
      for chunk in review.chunks {
        guard try OutboxStoreGRDB.insertNotice(db, chunk: chunk, now: now) else {
          throw StoreError.unexpected("candidate review chunk identity already exists")
        }
      }
      for target in review.targets {
        try Self.insertTarget(db, target)
      }
      return true
    }
  }

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
      guard
        let state = try Self.readState(db, jobId: predecessor.manifest.jobId),
        let control = try Self.candidateControl(
          db,
          eventId: approval.feedbackEventId,
          candidate: predecessor,
          signal: .candidateApprove,
          expectedPayload: nil
        ),
        state.feedbackRevision == control.revision
      else {
        return .rejected(.invalidOwnerControl)
      }
      if let existing = try Self.existingSuccessor(
        db,
        predecessor: predecessor.digest,
        control: control,
        origin: .ownerApproval
      ) {
        return try Self.admit(db, artifact: existing, redactor: redactor, now: now)
      }
      guard try Self.hasSuccessor(db, predecessor: predecessor.digest) == false else {
        return .rejected(.invalidOwnerControl)
      }
      guard let preparation = try Self.currentPreparation(db, artifact: predecessor, state: state)
      else {
        return .rejected(.sourceBindingsChanged)
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
      if let rejection = Self.contentRejection(successor, redactor: redactor) {
        return .rejected(rejection)
      }
      try Self.recordCandidateArtifact(db, artifact: successor, now: now)
      return try Self.admit(db, artifact: successor, redactor: redactor, now: now)
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
      if let existing = try Self.existingSuccessor(
        db,
        predecessor: context.predecessor.digest,
        control: context.control,
        origin: .ownerEdit
      ) {
        return .awaitingApproval(existing)
      }
      guard try Self.hasSuccessor(db, predecessor: context.predecessor.digest) == false else {
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
      guard
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
      _ = try Self.closeCandidateTrial(db, candidate: context.predecessor)
      try Self.recordCandidateArtifact(
        db,
        artifact: successor,
        lessonSource: .ownerEdit,
        now: now
      )
      return .awaitingApproval(successor)
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
      state.feedbackRevision == control.revision,
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

  static func validateReview(_ review: CandidateReviewNotice) throws {
    guard
      review.targets.isEmpty == false,
      review.chunks.isEmpty == false,
      Set(review.targets.map(\.nonce)).count == review.targets.count,
      review.targets.first?.subjectKind == .candidate,
      let candidateDigest = review.targets.first?.subjectDigest,
      review.subjectDigest
        == CandidateReviewIdentity.digest(
          candidateDigest: CandidateDigest(rawValue: candidateDigest)
        ),
      review.chunks.enumerated().allSatisfy({ ordinal, chunk in
        chunk.ordinal == ordinal && chunk.subjectDigest == review.subjectDigest
      }),
      review.chunks.dropLast().allSatisfy({ chunk in chunk.replyMarkup == nil }),
      review.chunks.last?.replyMarkup != nil
    else {
      throw StoreError.unexpected("candidate review carrier is inconsistent")
    }
  }
}

// MARK: - Common Admission

private extension ScheduledLearningStoreGRDB {
  struct AdmissionJob {
    let status: ScheduledJobStatus
    let hasRecurrence: Bool
    let sessionId: Int64?
  }

  struct TrialRow {
    let id: Int64
    let generation: Int
    let state: LearningTrialState
  }

  static func admit(
    _ db: Database,
    artifact: CandidateArtifact,
    redactor: SecretRedactor,
    now: Date
  ) throws -> AdmissionOutcome {
    guard
      let exact = try readCandidateArtifact(db, digest: artifact.digest),
      exact == artifact
    else {
      throw StoreError.unexpected("candidate changed during admission reload")
    }
    if let existing = try trialRow(db, candidate: artifact.digest) {
      guard existing.state == .open || existing.state == .draining else {
        return .rejected(.replacementAlreadyClosed)
      }
      return .admitted(
        AdmissionReceipt(
          candidateDigest: artifact.digest,
          replacementDigest: artifact.replacement.digest,
          trialId: existing.id,
          generation: existing.generation
        )
      )
    }
    guard
      let state = try readState(db, jobId: artifact.manifest.jobId),
      let job = try admissionJob(db, jobId: artifact.manifest.jobId)
    else {
      return .rejected(.jobNotRepeatable)
    }
    let live = try liveTrial(db, jobId: artifact.manifest.jobId)
    let sourcesCurrent = try sourceBindingsAreCurrent(db, artifact: artifact, state: state)
    let vetoes = try hardVetoes(db, artifact: artifact)
    let context = AdmissionValidationContext(
      currentState: state,
      jobHasRecurrence: job.hasRecurrence,
      jobStatus: job.status,
      hasLiveTrial: live != nil,
      sourceBindingsAreCurrent: sourcesCurrent,
      hardVetoes: vetoes,
      replacementAlreadyClosed: try replacementWasClosed(db, artifact: artifact),
      support: support(for: artifact),
      redactor: redactor
    )
    if let rejection = AdmissionValidator.validate(candidate: artifact, context: context) {
      return .rejected(rejection)
    }
    guard artifact.manifest.origin != .ownerEdit else {
      return .awaitingApproval(artifact)
    }
    let generation = try nextGeneration(db, artifact: artifact)
    let receipt = try insertTrial(
      db,
      artifact: artifact,
      job: job,
      generation: generation,
      now: now
    )
    return .admitted(receipt)
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

  static func admissionJob(_ db: Database, jobId: Int64) throws -> AdmissionJob? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT status, recurrence, session_id FROM scheduled_jobs WHERE id = ?",
        arguments: [jobId]
      ),
      let status = ScheduledJobStatus(rawValue: row["status"])
    else {
      return nil
    }
    return AdmissionJob(
      status: status,
      hasRecurrence: (row["recurrence"] as String?) != nil,
      sessionId: row["session_id"]
    )
  }

  static func trialRow(_ db: Database, candidate: CandidateDigest) throws -> TrialRow? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT trial_id, generation, state FROM learning_trials
          WHERE candidate_digest = ? ORDER BY trial_id DESC LIMIT 1
          """,
        arguments: [candidate.rawValue]
      ),
      let state = LearningTrialState(rawValue: row["state"])
    else {
      return nil
    }
    return TrialRow(id: row["trial_id"], generation: row["generation"], state: state)
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
            AND candidate.replacement_digest = ?
            AND trial.state NOT IN (?, ?)
        )
        """,
      arguments: [
        artifact.manifest.jobId,
        artifact.manifest.epoch.value,
        artifact.manifest.baseDigest.rawValue,
        artifact.replacement.digest.rawValue,
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
    struct Inputs: Encodable {
      let candidateDigest: CandidateDigest

      enum CodingKeys: String, CodingKey {
        case candidateDigest = "candidate_digest"
      }
    }
    let inputs = try CanonicalJSON.data(encoding: Inputs(candidateDigest: artifact.digest))
    let result = try CanonicalJSON.data(encoding: receipt)
    // swiftlint:disable:next optional_data_string_conversion
    let inputsJSON = String(decoding: inputs, as: UTF8.self)
    // swiftlint:disable:next optional_data_string_conversion
    let resultJSON = String(decoding: result, as: UTF8.self)
    try db.execute(
      sql: """
        INSERT INTO learning_decisions(kind, job_id, learning_epoch, inputs, result, algorithm,
          decided_at) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        AdmissionReceipt.kind,
        artifact.manifest.jobId,
        artifact.manifest.epoch.value,
        inputsJSON,
        resultJSON,
        artifact.manifest.algorithm.rawValue,
        EpochSecondCodec.epoch(now),
      ]
    )
  }
}
