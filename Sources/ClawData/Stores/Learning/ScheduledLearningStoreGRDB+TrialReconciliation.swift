import ClawCore
import Foundation
import GRDB

// MARK: - Public Trial Resolution

extension ScheduledLearningStoreGRDB {
  public func recomputeAssignment(
    runId: Int64,
    now: Date
  ) throws(StoreError) -> AssignmentRecomputation {
    try database.writeMapping { db in
      try Self.recomputeAssignment(db, runId: runId, now: now)
    }
  }

  public func liveTrialIdentities() throws(StoreError) -> [LearningTrialIdentity] {
    try database.readMapping { db in
      try Self.readLiveTrialIdentities(db)
    }
  }

  public func reconcileTrial(
    _ identity: LearningTrialIdentity,
    now: Date
  ) throws(StoreError) -> TrialReconciliationResult {
    try database.writeMapping { db in
      try Self.reconcileTrial(db, identity: identity, now: now)
    }
  }
}

// MARK: - Reconciliation

extension ScheduledLearningStoreGRDB {
  @discardableResult
  static func recomputeAndReconcile(
    _ db: Database,
    runId: Int64,
    now: Date
  ) throws -> TrialReconciliationResult? {
    let recomputation = try recomputeAssignment(db, runId: runId, now: now)
    let identity: LearningTrialIdentity
    switch recomputation {
    case .notAssigned, .stale:
      return nil
    case .unchanged(let assignment), .updated(let assignment):
      identity = assignment.identity.trial
    }
    return try reconcileTrial(db, identity: identity, now: now)
  }

  static func reconcileTrial(
    _ db: Database,
    identity: LearningTrialIdentity,
    now: Date
  ) throws -> TrialReconciliationResult {
    guard let row = try trialRow(db, trialId: identity.trialId) else {
      return .stale
    }
    let trial = try strictTrial(db, row: row, currentState: nil)
    guard trial.state == .open || trial.state == .draining else {
      return .stale
    }
    guard trial.identity == identity else {
      throw StoreError.unexpected("live trial identity changed during reconciliation")
    }
    guard try readState(db, jobId: trial.jobId)?.epoch == trial.epoch else {
      return .stale
    }

    let runIds = try assignmentRunIds(db, trialId: trial.trialId)
    guard
      runIds.count == trial.consumedAssignments,
      Set(runIds).count == runIds.count
    else {
      throw StoreError.unexpected("trial assignment count does not match its exposure counter")
    }
    var assignments: [TrialAssignment] = []
    for runId in runIds {
      switch try recomputeAssignment(db, runId: runId, now: now) {
      case .unchanged(let assignment), .updated(let assignment):
        guard assignment.identity.trial == identity else {
          throw StoreError.unexpected("trial cohort contains a foreign assignment")
        }
        assignments.append(assignment)
      case .notAssigned, .stale:
        throw StoreError.unexpected("live trial cohort lost an assignment during reconciliation")
      }
    }
    let decision = TrialPolicy.decide(trial: trial, assignments: assignments, now: now)
    let shouldDrain = trial.state == .open && decision != .wait
    if shouldDrain {
      try drain(db, trial: trial)
    }
    return .reconciled(
      TrialReconciliation(
        identity: identity,
        didDrain: shouldDrain,
        assignments: assignments,
        decision: decision
      )
    )
  }

  static func readLiveTrialIdentities(_ db: Database) throws -> [LearningTrialIdentity] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT trial_id, job_id, learning_epoch, base_digest, candidate_digest, generation,
          admitted_at, assignment_deadline, decision_deadline, max_assignments,
          consumed_assignments, cohort_cutoff, state, close_reason, algorithm
        FROM learning_trials WHERE state IN (?, ?)
        ORDER BY job_id, trial_id
        """,
      arguments: [LearningTrialState.open.rawValue, LearningTrialState.draining.rawValue]
    )
    var seenJobs: Set<Int64> = []
    return try rows.map { row in
      guard
        let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
        jobId > 0,
        seenJobs.insert(jobId).inserted,
        let currentState = try readState(db, jobId: jobId)
      else {
        throw StoreError.unexpected("live trial identity set is unreadable or duplicated")
      }
      return try strictTrial(db, row: row, currentState: currentState).identity
    }
  }

  static func recomputeEvaluatorSource(
    _ db: Database,
    jobId: Int64,
    epoch: LearningEpoch,
    evidenceDigest: String,
    now: Date
  ) throws {
    let runIds = try Int64.fetchAll(
      db,
      sql: """
        SELECT run_id FROM learning_evidence
        WHERE job_id = ? AND learning_epoch = ? AND evidence_digest = ?
        ORDER BY run_id
        """,
      arguments: [jobId, epoch.value, evidenceDigest]
    )
    guard runIds.count <= 1 else {
      throw StoreError.unexpected("evaluator source resolves to multiple evidence receipts")
    }
    if let runId = runIds.first {
      _ = try recomputeAndReconcile(db, runId: runId, now: now)
    }
  }

  static func recomputeFeedbackSubject(
    _ db: Database,
    jobId: Int64,
    epoch: LearningEpoch,
    subjectKind: FeedbackSubjectKind,
    subjectDigest: String,
    now: Date
  ) throws {
    let runId: Int64?
    switch subjectKind {
    case .run:
      guard let parsed = Int64(subjectDigest), String(parsed) == subjectDigest else {
        return
      }
      let isAssigned =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS(
              SELECT 1 FROM trial_assignments
              WHERE run_id = ? AND job_id = ? AND learning_epoch = ?
            )
            """,
          arguments: [parsed, jobId, epoch.value]
        ) ?? false
      runId = isAssigned ? parsed : nil
    case .evaluation:
      let rows = try Int64.fetchAll(
        db,
        sql: """
          SELECT evaluation.run_id
          FROM learning_evaluations AS evaluation
          JOIN trial_assignments AS assignment ON assignment.run_id = evaluation.run_id
            AND assignment.job_id = evaluation.job_id
            AND assignment.learning_epoch = evaluation.learning_epoch
          WHERE evaluation.job_id = ? AND evaluation.learning_epoch = ?
            AND evaluation.evaluation_digest = ?
          ORDER BY evaluation.run_id
          """,
        arguments: [jobId, epoch.value, subjectDigest]
      )
      guard rows.count <= 1 else {
        throw StoreError.unexpected("evaluation feedback resolves to multiple runs")
      }
      runId = rows.first
    case .candidate, .promotion:
      runId = nil
    }
    if let runId {
      _ = try recomputeAndReconcile(db, runId: runId, now: now)
    }
  }
}
