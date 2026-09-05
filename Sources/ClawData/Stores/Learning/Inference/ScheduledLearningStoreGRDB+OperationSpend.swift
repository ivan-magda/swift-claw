import ClawCore
import Foundation
import GRDB

// MARK: - Result Commit

extension ScheduledLearningStoreGRDB {
  /// - Returns: whether this call is the one that committed the result. A duplicate writes nothing,
  ///   so it can neither insert a second usage row nor close the reservation twice.
  static func finish(_ db: Database, _ result: LearningOperationResult, now: Date) throws -> Bool {
    guard
      let operation = try readOperation(db, id: result.operationId),
      operation.state == .started
    else {
      return false
    }
    // Deliberately throwing, not another `false`: `started` is written by the same statement that
    // stamps the call reservation, so a row missing any required part is corrupt. Returning
    // "duplicate" would let the caller discard a real result as one already committed.
    let reservation = try startedOperationReservation(operation)
    guard product(result.product, belongsTo: operation.phase) else {
      throw StoreError.unexpected(
        "operation \(operation.id.rawValue) received a product for another phase"
      )
    }
    let failure = result.product.failure
    let terminal: LearningOperationState = failure == nil ? .succeeded : .failed
    guard try closeStarted(db, operation, terminal: terminal, failure: failure) else {
      return false
    }
    // The reserved call id, never a fresh one: the estimate never became a row, so this is the
    // only row that will ever carry this call's spend.
    try chargeLearningUsage(
      db,
      operation: operation,
      callID: reservation.providerCallID,
      model: result.usage.model,
      promptTokens: result.usage.promptTokens,
      completionTokens: result.usage.completionTokens,
      costUSD: result.usage.costUSD,
      costSource: result.usage.costSource,
      isEstimated: result.usage.isEstimated,
      now: now
    )
    guard try readState(db, jobId: operation.jobId)?.epoch == operation.epoch else {
      return true
    }
    switch result.product {
    case .failure:
      break
    case .evaluation(let evaluation):
      try recordEvaluation(db, operation: operation, evaluation: evaluation, now: now)
    case .candidate(let artifact):
      if try candidateIsCurrent(db, artifact: artifact, operation: operation) {
        try recordCandidateArtifact(db, artifact: artifact, now: now)
      }
    case .noCandidate(let noCandidate):
      if try noCandidateIsCurrent(db, result: noCandidate, operation: operation) {
        try recordNoCandidate(
          db,
          result: noCandidate,
          jobId: operation.jobId,
          epoch: operation.epoch,
          now: now
        )
      }
    }
    if operation.phase == .evaluator {
      try recomputeEvaluatorSource(
        db,
        jobId: operation.jobId,
        epoch: operation.epoch,
        evidenceDigest: operation.sourceDigest,
        now: now
      )
    }
    return true
  }
}

// MARK: - Result Validation

private extension ScheduledLearningStoreGRDB {
  static func product(
    _ product: LearningOperationProduct,
    belongsTo phase: LearningPhase
  ) -> Bool {
    switch (phase, product) {
    case (.evaluator, .evaluation), (.reflector, .candidate), (.reflector, .noCandidate),
      (_, .failure):
      return true
    case (.evaluator, .candidate), (.evaluator, .noCandidate), (.reflector, .evaluation):
      return false
    }
  }

  static func noCandidateIsCurrent(
    _ db: Database,
    result: NoCandidateResult,
    operation: OperationRow
  ) throws -> Bool {
    guard
      result.algorithm == .v1,
      result.triggerDigest.rawValue == operation.sourceDigest,
      result.operationId == operation.id,
      result.carrierDigest == operation.carrierDigest,
      result.authorization.trigger.digest == result.triggerDigest
    else {
      return false
    }
    // A no-candidate carries no durable source bytes. Its authorization is revalidated before the
    // call, and finish still fences the state whose identity is stored on the operation itself.
    guard
      try reflectionAuthorizationIsCurrent(db, authorization: result.authorization)
    else {
      return false
    }
    return true
  }
}

// MARK: - Candidate Sources

extension ScheduledLearningStoreGRDB {
  static func candidateIsCurrent(
    _ db: Database,
    artifact: CandidateArtifact,
    operation: OperationRow
  ) throws -> Bool {
    guard let trigger = reflectionTrigger(artifact: artifact, operation: operation) else {
      return false
    }
    guard
      let current = try prepareReflection(db, trigger: trigger)
    else {
      return false
    }
    let manifest = artifact.manifest
    return manifest.baseRevision == current.stableRevision
      && manifest.evidence == current.evidenceSources
      && manifest.evaluations == current.evaluationSources
      && manifest.feedback == current.feedbackSources
  }

  static func reflectionTrigger(
    artifact: CandidateArtifact,
    operation: OperationRow
  ) -> TriggerIdentity? {
    let manifest = artifact.manifest
    guard
      manifest.schemaVersion == CandidateSourceManifest.currentSchemaVersion,
      manifest.origin == .reflection,
      manifest.algorithm == .v1,
      manifest.jobId == operation.jobId,
      artifact.replacement.jobId == operation.jobId,
      manifest.epoch == operation.epoch,
      manifest.triggerDigest.rawValue == operation.sourceDigest,
      manifest.operationId == operation.id,
      manifest.carrierDigest == operation.carrierDigest,
      manifest.predecessorCandidate == nil,
      manifest.predecessorFeedback == nil
    else {
      return nil
    }
    let trigger = TriggerIdentity(
      jobId: manifest.jobId,
      epoch: manifest.epoch,
      algorithm: manifest.algorithm,
      stableDigest: manifest.baseDigest,
      evidenceDigests: manifest.evidence.map(\.digest),
      feedbackRevision: manifest.feedbackRevision,
      issueCodes: manifest.qualifyingIssueCodes,
      reason: manifest.triggerReason
    )
    return trigger.digest == manifest.triggerDigest ? trigger : nil
  }
}

// MARK: - Boot Reconciliation

extension ScheduledLearningStoreGRDB {
  /// The daemon owns its database alone, so every row still `started` or `claimed` at boot belongs
  /// to a process that is gone.
  static func reconcile(_ db: Database, now: Date) throws -> OperationReconciliation {
    let affectedEvaluatorRuns = try bootAffectedEvaluatorRuns(db)
    let interrupted = try operationIDs(db, state: .started)
    for id in interrupted {
      try chargeInterrupted(db, id: id, now: now)
    }
    try db.execute(
      sql: "UPDATE learning_operations SET state = ? WHERE state = ?",
      arguments: [
        LearningOperationState.pending.rawValue,
        LearningOperationState.claimed.rawValue,
      ]
    )
    let returnedToClaimable = db.changesCount
    for runId in affectedEvaluatorRuns {
      _ = try recomputeAndReconcile(db, runId: runId, now: now)
    }
    return OperationReconciliation(
      interrupted: interrupted.count,
      returnedToClaimable: returnedToClaimable
    )
  }
}

// MARK: - Trial Projection Hook

private extension ScheduledLearningStoreGRDB {
  static func bootAffectedEvaluatorRuns(_ db: Database) throws -> [Int64] {
    try Int64.fetchAll(
      db,
      sql: """
        SELECT DISTINCT evidence.run_id
        FROM learning_operations AS operation
        JOIN learning_evidence AS evidence
          ON evidence.job_id = operation.job_id
          AND evidence.learning_epoch = operation.learning_epoch
          AND evidence.evidence_digest = operation.source_digest
        JOIN trial_assignments AS assignment ON assignment.run_id = evidence.run_id
        JOIN job_learning_state AS learning ON learning.job_id = assignment.job_id
          AND learning.learning_epoch = assignment.learning_epoch
        WHERE operation.phase = ? AND operation.state IN (?, ?)
        ORDER BY evidence.run_id
        """,
      arguments: [
        LearningPhase.evaluator.rawValue,
        LearningOperationState.started.rawValue,
        LearningOperationState.claimed.rawValue,
      ]
    )
  }
}

// MARK: - Reservation Close

private extension ScheduledLearningStoreGRDB {
  /// The one predicate that makes closing idempotent. A duplicate result finds the row already out
  /// of `started` and changes nothing, so the reservation is emptied exactly once.
  static func closeStarted(
    _ db: Database,
    _ operation: OperationRow,
    terminal: LearningOperationState,
    failure: LearningOperationFailure?
  ) throws -> Bool {
    try db.execute(
      sql: """
        UPDATE learning_operations
        SET state = ?, failure_code = ?, reserved_tokens = 0, reserved_cost_usd = 0,
          reservation_state = ?
        WHERE operation_id = ? AND state = ?
        """,
      arguments: [
        terminal.rawValue,
        failure?.rawValue,
        LearningReservationState.closed.rawValue,
        operation.id.rawValue,
        LearningOperationState.started.rawValue,
      ]
    )
    return db.changesCount > 0
  }

  /// A `started` row at boot means the call may have been billed and its answer is unrecoverable.
  /// The estimate becomes a real charge under the id the call was sent with, so the same id can
  /// never be reused and the day's totals do not under-report what the provider may have billed.
  static func chargeInterrupted(_ db: Database, id: LearningOperationID, now: Date) throws {
    guard let operation = try readOperation(db, id: id) else {
      return
    }
    let reservation = try startedOperationReservation(operation)
    // Before the state change, so a failure to charge aborts the whole reconciliation rather than
    // leaving a closed reservation whose spend was never recorded.
    try chargeLearningUsage(
      db,
      operation: operation,
      callID: reservation.providerCallID,
      model: reservation.route,
      promptTokens: reservation.reservedTokens,
      completionTokens: 0,
      costUSD: reservation.reservedCostUSD,
      costSource: .heuristic,
      isEstimated: true,
      now: now
    )
    try db.execute(
      sql: """
        UPDATE learning_operations
        SET state = ?, reserved_tokens = 0, reserved_cost_usd = 0, reservation_state = ?
        WHERE operation_id = ? AND state = ?
        """,
      arguments: [
        LearningOperationState.interruptedUnknown.rawValue,
        LearningReservationState.closed.rawValue,
        id.rawValue,
        LearningOperationState.started.rawValue,
      ]
    )
  }
}

// MARK: - Learning Usage Rows

private extension ScheduledLearningStoreGRDB {
  /// One learning call's spend, scoped to its operation and job rather than to a run it has none
  /// of. `provider_usage.session_id` is NOT NULL, so the row rides the job's own session lane.
  static func chargeLearningUsage(  // swiftlint:disable:this function_parameter_count
    _ db: Database,
    operation: OperationRow,
    callID: ProviderCallID,
    model: String,
    promptTokens: Int,
    completionTokens: Int,
    costUSD: Double,
    costSource: CostSource,
    isEstimated: Bool,
    now: Date
  ) throws {
    let usage = ProviderUsage(
      providerCallID: callID,
      runId: nil,
      sessionId: try jobSessionID(db, jobId: operation.jobId),
      model: model,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      costUSD: costUSD,
      costSource: costSource,
      isEstimated: isEstimated,
      ts: now,
      learningScope: LearningUsageScope(operationId: operation.id, jobId: operation.jobId)
    )
    _ = try RunStoreGRDB.insertUsage(db, usage)
  }

  static func jobSessionID(_ db: Database, jobId: Int64) throws -> Int64 {
    let sessionId = try Int64.fetchOne(
      db,
      sql: "SELECT session_id FROM scheduled_jobs WHERE id = ?",
      arguments: [jobId]
    )
    guard let sessionId else {
      throw StoreError.unexpected("job \(jobId) has no session to charge learning spend against")
    }
    return sessionId
  }

  static func operationIDs(
    _ db: Database,
    state: LearningOperationState
  ) throws -> [LearningOperationID] {
    try String.fetchAll(
      db,
      sql: "SELECT operation_id FROM learning_operations WHERE state = ? ORDER BY operation_id",
      arguments: [state.rawValue]
    )
    .map(LearningOperationID.init(rawValue:))
  }
}
