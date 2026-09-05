import ClawCore
import Foundation
import GRDB

// MARK: - Canonical Decision Persistence

extension ScheduledLearningStoreGRDB {
  static func canonicalDecisionJSON<Value: Encodable>(_ value: Value) throws -> String {
    let bytes = try CanonicalJSON.data(encoding: value)
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: bytes, as: UTF8.self)
  }

  static func decodeCanonicalDecision<Value: Codable>(_ json: String) throws -> Value {
    let bytes = Data(json.utf8)
    guard
      let value = try? JSONDecoder().decode(Value.self, from: bytes),
      let canonical = try? CanonicalJSON.data(encoding: value),
      canonical == bytes
    else {
      throw StoreError.unexpected("learning decision payload is unreadable")
    }
    return value
  }

  @discardableResult
  // swiftlint:disable:next function_parameter_count
  static func insertDecision<Inputs: Encodable, Result: Encodable>(
    _ db: Database,
    kind: String,
    jobId: Int64,
    epoch: LearningEpoch,
    inputs: Inputs,
    result: Result,
    algorithm: LearningAlgorithm,
    now: Date
  ) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO learning_decisions(kind, job_id, learning_epoch, inputs, result, algorithm,
          decided_at) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        kind,
        jobId,
        epoch.value,
        try canonicalDecisionJSON(inputs),
        try canonicalDecisionJSON(result),
        algorithm.rawValue,
        EpochSecondCodec.epoch(now),
      ]
    )
    return db.lastInsertedRowID
  }
}
