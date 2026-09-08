import ClawCore
import Foundation
import GRDB

@testable import ClawData

enum ResetEmptyCollision: CaseIterable {
  case schemaVersion
  case canonicalBytes
  case source
}

enum ResetReceiptCorruption: CaseIterable {
  case noncanonicalJSON
  case wrongStableRevision
}

enum ResetStartedOperationCorruption: CaseIterable {
  case missingProviderCallID
  case emptyProviderCallID
  case missingRoute
  case emptyRoute
  case closedReservation
  case missingReservedTokens
  case negativeReservedTokens
  case missingReservedCost
  case negativeReservedCost
  case nonFiniteReservedCost
}

extension ResetFixture {
  func clearTrialPointer() throws {
    try env.queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET open_trial_id = NULL WHERE job_id = ?",
        arguments: [env.jobId]
      )
    }
  }

  func corruptFirstLiveTrialBaseDigest() throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          UPDATE learning_trials SET base_digest = 'corrupt'
          WHERE trial_id = (
            SELECT trial_id FROM learning_trials WHERE job_id = ? ORDER BY trial_id LIMIT 1
          )
          """,
        arguments: [env.jobId]
      )
    }
  }

  func corruptStartedOperation(
    _ corruption: ResetStartedOperationCorruption,
    id: String = "op-started"
  ) throws {
    try env.queue.write { db in
      switch corruption {
      case .missingProviderCallID:
        try db.execute(
          sql: "UPDATE learning_operations SET provider_call_id = NULL WHERE operation_id = ?",
          arguments: [id]
        )
      case .emptyProviderCallID:
        try db.execute(
          sql: "UPDATE learning_operations SET provider_call_id = '' WHERE operation_id = ?",
          arguments: [id]
        )
      case .missingRoute:
        try db.execute(
          sql: "UPDATE learning_operations SET route = NULL WHERE operation_id = ?",
          arguments: [id]
        )
      case .emptyRoute:
        try db.execute(
          sql: "UPDATE learning_operations SET route = '' WHERE operation_id = ?",
          arguments: [id]
        )
      case .closedReservation:
        try db.execute(
          sql: "UPDATE learning_operations SET reservation_state = ? WHERE operation_id = ?",
          arguments: [LearningReservationState.closed.rawValue, id]
        )
      case .missingReservedTokens:
        try db.execute(
          sql: "UPDATE learning_operations SET reserved_tokens = NULL WHERE operation_id = ?",
          arguments: [id]
        )
      case .negativeReservedTokens:
        try db.execute(
          sql: "UPDATE learning_operations SET reserved_tokens = -1 WHERE operation_id = ?",
          arguments: [id]
        )
      case .missingReservedCost:
        try db.execute(
          sql: "UPDATE learning_operations SET reserved_cost_usd = NULL WHERE operation_id = ?",
          arguments: [id]
        )
      case .negativeReservedCost:
        try db.execute(
          sql: "UPDATE learning_operations SET reserved_cost_usd = -0.5 WHERE operation_id = ?",
          arguments: [id]
        )
      case .nonFiniteReservedCost:
        try db.execute(
          sql: "UPDATE learning_operations SET reserved_cost_usd = ? WHERE operation_id = ?",
          arguments: [Double.infinity, id]
        )
      }
    }
  }

  func corruptCanonicalEmpty(_ collision: ResetEmptyCollision) throws {
    let empty = LessonSet.empty(jobId: env.jobId)
    try env.queue.write { db in
      switch collision {
      case .schemaVersion:
        try db.execute(
          sql: "UPDATE lesson_sets SET schema_version = ? WHERE job_id = ? AND digest = ?",
          arguments: [empty.schemaVersion + 1, env.jobId, empty.digest.rawValue]
        )
      case .canonicalBytes:
        try db.execute(
          sql: "UPDATE lesson_sets SET canonical_bytes = ? WHERE job_id = ? AND digest = ?",
          arguments: [Data("reset-corrupt".utf8), env.jobId, empty.digest.rawValue]
        )
      case .source:
        try db.execute(
          sql: "UPDATE lesson_sets SET source = ? WHERE job_id = ? AND digest = ?",
          arguments: [LessonSetSource.ownerEdit.rawValue, env.jobId, empty.digest.rawValue]
        )
      }
    }
  }

  func dropLearningStateTable() throws {
    try env.queue.write { db in
      try db.drop(table: "job_learning_state")
    }
  }

  func failResetAudit() throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_reset_audit BEFORE INSERT ON audit_events
          WHEN NEW.action = '\(AuditAction.learningReset.rawValue)'
          BEGIN SELECT RAISE(ABORT, 'forced reset audit failure'); END
          """
      )
    }
  }

  func allowResetAudit() throws {
    try env.queue.write { db in
      try db.execute(sql: "DROP TRIGGER fail_reset_audit")
    }
  }

  func corruptResetResult(_ corruption: ResetReceiptCorruption) throws {
    try env.queue.write { db in
      let result = try String.fetchOne(
        db,
        sql: "SELECT result FROM learning_decisions WHERE kind = ?",
        arguments: [ResetReceipt.kind]
      )
      guard let result else {
        throw StoreError.unexpected("fixture reset decision is missing")
      }
      let corrupted: String
      switch corruption {
      case .noncanonicalJSON:
        corrupted = " \(result)"
      case .wrongStableRevision:
        let decoded: LearningResetDecisionResult =
          try ScheduledLearningStoreGRDB.decodeCanonicalDecision(result)
        let changed = LearningResetDecisionResult(
          newEpoch: decoded.newEpoch,
          emptyStableDigest: decoded.emptyStableDigest,
          newStableRevision: decoded.newStableRevision.next(),
          closedTrials: decoded.closedTrials,
          invalidatedTargetCount: decoded.invalidatedTargetCount,
          invalidatedChallengeCount: decoded.invalidatedChallengeCount,
          staleNoCallOperationIds: decoded.staleNoCallOperationIds,
          inFlightOperationIds: decoded.inFlightOperationIds
        )
        corrupted = try ScheduledLearningStoreGRDB.canonicalDecisionJSON(changed)
      }
      try db.execute(
        sql: "UPDATE learning_decisions SET result = ? WHERE kind = ?",
        arguments: [corrupted, ResetReceipt.kind]
      )
    }
  }

  func duplicateCurrentResetDecision() throws {
    try env.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO learning_decisions(kind, job_id, learning_epoch, inputs, result, algorithm,
            decided_at)
          SELECT kind, job_id, learning_epoch, inputs, result, algorithm, decided_at
          FROM learning_decisions WHERE kind = ? ORDER BY decision_id DESC LIMIT 1
          """,
        arguments: [ResetReceipt.kind]
      )
    }
  }
}
