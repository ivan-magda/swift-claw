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
    let label: String?
    let status: String?
    let timezone: String?
    let hasRecurrence: Bool
    let primitivesAreValid: Bool
  }

  enum ViewCorruption: Error {
    case invalid
  }

  static func armedViewJobs(_ db: Database) throws -> [ViewJobRow] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT state.job_id AS selected_job_id, job.id, job.label, job.status, job.timezone,
          job.recurrence
        FROM job_learning_state AS state
        JOIN scheduled_jobs AS job ON job.id = state.job_id
        ORDER BY job.id
        """
    )
    return rows.map { row in
      viewJob(row: row, requestedJobId: nil)
    }
  }

  static func viewJob(_ db: Database, jobId: Int64) throws -> ViewJobRow? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT id, label, status, timezone, recurrence
        FROM scheduled_jobs WHERE id = ?
        """,
      arguments: [jobId]
    ).map { row in
      viewJob(row: row, requestedJobId: jobId)
    }
  }

  static func viewJob(row: Row, requestedJobId: Int64?) -> ViewJobRow {
    let storedJobId = SQLiteStoredValue.int64(in: row, column: "id")
    let selectedJobId = SQLiteStoredValue.int64(in: row, column: "selected_job_id")
    let jobId = requestedJobId ?? selectedJobId ?? storedJobId ?? 0
    let label = SQLiteStoredValue.string(in: row, column: "label")
    let status = SQLiteStoredValue.string(in: row, column: "status")
    let timezone = SQLiteStoredValue.string(in: row, column: "timezone")
    let recurrence = SQLiteStoredValue.nullableString(in: row, column: "recurrence")
    return ViewJobRow(
      jobId: jobId,
      label: label,
      status: status,
      timezone: timezone,
      hasRecurrence: recurrence?.value != nil,
      primitivesAreValid: storedJobId == jobId
        && label != nil
        && status != nil
        && timezone != nil
        && recurrence != nil
    )
  }

  static func view(_ db: Database, job: ViewJobRow) throws -> JobLearningView {
    let fallback = UnreadableLearningJob(
      jobId: job.jobId,
      validatedLabel: job.label.flatMap(validatedLabel)
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
      row.primitivesAreValid,
      row.jobId > 0,
      let rawLabel = row.label,
      let label = validatedLabel(rawLabel),
      let rawStatus = row.status,
      let status = ScheduledJobStatus(rawValue: rawStatus),
      let timezone = row.timezone,
      TimeZone(identifier: timezone) != nil
    else {
      throw ViewCorruption.invalid
    }
    return LearningJobIdentity(
      jobId: row.jobId,
      label: label,
      status: status,
      timezone: timezone
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
      isCanonicalDigest(state.stableDigest.rawValue),
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
    guard
      job.hasRecurrence,
      let rawStatus = job.status,
      let status = ScheduledJobStatus(rawValue: rawStatus),
      status == .active || status == .paused
    else {
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
      let trialId = SQLiteStoredValue.int64(in: row, column: "trial_id"),
      let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
      let epoch = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      let baseDigest = SQLiteStoredValue.string(in: row, column: "base_digest"),
      let candidateDigest = SQLiteStoredValue.string(in: row, column: "candidate_digest"),
      let generation = SQLiteStoredValue.int(in: row, column: "generation"),
      let stateRaw = SQLiteStoredValue.string(in: row, column: "state"),
      let state = LearningTrialState(rawValue: stateRaw),
      let admittedEpoch = SQLiteStoredValue.int64(in: row, column: "admitted_at"),
      let admittedAt = EpochSecondCodec.date(fromEpoch: admittedEpoch),
      let assignmentEpoch = SQLiteStoredValue.int64(in: row, column: "assignment_deadline"),
      let assignmentDeadline = EpochSecondCodec.date(fromEpoch: assignmentEpoch),
      let decisionEpoch = SQLiteStoredValue.int64(in: row, column: "decision_deadline"),
      let decisionDeadline = EpochSecondCodec.date(fromEpoch: decisionEpoch),
      let maximumAssignments = SQLiteStoredValue.int(in: row, column: "max_assignments"),
      let consumedAssignments = SQLiteStoredValue.int(in: row, column: "consumed_assignments"),
      let cutoffEpoch = SQLiteStoredValue.int64(in: row, column: "cohort_cutoff"),
      let cohortCutoff = EpochSecondCodec.date(fromEpoch: cutoffEpoch),
      let closeReason = SQLiteStoredValue.nullableString(in: row, column: "close_reason"),
      let algorithmRaw = SQLiteStoredValue.string(in: row, column: "algorithm")
    else {
      throw ViewCorruption.invalid
    }
    let trialRow = TrialRow(
      id: trialId,
      jobId: jobId,
      epoch: LearningEpoch(epoch),
      baseDigest: LessonSetDigest(rawValue: baseDigest),
      candidateDigest: CandidateDigest(rawValue: candidateDigest),
      generation: generation,
      state: state,
      algorithm: LearningAlgorithm(rawValue: algorithmRaw)
    )
    return LiveTrialProjection(
      row: trialRow,
      admittedAt: admittedAt,
      assignmentDeadline: assignmentDeadline,
      decisionDeadline: decisionDeadline,
      maximumAssignments: maximumAssignments,
      consumedAssignments: consumedAssignments,
      cohortCutoff: cohortCutoff,
      closeReason: closeReason.value
    )
  }

  static func validateTrial(
    _ db: Database,
    trial: LiveTrialProjection,
    state: JobLearningState
  ) throws -> LearningTrialView {
    let row = trial.row
    guard
      trialMetadataMatches(trial, state: state),
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

  static func trialMetadataMatches(
    _ trial: LiveTrialProjection,
    state: JobLearningState
  ) -> Bool {
    let row = trial.row
    return row.id > 0
      && row.jobId == state.jobId
      && row.epoch == state.epoch
      && row.baseDigest == state.stableDigest
      && row.generation > 0
      && row.algorithm == .v1
      && (row.state == .open || row.state == .draining)
      && isCanonicalDigest(row.candidateDigest.rawValue)
      && trial.maximumAssignments == TrialAdmissionPolicy.maximumAssignments
      && trial.consumedAssignments >= 0
      && trial.consumedAssignments <= trial.maximumAssignments
      && trial.cohortCutoff == trial.admittedAt
      && trial.assignmentDeadline
        == trial.admittedAt.addingTimeInterval(TrialAdmissionPolicy.assignmentWindow)
      && trial.decisionDeadline
        == trial.admittedAt.addingTimeInterval(TrialAdmissionPolicy.decisionWindow)
      && trial.closeReason == nil
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
      guard createdAssignmentMatches(row, trial: trial, replacement: replacement) else {
        throw ViewCorruption.invalid
      }
    }
    return rows.count
  }

  static func createdAssignmentMatches(
    _ row: Row,
    trial: TrialRow,
    replacement: LessonSetDigest
  ) -> Bool {
    guard
      let runId = SQLiteStoredValue.int64(in: row, column: "run_id"),
      let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
      jobId == trial.jobId,
      let epoch = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      LearningEpoch(epoch) == trial.epoch,
      let generation = SQLiteStoredValue.int(in: row, column: "trial_generation"),
      generation == trial.generation,
      let state = SQLiteStoredValue.string(in: row, column: "state"),
      state == TrialAssignmentState.created.rawValue,
      let outcome = SQLiteStoredValue.nullableString(in: row, column: "outcome"),
      outcome.value == nil,
      let issueCodes = SQLiteStoredValue.nullableString(in: row, column: "issue_codes"),
      issueCodes.value == nil,
      let evaluation = SQLiteStoredValue.nullableString(in: row, column: "evaluation_digest"),
      evaluation.value == nil,
      SQLiteStoredValue.boolean(in: row, column: "evaluation_required") == .trueValue,
      let feedback = SQLiteStoredValue.nullableInt64(
        in: row,
        column: "effective_feedback_revision"
      ),
      feedback.value == nil,
      let resolvedAt = SQLiteStoredValue.nullableInt64(in: row, column: "resolved_at"),
      resolvedAt.value == nil,
      let bindingRun = SQLiteStoredValue.nullableInt64(in: row, column: "binding_run_id"),
      bindingRun.value == runId,
      let bindingJob = SQLiteStoredValue.nullableInt64(in: row, column: "binding_job_id"),
      bindingJob.value == trial.jobId,
      let bindingEpoch = SQLiteStoredValue.nullableInt64(in: row, column: "binding_epoch"),
      bindingEpoch.value == trial.epoch.value,
      let stableDigest = SQLiteStoredValue.nullableString(in: row, column: "stable_digest"),
      stableDigest.value == trial.baseDigest.rawValue,
      let effectiveDigest = SQLiteStoredValue.nullableString(
        in: row,
        column: "effective_digest"
      ),
      effectiveDigest.value == replacement.rawValue,
      let bindingTrial = SQLiteStoredValue.nullableInt64(in: row, column: "trial_id"),
      bindingTrial.value == trial.id,
      let bindingGeneration = SQLiteStoredValue.nullableInt(
        in: row,
        column: "binding_generation"
      ),
      bindingGeneration.value == trial.generation
    else {
      return false
    }
    return true
  }
}

// MARK: - Decision Projection

private extension ScheduledLearningStoreGRDB {
  struct ViewDecisionRecord {
    let decisionId: Int64
    let kind: String
    let inputsJSON: String
    let resultJSON: String
    let algorithm: LearningAlgorithm
    let decidedAt: Date
  }

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
      let decisionId = SQLiteStoredValue.int64(in: row, column: "decision_id"),
      decisionId > 0,
      let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
      jobId == state.jobId,
      let epoch = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      LearningEpoch(epoch) == state.epoch,
      let algorithmRaw = SQLiteStoredValue.string(in: row, column: "algorithm"),
      let kind = SQLiteStoredValue.string(in: row, column: "kind"),
      let inputsJSON = SQLiteStoredValue.string(in: row, column: "inputs"),
      let resultJSON = SQLiteStoredValue.string(in: row, column: "result"),
      let decidedEpoch = SQLiteStoredValue.int64(in: row, column: "decided_at"),
      let decidedAt = EpochSecondCodec.date(fromEpoch: decidedEpoch)
    else {
      throw ViewCorruption.invalid
    }
    let algorithm = LearningAlgorithm(rawValue: algorithmRaw)
    guard algorithm == .v1 else {
      throw ViewCorruption.invalid
    }
    let record = ViewDecisionRecord(
      decisionId: decisionId,
      kind: kind,
      inputsJSON: inputsJSON,
      resultJSON: resultJSON,
      algorithm: algorithm,
      decidedAt: decidedAt
    )
    let detail = try decisionDetail(db, record: record, state: state)
    return LearningDecisionView(
      decisionId: record.decisionId,
      jobId: state.jobId,
      epoch: state.epoch,
      algorithm: record.algorithm,
      decidedAt: record.decidedAt,
      detail: detail
    )
  }

  static func decisionDetail(
    _ db: Database,
    record: ViewDecisionRecord,
    state: JobLearningState
  ) throws -> LearningDecisionDetail {
    switch record.kind {
    case AdmissionReceipt.kind:
      let inputs: AdmissionDecisionInputs = try decodeCanonicalDecision(record.inputsJSON)
      let result: AdmissionReceipt = try decodeCanonicalDecision(record.resultJSON)
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
      let inputs: ReflectionNoCandidateInputs = try decodeCanonicalDecision(record.inputsJSON)
      let result: ReflectionNoCandidateReceipt = try decodeCanonicalDecision(record.resultJSON)
      guard
        isCanonicalDigest(inputs.triggerDigest.rawValue),
        isCanonicalDigest(inputs.carrierDigest.rawValue),
        isCanonicalDigest(result.resultDigest.rawValue),
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
    case ResetReceipt.kind:
      guard
        let receipt = try resetReceipt(
          db,
          record: ResetDecisionRecord(
            decisionId: record.decisionId,
            jobId: state.jobId,
            epoch: state.epoch,
            inputsJSON: record.inputsJSON,
            resultJSON: record.resultJSON,
            algorithm: record.algorithm,
            decidedAt: record.decidedAt
          )
        )
      else {
        throw ViewCorruption.invalid
      }
      return .learningReset(inputs: receipt.inputs, result: receipt.result)
    default:
      throw ViewCorruption.invalid
    }
  }
}
