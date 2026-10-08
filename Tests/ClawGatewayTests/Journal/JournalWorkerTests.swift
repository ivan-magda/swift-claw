import ClawCore
import ClawTestSupport
import ClawWorkspace
import Foundation
import GRDB
import Logging
import Synchronization
import Testing

@testable import ClawData
@testable import ClawGateway

@Suite
struct JournalWorkerTests {
  @Test
  func overlappingTriggersDrainOnceAndKeepLeftoversDue() async throws {
    // given
    let fixture = try JournalWorkerFixture()
    defer {
      fixture.removeFiles()
    }
    let due = try fixture.seed(count: 23, at: fixture.now.addingTimeInterval(-86_400))
    let entered = AsyncGate()
    let release = AsyncGate()
    defer {
      release.open()
    }
    let calls = Mutex((active: 0, maximum: 0))
    let provider = SequenceProvider(
      Array(repeating: fixture.response, count: 24),
      beforeResponse: {
        calls.withLock { state in
          state.active += 1
          state.maximum = max(state.maximum, state.active)
        }
        entered.open()
        await release.waitIgnoringCancellation()
        calls.withLock { state in
          state.active -= 1
        }
      }
    )
    let worker = fixture.worker(provider: provider, inputCap: 1800)
    worker.notifyPending()
    #expect(await provider.requests.isEmpty)

    // when
    let first = Task {
      await worker.sweep(now: fixture.now)
    }
    defer {
      first.cancel()
    }
    guard await entered.waitUntilOpen() else {
      Issue.record("Provider did not start")
      return
    }
    try await fixture.queue.write { db in
      try JournalStoreGRDB.markPendingSourcesDue(db, ownerUserID: 42, sessionID: fixture.sessionID)
    }
    let today = try fixture.seed(count: 2, at: fixture.now, firstID: 100)
    worker.notifyPending()
    let second = Task {
      await worker.sweep(now: fixture.now)
    }
    defer {
      second.cancel()
    }
    release.open()
    await first.value
    await second.value
    await worker.shutdown()
    let restarted = fixture.worker(provider: provider)
    try fixture.store.reconcileAtBoot(now: fixture.now)
    await restarted.sweep(now: fixture.now)
    await restarted.shutdown()

    // then
    let batches = try fixture.batches()
    #expect(
      calls.withLock {
        $0.maximum
      } == 1
    )
    #expect(Set(batches.flatMap(\.sourceIDs)) == Set(due.map(\.id)))
    #expect(
      batches.contains {
        $0.sourceIDs.count < JournalLimits.batchSources
      }
    )
    #expect(try fixture.store.status(ownerUserID: 42, now: fixture.now).pendingCount == today.count)
    #expect(try fixture.store.pendingCount(day: today[0].day, ownerUserID: 42) == today.count)
    #expect(await provider.requests.count == batches.count)
  }

  enum Publication: CaseIterable {
    case written, damagedFile, cancelled, noStart
  }

  @Test(arguments: Publication.allCases)
  func publicationRechecksCancellationAndAlwaysFinishesUsage(branch: Publication) async throws {
    // given
    let fixture = try JournalWorkerFixture()
    defer {
      fixture.removeFiles()
    }
    let sources = try fixture.seed(count: 1, at: fixture.now.addingTimeInterval(-86_400))
    let day = sources[0].day
    let gate = WorkspaceMutationGate()
    let entered = AsyncGate()
    let release = AsyncGate()
    defer {
      release.open()
    }
    let response = ChatResponse(
      content: """
        ```json
        {"notes":[{"kind":"decision","attribution":"owner",
        "text":"Choose SQLite","source_ids":["message:1"]}]}
        ```
        """,
      finishReason: "stop",
      usage: ChatUsage(promptTokens: 123, completionTokens: 17, totalTokens: 140),
      costFromProvider: 0.01
    )
    let provider = SequenceProvider(
      branch == .noStart ? [] : [response],
      beforeResponse: {
        entered.open()
        await release.waitIgnoringCancellation()
      },
      then: ProviderFailure(
        cause: .terminal(status: nil, message: "Untrusted secret provider diagnostic"),
        accounting: .notStarted
      )
    )
    if branch == .damagedFile {
      try fixture.files.append(day: day, text: "Owner edits")
      try Data([0xFF]).write(to: fixture.root.appendingPathComponent("memory/\(day.isoDate).md"))
    }
    let worker = fixture.worker(provider: provider, gate: gate)
    let drain = Task {
      await worker.sweep(now: fixture.now)
    }
    defer {
      drain.cancel()
    }
    guard await entered.waitUntilOpen() else {
      Issue.record("Provider did not start")
      return
    }

    // when
    if branch == .cancelled {
      try await gate.perform {
        _ = try fixture.store.cancelDay(day, ownerUserID: 42, now: fixture.now)
        try fixture.files.delete(day: day)
      }
    }
    release.open()
    await drain.value
    await worker.shutdown()

    // then
    #expect(await provider.requests.count == 1)
    #expect(try fixture.store.status(ownerUserID: 42, now: fixture.now).pendingCount == 0)
    let usageCount = try await fixture.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provider_usage")
    }
    #expect(usageCount == (branch == .noStart ? 0 : 1))
    let status = try fixture.store.status(ownerUserID: 42, now: fixture.now)
    switch branch {
    case .written:
      #expect(status.lastOutcome == .written)
      #expect(fixture.files.load(day: day).text.contains("Choose SQLite"))
    case .damagedFile:
      #expect(status.lastOutcome == .failed(redactedReason: "Journal day file unreadable"))
      #expect(fixture.files.load(day: day).outcome == .unreadable)
    case .cancelled:
      #expect(status.lastOutcome == .cancelled)
      #expect(fixture.files.load(day: day).outcome == .missing)
    case .noStart:
      #expect(status.lastOutcome == .failed(redactedReason: "Journal summary provider failed"))
      #expect(fixture.files.load(day: day).outcome == .missing)
    }
  }

  @Test
  func deferredBudgetAndUnrepresentableSourcesDoNotSpin() async throws {
    // given
    let fixture = try JournalWorkerFixture()
    defer {
      fixture.removeFiles()
    }
    let sources = try fixture.seed(count: 2, at: fixture.now.addingTimeInterval(-86_400))
    let provider = SequenceProvider([])
    let deferred = fixture.worker(provider: provider, perRunUSD: 0)

    // when
    await deferred.sweep(now: fixture.now)
    await deferred.shutdown()
    let pendingAfterRefusal = try fixture.store.pendingSources(ownerUserID: 42, now: fixture.now)
    let impossible = fixture.worker(provider: provider, inputCap: 1)
    await impossible.sweep(now: fixture.now)
    await impossible.shutdown()

    // then
    #expect(pendingAfterRefusal.map(\.id) == sources.map(\.id))
    #expect(try fixture.batches().isEmpty)
    #expect(await provider.requests.isEmpty)
    let status = try fixture.store.status(ownerUserID: 42, now: fixture.now)
    #expect(status.pendingCount == 0)
    #expect(status.skippedCount == sources.count)
    #expect(status.lastRedactedError == "Journal source cannot fit request")
  }

}

struct JournalWorkerFixture {
  let queue: DatabaseQueue
  let root: URL
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let sessionID: Int64

  init() throws {
    queue = try TestDatabase.make()
    root = try makeTemporaryRoot(prefix: "journal-worker")
    let createdAt = now
    sessionID = try queue.write { db in
      try db.execute(
        sql: "INSERT INTO sessions(session_key, created_ts, updated_ts) VALUES (?, ?, ?)",
        arguments: [SessionKey.telegramDM(chatID: 42), createdAt, createdAt]
      )
      return db.lastInsertedRowID
    }
  }

  var store: JournalStoreGRDB {
    JournalStoreGRDB(writer: queue)
  }

  var files: FileSystemJournalFiles {
    FileSystemJournalFiles(root: root)
  }

  var response: ChatResponse {
    ChatResponse(
      content: "{\"notes\":[]}",
      finishReason: "stop",
      usage: ChatUsage(promptTokens: 123, completionTokens: 17, totalTokens: 140),
      costFromProvider: 0.01
    )
  }

  func removeFiles() {
    try? FileManager.default.removeItem(at: root)
  }

  func worker(
    provider: any LLMProvider,
    inputCap: Int = 24_000,
    perRunUSD: Double = 1,
    sweepClock: (any Clock<Duration>)? = nil,
    gate: WorkspaceMutationGate = WorkspaceMutationGate()
  ) -> JournalWorker {
    let binding = LLMRouteBinding(
      provider: provider,
      wireModel: "test-model",
      configuredReference: "test/test-model",
      costPolicy: .metered,
      reservationPolicy: .textOnly
    )
    let codec = JournalSummaryCodec(
      costResolver: CostResolver(priceTable: .empty, referenceUSDPerToken: 0.000_015),
      redact: {
        $0
      }
    )
    let clock = ScriptedClock { _ in
      await AsyncGate().wait()
      throw CancellationError()
    }
    return JournalWorker(
      ownerUserID: 42,
      store: store,
      files: files,
      mutationGate: gate,
      codec: codec,
      summarizer: JournalSummarizer(codec: codec, clock: clock),
      roster: ProviderRoster(primary: binding),
      budget: RunBudget(
        maxInputTokens: inputCap,
        maxOutputTokens: 500,
        wallClockDeadlineSeconds: 180,
        retryBudget: 2,
        perRunUSD: perRunUSD,
        perDayUSD: 10,
        proactivePerDayUSD: 1,
        referenceUSDPerToken: 0.000_015
      ),
      clock: sweepClock ?? clock,
      now: {
        now
      },
      logger: TestLog.silent
    )
  }

  func seed(count: Int, at activity: Date, firstID: Int = 1) throws -> [JournalSource] {
    let sources = try (firstID..<(firstID + count)).map { id in
      try JournalSource(
        id: "message:\(id)",
        scope: JournalScope(ownerUserID: 42, timeZoneID: id.isMultiple(of: 2) ? "UTC" : "GMT"),
        sessionID: sessionID,
        occurredAt: activity.addingTimeInterval(Double(id - firstID) / 1000),
        day: .containing(activity, timeZone: .gmt),
        ownerText: String(repeating: "Выбираем базу данных. ", count: 100),
        assistantText: String(repeating: "Нужны транзакции. ", count: 200),
        supportingProposal: nil,
        coderJobID: nil,
        evidence: []
      )
    }
    try queue.write { db in
      for source in sources {
        _ = try JournalStoreGRDB.insertSource(db, source: source)
      }
    }
    return sources
  }

  func usageCallIDs() throws -> [String] {
    try queue.read { db in
      try String.fetchAll(db, sql: "SELECT provider_call_id FROM provider_usage")
    }
  }

  func batches() throws -> [JournalBatch] {
    try queue.read { db in
      try Data.fetchAll(db, sql: "SELECT batch FROM journal_batches ORDER BY started_ts, id")
        .map {
          try JSONDecoder().decode(JournalBatch.self, from: $0)
        }
    }
  }
}
