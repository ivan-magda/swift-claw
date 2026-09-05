import ClawCore
import Foundation
import GRDB

// MARK: - Sealing

extension ScheduledLearningStoreGRDB {
  public func unsealed(limit: Int) throws(StoreError) -> [Int64] {
    try database.readMapping { db in
      // `settled_at`, never `terminal_at`: a run whose primary facts are not final yet would be
      // sealed against evidence a later usage row or observation fill still changes.
      try Int64.fetchAll(
        db,
        sql: """
          SELECT run_settlements.run_id FROM run_settlements
          JOIN run_learning_bindings ON run_learning_bindings.run_id = run_settlements.run_id
          LEFT JOIN learning_evidence ON learning_evidence.run_id = run_settlements.run_id
          WHERE run_settlements.settled_at IS NOT NULL AND learning_evidence.run_id IS NULL
          ORDER BY run_settlements.settled_at, run_settlements.run_id
          LIMIT ?
          """,
        arguments: [limit]
      )
    }
  }

  @discardableResult
  public func sealEvidence(runId: Int64, now: Date) throws(StoreError) -> SealOutcome {
    // Read first. The lane tail notifies on every lane exit, so the overwhelming majority of calls
    // are ordinary inbound turns that carry no binding, and taking a write lock per owner message
    // only to discover that is the hot path made expensive. `seal` re-reads the binding inside the
    // transaction, so this is a filter and never the decision.
    guard try binding(runId: runId) != nil else {
      return .excluded(.legacyUnbound)
    }
    return try database.writeMapping { db in
      try Self.seal(db, runId: runId, now: now)
    }
  }

  public func evidence(runId: Int64) throws(StoreError) -> SealedEvidence? {
    try database.readMapping { db in
      try Self.readEvidence(db, runId: runId)
    }
  }
}

// MARK: - Sealing Sequence

private extension ScheduledLearningStoreGRDB {
  /// The order is the whole contract: a row already present wins over every later check, an
  /// unsettled run is left alone rather than frozen early, and every remaining refusal writes a
  /// content-free tombstone so the run is closed exactly once.
  static func seal(_ db: Database, runId: Int64, now: Date) throws -> SealOutcome {
    guard try readEvidence(db, runId: runId) == nil else {
      _ = try recomputeAndReconcile(db, runId: runId, now: now)
      return .alreadySealed
    }
    guard let binding = try readBinding(db, runId: runId) else {
      return .excluded(.legacyUnbound)
    }
    guard
      let settlement = try readSettlement(db, runId: runId),
      settlement.settledAt != nil
    else {
      return .notSettled
    }

    // Before any receipt is built, and after the settlement guard above: every path from here
    // writes a receipt, and the payload reads this column back.
    try stampTerminalRoute(db, runId: runId)

    let state = try readState(db, jobId: binding.jobId)
    guard state?.epoch == binding.epoch else {
      return try tombstone(db, binding: binding, reason: .staleEpoch, now: now)
    }
    guard let compatibility = try readCompatibility(db, runId: runId) else {
      return try tombstone(db, binding: binding, reason: .compatibilityUnavailable, now: now)
    }
    guard try lessonSetExists(db, binding: binding) else {
      return try tombstone(db, binding: binding, reason: .sourceDigestUnresolved, now: now)
    }

    let transcript = try readTranscript(db, runId: runId)
    let eligibility = EligibilityClassifier.classify(settlement, transcript: transcript.summary)
    // Only task evidence carries a payload. Nothing reads the answer of a run the evaluator will
    // never see, and an over-cap answer is refused whole rather than clipped into one.
    let payload =
      eligibility.reachesEvaluator
      ? try buildPayload(
        db,
        runId: runId,
        binding: binding,
        compatibility: compatibility,
        transcript: transcript
      )
      : nil

    try insertReceipt(
      db,
      binding: binding,
      eligibility: eligibility,
      exclusion: nil,
      payload: payload,
      now: now
    )
    try stampSealingVersions(db, runId: runId)
    _ = try recomputeAndReconcile(db, runId: runId, now: now)
    return .sealed(eligibility: eligibility)
  }

  /// A content-free receipt: the run is recorded as seen and closed, and never sealed again. The
  /// eligibility is `insufficientEvidence` because a run the sealer could not reconstruct neither
  /// supports nor contradicts a candidate.
  static func tombstone(
    _ db: Database,
    binding: RunLearningBinding,
    reason: EvidenceExclusion,
    now: Date
  ) throws -> SealOutcome {
    try insertReceipt(
      db,
      binding: binding,
      eligibility: .insufficientEvidence,
      exclusion: reason,
      payload: nil,
      now: now
    )
    try stampSealingVersions(db, runId: binding.runId)
    _ = try recomputeAndReconcile(db, runId: binding.runId, now: now)
    return .excluded(reason)
  }

  static func insertReceipt(  // swiftlint:disable:this function_parameter_count
    _ db: Database,
    binding: RunLearningBinding,
    eligibility: LearningEligibility,
    exclusion: EvidenceExclusion?,
    payload: EvidencePayload?,
    now: Date
  ) throws {
    // Deliberately throwing. A swallowed encode would commit a row marked eligible with a null
    // payload — indistinguishable from a payload retention has aged out — and the receipt is
    // terminal, so nothing would ever re-seal it. Throwing aborts the transaction and leaves the
    // run in the durable unsealed queue for the next sweep instead.
    let bytes = try payload.map { value in
      try CanonicalJSON.data(encoding: value)
    }
    try db.execute(
      sql: """
        INSERT INTO learning_evidence(run_id, job_id, learning_epoch, evidence_digest, payload,
          exclusion_reason, eligibility, classifier_version, sealed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        binding.runId,
        binding.jobId,
        binding.epoch.value,
        digest(runId: binding.runId, eligibility: eligibility, payloadBytes: bytes).rawValue,
        bytes,
        exclusion?.rawValue,
        eligibility.rawValue,
        EligibilityClassifier.version,
        EpochSecondCodec.epoch(now),
      ]
    )
  }

  /// Over the payload when there is one, and over the compact receipt otherwise — a receipt still
  /// needs an identity later work can reference, and two payload-free receipts for different runs
  /// must not collide.
  static func digest(
    runId: Int64,
    eligibility: LearningEligibility,
    payloadBytes: Data?
  ) -> EvidenceDigest {
    guard let payloadBytes else {
      let receipt = "\(EvidenceLimits.schemaVersion):\(runId):\(eligibility.rawValue)"
      return EvidenceDigest(rawValue: SHA256Digest.hex(receipt))
    }
    return EvidenceDigest(rawValue: SHA256Digest.hex(payloadBytes))
  }

  /// Records the route the run's answering round actually served, on the settlement row where the
  /// compatibility pair lives. Stamped here rather than in the transaction that wins the state:
  /// `transitionRun` writes the terminal receipt before the same commit inserts that round's usage
  /// row, so a route read there would name the round before last. Sealing runs strictly after
  /// settlement, which is the first moment the answer cannot change.
  ///
  /// `provider_usage.model` holds the configured reference the call billed under — the same
  /// vocabulary `run_compatibility.configured_route` is frozen from, which is what makes the pair
  /// comparable. `id` orders it because `ts` is a formatted datetime string.
  static func stampTerminalRoute(_ db: Database, runId: Int64) throws {
    try db.execute(
      sql: """
        UPDATE run_settlements
        SET terminal_route = (
          SELECT provider_usage.model FROM provider_usage
          WHERE provider_usage.run_id = ? ORDER BY provider_usage.id DESC LIMIT 1
        )
        WHERE run_id = ?
        """,
      arguments: [runId, runId]
    )
  }

  static func lessonSetExists(_ db: Database, binding: RunLearningBinding) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS(SELECT 1 FROM lesson_sets WHERE job_id = ? AND digest = ?)",
      arguments: [binding.jobId, binding.effectiveDigest.rawValue]
    ) ?? false
  }
}

// MARK: - Receipt Rows

extension ScheduledLearningStoreGRDB {
  /// The route the run's answering round actually billed, as `stampTerminalRoute` froze it at
  /// sealing. Read from the settlement row rather than from the sealed payload: the payload is
  /// nulled by the 30-day sweep while the compact receipt around it lives 90, so this is the source
  /// that outlives retention.
  static func readTerminalRoute(_ db: Database, runId: Int64) throws -> String? {
    try String.fetchOne(
      db,
      sql: "SELECT terminal_route FROM run_settlements WHERE run_id = ?",
      arguments: [runId]
    )
  }

  static func readEvidence(_ db: Database, runId: Int64) throws -> SealedEvidence? {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT run_id, job_id, learning_epoch, evidence_digest, payload, exclusion_reason,
          eligibility, classifier_version, sealed_at
        FROM learning_evidence WHERE run_id = ?
        """,
      arguments: [runId]
    )
    guard let row else {
      return nil
    }
    return try decodeEvidence(row, expectedRunId: runId)
  }
}

// MARK: - Receipt Decoding

private extension ScheduledLearningStoreGRDB {
  static func decodeEvidence(_ row: Row, expectedRunId: Int64) throws -> SealedEvidence {
    guard
      let storedRunId = SQLiteStoredValue.int64(in: row, column: "run_id"),
      storedRunId == expectedRunId,
      let jobId = SQLiteStoredValue.int64(in: row, column: "job_id"),
      jobId > 0,
      let epochRaw = SQLiteStoredValue.int64(in: row, column: "learning_epoch"),
      epochRaw > 0,
      let digestRaw = SQLiteStoredValue.string(in: row, column: "evidence_digest"),
      isCanonicalDigest(digestRaw),
      let payloadStored = SQLiteStoredValue.nullableData(in: row, column: "payload"),
      let exclusionStored = SQLiteStoredValue.nullableString(in: row, column: "exclusion_reason"),
      let eligibilityRaw = SQLiteStoredValue.string(in: row, column: "eligibility"),
      let eligibility = LearningEligibility(rawValue: eligibilityRaw),
      let classifier = SQLiteStoredValue.string(in: row, column: "classifier_version"),
      classifier == EligibilityClassifier.version,
      let sealedRaw = SQLiteStoredValue.int64(in: row, column: "sealed_at"),
      let sealedAt = EpochSecondCodec.date(fromEpoch: sealedRaw)
    else {
      throw StoreError.unexpected("run \(expectedRunId) has an unreadable evidence receipt")
    }
    let exclusion = exclusionStored.value.flatMap(EvidenceExclusion.init(rawValue:))
    guard exclusionStored.value == nil || exclusion != nil else {
      throw StoreError.unexpected("run \(expectedRunId) has an unknown evidence exclusion")
    }
    let payload = try decodeEvidencePayload(
      payloadStored.value,
      runId: expectedRunId,
      digestRaw: digestRaw,
      eligibility: eligibility,
      exclusion: exclusion
    )
    return SealedEvidence(
      runId: expectedRunId,
      jobId: jobId,
      epoch: LearningEpoch(epochRaw),
      digest: EvidenceDigest(rawValue: digestRaw),
      eligibility: eligibility,
      classifierVersion: classifier,
      exclusion: exclusion,
      payload: payload,
      sealedAt: sealedAt
    )
  }

  static func decodeEvidencePayload(
    _ payloadBytes: Data?,
    runId: Int64,
    digestRaw: String,
    eligibility: LearningEligibility,
    exclusion: EvidenceExclusion?
  ) throws -> EvidencePayload? {
    if let payloadBytes {
      guard
        eligibility.reachesEvaluator,
        exclusion == nil,
        let decoded = try? JSONDecoder().decode(EvidencePayload.self, from: payloadBytes),
        decoded.schemaVersion == EvidenceLimits.schemaVersion,
        let canonical = try? CanonicalJSON.data(encoding: decoded),
        canonical == payloadBytes,
        digest(runId: runId, eligibility: eligibility, payloadBytes: payloadBytes).rawValue
          == digestRaw
      else {
        throw StoreError.unexpected("run \(runId) has an invalid evidence payload")
      }
      return decoded
    }
    guard
      eligibility.reachesEvaluator
        || digest(
          runId: runId,
          eligibility: eligibility,
          payloadBytes: nil
        ).rawValue == digestRaw,
      exclusion == nil
        || (eligibility == .insufficientEvidence && exclusion != .legacyUnbound),
      eligibility.reachesEvaluator == false || exclusion == nil
    else {
      throw StoreError.unexpected("run \(runId) has an invalid evidence receipt shape")
    }
    return nil
  }
}
