import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

enum EvidenceReceiptCorruption: CaseIterable {
  case ineligibleWithPayload
  case eligibleWithExclusion
  case exclusionWithWrongEligibility
  case unknownExclusion
  case payloadStorageClass
  case malformedPayload
  case noncanonicalPayload
  case payloadSchema
  case payloadDigest
  case compactDigest
}

extension BoundRunEnvironment {
  func seal(runID: Int64) throws -> SealedEvidence {
    _ = try learning.sealEvidence(runID: runID, now: now)
    return try #require(try learning.evidence(runID: runID))
  }

  func apply(_ corruption: EvidenceReceiptCorruption, runID: Int64) throws {
    try queue.write { db in
      switch corruption {
      case .ineligibleWithPayload:
        try db.execute(
          sql: "UPDATE learning_evidence SET eligibility = ? WHERE run_id = ?",
          arguments: [LearningEligibility.transientInfrastructureFailure.rawValue, runID]
        )
      case .eligibleWithExclusion:
        try db.execute(
          sql: "UPDATE learning_evidence SET exclusion_reason = ? WHERE run_id = ?",
          arguments: [EvidenceExclusion.staleEpoch.rawValue, runID]
        )
      case .exclusionWithWrongEligibility:
        let eligibility = LearningEligibility.transientInfrastructureFailure
        let digest = SHA256Digest.hex(
          "\(EvidenceLimits.schemaVersion):\(runID):\(eligibility.rawValue)"
        )
        try db.execute(
          sql: """
            UPDATE learning_evidence
            SET payload = NULL, eligibility = ?, exclusion_reason = ?, evidence_digest = ?
            WHERE run_id = ?
            """,
          arguments: [eligibility.rawValue, EvidenceExclusion.staleEpoch.rawValue, digest, runID]
        )
      case .unknownExclusion:
        try db.execute(
          sql: "UPDATE learning_evidence SET exclusion_reason = ? WHERE run_id = ?",
          arguments: ["unknown", runID]
        )
      case .payloadStorageClass:
        try db.execute(
          sql: "UPDATE learning_evidence SET payload = ? WHERE run_id = ?",
          arguments: ["not-a-blob", runID]
        )
      case .malformedPayload: try replaceEvidencePayload(db, runID: runID, with: Data("{}".utf8))
      case .noncanonicalPayload:
        var bytes = try evidencePayloadBytes(db, runID: runID)
        bytes.append(0x20)
        try replaceEvidencePayload(db, runID: runID, with: bytes)
      case .payloadSchema:
        let bytes = try evidencePayloadBytes(db, runID: runID)
        guard
          let json = String(data: bytes, encoding: .utf8),
          json.contains(EvidenceLimits.schemaVersion)
        else {
          throw StoreError.unexpected("fixture evidence payload is unreadable")
        }
        let changed = json.replacingOccurrences(
          of: EvidenceLimits.schemaVersion,
          with: "evidence/v2"
        )
        try replaceEvidencePayload(db, runID: runID, with: Data(changed.utf8))
      case .payloadDigest:
        try db.execute(
          sql: "UPDATE learning_evidence SET evidence_digest = ? WHERE run_id = ?",
          arguments: [String(repeating: "f", count: 64), runID]
        )
      case .compactDigest:
        try db.execute(
          sql: """
            UPDATE learning_evidence
            SET payload = NULL, eligibility = ?, exclusion_reason = NULL
            WHERE run_id = ?
            """,
          arguments: [LearningEligibility.insufficientEvidence.rawValue, runID]
        )
      }
    }
  }

  func removeEvidencePayload(runID: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE learning_evidence SET payload = NULL WHERE run_id = ?",
        arguments: [runID]
      )
    }
  }
}

// MARK: - Evidence Payloads

private extension BoundRunEnvironment {
  func evidencePayloadBytes(_ db: Database, runID: Int64) throws -> Data {
    guard
      let bytes = try Data.fetchOne(
        db,
        sql: "SELECT payload FROM learning_evidence WHERE run_id = ?",
        arguments: [runID]
      )
    else {
      throw StoreError.unexpected("fixture evidence payload is missing")
    }
    return bytes
  }

  func replaceEvidencePayload(_ db: Database, runID: Int64, with bytes: Data) throws {
    try db.execute(
      sql: "UPDATE learning_evidence SET payload = ?, evidence_digest = ? WHERE run_id = ?",
      arguments: [bytes, SHA256Digest.hex(bytes), runID]
    )
  }
}
