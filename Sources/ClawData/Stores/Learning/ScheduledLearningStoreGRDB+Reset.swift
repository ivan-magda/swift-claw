import ClawCore
import Foundation
import GRDB

// MARK: - Confirmed Reset

extension ScheduledLearningStoreGRDB {
  public func applyReset(
    updateId: Int64,
    jobId: Int64,
    now: Date
  ) throws(StoreError) -> ConfirmedLearningResetResult {
    try database.writeMapping { db in
      guard
        try ProcessedUpdateStoreGRDB.claimUpdate(
          db: db,
          updateId: updateId,
          claimedAt: now
        )
      else {
        return .duplicate
      }
      guard let job = try Self.resetJob(db, jobId: jobId) else {
        return .claimed(.notFound)
      }
      guard let state = try Self.readState(db, jobId: jobId) else {
        return .claimed(.unarmed)
      }
      if let receipt = try Self.cleanResetReceipt(db, state: state) {
        return .claimed(.alreadyReset(receipt))
      }
      let receipt = try Self.applyReset(db, job: job, state: state, now: now)
      return .claimed(.applied(receipt))
    }
  }
}

// MARK: - Reset Transaction

private extension ScheduledLearningStoreGRDB {
  struct ResetJob {
    let jobId: Int64
    let sessionId: Int64?
  }

  struct ResetOperationPlan {
    let staleNoCall: [LearningOperationID]
    let inFlight: [LearningOperationID]
  }

  struct ResetAuditProjection: Encodable {
    let decisionId: Int64
    let kind: String
    let jobId: Int64
    let algorithm: LearningAlgorithm
    let decidedAt: Int64
    let inputs: LearningResetDecisionInputs
    let result: LearningResetDecisionResult

    enum CodingKeys: String, CodingKey {
      case decisionId = "decision_id"
      case kind
      case jobId = "job_id"
      case algorithm
      case decidedAt = "decided_at"
      case inputs
      case result
    }
  }

  static func resetJob(_ db: Database, jobId: Int64) throws -> ResetJob? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT id, session_id FROM scheduled_jobs WHERE id = ?",
        arguments: [jobId]
      )
    else {
      return nil
    }
    guard
      SQLiteStoredValue.int64(in: row, column: "id") == jobId,
      let sessionId = SQLiteStoredValue.nullableInt64(in: row, column: "session_id")
    else {
      throw StoreError.unexpected("scheduled job is unreadable for learning reset")
    }
    return ResetJob(jobId: jobId, sessionId: sessionId.value)
  }

  static func applyReset(
    _ db: Database,
    job: ResetJob,
    state: JobLearningState,
    now: Date
  ) throws -> ResetReceipt {
    try validateResetState(state, job: job)
    let empty = LessonSet.empty(jobId: job.jobId)
    try ensureCanonicalEmptySet(db, empty, now: now)
    guard let decidedAt = EpochSecondCodec.date(fromEpoch: EpochSecondCodec.epoch(now)) else {
      throw StoreError.unexpected("learning reset time is out of range")
    }

    let inputs = LearningResetDecisionInputs(
      oldEpoch: state.epoch,
      oldStableDigest: state.stableDigest,
      oldStableRevision: state.stableRevision,
      feedbackRevisionAtCut: state.feedbackRevision,
      priorOpenTrialId: state.openTrialId
    )
    let newEpoch = state.epoch.next()
    let newRevision = state.stableRevision.next()
    try advanceResetState(
      db,
      state: state,
      newEpoch: newEpoch,
      newRevision: newRevision,
      emptyDigest: empty.digest
    )
    let trials = try resetLiveTrials(db, jobId: job.jobId)
    let targetCount = try invalidateTargets(db, jobId: job.jobId, now: now)
    let challengeCount = try invalidateChallenges(db, jobId: job.jobId, now: now)
    let operations = try resetOperations(db, jobId: job.jobId, before: newEpoch)
    let result = LearningResetDecisionResult(
      newEpoch: newEpoch,
      emptyStableDigest: empty.digest,
      newStableRevision: newRevision,
      closedTrials: trials,
      invalidatedTargetCount: targetCount,
      invalidatedChallengeCount: challengeCount,
      staleNoCallOperationIds: operations.staleNoCall,
      inFlightOperationIds: operations.inFlight
    )
    let decisionId = try insertDecision(
      db,
      kind: ResetReceipt.kind,
      jobId: job.jobId,
      epoch: newEpoch,
      inputs: inputs,
      result: result,
      algorithm: .v1,
      now: decidedAt
    )
    let receipt = ResetReceipt(
      decisionId: decisionId,
      jobId: job.jobId,
      algorithm: .v1,
      decidedAt: decidedAt,
      inputs: inputs,
      result: result
    )
    try insertResetAudit(db, receipt: receipt, sessionId: job.sessionId)
    return receipt
  }

  static func validateResetState(_ state: JobLearningState, job: ResetJob) throws {
    guard
      state.jobId == job.jobId,
      state.epoch.value > 0,
      state.epoch.value < Int64.max,
      resetDigestIsCanonical(state.stableDigest.rawValue),
      state.stableRevision.value >= 0,
      state.stableRevision.value < Int64.max,
      state.feedbackRevision.value >= 0,
      state.openTrialId.map({ $0 > 0 }) ?? true
    else {
      throw StoreError.unexpected("learning state cannot advance through reset")
    }
  }

  static func advanceResetState(
    _ db: Database,
    state: JobLearningState,
    newEpoch: LearningEpoch,
    newRevision: StableRevision,
    emptyDigest: LessonSetDigest
  ) throws {
    try db.execute(
      sql: """
        UPDATE job_learning_state
        SET learning_epoch = ?, stable_lesson_set_digest = ?, stable_revision = ?,
          open_trial_id = NULL
        WHERE job_id = ? AND learning_epoch = ? AND stable_revision = ?
        """,
      arguments: [
        newEpoch.value,
        emptyDigest.rawValue,
        newRevision.value,
        state.jobId,
        state.epoch.value,
        state.stableRevision.value,
      ]
    )
    guard db.changesCount == 1 else {
      throw StoreError.unexpected("learning state changed during reset")
    }
  }

  static func resetLiveTrials(_ db: Database, jobId: Int64) throws -> [ResetTrialIdentity] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT trial_id, job_id, learning_epoch, generation, base_digest, candidate_digest,
          algorithm
        FROM learning_trials
        WHERE job_id = ? AND state IN (?, ?)
        ORDER BY trial_id
        """,
      arguments: [
        jobId,
        LearningTrialState.open.rawValue,
        LearningTrialState.draining.rawValue,
      ]
    )
    let trials = try rows.map { row in
      try resetTrialIdentity(row, expectedJobId: jobId)
    }
    try db.execute(
      sql: """
        UPDATE learning_trials SET state = ?, close_reason = ?
        WHERE job_id = ? AND state IN (?, ?)
        """,
      arguments: [
        LearningTrialState.closed.rawValue,
        LearningTrialCloseReason.learningReset.rawValue,
        jobId,
        LearningTrialState.open.rawValue,
        LearningTrialState.draining.rawValue,
      ]
    )
    guard db.changesCount == trials.count else {
      throw StoreError.unexpected("live trials changed during reset")
    }
    return trials
  }

  static func resetTrialIdentity(_ row: Row, expectedJobId: Int64) throws -> ResetTrialIdentity {
    guard
      let trialId = SQLiteStoredValue.int64(in: row, column: "trial_id"),
      trialId > 0,
      let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
      jobId == expectedJobId,
      let epoch = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      epoch > 0,
      let generation = SQLiteStoredValue.int(in: row, column: "generation"),
      generation > 0,
      let baseDigest = SQLiteStoredValue.string(in: row, column: "base_digest"),
      resetDigestIsCanonical(baseDigest),
      let candidateDigest = SQLiteStoredValue.string(in: row, column: "candidate_digest"),
      resetDigestIsCanonical(candidateDigest),
      let algorithmRaw = SQLiteStoredValue.string(in: row, column: "algorithm"),
      LearningAlgorithm(rawValue: algorithmRaw) == .v1
    else {
      throw StoreError.unexpected("live trial is unreadable for learning reset")
    }
    return ResetTrialIdentity(
      trialId: trialId,
      jobId: jobId,
      epoch: LearningEpoch(epoch),
      generation: generation,
      baseDigest: LessonSetDigest(rawValue: baseDigest),
      candidateDigest: CandidateDigest(rawValue: candidateDigest),
      algorithm: .v1
    )
  }

  static func invalidateTargets(_ db: Database, jobId: Int64, now: Date) throws -> Int {
    try db.execute(
      sql: "UPDATE feedback_targets SET consumed_at = ? WHERE job_id = ? AND consumed_at IS NULL",
      arguments: [EpochSecondCodec.epoch(now), jobId]
    )
    return db.changesCount
  }

  static func invalidateChallenges(_ db: Database, jobId: Int64, now: Date) throws -> Int {
    try db.execute(
      sql: """
        UPDATE feedback_challenges SET consumed_at = ?
        WHERE job_id = ? AND superseded_by IS NULL AND consumed_at IS NULL
        """,
      arguments: [EpochSecondCodec.epoch(now), jobId]
    )
    return db.changesCount
  }

  static func resetOperations(
    _ db: Database,
    jobId: Int64,
    before newEpoch: LearningEpoch
  ) throws -> ResetOperationPlan {
    let stale = try resetOperationIDs(
      db,
      jobId: jobId,
      before: newEpoch,
      states: [.pending, .claimed]
    )
    let inFlight = try resetOperationIDs(
      db,
      jobId: jobId,
      before: newEpoch,
      states: [.started]
    )
    try db.execute(
      sql: """
        UPDATE learning_operations
        SET state = ?, failure_code = ?, reserved_tokens = 0, reserved_cost_usd = 0,
          reservation_state = ?
        WHERE job_id = ? AND learning_epoch < ? AND state IN (?, ?)
        """,
      arguments: [
        LearningOperationState.failedNoCall.rawValue,
        LearningOperationFailure.staleEpoch.rawValue,
        LearningReservationState.closed.rawValue,
        jobId,
        newEpoch.value,
        LearningOperationState.pending.rawValue,
        LearningOperationState.claimed.rawValue,
      ]
    )
    guard db.changesCount == stale.count else {
      throw StoreError.unexpected("not-started operations changed during reset")
    }
    return ResetOperationPlan(staleNoCall: stale, inFlight: inFlight)
  }
}

extension ScheduledLearningStoreGRDB {
  static func resetOperationIDs(
    _ db: Database,
    jobId: Int64,
    before newEpoch: LearningEpoch,
    states: [LearningOperationState]
  ) throws -> [LearningOperationID] {
    let stateValues = states.map(\.rawValue)
    let placeholders = Array(repeating: "?", count: stateValues.count).joined(separator: ", ")
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT operation_id, job_id, learning_epoch, state
        FROM learning_operations
        WHERE job_id = ? AND learning_epoch < ? AND state IN (\(placeholders))
        ORDER BY operation_id
        """,
      arguments: [jobId, newEpoch.value] + StatementArguments(stateValues)
    )
    return try rows.map { row in
      guard
        let operationId = SQLiteStoredValue.string(in: row, column: "operation_id"),
        operationId.isEmpty == false,
        SQLiteStoredValue.int64(in: row, column: "job_id") == jobId,
        let epoch = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
        epoch < newEpoch.value,
        let stateRaw = SQLiteStoredValue.string(in: row, column: "state"),
        stateValues.contains(stateRaw)
      else {
        throw StoreError.unexpected("learning operation is unreadable for reset")
      }
      return LearningOperationID(rawValue: operationId)
    }
  }
}

private extension ScheduledLearningStoreGRDB {
  static func insertResetAudit(
    _ db: Database,
    receipt: ResetReceipt,
    sessionId: Int64?
  ) throws {
    let projection = ResetAuditProjection(
      decisionId: receipt.decisionId,
      kind: ResetReceipt.kind,
      jobId: receipt.jobId,
      algorithm: receipt.algorithm,
      decidedAt: EpochSecondCodec.epoch(receipt.decidedAt),
      inputs: receipt.inputs,
      result: receipt.result
    )
    try AuditLogGRDB.insertAudit(
      db,
      AuditEvent(
        actor: .owner,
        action: .learningReset,
        tool: "/learning reset",
        argsRedacted: try canonicalDecisionJSON(projection),
        resultSize: 0,
        decision: "applied",
        sessionId: sessionId,
        ts: receipt.decidedAt
      )
    )
  }
}
