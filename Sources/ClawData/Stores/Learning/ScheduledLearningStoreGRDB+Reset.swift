import ClawCore
import Foundation
import GRDB

// MARK: - Confirmed Reset

extension ScheduledLearningStoreGRDB {
  public func applyReset(updateID: Int64, jobID: Int64, now: Date) throws(StoreError)
    -> ConfirmedLearningResetResult
  {
    try database.writeMapping { db in
      guard try ProcessedUpdateStoreGRDB.claimUpdate(db: db, updateID: updateID, claimedAt: now)
      else {
        return .duplicate
      }
      guard let job = try Self.resetJob(db, jobID: jobID) else {
        return .claimed(.notFound)
      }
      guard let state = try Self.readState(db, jobID: jobID) else {
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
    let jobID: Int64
    let sessionID: Int64?
  }

  struct ResetOperationPlan {
    let staleNoCall: [LearningOperationID]
    let inFlight: [LearningOperationID]
  }

  struct ResetAuditProjection: Encodable {
    let decisionID: Int64
    let kind: String
    let jobID: Int64
    let algorithm: LearningAlgorithm
    let decidedAt: Int64
    let inputs: LearningResetDecisionInputs
    let result: LearningResetDecisionResult

    enum CodingKeys: String, CodingKey {
      case decisionID = "decision_id"
      case kind
      case jobID = "job_id"
      case algorithm
      case decidedAt = "decided_at"
      case inputs
      case result
    }
  }

  static func resetJob(_ db: Database, jobID: Int64) throws -> ResetJob? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT id, session_id FROM scheduled_jobs WHERE id = ?",
        arguments: [jobID]
      )
    else {
      return nil
    }
    guard
      SQLiteStoredValue.int64(in: row, column: "id") == jobID,
      let sessionID = SQLiteStoredValue.nullableInt64(in: row, column: "session_id")
    else {
      throw StoreError.unexpected("scheduled job is unreadable for learning reset")
    }
    return ResetJob(jobID: jobID, sessionID: sessionID.value)
  }

  static func applyReset(_ db: Database, job: ResetJob, state: JobLearningState, now: Date) throws
    -> ResetReceipt
  {
    try validateResetState(state, job: job)
    let empty = LessonSet.empty(jobID: job.jobID)
    try ensureCanonicalEmptySet(db, empty, now: now)
    guard let decidedAt = EpochSecondCodec.date(fromEpoch: EpochSecondCodec.epoch(now)) else {
      throw StoreError.unexpected("learning reset time is out of range")
    }

    let inputs = LearningResetDecisionInputs(
      oldEpoch: state.epoch,
      oldStableDigest: state.stableDigest,
      oldStableRevision: state.stableRevision,
      feedbackRevisionAtCut: state.feedbackRevision,
      priorOpenTrialID: state.openTrialID
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
    let trials = try resetLiveTrials(db, jobID: job.jobID)
    let targetCount = try invalidateTargets(db, jobID: job.jobID, now: now)
    let challengeCount = try invalidateChallenges(db, jobID: job.jobID, now: now)
    let operations = try resetOperations(db, jobID: job.jobID, before: newEpoch)
    let result = LearningResetDecisionResult(
      newEpoch: newEpoch,
      emptyStableDigest: empty.digest,
      newStableRevision: newRevision,
      closedTrials: trials,
      invalidatedTargetCount: targetCount,
      invalidatedChallengeCount: challengeCount,
      staleNoCallOperationIDs: operations.staleNoCall,
      inFlightOperationIDs: operations.inFlight
    )
    let decisionID = try insertDecision(
      db,
      kind: ResetReceipt.kind,
      jobID: job.jobID,
      epoch: newEpoch,
      inputs: inputs,
      result: result,
      algorithm: .v1,
      now: decidedAt
    )
    let receipt = ResetReceipt(
      decisionID: decisionID,
      jobID: job.jobID,
      algorithm: .v1,
      decidedAt: decidedAt,
      inputs: inputs,
      result: result
    )
    try insertResetAudit(db, receipt: receipt, sessionID: job.sessionID)
    return receipt
  }

  static func validateResetState(_ state: JobLearningState, job: ResetJob) throws {
    guard
      state.jobID == job.jobID,
      state.epoch.value > 0,
      state.epoch.value < Int64.max,
      isCanonicalDigest(state.stableDigest.rawValue),
      state.stableRevision.value >= 0,
      state.stableRevision.value < Int64.max,
      state.feedbackRevision.value >= 0,
      state.openTrialID.map({
        $0 > 0
      }) ?? true
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
        state.jobID,
        state.epoch.value,
        state.stableRevision.value,
      ]
    )
    guard db.changesCount == 1 else {
      throw StoreError.unexpected("learning state changed during reset")
    }
  }

  static func resetLiveTrials(_ db: Database, jobID: Int64) throws -> [ResetTrialIdentity] {
    let rows = try Row.fetchAll(
      db,
      sql: """
      SELECT trial_id, job_id, learning_epoch, generation, base_digest, candidate_digest,
        algorithm
      FROM learning_trials
      WHERE job_id = ? AND state IN (?, ?)
      ORDER BY trial_id
      """,
      arguments: [jobID, LearningTrialState.open.rawValue, LearningTrialState.draining.rawValue]
    )
    let trials = try rows.map { row in
      try resetTrialIdentity(row, expectedJobID: jobID)
    }
    try db.execute(
      sql: """
      UPDATE learning_trials SET state = ?, close_reason = ?
      WHERE job_id = ? AND state IN (?, ?)
      """,
      arguments: [
        LearningTrialState.closed.rawValue,
        LearningTrialCloseReason.learningReset.rawValue,
        jobID,
        LearningTrialState.open.rawValue,
        LearningTrialState.draining.rawValue,
      ]
    )
    guard db.changesCount == trials.count else {
      throw StoreError.unexpected("live trials changed during reset")
    }
    return trials
  }

  static func resetTrialIdentity(_ row: Row, expectedJobID: Int64) throws -> ResetTrialIdentity {
    guard
      let trialID = SQLiteStoredValue.int64(in: row, column: "trial_id"),
      trialID > 0,
      let jobID = SQLiteStoredValue.int64(in: row, column: "job_id"),
      jobID == expectedJobID,
      let epoch = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      epoch > 0,
      let generation = SQLiteStoredValue.int(in: row, column: "generation"),
      generation > 0,
      let baseDigest = SQLiteStoredValue.string(in: row, column: "base_digest"),
      isCanonicalDigest(baseDigest),
      let candidateDigest = SQLiteStoredValue.string(in: row, column: "candidate_digest"),
      isCanonicalDigest(candidateDigest),
      let algorithmRaw = SQLiteStoredValue.string(in: row, column: "algorithm"),
      LearningAlgorithm(rawValue: algorithmRaw) == .v1
    else {
      throw StoreError.unexpected("live trial is unreadable for learning reset")
    }
    return ResetTrialIdentity(
      trialID: trialID,
      jobID: jobID,
      epoch: LearningEpoch(epoch),
      generation: generation,
      baseDigest: LessonSetDigest(rawValue: baseDigest),
      candidateDigest: CandidateDigest(rawValue: candidateDigest),
      algorithm: .v1
    )
  }

  static func invalidateTargets(_ db: Database, jobID: Int64, now: Date) throws -> Int {
    try db.execute(
      sql: "UPDATE feedback_targets SET consumed_at = ? WHERE job_id = ? AND consumed_at IS NULL",
      arguments: [EpochSecondCodec.epoch(now), jobID]
    )
    return db.changesCount
  }

  static func invalidateChallenges(_ db: Database, jobID: Int64, now: Date) throws -> Int {
    try db.execute(
      sql: """
      UPDATE feedback_challenges SET consumed_at = ?
      WHERE job_id = ? AND superseded_by IS NULL AND consumed_at IS NULL
      """,
      arguments: [EpochSecondCodec.epoch(now), jobID]
    )
    return db.changesCount
  }

  static func resetOperations(_ db: Database, jobID: Int64, before newEpoch: LearningEpoch) throws
    -> ResetOperationPlan
  {
    let stale = try resetOperationIDs(
      db,
      jobID: jobID,
      before: newEpoch,
      states: [.pending, .claimed]
    )
    let inFlight = try resetOperationIDs(db, jobID: jobID, before: newEpoch, states: [.started])
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
        jobID,
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
    jobID: Int64,
    before newEpoch: LearningEpoch,
    states: [LearningOperationState]
  ) throws -> [LearningOperationID] {
    let stateValues = states.map(\.rawValue)
    let placeholders = Array(repeating: "?", count: stateValues.count).joined(separator: ", ")
    let rows = try Row.fetchAll(
      db,
      sql: """
      SELECT operation_id
      FROM learning_operations
      WHERE job_id = ? AND learning_epoch < ? AND state IN (\(placeholders))
      ORDER BY operation_id
      """,
      arguments: [jobID, newEpoch.value] + StatementArguments(stateValues)
    )
    return try rows.map { row in
      guard
        let operationID = SQLiteStoredValue.string(in: row, column: "operation_id"),
        operationID.isEmpty == false
      else {
        throw StoreError.unexpected("learning operation is unreadable for reset")
      }
      let id = LearningOperationID(rawValue: operationID)
      guard
        let operation = try readOperation(db, id: id),
        operation.jobID == jobID,
        operation.epoch.value < newEpoch.value,
        stateValues.contains(operation.state.rawValue)
      else {
        throw StoreError.unexpected("learning operation is unreadable for reset")
      }
      if operation.state == .started {
        _ = try startedOperationReservation(operation)
      }
      return id
    }
  }
}

// MARK: - Reset Audit Persistence

private extension ScheduledLearningStoreGRDB {
  static func insertResetAudit(_ db: Database, receipt: ResetReceipt, sessionID: Int64?) throws {
    let projection = ResetAuditProjection(
      decisionID: receipt.decisionID,
      kind: ResetReceipt.kind,
      jobID: receipt.jobID,
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
        sessionID: sessionID,
        ts: receipt.decidedAt
      )
    )
  }
}
