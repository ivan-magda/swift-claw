import ClawCore
import Foundation
import GRDB

/// The lesson set one fire runs against, and the trial identity it belongs to when a trial
/// supplied it.
private struct EffectiveSelection {
  let digest: LessonSetDigest
  let trialId: Int64?
  let generation: Int?
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
    let selection = try selectEffectiveSet(db, state: state, now: now)
    let binding = RunLearningBinding(
      runId: runId,
      jobId: jobId,
      occurrenceAt: occurrenceAt,
      fireKind: fireKind,
      jobDefinitionDigest: try definitionDigest(db, jobId: jobId),
      epoch: state.epoch,
      stableDigest: state.stableDigest,
      effectiveDigest: selection.digest,
      trialId: selection.trialId,
      trialGeneration: selection.generation
    )
    try insertBinding(db, binding)
    if let trialId = selection.trialId {
      try consumeAssignment(db, binding: binding, trialId: trialId, now: now)
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
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT trial_id, learning_epoch, candidate_digest, generation, max_assignments,
          consumed_assignments, assignment_deadline, state
        FROM learning_trials
        WHERE job_id = ? AND state IN (?, ?)
        ORDER BY trial_id DESC LIMIT 1
        """,
      arguments: [
        jobId, LearningTrialState.open.rawValue, LearningTrialState.draining.rawValue,
      ]
    )
    guard let row else {
      return nil
    }
    guard
      let state = LearningTrialState(rawValue: row["state"]),
      let deadline = EpochSecondCodec.date(fromEpoch: row["assignment_deadline"])
    else {
      throw StoreError.unexpected("job \(jobId) has an unreadable trial row")
    }
    return LearningTrial(
      trialId: row["trial_id"],
      jobId: jobId,
      epoch: LearningEpoch(row["learning_epoch"]),
      generation: row["generation"],
      candidateDigest: CandidateDigest(rawValue: row["candidate_digest"]),
      maxAssignments: row["max_assignments"],
      consumedAssignments: row["consumed_assignments"],
      assignmentDeadline: deadline,
      state: state
    )
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
    now: Date
  ) throws -> EffectiveSelection {
    let stable = EffectiveSelection(digest: state.stableDigest, trialId: nil, generation: nil)
    guard let trial = try liveTrial(db, jobId: state.jobId) else {
      return stable
    }
    guard trial.acceptsAssignment(at: now) else {
      if trial.state == .open {
        try drain(db, trialId: trial.trialId)
      }
      return stable
    }
    guard let replacement = try replacementDigest(db, trial: trial) else {
      throw StoreError.unexpected(
        "trial \(trial.trialId) names candidate \(trial.candidateDigest.rawValue) with no set"
      )
    }
    return EffectiveSelection(
      digest: replacement,
      trialId: trial.trialId,
      generation: trial.generation
    )
  }

  static func replacementDigest(_ db: Database, trial: LearningTrial) throws -> LessonSetDigest? {
    let digest = try String.fetchOne(
      db,
      sql: "SELECT replacement_digest FROM learning_candidates WHERE candidate_digest = ?",
      arguments: [trial.candidateDigest.rawValue]
    )
    return digest.map { raw in
      LessonSetDigest(rawValue: raw)
    }
  }

  static func drain(_ db: Database, trialId: Int64) throws {
    try db.execute(
      sql: "UPDATE learning_trials SET state = ? WHERE trial_id = ? AND state = ?",
      arguments: [
        LearningTrialState.draining.rawValue, trialId, LearningTrialState.open.rawValue,
      ]
    )
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
    trialId: Int64,
    now: Date
  ) throws {
    try db.execute(
      sql: """
        UPDATE learning_trials SET consumed_assignments = consumed_assignments + 1
        WHERE trial_id = ?
        """,
      arguments: [trialId]
    )
    try db.execute(
      sql: """
        INSERT INTO trial_assignments(run_id, trial_id, job_id, learning_epoch, trial_generation,
          assigned_at, state, evaluation_required)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        binding.runId,
        trialId,
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
