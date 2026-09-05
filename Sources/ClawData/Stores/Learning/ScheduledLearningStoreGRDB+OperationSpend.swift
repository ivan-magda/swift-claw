import ClawCore
import Foundation
import GRDB

// MARK: - Authorize And Start

extension ScheduledLearningStoreGRDB {
  /// The whole gap between a claim and the network, in one commit. Every check reads state this
  /// transaction also writes, so a second worker cannot observe the headroom this one is about to
  /// consume: the reservation is visible to it before either call goes out.
  static func authorize(
    _ db: Database,
    _ authorization: LearningAuthorization,
    now: Date
  ) throws -> AuthorizeOutcome {
    guard
      let operation = try readOperation(db, id: authorization.operationId),
      operation.state == .claimed
    else {
      return .superseded
    }
    // A job that re-epoched between the claim and here is asking a different question. Nothing is
    // written: no policy refused this call, so no policy verdict may be recorded against it.
    guard try readState(db, jobId: operation.jobId)?.epoch == operation.epoch else {
      return .superseded
    }
    // The epoch cannot stand in for this: cancelling a job leaves its learning state row exactly
    // as it was, so a cancelled job would otherwise still buy a paid call against its evidence.
    guard try jobPermitsLearningCalls(db, jobId: operation.jobId) else {
      return .superseded
    }
    // A carrier built from another source is a caller plumbing bug, not a policy verdict, and gets
    // the same treatment as the two checks above. Writing `carrier_policy_denied` here would claim
    // privacy refused a call privacy never saw, and `claim` refuses a closed key forever — so one
    // bug would also destroy that evidence's only chance of ever being evaluated.
    guard authorization.carrier.sourceDigest == operation.sourceDigest else {
      return .superseded
    }
    guard try authorizationMatchesPhase(db, authorization, operation: operation) else {
      return .superseded
    }
    guard authorization.carrier.isPermitted else {
      return try closeWithoutCall(db, operation, failure: .carrierPolicyDenied)
    }
    guard try budgetPermits(db, authorization, now: now) else {
      return try closeWithoutCall(db, operation, failure: .budgetDenied)
    }
    return try start(db, operation, authorization)
  }
}

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
    // stamps the call id, so a row missing one is corrupt, and returning "duplicate" would let the
    // caller discard a real result as one already committed.
    guard let callID = operation.providerCallID else {
      throw StoreError.unexpected(
        "started operation \(operation.id.rawValue) has no provider call id to charge"
      )
    }
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
      callID: callID,
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
    return true
  }
}

// MARK: - Phase Gates

private extension ScheduledLearningStoreGRDB {
  static func authorizationMatchesPhase(
    _ db: Database,
    _ authorization: LearningAuthorization,
    operation: OperationRow
  ) throws -> Bool {
    switch (operation.phase, authorization.context) {
    case (.evaluator, .evaluation):
      return true
    case (.reflector, .reflection(let reflection)):
      let sourcesAreCurrent = try reflectionAuthorizationIsCurrent(
        db,
        authorization: reflection
      )
      let expectedKey = LearningOperationKey(
        jobId: operation.jobId,
        epoch: operation.epoch,
        phase: .reflector,
        sourceDigest: reflection.trigger.digest.rawValue,
        promptVersion: ReflectorPrompt.v1.version,
        schemaVersion: ReflectorOutput.currentSchemaVersion,
        rubricVersion: ReflectorRubric.v1
      )
      return operation.keyDigest == expectedKey.digest
        && operation.sourceDigest == reflection.trigger.digest.rawValue
        && reflection.trigger.jobId == operation.jobId
        && reflection.trigger.epoch == operation.epoch
        && reflection.trigger.algorithm == .v1
        && sourcesAreCurrent
    case (.evaluator, .reflection), (.reflector, .evaluation):
      return false
    }
  }

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
}

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

private extension ScheduledLearningStoreGRDB {
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

// MARK: - Boot Reconciliation

extension ScheduledLearningStoreGRDB {
  /// The daemon owns its database alone, so every row still `started` or `claimed` at boot belongs
  /// to a process that is gone.
  static func reconcile(_ db: Database, now: Date) throws -> OperationReconciliation {
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
    return OperationReconciliation(
      interrupted: interrupted.count,
      returnedToClaimable: db.changesCount
    )
  }
}

// MARK: - Authorization Steps

private extension ScheduledLearningStoreGRDB {
  /// Stored spend plus every open reservation. The second term is the whole point: without it two
  /// workers read the same empty headroom and both dispatch a paid call.
  static func budgetPermits(
    _ db: Database,
    _ authorization: LearningAuthorization,
    now: Date
  ) throws -> Bool {
    let global = try UsageStoreGRDB.dayTotals(db, now: now)
    let proactive = try UsageStoreGRDB.dayTotals(
      db,
      origins: RunOrigin.proactiveOrigins,
      now: now
    )
    let reserved = try openReservations(db)
    let decision = authorization.budget.preflight(
      todayTokens: global.tokens + reserved.tokens,
      todayUSD: global.costUSD + reserved.costUSD,
      estimatedTotalTokens: authorization.estimatedTokens,
      estimatedCostUSD: authorization.estimatedCostUSD,
      // Learning spend charges the pool of the scheduled job that caused it, so the proactive
      // branch of the gate is the one that must be consulted.
      origin: .scheduled,
      proactiveTodayUSD: proactive.costUSD + reserved.costUSD
    )
    return decision == .allow
  }

  /// Every reservation, not only today's: one survives no longer than the process that opened it,
  /// because boot closes each of them.
  static func openReservations(_ db: Database) throws -> (tokens: Int, costUSD: Double) {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT COALESCE(SUM(reserved_tokens), 0) AS tokens,
               COALESCE(SUM(reserved_cost_usd), 0) AS cost
        FROM learning_operations WHERE reservation_state = ?
        """,
      arguments: [LearningReservationState.open.rawValue]
    )
    guard let row else {
      return (0, 0)
    }
    return (row["tokens"], row["cost"])
  }

  static func start(
    _ db: Database,
    _ operation: OperationRow,
    _ authorization: LearningAuthorization
  ) throws -> AuthorizeOutcome {
    try db.execute(
      sql: """
        UPDATE learning_operations
        SET state = ?, carrier_digest = ?, route = ?, provider_call_id = ?,
          reserved_tokens = ?, reserved_cost_usd = ?, reservation_state = ?
        WHERE operation_id = ? AND state = ?
        """,
      arguments: [
        LearningOperationState.started.rawValue,
        authorization.carrier.digest.rawValue,
        authorization.configuredRoute,
        authorization.providerCallID.rawValue,
        authorization.estimatedTokens,
        authorization.estimatedCostUSD,
        LearningReservationState.open.rawValue,
        operation.id.rawValue,
        LearningOperationState.claimed.rawValue,
      ]
    )
    return db.changesCount > 0 ? .started : .superseded
  }

  /// A denial is terminal and never requeued: the same inputs would earn the same refusal, and a
  /// requeue would spend the breaker's remaining headroom on retrying a decision, not on work.
  static func closeWithoutCall(
    _ db: Database,
    _ operation: OperationRow,
    failure: LearningOperationFailure
  ) throws -> AuthorizeOutcome {
    try db.execute(
      sql: """
        UPDATE learning_operations
        SET state = ?, failure_code = ?, reserved_tokens = 0, reserved_cost_usd = 0,
          reservation_state = ?
        WHERE operation_id = ? AND state = ?
        """,
      arguments: [
        LearningOperationState.failedNoCall.rawValue,
        failure.rawValue,
        LearningReservationState.closed.rawValue,
        operation.id.rawValue,
        LearningOperationState.claimed.rawValue,
      ]
    )
    return db.changesCount > 0 ? .deniedNoCall(failure) : .superseded
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
    guard let callID = operation.providerCallID, let route = operation.route else {
      throw StoreError.unexpected(
        "started operation \(id.rawValue) has no provider call id or route to charge"
      )
    }
    // Before the state change, so a failure to charge aborts the whole reconciliation rather than
    // leaving a closed reservation whose spend was never recorded.
    try chargeLearningUsage(
      db,
      operation: operation,
      callID: callID,
      model: route,
      promptTokens: operation.reservedTokens,
      completionTokens: 0,
      costUSD: operation.reservedCostUSD,
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
