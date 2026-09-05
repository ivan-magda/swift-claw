import ClawCore
import Foundation
import GRDB

// MARK: - Assignment Cache

extension ScheduledLearningStoreGRDB {
  struct CachedAssignment {
    let identity: TrialAssignmentIdentity
    let assignedAt: Date
    let state: TrialAssignmentState
    let outcome: TrialOutcomeKind?
    let issueCodes: [String]?
    let evaluationDigest: EvaluationDigest?
    let evaluationRequired: Bool
    let feedbackRevision: FeedbackRevision?
    let resolvedAt: Date?
  }

  static func recomputeAssignment(
    _ db: Database,
    runId: Int64,
    now: Date
  ) throws -> AssignmentRecomputation {
    guard let cached = try cachedAssignment(db, runId: runId) else {
      return .notAssigned
    }
    guard let trialRow = try trialRow(db, trialId: cached.identity.trial.trialId) else {
      throw StoreError.unexpected("assignment \(runId) names a missing trial")
    }
    var trial = try strictTrial(db, row: trialRow, currentState: nil)
    try validateAssignmentIdentity(db, cached: cached, trial: trial)
    guard let current = try readState(db, jobId: trial.jobId) else {
      throw StoreError.unexpected("assignment \(runId) belongs to a job without learning state")
    }
    if trial.epoch < current.epoch {
      return .stale
    }
    guard trial.epoch == current.epoch else {
      throw StoreError.unexpected("assignment \(runId) is ahead of the job learning epoch")
    }
    if trial.state == .open || trial.state == .draining {
      trial = try strictTrial(db, row: trialRow, currentState: current)
    }

    let projected = try projectAssignment(
      db,
      cached: cached,
      trial: trial,
      currentState: current
    )
    if cached.state == .learningOutcomeResolved, projected.resolvedEvidence == nil {
      throw StoreError.unexpected("resolved assignment cache has no authoritative resolution event")
    }
    if cacheMatches(cached, projected: projected) {
      return .unchanged(withResolvedAt(projected, cached.resolvedAt))
    }
    let updated = withResolvedAt(
      projected,
      projected.resolvedEvidence == nil ? nil : now
    )
    try persistAssignment(db, cached: cached, assignment: updated)
    return .updated(updated)
  }

  static func assignmentRunIds(_ db: Database, trialId: Int64) throws -> [Int64] {
    try Int64.fetchAll(
      db,
      sql: "SELECT run_id FROM trial_assignments WHERE trial_id = ? ORDER BY run_id",
      arguments: [trialId]
    )
  }

  static func authoritativeAssignment(
    _ db: Database,
    runId: Int64,
    trial: LearningTrial,
    currentState: JobLearningState
  ) throws -> TrialAssignment {
    guard let cached = try cachedAssignment(db, runId: runId) else {
      throw StoreError.unexpected("trial cohort names a missing assignment")
    }
    try validateAssignmentIdentity(db, cached: cached, trial: trial)
    guard
      trial.epoch == currentState.epoch,
      trial.jobId == currentState.jobId
    else {
      throw StoreError.unexpected("live assignment projection crossed a learning epoch")
    }
    let projected = try projectAssignment(
      db,
      cached: cached,
      trial: trial,
      currentState: currentState
    )
    if cached.state == .learningOutcomeResolved, projected.resolvedEvidence == nil {
      throw StoreError.unexpected("resolved assignment cache has no authoritative resolution event")
    }
    return projected
  }

  private static func cachedAssignment(_ db: Database, runId: Int64) throws -> CachedAssignment? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT run_id, trial_id, job_id, learning_epoch, trial_generation, assigned_at, state,
            outcome, issue_codes, evaluation_digest, evaluation_required,
            effective_feedback_revision, resolved_at
          FROM trial_assignments WHERE run_id = ?
          """,
        arguments: [runId]
      )
    else {
      return nil
    }
    guard
      let storedRunId = SQLiteStoredValue.int64(in: row, column: "run_id"),
      storedRunId == runId,
      let trialId = SQLiteStoredValue.int64(in: row, column: "trial_id"),
      trialId > 0,
      let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
      jobId > 0,
      let epochRaw = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      epochRaw > 0,
      let generation = SQLiteStoredValue.int(in: row, column: "trial_generation"),
      generation > 0,
      let assignedRaw = SQLiteStoredValue.int64(in: row, column: "assigned_at"),
      let assignedAt = EpochSecondCodec.date(fromEpoch: assignedRaw),
      let stateRaw = SQLiteStoredValue.string(in: row, column: "state"),
      let state = TrialAssignmentState(rawValue: stateRaw),
      let outcomeRaw = SQLiteStoredValue.nullableString(in: row, column: "outcome"),
      let issueJSON = SQLiteStoredValue.nullableString(in: row, column: "issue_codes"),
      let evaluationRaw = SQLiteStoredValue.nullableString(
        in: row,
        column: "evaluation_digest"
      ),
      let evaluationRequiredRaw = SQLiteStoredValue.boolean(
        in: row,
        column: "evaluation_required"
      ),
      let feedbackRaw = SQLiteStoredValue.nullableInt64(
        in: row,
        column: "effective_feedback_revision"
      ),
      let resolvedRaw = SQLiteStoredValue.nullableInt64(in: row, column: "resolved_at")
    else {
      throw StoreError.unexpected("assignment \(runId) has unreadable stored values")
    }
    let outcome = outcomeRaw.value.flatMap(TrialOutcomeKind.init(rawValue:))
    guard outcomeRaw.value == nil || outcome != nil else {
      throw StoreError.unexpected("assignment \(runId) has an unknown outcome")
    }
    let issueCodes = try issueJSON.value.map(decodeCanonicalIssueCodes)
    let feedback = feedbackRaw.value.map(FeedbackRevision.init)
    let resolvedAt = resolvedRaw.value.flatMap(EpochSecondCodec.date(fromEpoch:))
    let evaluationRequired = evaluationRequiredRaw == .trueValue
    let isResolved = state == .learningOutcomeResolved
    if isResolved {
      guard
        let outcome,
        let issueCodes,
        let feedback,
        feedback.value >= 0,
        resolvedAt != nil,
        issueCodesMatchOutcome(issueCodes, outcome: outcome)
      else {
        throw StoreError.unexpected("assignment \(runId) has an invalid resolved cache shape")
      }
    } else {
      guard
        outcome == nil,
        issueCodes == nil,
        evaluationRaw.value == nil,
        evaluationRequired,
        feedback == nil,
        resolvedAt == nil
      else {
        throw StoreError.unexpected("assignment \(runId) has an invalid unresolved cache shape")
      }
    }
    return CachedAssignment(
      identity: TrialAssignmentIdentity(
        trial: LearningTrialIdentity(
          trialId: trialId,
          jobId: jobId,
          epoch: LearningEpoch(epochRaw),
          generation: generation
        ),
        runId: runId
      ),
      assignedAt: assignedAt,
      state: state,
      outcome: outcome,
      issueCodes: issueCodes,
      evaluationDigest: evaluationRaw.value.map(EvaluationDigest.init(rawValue:)),
      evaluationRequired: evaluationRequired,
      feedbackRevision: feedback,
      resolvedAt: resolvedAt
    )
  }

  private static func validateAssignmentIdentity(
    _ db: Database,
    cached: CachedAssignment,
    trial: LearningTrial
  ) throws {
    let identity = cached.identity
    guard
      identity.trial == trial.identity,
      let binding = try readBinding(db, runId: identity.runId),
      binding.runId == identity.runId,
      binding.jobId == trial.jobId,
      binding.epoch == trial.epoch,
      binding.trialId == trial.trialId,
      binding.trialGeneration == trial.generation,
      binding.stableDigest == trial.baseDigest,
      binding.effectiveDigest == trial.replacementDigest
    else {
      throw StoreError.unexpected(
        "assignment \(identity.runId) has inconsistent five-part identity"
      )
    }
  }

  private static func cacheMatches(
    _ cached: CachedAssignment,
    projected: TrialAssignment
  ) -> Bool {
    guard
      cached.identity == projected.identity,
      cached.assignedAt == projected.assignedAt,
      cached.state == projected.state
    else {
      return false
    }
    guard let evidence = projected.resolvedEvidence else {
      return cached.outcome == nil
        && cached.issueCodes == nil
        && cached.evaluationDigest == nil
        && cached.evaluationRequired
        && cached.feedbackRevision == nil
        && cached.resolvedAt == nil
    }
    return cached.outcome == evidence.outcome
      && cached.issueCodes == evidence.issueCodes
      && cached.evaluationDigest == evidence.evaluationDigest
      && cached.evaluationRequired == evidence.evaluationRequired
      && cached.feedbackRevision == evidence.effectiveFeedbackRevision
      && cached.resolvedAt != nil
  }

  private static func persistAssignment(
    _ db: Database,
    cached: CachedAssignment,
    assignment: TrialAssignment
  ) throws {
    let evidence = assignment.resolvedEvidence
    let issueJSON = try evidence.map { value in
      try issueCodesJSON(value.issueCodes)
    }
    try db.execute(
      sql: """
        UPDATE trial_assignments
        SET state = ?, outcome = ?, issue_codes = ?, evaluation_digest = ?,
          evaluation_required = ?, effective_feedback_revision = ?, resolved_at = ?
        WHERE run_id = ? AND trial_id = ? AND job_id = ? AND learning_epoch = ?
          AND trial_generation = ?
        """,
      arguments: [
        assignment.state.rawValue,
        evidence?.outcome.rawValue,
        issueJSON,
        evidence?.evaluationDigest?.rawValue,
        evidence?.evaluationRequired ?? true,
        evidence?.effectiveFeedbackRevision.value,
        assignment.resolvedAt.map(EpochSecondCodec.epoch),
        cached.identity.runId,
        cached.identity.trial.trialId,
        cached.identity.trial.jobId,
        cached.identity.trial.epoch.value,
        cached.identity.trial.generation,
      ]
    )
    guard db.changesCount == 1 else {
      throw StoreError.unexpected("assignment cache update lost its exact identity")
    }
  }

  private static func withResolvedAt(
    _ assignment: TrialAssignment,
    _ resolvedAt: Date?
  ) -> TrialAssignment {
    TrialAssignment(
      identity: assignment.identity,
      assignedAt: assignment.assignedAt,
      state: assignment.state,
      resolvedEvidence: assignment.resolvedEvidence,
      resolvedAt: resolvedAt
    )
  }

  private static func issueCodesMatchOutcome(
    _ issueCodes: [String],
    outcome: TrialOutcomeKind
  ) -> Bool {
    switch outcome {
    case .positive, .neutral:
      return issueCodes.isEmpty
    case .negative:
      return true
    }
  }
}

// MARK: - Authoritative Projection

extension ScheduledLearningStoreGRDB {
  private static func projectAssignment(
    _ db: Database,
    cached: CachedAssignment,
    trial: LearningTrial,
    currentState: JobLearningState
  ) throws -> TrialAssignment {
    let runId = cached.identity.runId
    if let cachedRevision = cached.feedbackRevision,
      cachedRevision > currentState.feedbackRevision
    {
      throw StoreError.unexpected("assignment \(runId) names a future feedback revision")
    }
    guard let settlement = try readSettlement(db, runId: runId), settlement.settledAt != nil else {
      return unresolvedAssignment(cached, state: .created)
    }
    guard let evidence = try strictEvidence(db, runId: runId, trial: trial) else {
      return unresolvedAssignment(cached, state: .primaryRunSettled)
    }
    guard evidence.eligibility.reachesEvaluator else {
      return resolvedAssignment(
        cached,
        effective: ResolvedOutcome(
          outcome: .neutral,
          ownerConfirmed: false,
          evaluationRequired: false,
          hardVetoes: []
        ),
        evaluationDigest: nil,
        feedback: [],
        currentState: currentState
      )
    }

    let source = try strictEvaluatorSource(
      db,
      runId: runId,
      trial: trial,
      evidence: evidence
    )
    guard let attempt = source.attempt else {
      return unresolvedAssignment(cached, state: .primaryRunSettled)
    }
    switch attempt.operation.state {
    case .pending, .claimed, .started, .interruptedUnknown:
      return unresolvedAssignment(cached, state: .learningOutcomeUnresolved)
    case .failed, .failedNoCall:
      let feedback = try assignmentFeedback(
        db,
        jobId: trial.jobId,
        epoch: trial.epoch,
        runIds: [runId],
        evaluationRuns: [:],
        currentRevision: currentState.feedbackRevision
      )
      let resolved = OwnerPrecedence.resolve(
        evaluator: nil,
        issueCodes: [],
        signals: feedback.map(\.event)
      )
      return resolvedAssignment(
        cached,
        effective: ResolvedOutcome(
          outcome: resolved.outcome,
          ownerConfirmed: resolved.ownerConfirmed,
          evaluationRequired: false,
          hardVetoes: resolved.hardVetoes
        ),
        evaluationDigest: nil,
        feedback: feedback,
        currentState: currentState
      )
    case .succeeded:
      guard let evaluation = source.evaluation else {
        throw StoreError.unexpected("succeeded evaluator has no exact evaluation")
      }
      let feedback = try assignmentFeedback(
        db,
        jobId: trial.jobId,
        epoch: trial.epoch,
        runIds: [runId],
        evaluationRuns: [evaluation.digest.rawValue: runId],
        currentRevision: currentState.feedbackRevision
      )
      let resolved = OwnerPrecedence.resolve(
        evaluator: evaluation.evaluation.outcome,
        issueCodes: evaluation.evaluation.issueCodes,
        signals: feedback.map(\.event)
      )
      return resolvedAssignment(
        cached,
        effective: resolved,
        evaluationDigest: evaluation.digest,
        feedback: feedback,
        currentState: currentState
      )
    }
  }

  private static func unresolvedAssignment(
    _ cached: CachedAssignment,
    state: TrialAssignmentState
  ) -> TrialAssignment {
    TrialAssignment(
      identity: cached.identity,
      assignedAt: cached.assignedAt,
      state: state,
      resolvedEvidence: nil,
      resolvedAt: nil
    )
  }

  private static func resolvedAssignment(
    _ cached: CachedAssignment,
    effective: ResolvedOutcome,
    evaluationDigest: EvaluationDigest?,
    feedback: [StoredFeedbackProjection],
    currentState: JobLearningState
  ) -> TrialAssignment {
    let effectiveEvents = FeedbackEvent.unsuperseded(feedback.map(\.event))
    let correction = FeedbackEvent.latestUnsupersededResult(in: effectiveEvents)
    let correctionDigest: FeedbackEventDigest?
    if correction?.signal == .resultCorrection {
      correctionDigest =
        feedback.first { stored in
          stored.event.id == correction?.id
        }?.source.digest
    } else {
      correctionDigest = nil
    }
    let latestRelevant = feedback.map(\.event.revision).max()
    let revision =
      cached.feedbackRevision.map { stored in
        max(stored, latestRelevant ?? stored)
      } ?? currentState.feedbackRevision
    return TrialAssignment(
      identity: cached.identity,
      assignedAt: cached.assignedAt,
      state: .learningOutcomeResolved,
      resolvedEvidence: ResolvedRunEvidence(
        effective: effective,
        evaluationDigest: evaluationDigest,
        correctionEventDigest: correctionDigest,
        effectiveFeedbackRevision: revision
      ),
      resolvedAt: cached.resolvedAt
    )
  }

  private static func assignmentFeedback(
    _ db: Database,
    jobId: Int64,
    epoch: LearningEpoch,
    runIds: Set<Int64>,
    evaluationRuns: [String: Int64],
    currentRevision: FeedbackRevision
  ) throws -> [StoredFeedbackProjection] {
    let feedback = try storedFeedback(
      db,
      jobId: jobId,
      epoch: epoch,
      runIds: runIds,
      evaluationRuns: evaluationRuns
    )
    guard
      feedback.allSatisfy({ stored in
        stored.event.revision <= currentRevision
      })
    else {
      throw StoreError.unexpected("assignment source names a future feedback revision")
    }
    return feedback
  }
}
