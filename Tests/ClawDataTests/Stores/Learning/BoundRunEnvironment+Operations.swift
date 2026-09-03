import ClawCore
import Foundation
import GRDB

@testable import ClawData

/// The operation-lifecycle suite's shapes: sealed evidence to claim against, the authorization a
/// worker presents just before the network, and the raw `learning_operations` columns the store
/// writes — read back as columns, so a state or reservation the store never wrote is visible
/// rather than papered over by a typed accessor.
extension BoundRunEnvironment {
  /// The evaluator's own versions are the caller's policy — the store only folds them into the key
  /// digest — so the fixture pins one triple and varies it nowhere.
  static let evaluatorPromptVersion = 1
  static let evaluatorSchemaVersion = 1
  static let evaluatorRubricVersion = 1
  /// Enough headroom that a test not about the breaker never trips it.
  static let unboundedProactiveCapUSD = 1_000.0
  /// Deliberately not the route `authorization` configures: a commit that stamped the configured
  /// route in place of the served one would be indistinguishable otherwise.
  static let evaluatorServedRoute = "openai-compatible/fallback-model"

  struct ReservationRow: Equatable {
    let state: String?
    let tokens: Int?
    let costUSD: Double?
  }

  /// What every terminal transition leaves behind: a reservation that holds nothing and can never
  /// be closed a second time.
  static let closedReservation = ReservationRow(
    state: LearningReservationState.closed.rawValue,
    tokens: 0,
    costUSD: 0
  )

  struct LearningUsageRow: Equatable {
    let providerCallID: String
    let jobId: Int64?
    let runId: Int64?
    let costUSD: Double
    let tokens: Int
  }

  var usage: UsageStoreGRDB {
    UsageStoreGRDB(writer: queue)
  }

  /// One completed bound run, sealed as evidence the evaluator is allowed to read.
  func sealedEvidence() throws -> SealedEvidence {
    let runId = try settledBoundRun()
    _ = try learning.sealEvidence(runId: runId, now: now)
    return try sealed(runId: runId)
  }

  /// A bound run that ended in provider failure: sealed, but classified as infrastructure noise
  /// rather than task evidence.
  func ineligibleSealedEvidence() throws -> SealedEvidence {
    let runId = try runningBoundRun()
    try freezeSurface(runId: runId, skillSetDigest: Self.pickupSkillSetDigest)
    _ = try runs.commitDegradedTurn(
      degradedTurn(runId: runId, cause: .providerFailure),
      now: now
    )
    _ = try learning.sealEvidence(runId: runId, now: now)
    return try sealed(runId: runId)
  }

  func evaluatorKey(for evidence: SealedEvidence) -> LearningOperationKey {
    LearningOperationKey(
      jobId: evidence.jobId,
      epoch: evidence.epoch,
      phase: .evaluator,
      sourceDigest: evidence.digest.rawValue,
      promptVersion: Self.evaluatorPromptVersion,
      schemaVersion: Self.evaluatorSchemaVersion,
      rubricVersion: Self.evaluatorRubricVersion
    )
  }

  func evaluatorKey() throws -> LearningOperationKey {
    evaluatorKey(for: try sealedEvidence())
  }

  func claim(_ key: LearningOperationKey) throws -> ClaimedOperation {
    guard let claim = try learning.claimOperation(key, now: now) else {
      throw StoreError.unexpected("key \(key.digest.rawValue) refused to claim")
    }
    return claim
  }

  func authorization(
    for claim: ClaimedOperation,
    carrier: CarrierAuthorization? = nil,
    estimatedCostUSD: Double = 0.01,
    proactiveCapUSD: Double = BoundRunEnvironment.unboundedProactiveCapUSD,
    providerCallID: ProviderCallID = UUIDProviderCallIDGenerator().next()
  ) -> LearningAuthorization {
    LearningAuthorization(
      operationId: claim.id,
      carrier: carrier ?? permittedCarrier(for: claim),
      estimatedTokens: 1_000,
      estimatedCostUSD: estimatedCostUSD,
      configuredRoute: "openai-compatible/test-model",
      providerCallID: providerCallID,
      budget: gate(proactiveCapUSD: proactiveCapUSD)
    )
  }

  func permittedCarrier(for claim: ClaimedOperation) -> CarrierAuthorization {
    CarrierAuthorization(
      sourceDigest: claim.key.sourceDigest,
      digest: CarrierDigest(rawValue: "carrier-\(claim.id.rawValue)"),
      isPermitted: true
    )
  }

  /// An operation carried all the way to `started`: claimed, then authorized against a cap no
  /// test-sized estimate can reach.
  func startedOperation(_ key: LearningOperationKey) throws -> ClaimedOperation {
    let claim = try claim(key)
    let outcome = try learning.authorizeAndStartOperation(authorization(for: claim), now: now)
    guard outcome == .started else {
      throw StoreError.unexpected("operation \(claim.id.rawValue) did not start: \(outcome)")
    }
    return claim
  }

  func result(
    for id: LearningOperationID,
    failure: LearningOperationFailure? = nil,
    costUSD: Double = 0.25,
    evaluation: LearningEvaluation? = nil
  ) -> LearningOperationResult {
    LearningOperationResult(
      operationId: id,
      failure: failure,
      usage: LearningCallUsage(
        model: "openai-compatible/test-model",
        promptTokens: 900,
        completionTokens: 100,
        costUSD: costUSD,
        costSource: .providerReturned,
        isEstimated: false
      ),
      evaluation: evaluation
    )
  }

  /// A verdict served by a route other than the one the operation was authorized to start on, so
  /// the served route the commit stamps is distinguishable from the configured one it holds.
  func verdict(
    outcome: EvaluatorOutcome = .reusableIssue,
    issueCodes: [String] = ["missed_price_change", "empty_answer"]
  ) -> LearningEvaluation {
    LearningEvaluation(
      outcome: outcome,
      issueCodes: issueCodes,
      evaluator: EvaluatorSurface(
        route: Self.evaluatorServedRoute,
        promptVersion: Self.evaluatorPromptVersion,
        schemaVersion: Self.evaluatorSchemaVersion,
        rubricVersion: Self.evaluatorRubricVersion
      )
    )
  }

  func gate(proactiveCapUSD: Double) -> BudgetGate {
    let base = RunBudget.default
    return BudgetGate(
      budget: RunBudget(
        maxInputTokens: base.maxInputTokens,
        maxOutputTokens: base.maxOutputTokens,
        wallClockDeadlineSeconds: base.wallClockDeadlineSeconds,
        retryBudget: base.retryBudget,
        perRunUSD: base.perRunUSD,
        perDayUSD: base.perDayUSD,
        proactivePerDayUSD: proactiveCapUSD,
        referenceUSDPerToken: base.referenceUSDPerToken
      )
    )
  }

  func cancelJob() throws {
    guard try jobs.cancel(id: jobId, now: now) != nil else {
      throw StoreError.unexpected("job \(jobId) refused to cancel")
    }
  }

  func proactiveSpentUSD() throws -> Double {
    try usage.todayTokensAndCost(origins: RunOrigin.proactiveOrigins, now: now).costUSD
  }
}

// MARK: - Operation Columns

extension BoundRunEnvironment {
  func operationState(_ id: LearningOperationID) throws -> LearningOperationState? {
    try queue.read { db in
      let raw = try String.fetchOne(
        db,
        sql: "SELECT state FROM learning_operations WHERE operation_id = ?",
        arguments: [id.rawValue]
      )
      return raw.flatMap(LearningOperationState.init(rawValue:))
    }
  }

  func failureCode(_ id: LearningOperationID) throws -> LearningOperationFailure? {
    try queue.read { db in
      let raw = try String.fetchOne(
        db,
        sql: "SELECT failure_code FROM learning_operations WHERE operation_id = ?",
        arguments: [id.rawValue]
      )
      return raw.flatMap(LearningOperationFailure.init(rawValue:))
    }
  }

  func providerCallID(_ id: LearningOperationID) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT provider_call_id FROM learning_operations WHERE operation_id = ?",
        arguments: [id.rawValue]
      )
    }
  }

  func evaluatorRoute(runId: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT evaluator_route FROM run_compatibility WHERE run_id = ?",
        arguments: [runId]
      )
    }
  }

  func reservation(_ id: LearningOperationID) throws -> ReservationRow? {
    try queue.read { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT reservation_state, reserved_tokens, reserved_cost_usd
          FROM learning_operations WHERE operation_id = ?
          """,
        arguments: [id.rawValue]
      )
      guard let row else {
        return nil
      }
      return ReservationRow(
        state: row["reservation_state"],
        tokens: row["reserved_tokens"],
        costUSD: row["reserved_cost_usd"]
      )
    }
  }

  func learningUsage(operationId: LearningOperationID) throws -> [LearningUsageRow] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT provider_call_id, learning_job_id, run_id, cost_usd,
            prompt_tokens + completion_tokens AS tokens
          FROM provider_usage WHERE learning_operation_id = ? ORDER BY id
          """,
        arguments: [operationId.rawValue]
      )
      .map { row in
        LearningUsageRow(
          providerCallID: row["provider_call_id"],
          jobId: row["learning_job_id"],
          runId: row["run_id"],
          costUSD: row["cost_usd"],
          tokens: row["tokens"]
        )
      }
    }
  }

  /// The evaluation row Task 8 will write, seeded straight to the table: what the claim has to
  /// treat as "this evidence already has a verdict".
  func recordEvaluation(of evidence: SealedEvidence) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_evaluations(evaluation_digest, job_id, learning_epoch, run_id,
            evidence_digest, outcome, issue_codes, rubric_version, evaluator_prompt_version,
            evaluator_schema_version, compatibility_digest, created_at)
          VALUES (?, ?, ?, ?, ?, ?, '[]', '1', '1', '1', 'compat', ?)
          """,
        arguments: [
          "evaluation-\(evidence.digest.rawValue)",
          evidence.jobId,
          evidence.epoch.value,
          evidence.runId,
          evidence.digest.rawValue,
          EvaluatorOutcome.noIssue.rawValue,
          EpochSecondCodec.epoch(now),
        ]
      )
    }
  }
}

// MARK: - Sealing Plumbing

private extension BoundRunEnvironment {
  func sealed(runId: Int64) throws -> SealedEvidence {
    guard let evidence = try learning.evidence(runId: runId) else {
      throw StoreError.unexpected("run \(runId) sealed no evidence")
    }
    return evidence
  }
}
