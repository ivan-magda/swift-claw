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
      let outcome = try closeWithoutCall(db, operation, failure: .carrierPolicyDenied)
      try recomputeEvaluatorOperation(db, operation: operation, outcome: outcome, now: now)
      return outcome
    }
    guard try budgetPermits(db, authorization, now: now) else {
      let outcome = try closeWithoutCall(db, operation, failure: .budgetDenied)
      try recomputeEvaluatorOperation(db, operation: operation, outcome: outcome, now: now)
      return outcome
    }
    let outcome = try start(db, operation, authorization)
    try recomputeEvaluatorOperation(db, operation: operation, outcome: outcome, now: now)
    return outcome
  }
}

// MARK: - Phase Gate

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
}

// MARK: - Trial Projection Hook

private extension ScheduledLearningStoreGRDB {
  static func recomputeEvaluatorOperation(
    _ db: Database,
    operation: OperationRow,
    outcome: AuthorizeOutcome,
    now: Date
  ) throws {
    guard operation.phase == .evaluator, outcome != .superseded else {
      return
    }
    try recomputeEvaluatorSource(
      db,
      jobId: operation.jobId,
      epoch: operation.epoch,
      evidenceDigest: operation.sourceDigest,
      now: now
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
