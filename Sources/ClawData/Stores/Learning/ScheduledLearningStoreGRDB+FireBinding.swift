import ClawCore
import Foundation
import GRDB

/// The lesson set one fire runs against, and the trial identity it belongs to when a trial
/// supplied it.
private struct EffectiveSelection {
  let digest: LessonSetDigest
  let trial: LearningTrial?
}

// MARK: - Fire Binding

extension ScheduledLearningStoreGRDB {
  // The six parameters are the fire's frozen facts; bundling five of them into a parameter object
  // would duplicate half of `RunLearningBinding` to satisfy the count alone.
  /// The learning half of the fire transaction, run inside the caller's write after the occurrence
  /// claim and the overlap guard have both passed and the run row exists. The caller gates this on
  /// the learning flag: a disarmed daemon never reaches it and writes no learning row at all.
  ///
  /// Arming, selection, the binding and the assignment ride the caller's transaction together, so
  /// a run can never exist without the lessons it ran against — nor an assignment without a run.
  static func bindFire(  // swiftlint:disable:this function_parameter_count
    _ db: Database,
    jobId: Int64,
    runId: Int64,
    fireKind: ScheduledFireKind,
    occurrenceAt: Date,
    now: Date
  ) throws -> RunLearningBinding {
    let state = try armState(db, jobId: jobId, now: now)
    let selection = try selectEffectiveSet(
      db,
      state: state,
      occurrenceAt: occurrenceAt,
      now: now
    )
    let binding = RunLearningBinding(
      runId: runId,
      jobId: jobId,
      occurrenceAt: occurrenceAt,
      fireKind: fireKind,
      jobDefinitionDigest: try definitionDigest(db, jobId: jobId),
      epoch: state.epoch,
      stableDigest: state.stableDigest,
      effectiveDigest: selection.digest,
      trialId: selection.trial?.trialId,
      trialGeneration: selection.trial?.generation
    )
    try insertBinding(db, binding)
    if let trial = selection.trial {
      try consumeAssignment(db, binding: binding, trial: trial, now: now)
    }
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .system,
        action: .learningBound,
        argsRedacted: auditArgs(binding),
        runId: runId,
        ts: now
      )
    )
    return binding
  }

  static func readBinding(_ db: Database, runId: Int64) throws -> RunLearningBinding? {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT job_id, learning_epoch, occurrence_at, fire_kind, job_definition_digest,
          stable_digest, effective_digest, trial_id, trial_generation
        FROM run_learning_bindings WHERE run_id = ?
        """,
      arguments: [runId]
    )
    guard let row else {
      return nil
    }
    guard
      let fireKind = ScheduledFireKind(rawValue: row["fire_kind"]),
      let occurrenceAt = EpochSecondCodec.date(fromEpoch: row["occurrence_at"])
    else {
      throw StoreError.unexpected("run \(runId) has an unreadable learning binding")
    }
    return RunLearningBinding(
      runId: runId,
      jobId: row["job_id"],
      occurrenceAt: occurrenceAt,
      fireKind: fireKind,
      jobDefinitionDigest: JobDefinitionDigest(rawValue: row["job_definition_digest"]),
      epoch: LearningEpoch(row["learning_epoch"]),
      stableDigest: LessonSetDigest(rawValue: row["stable_digest"]),
      effectiveDigest: LessonSetDigest(rawValue: row["effective_digest"]),
      trialId: row["trial_id"],
      trialGeneration: row["trial_generation"]
    )
  }

  /// The job's trial while it still owns the job's learning position — open or draining. A decided
  /// trial is gone from this read, which is what makes the job admissible for a new candidate.
  static func liveTrial(_ db: Database, jobId: Int64) throws -> LearningTrial? {
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
        jobId, LearningTrialState.open.rawValue, LearningTrialState.draining.rawValue,
      ]
    )
    guard rows.count <= 1 else {
      throw StoreError.unexpected("job \(jobId) has multiple live trials")
    }
    guard let row = rows.first else {
      return nil
    }
    guard let state = try readState(db, jobId: jobId) else {
      throw StoreError.unexpected("job \(jobId) has a live trial without learning state")
    }
    return try decodeLiveTrial(db, row: row, currentState: state)
  }

  static func decodeLiveTrial(
    _ db: Database,
    row: Row,
    currentState: JobLearningState
  ) throws -> LearningTrial {
    let trial = try strictTrial(db, row: row, currentState: currentState)
    guard trial.state == .open || trial.state == .draining else {
      throw StoreError.unexpected("job \(currentState.jobId) has a non-live trial in its live set")
    }
    return trial
  }
}

// MARK: - Effective Set Selection

private extension ScheduledLearningStoreGRDB {
  /// The trial's candidate while the trial still accepts assignments, the stable set otherwise.
  /// Reaching either exposure bound drains the trial in this same read: runs already assigned
  /// still finish and still decide it, but no further fire binds to the candidate.
  static func selectEffectiveSet(
    _ db: Database,
    state: JobLearningState,
    occurrenceAt: Date,
    now: Date
  ) throws -> EffectiveSelection {
    let stable = EffectiveSelection(digest: state.stableDigest, trial: nil)
    guard let trial = try liveTrial(db, jobId: state.jobId) else {
      return stable
    }
    if trial.state == .open,
      trial.consumedAssignments >= trial.maxAssignments || now >= trial.assignmentDeadline
    {
      try drain(db, trial: trial)
      return stable
    }
    guard trial.state == .open else {
      return stable
    }
    guard occurrenceAt >= trial.cohortCutoff else {
      return stable
    }
    guard trial.acceptsAssignment(occurrenceAt: occurrenceAt, now: now) else {
      throw StoreError.unexpected("trial \(trial.trialId) changed during fire selection")
    }
    return EffectiveSelection(digest: trial.replacementDigest, trial: trial)
  }
}

extension ScheduledLearningStoreGRDB {
  static func drain(_ db: Database, trial: LearningTrial) throws {
    try db.execute(
      sql: """
        UPDATE learning_trials SET state = ?
        WHERE trial_id = ? AND job_id = ? AND learning_epoch = ? AND generation = ?
          AND base_digest = ? AND candidate_digest = ? AND algorithm = ? AND state = ?
        """,
      arguments: [
        LearningTrialState.draining.rawValue,
        trial.trialId,
        trial.jobId,
        trial.epoch.value,
        trial.generation,
        trial.baseDigest.rawValue,
        trial.candidateDigest.rawValue,
        trial.algorithm.rawValue,
        LearningTrialState.open.rawValue,
      ]
    )
    guard db.changesCount == 1 else {
      throw StoreError.unexpected("trial \(trial.trialId) could not drain exactly once")
    }
  }
}

// MARK: - Binding Rows

private extension ScheduledLearningStoreGRDB {
  static func insertBinding(_ db: Database, _ binding: RunLearningBinding) throws {
    try db.execute(
      sql: """
        INSERT INTO run_learning_bindings(run_id, job_id, learning_epoch, occurrence_at,
          fire_kind, job_definition_digest, stable_digest, effective_digest, trial_id,
          trial_generation)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        binding.runId,
        binding.jobId,
        binding.epoch.value,
        EpochSecondCodec.epoch(binding.occurrenceAt),
        binding.fireKind.rawValue,
        binding.jobDefinitionDigest.rawValue,
        binding.stableDigest.rawValue,
        binding.effectiveDigest.rawValue,
        binding.trialId,
        binding.trialGeneration,
      ]
    )
  }

  /// Exposure is granted exactly once per created run: the counter the selection reads and the
  /// per-run assignment the decision reads move together, in the run's own transaction.
  static func consumeAssignment(
    _ db: Database,
    binding: RunLearningBinding,
    trial: LearningTrial,
    now: Date
  ) throws {
    let consumed = try Int.fetchOne(
      db,
      sql: """
        UPDATE learning_trials
        SET consumed_assignments = consumed_assignments + 1,
          state = CASE
            WHEN consumed_assignments + 1 = max_assignments THEN ?
            ELSE state
          END
        WHERE trial_id = ? AND job_id = ? AND learning_epoch = ? AND generation = ?
          AND base_digest = ? AND candidate_digest = ? AND algorithm = ? AND state = ?
          AND consumed_assignments < max_assignments
          AND cohort_cutoff <= ? AND assignment_deadline > ?
          AND EXISTS(
            SELECT 1 FROM learning_candidates AS candidate
            WHERE candidate.candidate_digest = learning_trials.candidate_digest
              AND candidate.job_id = learning_trials.job_id
              AND candidate.learning_epoch = learning_trials.learning_epoch
              AND candidate.base_digest = learning_trials.base_digest
              AND candidate.base_revision = ? AND candidate.replacement_digest = ?
              AND candidate.algorithm = learning_trials.algorithm
          )
        RETURNING consumed_assignments
        """,
      arguments: [
        LearningTrialState.draining.rawValue,
        trial.trialId,
        trial.jobId,
        trial.epoch.value,
        trial.generation,
        trial.baseDigest.rawValue,
        trial.candidateDigest.rawValue,
        trial.algorithm.rawValue,
        LearningTrialState.open.rawValue,
        EpochSecondCodec.epoch(binding.occurrenceAt),
        EpochSecondCodec.epoch(now),
        trial.baseRevision.value,
        trial.replacementDigest.rawValue,
      ]
    )
    guard consumed != nil else {
      throw StoreError.unexpected("trial \(trial.trialId) could not consume exact assignment")
    }
    try db.execute(
      sql: """
        INSERT INTO trial_assignments(run_id, trial_id, job_id, learning_epoch, trial_generation,
          assigned_at, state, evaluation_required)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        binding.runId,
        trial.trialId,
        binding.jobId,
        binding.epoch.value,
        binding.trialGeneration,
        EpochSecondCodec.epoch(now),
        TrialAssignmentState.created.rawValue,
        // A trial run's outcome is unknown until its evidence is evaluated; owner precedence can
        // override that verdict later, but it cannot stand in for it.
        true,
      ]
    )
  }

  static func definitionDigest(_ db: Database, jobId: Int64) throws -> JobDefinitionDigest {
    let row = try Row.fetchOne(
      db,
      sql: "SELECT label, prompt, recurrence, timezone FROM scheduled_jobs WHERE id = ?",
      arguments: [jobId]
    )
    guard let row else {
      throw StoreError.unexpected("job \(jobId) has no row to digest")
    }
    return try JobDefinitionDigest.of(
      label: row["label"],
      prompt: row["prompt"],
      recurrenceJSON: row["recurrence"],
      timezone: row["timezone"]
    )
  }

  static func auditArgs(_ binding: RunLearningBinding) -> String {
    let trial = binding.trialId.map(String.init) ?? "null"
    return """
      {"job_id":\(binding.jobId),"effective_digest":"\(binding.effectiveDigest.rawValue)",\
      "trial_id":\(trial)}
      """
  }
}
