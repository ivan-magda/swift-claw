import ClawCore
import Foundation
import GRDB

// MARK: - Pending Sources

extension JournalStoreGRDB {
  public func pendingSources(ownerUserID: Int64, now: Date) throws(StoreError) -> [JournalSource] {
    try database.writeMapping { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM journal_sources WHERE owner_user_id = ? AND state = ?
          ORDER BY activity_ts, source_id LIMIT ?
          """,
        arguments: [ownerUserID, SourceState.pending.rawValue, JournalLimits.sweepCandidates]
      )
      var sources: [JournalSource] = []
      for row in rows {
        let source = try Self.decodeSource(row)
        guard try Self.keepPending(db, source: source, now: now) else {
          continue
        }
        sources.append(source)
      }
      // Determine due days before returning their sources, even when frozen timezones differ.
      for source in sources where try Self.dayIsDue(db, source: source, now: now) {
        try Self.markDayDue(db, ownerUserID: ownerUserID, day: source.day)
      }
      return try sources.filter { source in
        try Self.dayIsDue(db, source: source, now: now)
      }
    }
  }

  public func skipSources(ids: [String], reason: String, now: Date) throws(StoreError) {
    try database.writeMapping { db in
      for id in Set(ids) {
        guard let row = try Row.fetchOne(
          db,
          sql: """
              SELECT * FROM journal_sources WHERE source_id = ? AND state = ?
              """,
          arguments: [id, SourceState.pending.rawValue]
        )
        else {
          continue
        }
        try Self.closeSource(db, id: id)
        try Self.recordStatus(
          db,
          ownerUserID: row["owner_user_id"],
          outcome: .skipped(redactedReason: reason),
          now: now,
          skipped: 1,
          interrupted: 0
        )
      }
    }
  }
}

// MARK: - Transaction-Local Capture

extension JournalStoreGRDB {
  /// Optional capture cannot roll back required reply, result or outbox facts.
  static func captureBestEffort(
    _ db: Database,
    capture: JournalCaptureOutcome,
    now: Date,
    eligible: () throws -> Bool
  ) {
    do {
      try db.inSavepoint {
        guard try eligible() else {
          return .commit
        }
        switch capture {
        case .source(let source):
          try insertSource(db, source: source)
        case .skipped(let scope):
          try recordStatus(
            db,
            ownerUserID: scope.ownerUserID,
            outcome: .skipped(redactedReason: "Journal source preparation failed"),
            now: now,
            skipped: 1,
            interrupted: 0
          )
        }
        return .commit
      }
    } catch {
      // SQL diagnostics can contain payload text. Persist a fixed reason rather than the error.
      try? db.inSavepoint {
        try recordStatus(
          db,
          ownerUserID: capture.scope.ownerUserID,
          outcome: .skipped(redactedReason: "Journal source capture failed"),
          now: now,
          skipped: 1,
          interrupted: 0
        )
        return .commit
      }
    }
  }

  /// Called inside the producer's transaction or savepoint; duplicate IDs leave the receipt intact.
  @discardableResult
  static func insertSource(_ db: Database, source: JournalSource) throws -> Bool {
    let payload = try JSONEncoder().encode(source)
    guard payload.count <= JournalLimits.storedSourceBytes else {
      throw StoreError.unexpected("journal source exceeded serialized byte limit")
    }
    try db.execute(
      sql: """
        INSERT INTO journal_sources(source_id, owner_user_id, day, timezone, session_id,
          activity_ts, payload, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_id) DO NOTHING
        """,
      arguments: [
        source.id,
        source.scope.ownerUserID,
        source.day.isoDate,
        source.scope.timeZoneID,
        source.sessionID,
        source.occurredAt,
        payload,
        SourceState.pending.rawValue,
      ]
    )
    return db.changesCount > 0
  }

  /// Reset marking is optional; a failed journal write must not undo the conversation reset.
  static func markPendingSourcesDueBestEffort(
    _ db: Database,
    ownerUserID: Int64,
    sessionID: Int64,
    now: Date
  ) {
    do {
      try db.inSavepoint {
        try markPendingSourcesDue(db, ownerUserID: ownerUserID, sessionID: sessionID)
        return .commit
      }
    } catch {
      // Failed marking leaves sources pending for another trigger, so it is not a source skip.
      try? db.inSavepoint {
        try recordStatus(
          db,
          ownerUserID: ownerUserID,
          outcome: .failed(redactedReason: "Journal reset marking failed"),
          now: now,
          skipped: 0,
          interrupted: 0
        )
        return .commit
      }
    }
  }

  /// A reset marks only sources that already exist in this session, never future arrivals.
  static func markPendingSourcesDue(_ db: Database, ownerUserID: Int64, sessionID: Int64) throws {
    try db.execute(
      sql: """
        UPDATE journal_sources SET due = 1 WHERE owner_user_id = ? AND session_id = ? AND state = ?
        """,
      arguments: [ownerUserID, sessionID, SourceState.pending.rawValue]
    )
  }
}

// MARK: - Eligibility Transactions

extension JournalStoreGRDB {
  static func decodeSource(_ row: Row) throws -> JournalSource {
    guard let payload: Data = row["payload"] else {
      throw StoreError.unexpected("pending journal source has no payload")
    }
    return try JSONDecoder().decode(JournalSource.self, from: payload)
  }

  static func keepPending(_ db: Database, source: JournalSource, now: Date) throws -> Bool {
    guard now.timeIntervalSince(source.occurredAt) > Double(JournalLimits.pendingAgeSeconds) else {
      return true
    }
    try closeSource(db, id: source.id)
    try recordStatus(
      db,
      ownerUserID: source.scope.ownerUserID,
      outcome: .skipped(redactedReason: expiredSourceReason),
      now: now,
      skipped: 1,
      interrupted: 0
    )
    return false
  }

  static func dayIsDue(_ db: Database, source: JournalSource, now: Date) throws -> Bool {
    guard let timeZone = TimeZone(identifier: source.scope.timeZoneID) else {
      throw StoreError.unexpected("journal source has invalid frozen timezone")
    }
    if source.day.isoDate < JournalDay.containing(now, timeZone: timeZone).isoDate {
      return true
    }
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) AS count, MAX(due) AS due FROM journal_sources
        WHERE owner_user_id = ? AND day = ? AND state = ? AND activity_ts >= ?
        """,
      arguments: [
        source.scope.ownerUserID,
        source.day.isoDate,
        SourceState.pending.rawValue,
        now.addingTimeInterval(-Double(JournalLimits.pendingAgeSeconds)),
      ]
    )
    guard let row else {
      return false
    }
    let count: Int = row["count"]
    let due: Bool = row["due"] ?? false
    return due || count >= JournalLimits.batchSources
  }

  static func markDayDue(_ db: Database, ownerUserID: Int64, day: JournalDay) throws {
    try db.execute(
      sql: """
        UPDATE journal_sources SET due = 1 WHERE owner_user_id = ? AND day = ? AND state = ?
        """,
      arguments: [ownerUserID, day.isoDate, SourceState.pending.rawValue]
    )
  }

  static func closeSource(_ db: Database, id: String) throws {
    // Keep the ID tombstone to deduplicate a producer retry, without retaining source text.
    try db.execute(
      sql: "UPDATE journal_sources SET state = ?, payload = NULL WHERE source_id = ?",
      arguments: [SourceState.closed.rawValue, id]
    )
  }
}
