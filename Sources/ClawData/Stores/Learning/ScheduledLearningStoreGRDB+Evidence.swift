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
    try database.writeMapping { db in
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
    return .excluded(reason)
  }

  static func insertReceipt(
    _ db: Database,
    binding: RunLearningBinding,
    eligibility: LearningEligibility,
    exclusion: EvidenceExclusion?,
    payload: EvidencePayload?,
    now: Date
  ) throws {
    let bytes = payload.flatMap { value in
      try? CanonicalJSON.data(encoding: value)
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
  static func readEvidence(_ db: Database, runId: Int64) throws -> SealedEvidence? {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT job_id, learning_epoch, evidence_digest, payload, exclusion_reason, eligibility,
          classifier_version, sealed_at
        FROM learning_evidence WHERE run_id = ?
        """,
      arguments: [runId]
    )
    guard let row else {
      return nil
    }
    guard
      let eligibility = LearningEligibility(rawValue: row["eligibility"]),
      let sealedAt = EpochSecondCodec.date(fromEpoch: row["sealed_at"])
    else {
      throw StoreError.unexpected("run \(runId) has an unreadable evidence receipt")
    }
    let payloadBytes: Data? = row["payload"]
    return SealedEvidence(
      runId: runId,
      jobId: row["job_id"],
      epoch: LearningEpoch(row["learning_epoch"]),
      digest: EvidenceDigest(rawValue: row["evidence_digest"]),
      eligibility: eligibility,
      classifierVersion: row["classifier_version"],
      exclusion: (row["exclusion_reason"] as String?).flatMap(EvidenceExclusion.init(rawValue:)),
      payload: payloadBytes.flatMap { bytes in
        try? JSONDecoder().decode(EvidencePayload.self, from: bytes)
      },
      sealedAt: sealedAt
    )
  }
}
