import ClawTestSupport
import ClawWorkspace
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite
struct JournalContextTests {
  @Test
  func recentDaysKeepNewestNotesAfterHigherPriorityRows() throws {
    // given — midnight after Berlin's 23-hour spring transition.
    let root = try makeTemporaryRoot(prefix: "journal-context")
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let files = FileSystemJournalFiles(root: root)
    let today = try #require(JournalDay(isoDate: "2026-03-30"))
    let yesterday = try #require(JournalDay(isoDate: "2026-03-29"))
    try files.append(
      day: today,
      text: "oldestDroppedNote" + String(repeating: "я", count: 5_000)
        + "todaysNewestNote"
    )
    try files.append(day: yesterday, text: "yesterdaysNewestNote")
    let instant = try #require(ISO8601DateFormatter().date(from: "2026-03-29T22:15:00Z"))
    let curatedText = "curated memory " + String(repeating: "m", count: 100)
    let item = MemoryItem(
      id: 1,
      text: curatedText,
      kind: .project,
      sensitivity: .normal,
      importance: .normal,
      source: .owner,
      sessionID: nil,
      createdAt: instant
    )
    let builder = makeBuilder(
      files: files,
      instant: instant,
      inputCap: 800,
      memoryStore: FakeMemoryStore(items: [item])
    )

    // when
    let result = try builder.assemble(snapshot: snapshot(), sessionID: 42, origin: .interactive)
    let text = result.messages.map(\.content.text).joined()
    let generous = try makeBuilder(files: files, instant: instant).assemble(
      snapshot: snapshot(),
      sessionID: 42,
      origin: .interactive
    )
    try files.delete(day: today)
    let previousOnly = try builder.assemble(
      snapshot: snapshot(),
      sessionID: 42,
      origin: .interactive
    )

    // then — both the row cap and the later residual cut retain the latest conclusion.
    #expect(text.contains("todaysNewestNote"))
    #expect(text.contains("oldestDroppedNote") == false)
    #expect(text.contains("2026-03-30"))
    #expect(text.contains(TextTruncation.marker))
    #expect(text.contains("current question"))
    #expect(text.contains(curatedText))
    #expect(text.contains("archive answer") == false)
    #expect(generous.messages.map(\.content.text).joined().contains("oldestDroppedNote") == false)
    #expect(previousOnly.messages.map(\.content.text).joined().contains("yesterdaysNewestNote"))
    #expect(previousOnly.messages.map(\.content.text).joined().contains("2026-03-29"))
  }

  @Test
  func journalPreservesCleanTurnAndSensitiveMemory() throws {
    // given
    let root = try makeTemporaryRoot(prefix: "journal-context")
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let files = FileSystemJournalFiles(root: root)
    try files.append(day: JournalDay.containing(.distantPast, timeZone: .gmt), text: "journal note")
    let memory = MemoryItem(
      id: 1,
      text: "highSensitivityMemory",
      kind: .project,
      sensitivity: .high,
      importance: .normal,
      source: .owner,
      sessionID: nil,
      createdAt: .distantPast
    )
    let builder = makeBuilder(files: files, memoryStore: FakeMemoryStore(items: [memory]))

    // when
    let result = try builder.assemble(snapshot: snapshot(), sessionID: 42, origin: .interactive)
    let text = result.messages.map(\.content.text).joined()
    let journalOnly = try makeBuilder(files: files).assemble(
      snapshot: snapshot(history: []),
      sessionID: 42,
      origin: .interactive
    )

    // then
    #expect(text.contains("journal note"))
    #expect(text.contains("highSensitivityMemory"))
    #expect(text.contains("archive answer"))
    #expect(text.contains("label=\"journal\""))
    #expect(journalOnly.hasPrivateDataAccess)
    #expect(result.hasPinnedLessons == false)
    #expect(
      TurnTrust(
        session: SessionTrust(isTainted: false, hasPrivateData: false),
        context: result,
        toolDefinitions: []
      ).ingestedUntrusted == false
    )
  }

  @Test
  func failedDayReadsNotifyOwnerWhileMissingDaysStayQuiet() throws {
    // given
    let root = try makeTemporaryRoot(prefix: "journal-context")
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let directory = root.appendingPathComponent("memory")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let instant = try #require(ISO8601DateFormatter().date(from: "2026-03-29T22:15:00Z"))
    let files = FileSystemJournalFiles(root: root)
    let builder = makeBuilder(files: files, instant: instant)
    let missing = try builder.assemble(snapshot: snapshot(), sessionID: 42, origin: .interactive)
    try Data(repeating: 65, count: JournalLimits.dayFileBytes + 1).write(
      to: directory.appendingPathComponent("2026-03-30.md")
    )
    try Data([0xFF]).write(to: directory.appendingPathComponent("2026-03-29.md"))

    // when
    let failed = try builder.assemble(snapshot: snapshot(), sessionID: 42, origin: .interactive)

    // then
    #expect(missing.ownerNotices.isEmpty)
    #expect(failed.ownerNotices.count == 2)
    #expect(
      failed.ownerNotices.contains {
        $0.contains("2026-03-30")
      }
    )
    #expect(
      failed.ownerNotices.contains {
        $0.contains("2026-03-29")
      }
    )
    #expect(failed.hasPrivateDataAccess == false)
  }

  @Test(arguments: ["disabled", "nonowner", "scheduled"])
  func excludedScopeDoesNotReadJournal(scope: String) throws {
    // given
    let policy = JournalPolicy(
      enabled: scope != "disabled",
      ownerUserID: 42,
      timeZoneID: "UTC"
    )
    let key = SessionKey.telegramDM(chatID: scope == "nonowner" ? 43 : 42)
    let origin: RunOrigin = scope == "scheduled" ? .scheduled : .interactive
    let builder = makeBuilder(files: ForbiddenJournalReads(), policy: policy)

    // when
    let result = try builder.assemble(snapshot: snapshot(key: key), sessionID: 42, origin: origin)

    // then
    #expect(result.messages.map(\.content.text).joined().contains("journal note") == false)
  }
}

// MARK: - Fixtures

private extension JournalContextTests {
  func makeBuilder(
    files: any JournalFiles,
    policy: JournalPolicy = JournalPolicy(
      enabled: true,
      ownerUserID: 42,
      timeZoneID: "Europe/Berlin"
    ),
    instant: Date = .distantPast,
    inputCap: Int = 20_000,
    memoryStore: FakeMemoryStore = FakeMemoryStore()
  ) -> ContextBuilder {
    ContextBuilder(
      systemPrompt: "policy",
      workspace: FakeWorkspace(),
      memoryStore: memoryStore,
      retriever: JournalRetriever(),
      budget: ContextBudget(
        inputCapGraphemes: inputCap,
        userFileCap: 100,
        memoryFileCap: 100,
        itemsCap: 200,
        historyCap: 200,
        recallCap: 200,
        skillsCap: 0,
        recallHitCap: 200
      ),
      journalFiles: files,
      journalPolicy: policy,
      now: {
        instant
      }
    )
  }

  func snapshot(
    key: String = SessionKey.telegramDM(chatID: 42),
    history: [StoredMessage] = [
      StoredMessage(role: .user, content: "current question", provenance: .trusted),
    ]
  ) -> SessionContextSnapshot {
    SessionContextSnapshot(
      sessionKey: key,
      history: history,
      historyMessageIDs: [],
      windowStartMessageID: 0,
      isTainted: false,
      hasPrivateData: false
    )
  }
}

private struct JournalRetriever: Retriever {
  func searchRelevantMessages(
    query: String,
    currentSessionID: Int64,
    restrictToSessionID: Int64?,
    windowStartMessageID: Int64?,
    excludedMessageIDs: [Int64],
    limit: Int
  ) throws(StoreError) -> [RecallHit] {
    [
      RecallHit(
        id: 1,
        sessionID: 1,
        role: .assistant,
        content: "archive answer",
        score: RecallScore(value: 1),
        createdAt: .distantPast
      ),
    ]
  }
}

private struct ForbiddenJournalReads: JournalFiles {
  func load(day: JournalDay) -> JournalFileSnapshot {
    Issue.record("Excluded scope performed journal IO")
    return JournalFileSnapshot(day: day, text: "journal note", outcome: .present)
  }

  func append(day: JournalDay, text: String) throws {}
  func delete(day: JournalDay) throws {}
  func recentDays(limit: Int) throws -> [JournalDay] {
    []
  }
}
