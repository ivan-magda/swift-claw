import ClawCore
import Foundation
import GRDB

// MARK: - Owner Learning View

extension ScheduledLearningStoreGRDB {
  public func learningView(jobId: Int64?) throws(StoreError) -> [JobLearningView] {
    try database.readMapping { db in
      if let jobId {
        guard let job = try Self.viewJob(db, jobId: jobId) else {
          return [.notFound(jobId: jobId)]
        }
        return [try Self.view(db, job: job)]
      }

      let jobs = try Self.armedViewJobs(db)
      return try jobs.map { job in
        try Self.view(db, job: job)
      }
    }
  }
}

// MARK: - Snapshot Assembly

private extension ScheduledLearningStoreGRDB {
  struct ViewJobRow {
    let jobId: Int64
    let label: String
    let status: String
    let timezone: String
    let hasRecurrence: Bool
  }

  enum ViewCorruption: Error {
    case invalid
  }

  static func armedViewJobs(_ db: Database) throws -> [ViewJobRow] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT job.id, job.label, job.status, job.timezone, job.recurrence
        FROM job_learning_state AS state
        JOIN scheduled_jobs AS job ON job.id = state.job_id
        ORDER BY job.id
        """
    )
    return rows.map(viewJob(row:))
  }

  static func viewJob(_ db: Database, jobId: Int64) throws -> ViewJobRow? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT id, label, status, timezone, recurrence
        FROM scheduled_jobs WHERE id = ?
        """,
      arguments: [jobId]
    ).map(viewJob(row:))
  }

  static func viewJob(row: Row) -> ViewJobRow {
    ViewJobRow(
      jobId: row["id"],
      label: row["label"],
      status: row["status"],
      timezone: row["timezone"],
      hasRecurrence: (row["recurrence"] as String?) != nil
    )
  }

  static func view(_ db: Database, job: ViewJobRow) throws -> JobLearningView {
    let fallback = UnreadableLearningJob(
      jobId: job.jobId,
      validatedLabel: validatedLabel(job.label)
    )
    do {
      let identity = try jobIdentity(job)
      guard let state = try readState(db, jobId: job.jobId) else {
        return .unarmed(identity)
      }
      return .readable(try readableView(db, job: job, identity: identity, state: state))
    } catch ViewCorruption.invalid {
      return .unreadable(fallback)
    } catch let error as StoreError {
      guard case .unexpected = error else {
        throw error
      }
      return .unreadable(fallback)
    }
  }

  static func jobIdentity(_ row: ViewJobRow) throws -> LearningJobIdentity {
    guard
      row.jobId > 0,
      let label = validatedLabel(row.label),
      let status = ScheduledJobStatus(rawValue: row.status),
      TimeZone(identifier: row.timezone) != nil
    else {
      throw ViewCorruption.invalid
    }
    return LearningJobIdentity(
      jobId: row.jobId,
      label: label,
      status: status,
      timezone: row.timezone
    )
  }

  static func validatedLabel(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      trimmed == raw,
      trimmed.isEmpty == false,
      trimmed.count <= ScheduleDraftValidator.maxLabelGraphemes
    else {
      return nil
    }
    return trimmed
  }

  static func readableView(
    _ db: Database,
    job: ViewJobRow,
    identity: LearningJobIdentity,
    state: JobLearningState
  ) throws -> ReadableJobLearningView {
    guard
      state.jobId == job.jobId,
      state.epoch.value > 0,
      state.stableRevision.value >= 0,
      state.feedbackRevision.value >= 0,
      isDigest(state.stableDigest.rawValue),
      let stable = try readLessonSet(db, jobId: job.jobId, digest: state.stableDigest),
      stable.jobId == job.jobId,
      stable.digest == state.stableDigest
    else {
      throw ViewCorruption.invalid
    }

    let liveTrial = try liveTrialView(db, job: job, state: state)
    var warnings: [LearningViewWarning] = []
    if state.openTrialId != liveTrial?.trialId {
      warnings.append(.trialPointerMismatch)
    }
    let decision = try lastDecisionView(db, state: state)
    return ReadableJobLearningView(
      job: identity,
      epoch: state.epoch,
      stableRevision: state.stableRevision,
      stableLessons: stable,
      liveTrial: liveTrial,
      lastDecision: decision,
      warnings: warnings
    )
  }
}

// MARK: - Trial Projection

private extension ScheduledLearningStoreGRDB {
  struct LiveTrialProjection {
    let row: TrialRow
    let admittedAt: Date
    let assignmentDeadline: Date
    let decisionDeadline: Date
    let maximumAssignments: Int
    let consumedAssignments: Int
    let cohortCutoff: Date
    let closeReason: String?
  }

  static func liveTrialView(
    _ db: Database,
    job: ViewJobRow,
    state: JobLearningState
  ) throws -> LearningTrialView? {
    guard try currentEpochHasOnlyKnownTrialStates(db, state: state) else {
      throw ViewCorruption.invalid
    }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT trial_id, job_id, learning_epoch, base_digest, candidate_digest, generation,
          admitted_at, assignment_deadline, decision_deadline, max_assignments,
          consumed_assignments, cohort_cutoff, state, close_reason, algorithm
        FROM learning_trials
        WHERE job_id = ? AND state IN (?, ?)
        ORDER BY trial_id
        """,
      arguments: [
        job.jobId,
        LearningTrialState.open.rawValue,
        LearningTrialState.draining.rawValue,
      ]
    )
    guard rows.count <= 1 else {
      throw ViewCorruption.invalid
    }
    guard let row = rows.first else {
      return nil
    }
    guard job.hasRecurrence else {
      throw ViewCorruption.invalid
    }
    let trial = try liveTrialProjection(row)
    return try validateTrial(db, trial: trial, state: state)
  }

  static func currentEpochHasOnlyKnownTrialStates(
    _ db: Database,
    state: JobLearningState
  ) throws -> Bool {
    let known = LearningTrialState.allCases.map(\.rawValue)
    return try Bool.fetchOne(
      db,
      sql: """
        SELECT NOT EXISTS(
          SELECT 1 FROM learning_trials
          WHERE job_id = ? AND learning_epoch = ?
            AND state NOT IN (?, ?, ?, ?, ?)
        )
        """,
      arguments: [state.jobId, state.epoch.value] + StatementArguments(known)
    ) ?? false
  }

  static func liveTrialProjection(_ row: Row) throws -> LiveTrialProjection {
    guard
      let state = LearningTrialState(rawValue: row["state"]),
      let admittedAt = EpochSecondCodec.date(fromEpoch: row["admitted_at"]),
      let assignmentDeadline = EpochSecondCodec.date(fromEpoch: row["assignment_deadline"]),
      let decisionDeadline = EpochSecondCodec.date(fromEpoch: row["decision_deadline"]),
      let cohortCutoff = EpochSecondCodec.date(fromEpoch: row["cohort_cutoff"])
    else {
      throw ViewCorruption.invalid
    }
    let algorithm = LearningAlgorithm(rawValue: row["algorithm"])
    let trialRow = TrialRow(
      id: row["trial_id"],
      jobId: row["job_id"],
      epoch: LearningEpoch(row["learning_epoch"]),
      baseDigest: LessonSetDigest(rawValue: row["base_digest"]),
      candidateDigest: CandidateDigest(rawValue: row["candidate_digest"]),
      generation: row["generation"],
      state: state,
      algorithm: algorithm
    )
    return LiveTrialProjection(
      row: trialRow,
      admittedAt: admittedAt,
      assignmentDeadline: assignmentDeadline,
      decisionDeadline: decisionDeadline,
      maximumAssignments: row["max_assignments"],
      consumedAssignments: row["consumed_assignments"],
      cohortCutoff: cohortCutoff,
      closeReason: row["close_reason"]
    )
  }

  static func validateTrial(
    _ db: Database,
    trial: LiveTrialProjection,
    state: JobLearningState
  ) throws -> LearningTrialView {
    let row = trial.row
    guard
      row.id > 0,
      row.jobId == state.jobId,
      row.epoch == state.epoch,
      row.baseDigest == state.stableDigest,
      row.generation > 0,
      row.algorithm == .v1,
      row.state == .open || row.state == .draining,
      isDigest(row.candidateDigest.rawValue),
      trial.maximumAssignments == TrialAdmissionPolicy.maximumAssignments,
      trial.consumedAssignments >= 0,
      trial.consumedAssignments <= trial.maximumAssignments,
      trial.cohortCutoff == trial.admittedAt,
      trial.assignmentDeadline
        == trial.admittedAt.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow),
      trial.decisionDeadline
        == trial.admittedAt.addingTimeInterval(TrialAdmissionPolicy.decisionWindow),
      trial.closeReason == nil,
      let artifact = try readCandidateArtifact(db, digest: row.candidateDigest),
      artifact.manifest.jobId == state.jobId,
      artifact.manifest.epoch == state.epoch,
      artifact.manifest.baseDigest == state.stableDigest,
      artifact.manifest.baseRevision == state.stableRevision,
      artifact.manifest.algorithm == .v1,
      artifact.replacement.jobId == state.jobId
    else {
      throw ViewCorruption.invalid
    }
    let receipt = try admissionReceipt(db, artifact: artifact, trial: row)
    guard
      receipt.candidateDigest == row.candidateDigest,
      receipt.replacementDigest == artifact.replacement.digest,
      receipt.trialId == row.id,
      receipt.generation == row.generation
    else {
      throw ViewCorruption.invalid
    }
    let unresolved = try validateCreatedAssignments(
      db,
      trial: row,
      replacement: artifact.replacement.digest
    )
    guard unresolved == trial.consumedAssignments else {
      throw ViewCorruption.invalid
    }
    let counts = LearningTrialCounts(
      consumed: trial.consumedAssignments,
      maximum: trial.maximumAssignments,
      unresolved: unresolved
    )
    return LearningTrialView(
      trialId: row.id,
      epoch: row.epoch,
      generation: row.generation,
      state: row.state,
      candidateDigest: row.candidateDigest,
      baseDigest: row.baseDigest,
      baseRevision: artifact.manifest.baseRevision,
      replacementDigest: artifact.replacement.digest,
      counts: counts,
      assignmentDeadline: trial.assignmentDeadline,
      decisionDeadline: trial.decisionDeadline
    )
  }

  static func validateCreatedAssignments(
    _ db: Database,
    trial: TrialRow,
    replacement: LessonSetDigest
  ) throws -> Int {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT assignment.run_id, assignment.job_id, assignment.learning_epoch,
          assignment.trial_generation, assignment.state, assignment.outcome,
          assignment.issue_codes, assignment.evaluation_digest,
          assignment.evaluation_required, assignment.effective_feedback_revision,
          assignment.resolved_at, binding.run_id AS binding_run_id,
          binding.job_id AS binding_job_id, binding.learning_epoch AS binding_epoch,
          binding.stable_digest, binding.effective_digest, binding.trial_id,
          binding.trial_generation AS binding_generation
        FROM trial_assignments AS assignment
        LEFT JOIN run_learning_bindings AS binding ON binding.run_id = assignment.run_id
        WHERE assignment.trial_id = ?
        ORDER BY assignment.run_id
        """,
      arguments: [trial.id]
    )
    for row in rows {
      guard
        (row["job_id"] as Int64) == trial.jobId,
        LearningEpoch(row["learning_epoch"] as Int64) == trial.epoch,
        (row["trial_generation"] as Int) == trial.generation,
        (row["state"] as String) == TrialAssignmentState.created.rawValue,
        (row["outcome"] as String?) == nil,
        (row["issue_codes"] as String?) == nil,
        (row["evaluation_digest"] as String?) == nil,
        row["evaluation_required"] as Bool,
        (row["effective_feedback_revision"] as Int64?) == nil,
        (row["resolved_at"] as Int64?) == nil,
        (row["binding_run_id"] as Int64?) == row["run_id"] as Int64,
        (row["binding_job_id"] as Int64?) == trial.jobId,
        (row["binding_epoch"] as Int64?) == trial.epoch.value,
        (row["stable_digest"] as String?) == trial.baseDigest.rawValue,
        (row["effective_digest"] as String?) == replacement.rawValue,
        (row["trial_id"] as Int64?) == trial.id,
        (row["binding_generation"] as Int?) == trial.generation
      else {
        throw ViewCorruption.invalid
      }
    }
    return rows.count
  }
}

// MARK: - Decision Projection

private extension ScheduledLearningStoreGRDB {
  static func lastDecisionView(
    _ db: Database,
    state: JobLearningState
  ) throws -> LearningDecisionView? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT decision_id, kind, job_id, learning_epoch, inputs, result, algorithm, decided_at
          FROM learning_decisions
          WHERE job_id = ? AND learning_epoch = ?
          ORDER BY decided_at DESC, decision_id DESC
          LIMIT 1
          """,
        arguments: [state.jobId, state.epoch.value]
      )
    else {
      return nil
    }
    guard
      let decidedAt = EpochSecondCodec.date(fromEpoch: row["decided_at"]),
      (row["decision_id"] as Int64) > 0,
      (row["job_id"] as Int64) == state.jobId,
      LearningEpoch(row["learning_epoch"] as Int64) == state.epoch
    else {
      throw ViewCorruption.invalid
    }
    let algorithm = LearningAlgorithm(rawValue: row["algorithm"])
    guard algorithm == .v1 else {
      throw ViewCorruption.invalid
    }
    let inputsJSON: String = row["inputs"]
    let resultJSON: String = row["result"]
    let detail = try decisionDetail(
      db,
      kind: row["kind"],
      inputsJSON: inputsJSON,
      resultJSON: resultJSON,
      state: state
    )
    return LearningDecisionView(
      decisionId: row["decision_id"],
      jobId: state.jobId,
      epoch: state.epoch,
      algorithm: algorithm,
      decidedAt: decidedAt,
      detail: detail
    )
  }

  static func decisionDetail(
    _ db: Database,
    kind: String,
    inputsJSON: String,
    resultJSON: String,
    state: JobLearningState
  ) throws -> LearningDecisionDetail {
    switch kind {
    case AdmissionReceipt.kind:
      let inputs: AdmissionDecisionInputs = try decodeCanonical(inputsJSON)
      let result: AdmissionReceipt = try decodeCanonical(resultJSON)
      guard
        inputs.candidateDigest == result.candidateDigest,
        let artifact = try readCandidateArtifact(db, digest: inputs.candidateDigest),
        artifact.manifest.jobId == state.jobId,
        artifact.manifest.epoch == state.epoch,
        artifact.manifest.algorithm == .v1,
        let trial = try trialRow(db, candidate: inputs.candidateDigest),
        try admissionReceipt(db, artifact: artifact, trial: trial) == result
      else {
        throw ViewCorruption.invalid
      }
      return .candidateAdmission(inputs: inputs, result: result)
    case ReflectionNoCandidateReceipt.kind:
      let inputs: ReflectionNoCandidateInputs = try decodeCanonical(inputsJSON)
      let result: ReflectionNoCandidateReceipt = try decodeCanonical(resultJSON)
      guard
        isDigest(inputs.triggerDigest.rawValue),
        isDigest(inputs.carrierDigest.rawValue),
        isDigest(result.resultDigest.rawValue),
        let operation = try readOperation(db, id: inputs.operationId),
        operation.jobId == state.jobId,
        operation.epoch == state.epoch,
        operation.phase == .reflector,
        operation.sourceDigest == inputs.triggerDigest.rawValue,
        operation.carrierDigest == inputs.carrierDigest,
        operation.state == .succeeded
      else {
        throw ViewCorruption.invalid
      }
      return .reflectionNoCandidate(inputs: inputs, result: result)
    default:
      throw ViewCorruption.invalid
    }
  }

  static func decodeCanonical<Value: Codable>(_ json: String) throws -> Value {
    let bytes = Data(json.utf8)
    guard
      let value = try? JSONDecoder().decode(Value.self, from: bytes),
      let canonical = try? CanonicalJSON.data(encoding: value),
      canonical == bytes
    else {
      throw ViewCorruption.invalid
    }
    return value
  }

  static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}
