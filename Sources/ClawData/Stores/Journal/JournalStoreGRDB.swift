import ClawCore
import Foundation
import GRDB

public struct JournalStoreGRDB: JournalStore {
  public static let startedCallsCap = "journal started calls per UTC day"
  static let expiredSourceReason = "journal source exceeded pending age"
  let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func canPublish(batchID: UUID) throws(StoreError) -> Bool {
    try database.readMapping { db in
      let batchState = try String.fetchOne(
        db,
        sql: "SELECT state FROM journal_batches WHERE id = ?",
        arguments: [batchID.uuidString]
      )
      return batchState == BatchState.started.rawValue
    }
  }

  public func pendingCount(day: JournalDay, ownerUserID: Int64) throws(StoreError) -> Int {
    try database.readMapping { db in
      try Self.unpublishedCount(db, ownerUserID: ownerUserID, day: day)
    }
  }

  public func cancelDay(
    _ day: JournalDay,
    ownerUserID: Int64,
    now: Date
  ) throws(StoreError) -> Int {
    try database.writeMapping { db in
      let unpublishedSourceCount = try Self.unpublishedCount(db, ownerUserID: ownerUserID, day: day)

      try db.execute(
        sql: """
          UPDATE journal_sources SET state = ?, payload = NULL
          WHERE owner_user_id = ? AND day = ? AND state IN (?, ?)
          """,
        arguments: [
          SourceState.closed.rawValue,
          ownerUserID,
          day.isoDate,
          SourceState.pending.rawValue,
          SourceState.started.rawValue,
        ]
      )
      try db.execute(
        sql: """
          UPDATE journal_batches SET state = ?, outcome = ?
          WHERE owner_user_id = ? AND day = ? AND state = ?
          """,
        arguments: [
          BatchState.cancelled.rawValue,
          try JSONEncoder().encode(JournalOutcome.cancelled),
          ownerUserID,
          day.isoDate,
          BatchState.started.rawValue,
        ]
      )

      if unpublishedSourceCount > 0 {
        try Self.recordStatus(
          db,
          ownerUserID: ownerUserID,
          outcome: .cancelled,
          now: now,
          skipped: 0,
          interrupted: 0
        )
      }
      return unpublishedSourceCount
    }
  }

  public func status(ownerUserID: Int64, now: Date) throws(StoreError) -> JournalStatus {
    try database.readMapping { db in
      let statusRow = try Row.fetchOne(
        db,
        sql: "SELECT * FROM journal_status WHERE owner_user_id = ?",
        arguments: [ownerUserID]
      )
      let encodedLastOutcome: Data? = statusRow?["last_outcome"]

      let unpublishedSourceCount = try Self.unpublishedCount(db, ownerUserID: ownerUserID, day: nil)
      let lastOutcome = try encodedLastOutcome.map { encodedOutcome in
        try JSONDecoder().decode(JournalOutcome.self, from: encodedOutcome)
      }
      return JournalStatus(
        pendingCount: unpublishedSourceCount,
        lastOutcome: lastOutcome,
        lastOutcomeAt: statusRow?["last_outcome_ts"],
        skippedCount: statusRow?["skipped_count"] ?? 0,
        interruptedCount: statusRow?["interrupted_count"] ?? 0,
        lastRedactedError: statusRow?["last_redacted_error"]
      )
    }
  }
}

// MARK: - Transaction Records

extension JournalStoreGRDB {
  enum SourceState: String {
    case pending, started, closed
  }

  enum BatchState: String {
    case started, cancelled, finished
  }

  static func unpublishedCount(
    _ db: Database,
    ownerUserID: Int64,
    day: JournalDay?
  ) throws -> Int {
    let dayClause = day == nil ? "" : " AND day = ?"
    var arguments: StatementArguments = [
      ownerUserID,
      SourceState.pending.rawValue,
      SourceState.started.rawValue,
    ]
    if let day {
      arguments += [day.isoDate]
    }
    return try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM journal_sources WHERE owner_user_id = ? AND state IN (?, ?)
        \(dayClause)
        """,
      arguments: arguments
    ) ?? 0
  }

  static func recordStatus(
    _ db: Database,
    ownerUserID: Int64,
    outcome: JournalOutcome,
    now: Date,
    skipped: Int,
    interrupted: Int
  ) throws {
    let redactedErrorReason: String? =
      switch outcome {
      case .invalidSummary(let reason), .failed(let reason), .skipped(let reason):
        reason
      case .written, .empty, .cancelled, .interrupted:
        nil
      }
    try db.execute(
      sql: """
        INSERT INTO journal_status(owner_user_id, last_outcome, last_outcome_ts,
          skipped_count, interrupted_count, last_redacted_error) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(owner_user_id) DO UPDATE SET
          last_outcome = excluded.last_outcome, last_outcome_ts = excluded.last_outcome_ts,
          skipped_count = skipped_count + excluded.skipped_count,
          interrupted_count = interrupted_count + excluded.interrupted_count,
          last_redacted_error = COALESCE(excluded.last_redacted_error, last_redacted_error)
        """,
      arguments: [
        ownerUserID,
        try JSONEncoder().encode(outcome),
        now,
        skipped,
        interrupted,
        redactedErrorReason,
      ]
    )
  }
}
