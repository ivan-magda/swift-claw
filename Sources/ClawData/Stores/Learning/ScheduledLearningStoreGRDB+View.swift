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
    let trial = try strictTrial(db, row: row, currentState: state)
    guard trial.state == .open || trial.state == .draining else {
      throw ViewCorruption.invalid
    }
    return try projectedTrialView(db, trial: trial, state: state)
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

  static func projectedTrialView(
    _ db: Database,
    trial: LearningTrial,
    state: JobLearningState
  ) throws -> LearningTrialView {
    let runIds = try assignmentRunIds(db, trialId: trial.trialId)
    guard
      runIds.count == trial.consumedAssignments,
      Set(runIds).count == runIds.count
    else {
      throw ViewCorruption.invalid
    }
    var positive = 0
    var negative = 0
    var neutral = 0
    var unresolved = 0
    for runId in runIds {
      let assignment = try authoritativeAssignment(
        db,
        runId: runId,
        trial: trial,
        currentState: state
      )
      switch assignment.resolvedEvidence?.outcome {
      case .positive:
        positive += 1
      case .negative:
        negative += 1
      case .neutral:
        neutral += 1
      case nil:
        unresolved += 1
      }
    }
    guard positive + negative + neutral + unresolved == trial.consumedAssignments else {
      throw ViewCorruption.invalid
    }
    let counts = LearningTrialCounts(
      consumed: trial.consumedAssignments,
      maximum: trial.maxAssignments,
      positive: positive,
      negative: negative,
      neutral: neutral,
      unresolved: unresolved
    )
    return LearningTrialView(
      trialId: trial.trialId,
      epoch: trial.epoch,
      generation: trial.generation,
      state: trial.state,
      candidateDigest: trial.candidateDigest,
      baseDigest: trial.baseDigest,
      baseRevision: trial.baseRevision,
      replacementDigest: trial.replacementDigest,
      counts: counts,
      assignmentDeadline: trial.assignmentDeadline,
      decisionDeadline: trial.decisionDeadline
    )
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
