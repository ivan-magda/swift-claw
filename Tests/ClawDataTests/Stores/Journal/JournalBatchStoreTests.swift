import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct JournalBatchStoreTests {
  enum Branch: CaseIterable {
    case threshold, endedDay, expired, budget, persistedBudget, reservedBudget, quota
  }

  @Test(arguments: Branch.allCases)
  func startDefersAndUsesUTCStartedCount(branch: Branch) throws {
    // given
    let queue = try TestDatabase.make()
    let store = JournalStoreGRDB(writer: queue)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = try makeSession(queue, now: now)
    let activity =
      branch == .expired
      ? now.addingTimeInterval(-Double(JournalLimits.pendingAgeSeconds) - 1)
      : (branch == .endedDay ? now.addingTimeInterval(-86_400) : now)
    let count = branch == .threshold ? JournalLimits.batchSources : 1
    let sources = try seed(queue, sessionID: sessionID, count: count, at: activity)
    if [.budget, .persistedBudget, .reservedBudget, .quota].contains(branch) {
      try queue.write { db in
        try JournalStoreGRDB.markPendingSourcesDue(db, ownerUserID: 42, sessionID: sessionID)
      }
    }
    if branch == .persistedBudget {
      let usage = row(
        callID: ProviderCallID(rawValue: "prior-interactive-call"),
        sessionID: sessionID,
        now: now,
        cost: RunBudget.default.perDayUSD
      )
      try queue.write { db in
        _ = try RunStoreGRDB.insertUsage(db, usage)
      }
    }
    if branch == .reservedBudget {
      let extra = try seed(queue, sessionID: sessionID, count: 1, at: now, firstID: 100)
      try queue.write { db in
        try JournalStoreGRDB.markPendingSourcesDue(db, ownerUserID: 42, sessionID: sessionID)
      }
      _ = try started(
        store.startBatch(request(extra, reservedCost: RunBudget.default.perDayUSD), now: now)
      )
    }
    if branch == .quota {
      for index in 0..<JournalLimits.startedCallsPerUTCDay {
        let extra = try seed(queue, sessionID: sessionID, count: 1, at: now, firstID: 100 + index)
        try queue.write { db in
          try JournalStoreGRDB.markPendingSourcesDue(db, ownerUserID: 42, sessionID: sessionID)
        }
        let batch = try started(store.startBatch(request(extra), now: now))
        if index.isMultiple(of: 2) {
          try store.finishBatch(
            id: batch.id,
            outcome: .empty,
            usage: row(callID: batch.providerCallID, sessionID: sessionID, now: now),
            now: now
          )
        }
      }
    }

    let originalPendingCount = try store.status(ownerUserID: 42, now: now).pendingCount

    // when
    let pending = try store.pendingSources(ownerUserID: 42, now: now)
    let outcome = try store.startBatch(
      request(sources, denied: branch == .budget),
      now: now
    )

    // then
    switch branch {
    case .threshold, .endedDay:
      #expect(Set(pending.map(\.id)) == Set(sources.map(\.id)))
      _ = try started(outcome)
    case .expired:
      #expect(pending.isEmpty)
      #expect(outcome == .obsolete)
      #expect(try store.status(ownerUserID: 42, now: now).skippedCount == 1)
    case .budget, .persistedBudget, .reservedBudget, .quota:
      guard case .deferred = outcome else {
        Issue.record("Expected deferral")
        return
      }
      let deferredStatus = try store.status(ownerUserID: 42, now: now)
      #expect(deferredStatus.pendingCount == originalPendingCount)
      #expect(try store.pendingSources(ownerUserID: 42, now: now).map(\.id) == sources.map(\.id))
      if branch == .quota {
        let localMidnight = now.startOfUTCDay.addingTimeInterval(21 * 60 * 60)
        // Istanbul's next day starts while the durable UTC quota remains full.
        let stillSameUTC = try store.startBatch(request(sources), now: localMidnight)
        guard case .deferred = stillSameUTC else {
          Issue.record("Local midnight must not reset the UTC quota")
          return
        }
        let startedCallsInUTCWindow = try queue.read { db in
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM journal_batches WHERE started_ts >= ?",
            arguments: [now.startOfUTCDay]
          )
        }
        #expect(startedCallsInUTCWindow == JournalLimits.startedCallsPerUTCDay)
        _ = try started(
          store.startBatch(
            request(sources),
            now: now.startOfUTCDay
              .addingTimeInterval(86_400)
          )
        )
      }
    }
  }

  @Test
  func partialBatchKeepsFrozenDayDueAndRejectsStaleSelection() throws {
    // given
    let queue = try TestDatabase.make()
    let store = JournalStoreGRDB(writer: queue)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = try makeSession(queue, now: now)
    let sources = try seed(queue, sessionID: sessionID, count: JournalLimits.batchSources, at: now)
    _ = try store.pendingSources(ownerUserID: 42, now: now)

    // when
    let batch = try started(store.startBatch(request(Array(sources.prefix(3))), now: now))
    let duplicate = try store.startBatch(request(Array(sources.prefix(3))), now: now)
    try store.finishBatch(
      id: batch.id,
      outcome: .written,
      usage: row(callID: batch.providerCallID, sessionID: sessionID, now: now),
      now: now
    )

    // then
    #expect(duplicate == .obsolete)
    #expect(
      try store.pendingSources(ownerUserID: 42, now: now).map(\.id)
        == Array(sources.dropFirst(3)).map(\.id)
    )
    #expect(
      try UsageStoreGRDB(writer: queue).todayTokensAndCost(
        origins: RunOrigin.proactiveOrigins,
        now: now
      ).costUSD == 0
    )
  }

  @Test
  func frozenTimezoneEndMakesTheWholeOwnerDayDue() throws {
    // given
    let queue = try TestDatabase.make()
    let store = JournalStoreGRDB(writer: queue)
    let formatter = ISO8601DateFormatter()
    let now = try #require(formatter.date(from: "2027-01-15T22:00:00Z"))
    let activity = try #require(formatter.date(from: "2027-01-15T16:00:00Z"))
    let day = try #require(JournalDay(isoDate: "2027-01-15"))
    let sessionID = try makeSession(queue, now: now)
    let sources = try ["America/New_York", "Europe/Istanbul"].enumerated().map { index, zone in
      try JournalSource(
        id: "message:\(index + 1)",
        scope: JournalScope(ownerUserID: 42, timeZoneID: zone),
        sessionID: sessionID,
        occurredAt: activity.addingTimeInterval(Double(index)),
        day: day,
        ownerText: "Choose SQLite",
        assistantText: "SQLite selected"
      )
    }
    try queue.write { db in
      for source in sources {
        _ = try JournalStoreGRDB.insertSource(db, source: source)
      }
    }

    // when
    let pending = try store.pendingSources(ownerUserID: 42, now: now)

    // then
    #expect(pending.map(\.id) == sources.map(\.id))
  }

  @Test
  func cancellationPreventsPublicationButStillChargesTheFinishedCallOnce() throws {
    // given
    let queue = try TestDatabase.make()
    let store = JournalStoreGRDB(writer: queue)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = try makeSession(queue, now: now)
    let sources = try seed(
      queue,
      sessionID: sessionID,
      count: 1,
      at: now.addingTimeInterval(-86_400)
    )
    let other = try seed(queue, sessionID: sessionID, count: 1, at: now, firstID: 50)
    let batch = try started(store.startBatch(request(sources), now: now))
    #expect(try store.canPublish(batchID: batch.id))
    #expect(try store.pendingCount(day: sources[0].day, ownerUserID: 42) == 1)

    // when
    let cancelled = try store.cancelDay(sources[0].day, ownerUserID: 42, now: now)
    let usage = row(callID: batch.providerCallID, sessionID: sessionID, now: now, cost: 0.2)
    try store.finishBatch(id: batch.id, outcome: .written, usage: usage, now: now)
    try store.finishBatch(id: batch.id, outcome: .written, usage: usage, now: now)

    // then
    #expect(cancelled == 1)
    #expect(try store.canPublish(batchID: batch.id) == false)
    #expect(try store.status(ownerUserID: 42, now: now).lastOutcome == .cancelled)
    #expect(try store.pendingCount(day: other[0].day, ownerUserID: 42) == 1)
    #expect(try usageRows(queue, callID: batch.providerCallID).count == 1)
    #expect(try UsageStoreGRDB(writer: queue).todayTokensAndCost(now: now).costUSD == 0.2)
  }

  @Test
  func bootClosesStartedWithoutReplay() throws {
    // given
    let root = try makeTemporaryRoot(prefix: "journal-boot")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("claw.sqlite").path
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let receipt = try abandonedBatch(path: path, now: now)

    // when
    let reopened = try ClawDatabase.makePool(path: path)
    let store = JournalStoreGRDB(writer: reopened)
    try store.reconcileAtBoot(now: now)
    try store.reconcileAtBoot(now: now)

    // then
    let reopenedPendingIDs = try store.pendingSources(ownerUserID: 42, now: now).map(\.id)
    let neverStartedIDs = receipt.pendingIDs
    #expect(reopenedPendingIDs == neverStartedIDs)
    #expect(try store.canPublish(batchID: receipt.batch.id) == false)
    let usageRowsForInterruptedCall = try usageRows(reopened, callID: receipt.batch.providerCallID)
    #expect(usageRowsForInterruptedCall.count == 1)
    #expect(usageRowsForInterruptedCall.first?["cost_usd"] == 0.1)
    #expect(try store.status(ownerUserID: 42, now: now).interruptedCount == 1)
    #expect(try store.pendingCount(day: .containing(now, timeZone: .gmt), ownerUserID: 42) == 1)
  }

  @Test
  func provenNoStartFinishesWithoutUsageAndRetainsTheQuotaReceiptAcrossBoot() throws {
    // given
    let root = try makeTemporaryRoot(prefix: "journal-no-start")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("claw.sqlite").path
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let batch = try finishedWithoutProviderStart(path: path, now: now)

    // when
    let reopened = try ClawDatabase.makePool(path: path)
    let store = JournalStoreGRDB(writer: reopened)
    try store.reconcileAtBoot(now: now)
    try store.reconcileAtBoot(now: now)

    // then
    #expect(try usageRows(reopened, callID: batch.providerCallID).isEmpty)
    #expect(try store.canPublish(batchID: batch.id) == false)
    #expect(try store.pendingCount(day: batch.day, ownerUserID: 42) == 0)
    let startedReceiptCount = try reopened.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM journal_batches WHERE provider_call_id = ?",
        arguments: [batch.providerCallID.rawValue]
      )
    }
    #expect(startedReceiptCount == 1)
  }

  @Test
  func sweepBoundsCandidatesAndPersistsSkipDiagnostics() throws {
    // given
    let queue = try TestDatabase.make()
    let store = JournalStoreGRDB(writer: queue)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = try makeSession(queue, now: now)
    let sources = try seed(
      queue,
      sessionID: sessionID,
      count: JournalLimits.sweepCandidates + 1,
      at: now.addingTimeInterval(-86_400)
    )

    // when
    let firstSweep = try store.pendingSources(ownerUserID: 42, now: now)
    try store.skipSources(ids: [sources[0].id], reason: "request cannot fit", now: now)

    // then
    #expect(firstSweep.count == JournalLimits.sweepCandidates)
    #expect(firstSweep.last?.id == "message:100")
    let status = try store.status(ownerUserID: 42, now: now)
    #expect(status.skippedCount == 1)
    #expect(status.lastRedactedError == "request cannot fit")
    #expect(status.pendingCount == JournalLimits.sweepCandidates)
  }
}

// MARK: - Real Journal Fixtures

private extension JournalBatchStoreTests {
  func makeSession(_ writer: any DatabaseWriter, now: Date) throws -> Int64 {
    try writer.write { db in
      try db.execute(
        sql: "INSERT INTO sessions(session_key, created_ts, updated_ts) VALUES (?, ?, ?)",
        arguments: [SessionKey.telegramDM(chatID: 42), now, now]
      )
      return db.lastInsertedRowID
    }
  }

  func seed(
    _ writer: any DatabaseWriter,
    sessionID: Int64,
    count: Int,
    at activityTime: Date,
    firstID: Int = 1
  ) throws -> [JournalSource] {
    let sources = try (firstID..<(firstID + count)).map { id in
      try JournalSource(
        id: "message:\(id)",
        scope: JournalScope(ownerUserID: 42, timeZoneID: "Europe/Istanbul"),
        sessionID: sessionID,
        occurredAt: activityTime.addingTimeInterval(Double(id - firstID) / 1000),
        day: .containing(
          activityTime,
          timeZone: try #require(TimeZone(identifier: "Europe/Istanbul"))
        ),
        ownerText: "Choose SQLite",
        assistantText: "SQLite selected"
      )
    }
    try writer.write { db in
      for source in sources {
        _ = try JournalStoreGRDB.insertSource(db, source: source)
      }
    }
    return sources
  }

  func row(callID: ProviderCallID, sessionID: Int64, now: Date, cost: Double = 0.1) -> ProviderUsage
  {
    ProviderUsage(
      providerCallID: callID,
      runID: nil,
      sessionID: sessionID,
      model: "test/model",
      promptTokens: 10,
      completionTokens: 20,
      costUSD: cost,
      costSource: .heuristic,
      isEstimated: true,
      ts: now
    )
  }

  func request(
    _ sources: [JournalSource],
    denied: Bool = false,
    reservedCost: Double = 0.1
  ) -> JournalStartRequest {
    let callID = ProviderCallID(rawValue: UUID().uuidString)
    return JournalStartRequest(
      sourceIDs: sources.map(\.id),
      scope: sources[0].scope,
      day: sources[0].day,
      sessionID: sources[0].sessionID,
      providerCallID: callID,
      estimate: .init(
        inputTokens: 10,
        totalTokens: 30,
        costUSD: denied ? 20 : 0.1,
        costSource: .heuristic
      ),
      conservativeUsage: row(
        callID: callID,
        sessionID: sources[0].sessionID,
        now: sources[0].occurredAt,
        cost: reservedCost
      ),
      budget: .default,
      costPolicy: .metered
    )
  }

  func started(_ outcome: JournalStartOutcome) throws -> JournalBatch {
    guard case .started(let batch) = outcome else {
      throw StoreError.unexpected("Expected started journal batch")
    }
    return batch
  }

  func usageRows(_ writer: any DatabaseWriter, callID: ProviderCallID) throws -> [Row] {
    try writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM provider_usage WHERE provider_call_id = ?",
        arguments: [callID.rawValue]
      )
    }
  }

  func finishedWithoutProviderStart(path: String, now: Date) throws -> JournalBatch {
    let pool = try ClawDatabase.makePool(path: path)
    try ClawDatabase.migrate(pool)
    let sessionID = try makeSession(pool, now: now)
    let sources = try seed(
      pool,
      sessionID: sessionID,
      count: 1,
      at: now.addingTimeInterval(-86_400)
    )
    let store = JournalStoreGRDB(writer: pool)
    let batch = try started(store.startBatch(request(sources), now: now))
    try store.finishBatch(
      id: batch.id,
      outcome: .failed(redactedReason: "request did not start"),
      usage: nil,
      now: now
    )
    return batch
  }

  func abandonedBatch(path: String, now: Date) throws -> (batch: JournalBatch, pendingIDs: [String])
  {
    let pool = try ClawDatabase.makePool(path: path)
    try ClawDatabase.migrate(pool)
    let sessionID = try makeSession(pool, now: now)
    let sources = try seed(
      pool,
      sessionID: sessionID,
      count: 2,
      at: now.addingTimeInterval(-86_400)
    )
    let store = JournalStoreGRDB(writer: pool)
    let batch = try started(store.startBatch(request([sources[0]]), now: now))
    _ = try seed(pool, sessionID: sessionID, count: 1, at: now, firstID: 50)
    return (batch, [sources[1].id])
  }
}
