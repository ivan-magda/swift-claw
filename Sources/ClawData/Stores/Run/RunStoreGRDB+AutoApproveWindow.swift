import ClawCore
import Foundation
import GRDB

// MARK: - Auto-Approve Window

extension RunStoreGRDB {
  @discardableResult
  public func openAutoApproveWindow(runId: Int64, now: Date) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try Self.openAutoApproveWindow(db, runId: runId, now: now)
    }
  }

  public func isAutoApproveWindowOpen(runId: Int64) throws(StoreError) -> Bool {
    try database.readMapping { db in
      try Self.isAutoApproveWindowOpen(db, runId: runId)
    }
  }
}

// MARK: - In-Transaction Window Helpers

extension RunStoreGRDB {
  /// Both helpers scope the row to `RunState.liveStates` — the same definition of "live" the
  /// terminate paths use — so a window is neither opened on nor read from a run that `/stop`,
  /// `/new`, or a failure already finished.
  @discardableResult
  static func openAutoApproveWindow(_ db: Database, runId: Int64, now: Date) throws -> Bool {
    let placeholders = databaseQuestionMarks(count: RunState.liveStates.count)
    var values: [DatabaseValueConvertible] = [now, runId]
    values.append(contentsOf: RunState.liveStates.map(\.rawValue))
    try db.execute(
      sql: """
        UPDATE runs SET auto_approve_window = 1, updated_ts = ?
        WHERE id = ? AND state IN (\(placeholders))
        """,
      arguments: StatementArguments(values)
    )
    // SQLite counts every matched row, so a re-open of an already-open window still reports true.
    return db.changesCount > 0
  }

  static func isAutoApproveWindowOpen(_ db: Database, runId: Int64) throws -> Bool {
    let placeholders = databaseQuestionMarks(count: RunState.liveStates.count)
    var values: [DatabaseValueConvertible] = [runId]
    values.append(contentsOf: RunState.liveStates.map(\.rawValue))
    let isOpen = try Bool.fetchOne(
      db,
      sql: """
        SELECT auto_approve_window FROM runs
        WHERE id = ? AND state IN (\(placeholders))
        """,
      arguments: StatementArguments(values)
    )
    return isOpen ?? false
  }
}
