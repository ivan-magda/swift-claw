import ClawCore
import Foundation
import GRDB

// MARK: - Settlement

extension ScheduledLearningStoreGRDB {
  public func settlement(runId: Int64) throws(StoreError) -> RunSettlement? {
    try database.readMapping { db in
      try Self.readSettlement(db, runId: runId)
    }
  }

  @discardableResult
  public func settleFromLane(runId: Int64, now: Date) throws(StoreError) -> Bool {
    try database.writeMapping { db in
      try Self.freezeEvidence(db, runId: runId, now: now)
    }
  }
}

// MARK: - Receipt Rows

/// `run_settlements` is written from the primary run path — `RunStore` owns the transaction that
/// wins a run's state — but the row is a learning fact, so all of its SQL lives here.
extension ScheduledLearningStoreGRDB {
  /// The terminal half of the receipt, written inside the caller's winning transaction. A run with
  /// no binding carries no lessons and produces no receipt at all: the learning loop never sees it,
  /// and a disarmed daemon therefore writes nothing here.
  static func recordTerminalReceipt(
    _ db: Database,
    runId: Int64,
    state: RunState,
    disposition: TerminalDisposition,
    now: Date
  ) throws {
    guard try isBound(db, runId: runId) else {
      return
    }
    let epoch = EpochSecondCodec.epoch(now)
    // OR IGNORE rather than a plain insert: `RunFSM` absorbs every event once a run is terminal, so
    // a second receipt is unreachable — but a raw conflict here would abort the whole commit and
    // take the assistant message and outbox rows with it.
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO run_settlements(run_id, winning_state, terminal_cause, terminal_at,
          settled_at)
        VALUES (?, ?, ?, ?, ?)
        """,
      arguments: [
        runId,
        state.rawValue,
        disposition.cause.rawValue,
        epoch,
        disposition.freezesEvidence ? epoch : nil,
      ]
    )
  }

  /// Stamps `settled_at` on a terminal receipt that is still open. The receipt's existence is what
  /// proves the run is terminal, so no state read is needed; the `IS NULL` predicate is what makes
  /// the write idempotent and keeps the first settler's instant.
  ///
  /// - Returns: whether this call froze the evidence.
  static func freezeEvidence(_ db: Database, runId: Int64, now: Date) throws -> Bool {
    try db.execute(
      sql: """
        UPDATE run_settlements SET settled_at = ?
        WHERE run_id = ? AND settled_at IS NULL
        """,
      arguments: [EpochSecondCodec.epoch(now), runId]
    )
    return db.changesCount > 0
  }

  static func isSettled(_ db: Database, runId: Int64) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(
          SELECT 1 FROM run_settlements WHERE run_id = ? AND settled_at IS NOT NULL
        )
        """,
      arguments: [runId]
    ) ?? false
  }

  static func readSettlement(_ db: Database, runId: Int64) throws -> RunSettlement? {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT winning_state, terminal_cause, terminal_at, settled_at
        FROM run_settlements WHERE run_id = ?
        """,
      arguments: [runId]
    )
    guard let row else {
      return nil
    }
    guard
      let winningState = RunState(rawValue: row["winning_state"]),
      let terminalCause = TerminalCause(rawValue: row["terminal_cause"]),
      let terminalAt = EpochSecondCodec.date(fromEpoch: row["terminal_at"])
    else {
      throw StoreError.unexpected("run \(runId) has an unreadable terminal receipt")
    }
    return RunSettlement(
      runId: runId,
      winningState: winningState,
      terminalCause: terminalCause,
      terminalAt: terminalAt,
      settledAt: EpochSecondCodec.date(fromEpoch: row["settled_at"])
    )
  }
}

// MARK: - Crash Backstop

extension ScheduledLearningStoreGRDB {
  /// Boot's sweep over what a crash left open, run inside the boot reconciliation transaction.
  ///
  /// Two shapes reach it. A bound terminal run whose lane tail never ran — `/stop` won and the
  /// process died before the closure returned — keeps the cause its cancellation stored and is
  /// simply frozen. A bound terminal run with no receipt at all is damaged or predates receipts,
  /// and records `unknown` rather than a cause inferred from its state; its `terminal_at` is the
  /// run's own last transition, never this boot, because the evidence-age window reads that column
  /// and a fabricated instant would re-admit a stale run on every restart.
  ///
  /// A run that still owes its approval placeholder is left open for the writer that owes it.
  /// Nothing else is excluded: boot reconciliation runs before lane admission opens, so no
  /// current-process lane owns a run here.
  static func settleAbandonedRuns(
    _ db: Database,
    unresolvedObservationContent: String,
    now: Date
  ) throws {
    let epoch = EpochSecondCodec.epoch(now)
    let terminalStates = RunState.terminalStates.map(\.rawValue)
    let statePlaceholders = databaseQuestionMarks(count: terminalStates.count)
    // `updated_ts` is a GRDB datetime string; COALESCE keeps one unparseable timestamp from
    // aborting the whole boot transaction on this NOT NULL column.
    let terminalAt = "COALESCE(CAST(strftime('%s', runs.updated_ts) AS INTEGER), ?)"

    try db.execute(
      sql: """
        INSERT INTO run_settlements(run_id, winning_state, terminal_cause, terminal_at, settled_at)
        SELECT runs.id, runs.state, ?, \(terminalAt), ?
        FROM runs
        JOIN run_learning_bindings ON run_learning_bindings.run_id = runs.id
        LEFT JOIN run_settlements ON run_settlements.run_id = runs.id
        WHERE run_settlements.run_id IS NULL
          AND runs.state IN (\(statePlaceholders))
          AND NOT \(owedFactExists(runColumn: "runs.id"))
        """,
      arguments: StatementArguments(
        [TerminalCause.unknown.rawValue, epoch, epoch] as [DatabaseValueConvertible]
          + terminalStates + [unresolvedObservationContent]
      )
    )

    try db.execute(
      sql: """
        UPDATE run_settlements SET settled_at = ?
        WHERE settled_at IS NULL
          AND NOT \(owedFactExists(runColumn: "run_settlements.run_id"))
        """,
      arguments: [epoch, unresolvedObservationContent]
    )
  }

  /// Whether this one run still owes the approval placeholder that the boot claimed-approval
  /// settlement writes. The per-run half of the same rule `settleAbandonedRuns` applies set-wide.
  static func owesUnresolvedFact(
    _ db: Database,
    runId: Int64,
    unresolvedObservationContent: String
  ) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: "SELECT \(owedFactExists(runColumn: "?"))",
      arguments: [runId, unresolvedObservationContent]
    ) ?? false
  }

  /// The one spelling of "this run still owes an approval placeholder", so the per-run disposition
  /// and the set-level backstop cannot disagree about the row shape. They are two halves of one
  /// rule: were they to drift, the orphan sweep would defer a run that the very same transaction's
  /// backstop then freezes, admitting a later observation fill against frozen evidence.
  ///
  /// `runColumn` is the SQL expression naming the run; the fragment binds `runColumn`'s arguments
  /// first (none, unless it is itself a `?`) and then the placeholder body.
  private static func owedFactExists(runColumn: String) -> String {
    """
    EXISTS (
      SELECT 1 FROM messages
      WHERE messages.run_id = \(runColumn)
        AND messages.role = '\(MessageRole.tool.rawValue)'
        AND messages.content = ?
    )
    """
  }
}

// MARK: - Binding Lookups

private extension ScheduledLearningStoreGRDB {
  static func isBound(_ db: Database, runId: Int64) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS(SELECT 1 FROM run_learning_bindings WHERE run_id = ?)",
      arguments: [runId]
    ) ?? false
  }
}
