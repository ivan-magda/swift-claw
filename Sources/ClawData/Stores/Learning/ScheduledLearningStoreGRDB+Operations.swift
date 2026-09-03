import ClawCore
import Foundation
import GRDB

// MARK: - Operation Lifecycle

extension ScheduledLearningStoreGRDB {
  public func claimOperation(
    _ key: LearningOperationKey,
    now: Date
  ) throws(StoreError) -> ClaimedOperation? {
    try database.writeMapping { db in
      try Self.claim(db, key: key, now: now)
    }
  }

  public func authorizeAndStartOperation(
    _ authorization: LearningAuthorization,
    now: Date
  ) throws(StoreError) -> AuthorizeOutcome {
    try database.writeMapping { db in
      try Self.authorize(db, authorization, now: now)
    }
  }

  public func finishOperation(
    _ result: LearningOperationResult,
    now: Date
  ) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try Self.finish(db, result, now: now)
    }
  }

  @discardableResult
  public func reconcileOperationsAtBoot(
    now: Date
  ) throws(StoreError) -> OperationReconciliation {
    try database.writeMapping { db in
      try Self.reconcile(db, now: now)
    }
  }
}

// MARK: - Claim

private extension ScheduledLearningStoreGRDB {
  /// Refuses far more often than it claims, and every refusal is the same nil: a claim is only
  /// worth taking when the job is still in the epoch the key names, the source is still work the
  /// evaluator may do, and no other attempt at this key is live or already finished.
  static func claim(
    _ db: Database,
    key: LearningOperationKey,
    now: Date
  ) throws -> ClaimedOperation? {
    guard try readState(db, jobId: key.jobId)?.epoch == key.epoch else {
      return nil
    }
    guard try sourceIsClaimable(db, key: key) else {
      return nil
    }
    guard let latest = try latestAttempt(db, key: key.digest) else {
      return try insertClaim(db, key: key, generation: 1, supersedes: nil, now: now)
    }

    switch latest.state {
    case .pending:
      // A claim the last process took but never authorized. No call was ever made under this row,
      // so the attempt is resumed where it stopped rather than replaced by a new generation.
      return try reclaim(db, latest, key: key)
    case .interruptedUnknown:
      return try insertClaim(
        db,
        key: key,
        generation: latest.attemptGeneration + 1,
        supersedes: latest.id,
        now: now
      )
    case .claimed, .started, .succeeded, .failed, .failedNoCall:
      return nil
    }
  }

  /// What the key's source has to be for the question to still be worth asking.
  static func sourceIsClaimable(_ db: Database, key: LearningOperationKey) throws -> Bool {
    switch key.phase {
    case .evaluator:
      guard try evidenceReachesEvaluator(db, key: key) else {
        return false
      }
      return try Bool.fetchOne(
        db,
        sql: """
          SELECT NOT EXISTS(
            SELECT 1 FROM learning_evaluations WHERE job_id = ? AND evidence_digest = ?
          )
          """,
        arguments: [key.jobId, key.sourceDigest]
      ) ?? false
    case .reflector:
      // The reflector's source is a frozen trigger identity, not a run receipt. What makes a
      // trigger admissible — the window, the qualifying issue codes, no open trial — is decided
      // where the trigger is frozen; there is nothing about it to re-derive from a digest here.
      return true
    }
  }

  /// Only a sealed receipt classified as task evidence may be evaluated, and only under the job and
  /// epoch it was sealed for: a digest alone would let one job's evidence be claimed under another.
  static func evidenceReachesEvaluator(_ db: Database, key: LearningOperationKey) throws -> Bool {
    let raw = try String.fetchOne(
      db,
      sql: """
        SELECT eligibility FROM learning_evidence
        WHERE job_id = ? AND learning_epoch = ? AND evidence_digest = ?
        """,
      arguments: [key.jobId, key.epoch.value, key.sourceDigest]
    )
    guard let eligibility = raw.flatMap(LearningEligibility.init(rawValue:)) else {
      return false
    }
    return eligibility.reachesEvaluator
  }

  static func insertClaim(
    _ db: Database,
    key: LearningOperationKey,
    generation: Int,
    supersedes: LearningOperationID?,
    now: Date
  ) throws -> ClaimedOperation {
    let id = LearningOperationID(key: key.digest, attemptGeneration: generation)
    try db.execute(
      sql: """
        INSERT INTO learning_operations(operation_id, job_id, learning_epoch, phase, source_digest,
          attempt_generation, supersedes, state, key_digest, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        id.rawValue,
        key.jobId,
        key.epoch.value,
        key.phase.rawValue,
        key.sourceDigest,
        generation,
        supersedes?.rawValue,
        LearningOperationState.claimed.rawValue,
        key.digest.rawValue,
        EpochSecondCodec.epoch(now),
      ]
    )
    return ClaimedOperation(
      id: id,
      key: key,
      attemptGeneration: generation,
      supersedes: supersedes
    )
  }

  static func reclaim(
    _ db: Database,
    _ attempt: AttemptRow,
    key: LearningOperationKey
  ) throws -> ClaimedOperation? {
    try db.execute(
      sql: "UPDATE learning_operations SET state = ? WHERE operation_id = ? AND state = ?",
      arguments: [
        LearningOperationState.claimed.rawValue,
        attempt.id.rawValue,
        LearningOperationState.pending.rawValue,
      ]
    )
    guard db.changesCount > 0 else {
      return nil
    }
    return ClaimedOperation(
      id: attempt.id,
      key: key,
      attemptGeneration: attempt.attemptGeneration,
      supersedes: attempt.supersedes
    )
  }
}

// MARK: - Operation Rows

extension ScheduledLearningStoreGRDB {
  /// The newest attempt at one key, whatever became of it. Generations are dense and ascending, so
  /// the newest row is the only one whose state can still permit or refuse a claim.
  static func latestAttempt(_ db: Database, key: LearningOperationKeyDigest) throws -> AttemptRow? {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT operation_id, attempt_generation, state, supersedes
        FROM learning_operations WHERE key_digest = ?
        ORDER BY attempt_generation DESC LIMIT 1
        """,
      arguments: [key.rawValue]
    )
    guard let row else {
      return nil
    }
    let id = LearningOperationID(rawValue: row["operation_id"])
    return AttemptRow(
      id: id,
      attemptGeneration: row["attempt_generation"],
      state: try operationState(row["state"], of: id),
      supersedes: (row["supersedes"] as String?).map(LearningOperationID.init(rawValue:))
    )
  }

  static func readOperation(_ db: Database, id: LearningOperationID) throws -> OperationRow? {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT job_id, learning_epoch, source_digest, state, route, provider_call_id,
          reserved_tokens, reserved_cost_usd
        FROM learning_operations WHERE operation_id = ?
        """,
      arguments: [id.rawValue]
    )
    guard let row else {
      return nil
    }
    return OperationRow(
      id: id,
      jobId: row["job_id"],
      epoch: LearningEpoch(row["learning_epoch"]),
      sourceDigest: row["source_digest"],
      state: try operationState(row["state"], of: id),
      route: row["route"],
      providerCallID: (row["provider_call_id"] as String?).map(ProviderCallID.init(rawValue:)),
      reservedTokens: row["reserved_tokens"] ?? 0,
      reservedCostUSD: row["reserved_cost_usd"] ?? 0
    )
  }

  static func operationState(
    _ raw: String,
    of id: LearningOperationID
  ) throws -> LearningOperationState {
    guard let state = LearningOperationState(rawValue: raw) else {
      throw StoreError.unexpected("operation \(id.rawValue) holds an unreadable state '\(raw)'")
    }
    return state
  }

  struct AttemptRow {
    let id: LearningOperationID
    let attemptGeneration: Int
    let state: LearningOperationState
    let supersedes: LearningOperationID?
  }

  struct OperationRow {
    let id: LearningOperationID
    let jobId: Int64
    let epoch: LearningEpoch
    let sourceDigest: String
    let state: LearningOperationState
    let route: String?
    let providerCallID: ProviderCallID?
    let reservedTokens: Int
    let reservedCostUSD: Double
  }
}
