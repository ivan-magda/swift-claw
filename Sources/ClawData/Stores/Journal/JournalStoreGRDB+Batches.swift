import ClawCore
import Foundation
import GRDB

// MARK: - Atomic Admission

extension JournalStoreGRDB {
  public func startBatch(
    _ request: JournalStartRequest,
    now: Date
  ) throws(StoreError) -> JournalStartOutcome {
    try database.writeMapping { db in
      let selectionIsCurrent = try Self.selectionIsCurrent(db, request: request, now: now)
      guard selectionIsCurrent else {
        return .obsolete
      }

      try Self.markDayDue(db, ownerUserID: request.scope.ownerUserID, day: request.day)
      let startedCallCount =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM journal_batches WHERE started_ts >= ? AND started_ts < ?
            """,
          arguments: [now.startOfUTCDay, now.startOfUTCDay.addingTimeInterval(86_400)]
        ) ?? 0
      guard startedCallCount < JournalLimits.startedCallsPerUTCDay else {
        return .deferred(cap: Self.startedCallsCap)
      }

      let dayUsage = try UsageStoreGRDB.dayTotals(db, now: now)
      let unaccountedUsage = try Self.unaccountedUsage(db)
      let budgetDecision = BudgetGate(budget: request.budget, costPolicy: request.costPolicy)
        .preflight(
          todayTokens: dayUsage.tokens + unaccountedUsage.tokens,
          todayUSD: dayUsage.costUSD + unaccountedUsage.costUSD,
          estimatedTotalTokens: request.estimate.totalTokens,
          estimatedCostUSD: request.estimate.costUSD
        )
      if case .deny(let cap) = budgetDecision {
        return .deferred(cap: cap)
      }

      let batch = JournalBatch(
        id: UUID(),
        sourceIDs: request.sourceIDs,
        scope: request.scope,
        day: request.day,
        sessionID: request.sessionID,
        providerCallID: request.providerCallID
      )
      try db.execute(
        sql: """
          INSERT INTO journal_batches(id, owner_user_id, day, batch, provider_call_id,
            saved_usage, started_ts, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          batch.id.uuidString,
          batch.scope.ownerUserID,
          batch.day.isoDate,
          try JSONEncoder().encode(batch),
          batch.providerCallID.rawValue,
          try JSONEncoder().encode(SavedUsage(request.conservativeUsage)),
          now,
          BatchState.started.rawValue,
        ]
      )
      for sourceID in batch.sourceIDs {
        try db.execute(
          sql: "UPDATE journal_sources SET state = ?, batch_id = ? WHERE source_id = ?",
          arguments: [SourceState.started.rawValue, batch.id.uuidString, sourceID]
        )
      }
      return .started(batch)
    }
  }

  public func finishBatch(
    id: UUID,
    outcome: JournalOutcome,
    usage: ProviderUsage?,
    now: Date
  ) throws(StoreError) {
    try database.writeMapping { db in
      let batchRow = try Self.batchRow(db, id: id)
      guard let batchRow else {
        return
      }
      let batch = try Self.decodeBatch(batchRow)
      if let usage {
        guard usage.providerCallID == batch.providerCallID, usage.runID == nil,
              usage.sessionID == batch.sessionID, usage.learningScope == nil
        else {
          throw StoreError.unexpected("journal usage does not match its batch")
        }
        _ = try RunStoreGRDB.insertUsage(db, usage)
      }

      let batchState: String = batchRow["state"]
      guard batchState != BatchState.finished.rawValue else {
        return
      }
      let terminalOutcome: JournalOutcome =
        batchState == BatchState.cancelled.rawValue ? .cancelled : outcome
      try Self.closeBatch(db, batch: batch, outcome: terminalOutcome, now: now, interrupted: 0)
    }
  }

  public func reconcileAtBoot(now: Date) throws(StoreError) {
    try database.writeMapping { db in
      let unfinishedBatchRows = try Row.fetchAll(
        db,
        sql: "SELECT * FROM journal_batches WHERE state IN (?, ?)",
        arguments: [BatchState.started.rawValue, BatchState.cancelled.rawValue]
      )
      for batchRow in unfinishedBatchRows {
        let batch = try Self.decodeBatch(batchRow)
        let conservativeUsage = try Self.decodeSavedUsage(batchRow).row(batch: batch)
        _ = try RunStoreGRDB.insertUsage(db, conservativeUsage)

        let batchState: String = batchRow["state"]
        let terminalOutcome: JournalOutcome =
          batchState == BatchState.cancelled.rawValue ? .cancelled : .interrupted
        try Self.closeBatch(db, batch: batch, outcome: terminalOutcome, now: now, interrupted: 1)
      }
    }
  }
}

// MARK: - Batch Transactions

private extension JournalStoreGRDB {
  static func selectionIsCurrent(
    _ db: Database,
    request: JournalStartRequest,
    now: Date
  ) throws -> Bool {
    guard !request.sourceIDs.isEmpty, request.sourceIDs.count <= JournalLimits.batchSources,
          Set(request.sourceIDs).count == request.sourceIDs.count,
          request.conservativeUsage.providerCallID == request.providerCallID,
          request.conservativeUsage.runID == nil, request.conservativeUsage.learningScope == nil,
          request.conservativeUsage.sessionID == request.sessionID
    else {
      return false
    }

    var hasDueDay = false
    for sourceID in request.sourceIDs {
      let sourceRow = try Row.fetchOne(
        db,
        sql: """
          SELECT * FROM journal_sources WHERE source_id = ? AND state = ?
          """,
        arguments: [sourceID, SourceState.pending.rawValue]
      )
      guard let sourceRow else {
        return false
      }
      let source = try decodeSource(sourceRow)
      guard source.scope.ownerUserID == request.scope.ownerUserID, source.day == request.day else {
        return false
      }

      let sourceRemainsPending = try keepPending(db, source: source, now: now)
      guard sourceRemainsPending else {
        return false
      }
      let sourceDayIsDue = try dayIsDue(db, source: source, now: now)
      if sourceDayIsDue {
        hasDueDay = true
      }
    }
    return hasDueDay
  }

  static func batchRow(_ db: Database, id: UUID) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: "SELECT * FROM journal_batches WHERE id = ?",
      arguments: [id.uuidString]
    )
  }

  static func decodeBatch(_ row: Row) throws -> JournalBatch {
    try JSONDecoder().decode(JournalBatch.self, from: row["batch"])
  }

  static func decodeSavedUsage(_ row: Row) throws -> SavedUsage {
    try JSONDecoder().decode(SavedUsage.self, from: row["saved_usage"])
  }

  static func closeBatch(
    _ db: Database,
    batch: JournalBatch,
    outcome: JournalOutcome,
    now: Date,
    interrupted: Int
  ) throws {
    try recordStatus(
      db,
      ownerUserID: batch.scope.ownerUserID,
      outcome: outcome,
      now: now,
      skipped: 0,
      interrupted: interrupted
    )
    try db.execute(
      sql: "UPDATE journal_batches SET state = ?, outcome = ? WHERE id = ?",
      arguments: [
        BatchState.finished.rawValue,
        try JSONEncoder().encode(outcome),
        batch.id.uuidString,
      ]
    )
    try db.execute(
      sql: "UPDATE journal_sources SET state = ?, payload = NULL WHERE batch_id = ?",
      arguments: [SourceState.closed.rawValue, batch.id.uuidString]
    )
  }

  static func unaccountedUsage(_ db: Database) throws -> (tokens: Int, costUSD: Double) {
    let unaccountedBatchRows = try Row.fetchAll(
      db,
      sql: """
        SELECT b.saved_usage FROM journal_batches b LEFT JOIN provider_usage u
          ON u.provider_call_id = b.provider_call_id
        WHERE b.state IN (?, ?) AND u.id IS NULL
        """,
      arguments: [BatchState.started.rawValue, BatchState.cancelled.rawValue]
    )
    var tokens = 0
    var costUSD = 0.0
    for batchRow in unaccountedBatchRows {
      let savedUsage = try decodeSavedUsage(batchRow)
      tokens += savedUsage.promptTokens + savedUsage.completionTokens
      costUSD += savedUsage.costUSD
    }
    return (tokens, costUSD)
  }
}

// MARK: - Saved Conservative Accounting

private struct SavedUsage: Codable {
  let model: String
  let promptTokens: Int
  let completionTokens: Int
  let costUSD: Double
  let costSource: String
  let isEstimated: Bool
  let ts: Date

  init(_ usage: ProviderUsage) {
    model = usage.model
    promptTokens = usage.promptTokens
    completionTokens = usage.completionTokens
    costUSD = usage.costUSD
    costSource = usage.costSource.rawValue
    isEstimated = usage.isEstimated
    ts = usage.ts
  }

  func row(batch: JournalBatch) throws -> ProviderUsage {
    guard let usageCostSource = CostSource(rawValue: costSource) else {
      throw StoreError.unexpected("journal saved usage has invalid cost source")
    }
    return ProviderUsage(
      providerCallID: batch.providerCallID,
      runID: nil,
      sessionID: batch.sessionID,
      model: model,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      costUSD: costUSD,
      costSource: usageCostSource,
      isEstimated: isEstimated,
      ts: ts
    )
  }
}
