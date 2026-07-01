import ClawWorkspace
import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

@Suite("ContextBuilder")
struct ContextBuilderTests {
  @Test func assemblesSystemUntrustedAndHistoryInTheRequiredOrder() throws {
    // given
    let builder = makeBuilder(
      workspace: FakeWorkspace(
        files: [
          .soul: .present("soul text"),
          .agents: .present("agent rules"),
          .tools: .present("tool policy"),
          .user: .present("owner profile"),
          .memory: .present("curated memory"),
        ]
      )
    )
    let snapshot = SessionContextSnapshot(
      history: [
        StoredMessage(role: .user, content: "hello", provenance: .trusted),
        StoredMessage(role: .assistant, content: "hi", provenance: .trusted),
      ],
      historyMessageIds: [10, 11],
      windowStartMessageId: 0,
      isTainted: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42)

    // then
    #expect(result.messages.map(\.role) == [.system, .user, .user, .assistant])
    let system = result.messages[0].content
    #expect(system.contains("system policy"))
    #expect(system.contains("soul text"))
    #expect(system.contains("agent rules"))
    #expect(system.contains("tool policy"))
    #expect(system.contains("1970-01-01T00:00:00Z"))
    #expect(system.contains("owner profile") == false)

    let untrusted = result.messages[1].content
    #expect(untrusted.contains("label=\"USER.md\""))
    #expect(untrusted.contains("owner profile"))
    #expect(untrusted.contains("label=\"MEMORY.md\""))
    #expect(untrusted.contains("curated memory"))
    #expect(result.messages.dropFirst(2).map(\.content) == ["hello", "hi"])
    #expect(result.hasPrivateDataAccess)
    #expect(result.ownerNotices.isEmpty)
  }

  @Test func hardCapOverflowOmitsFileAndProducesOwnerNotice() throws {
    // given
    let builder = makeBuilder(
      workspace: FakeWorkspace(files: [.memory: .overCap(count: 2_201)])
    )
    let snapshot = SessionContextSnapshot(
      history: [],
      historyMessageIds: [],
      windowStartMessageId: 0,
      isTainted: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42)

    // then
    #expect(result.messages.count == 1)
    #expect(result.messages[0].role == .system)
    #expect(result.messages[0].content.contains("MEMORY.md") == false)
    #expect(
      result.ownerNotices == [
        "⚠ `MEMORY.md` is 2201/2200 — edit it to trim; left out this turn."
      ]
    )
    #expect(result.hasPrivateDataAccess == false)
  }

  @Test func taintedSnapshotExcludesHighSensitivityMemoryAndSetsPrivateAccessForInjectedItems()
    throws {
    // given
    let high = memory(id: 1, text: "secret", sensitivity: .high, importance: .high)
    let normal = memory(id: 2, text: "normal fact", sensitivity: .normal, importance: .normal)
    let memoryStore = FakeMemoryStore(items: [high, normal])
    let builder = makeBuilder(memoryStore: memoryStore)
    let snapshot = SessionContextSnapshot(
      history: [StoredMessage(role: .user, content: "question", provenance: .trusted)],
      historyMessageIds: [44],
      windowStartMessageId: 0,
      isTainted: true
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42)

    // then
    #expect(memoryStore.fetchRankedCalls == [true])
    let untrusted = try #require(result.messages.first { message in message.role == .user })
      .content
    #expect(untrusted.contains("normal fact"))
    #expect(untrusted.contains("secret") == false)
    #expect(result.hasPrivateDataAccess)
  }

  @Test func recallUsesLatestUserMessageAndExcludesCurrentHistoryIds() throws {
    // given
    let retriever = FakeRetriever(
      hits: [
        RecallHit(
          id: 90,
          sessionId: 2,
          role: .user,
          content: String(repeating: "r", count: 450),
          score: RecallScore(value: 10),
          createdAt: Date(timeIntervalSince1970: 90)
        )
      ]
    )
    let builder = makeBuilder(retriever: retriever)
    let snapshot = SessionContextSnapshot(
      history: [
        StoredMessage(role: .user, content: "first", provenance: .trusted),
        StoredMessage(role: .assistant, content: "answer", provenance: .trusted),
        StoredMessage(role: .user, content: "latest query", provenance: .trusted),
      ],
      historyMessageIds: [10, 11, 12],
      windowStartMessageId: 7,
      isTainted: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42)

    // then
    #expect(
      retriever.calls == [
        FakeRetriever.Call(
          query: "latest query",
          currentSessionId: 42,
          windowStartMessageId: 7,
          excludedMessageIds: [10, 11, 12],
          limit: 20
        )
      ]
    )
    let untrusted = try #require(result.messages.first { message in message.role == .user })
      .content
    #expect(untrusted.contains("label=\"recall\""))
    #expect(untrusted.contains(BudgetFitter.truncationMarker))
  }

  @Test func skillsRenderAsUntrustedIndexWithoutSettingPrivateAccess() throws {
    // given
    let builder = makeBuilder(
      workspace: FakeWorkspace(
        skills: [
          SkillDescriptor(
            name: "summarize",
            description: "Summarize owner-provided text.",
            directory: URL(fileURLWithPath: "/tmp/skills/summarize")
          )
        ]
      )
    )
    let snapshot = SessionContextSnapshot(
      history: [],
      historyMessageIds: [],
      windowStartMessageId: 0,
      isTainted: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42)

    // then
    let untrusted = try #require(result.messages.first { message in message.role == .user })
      .content
    #expect(untrusted.contains("label=\"skills\""))
    #expect(untrusted.contains("- summarize: Summarize owner-provided text."))
    #expect(result.hasPrivateDataAccess == false)
  }

  @Test func fittedHistoryKeepsNewestMessagesButRestoresChronology() throws {
    // given
    let budget = ContextBudget(
      inputCapGraphemes: 80,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 1,
      historyCap: 10,
      recallCap: 1,
      skillsCap: 1,
      recallHitCap: 1
    )
    let builder = makeBuilder(budget: budget)
    let snapshot = SessionContextSnapshot(
      history: [
        StoredMessage(role: .user, content: "old", provenance: .trusted),
        StoredMessage(role: .assistant, content: "middle", provenance: .trusted),
        StoredMessage(role: .user, content: "new", provenance: .trusted),
      ],
      historyMessageIds: [1, 2, 3],
      windowStartMessageId: 0,
      isTainted: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42)

    // then
    #expect(result.messages.suffix(2).map(\.content) == ["middle", "new"])
  }

  @Test func fittedHistoryDoesNotReAdmitOlderMessagesAfterOversizedMiddleMessage() throws {
    // given
    let budget = ContextBudget(
      inputCapGraphemes: 80,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 1,
      historyCap: 10,
      recallCap: 1,
      skillsCap: 1,
      recallHitCap: 1
    )
    let builder = makeBuilder(budget: budget)
    let snapshot = SessionContextSnapshot(
      history: [
        StoredMessage(role: .user, content: "o", provenance: .trusted),
        StoredMessage(role: .assistant, content: "oversized middle", provenance: .trusted),
        StoredMessage(role: .user, content: "newest", provenance: .trusted),
      ],
      historyMessageIds: [1, 2, 3],
      windowStartMessageId: 0,
      isTainted: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42)

    // then
    #expect(result.messages.suffix(1).map(\.content) == ["newest"])
    #expect(result.messages.contains(where: { message in message.content == "o" }) == false)
  }

  @Test func triggerMessageSurvivesWhenBudgetCannotFitIt() throws {
    // given
    let budget = ContextBudget(
      inputCapGraphemes: 60,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 1,
      historyCap: 4,
      recallCap: 1,
      skillsCap: 1,
      recallHitCap: 1
    )
    let builder = makeBuilder(budget: budget)
    let snapshot = SessionContextSnapshot(
      history: [
        StoredMessage(role: .user, content: "what is the meaning of this", provenance: .trusted)
      ],
      historyMessageIds: [7],
      windowStartMessageId: 0,
      isTainted: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42)

    // then
    #expect(result.messages.last?.role == .user)
    #expect(result.messages.last?.content == "what is the meaning of this")
  }
}

private func makeBuilder(
  workspace: FakeWorkspace = FakeWorkspace(),
  memoryStore: FakeMemoryStore = FakeMemoryStore(),
  retriever: FakeRetriever = FakeRetriever(),
  budget: ContextBudget = .default
) -> ContextBuilder {
  ContextBuilder(
    systemPrompt: "system policy",
    workspace: workspace,
    memoryStore: memoryStore,
    retriever: retriever,
    recallCutoff: CandidateCapRecallCutoff(),
    budget: budget,
    now: { Date(timeIntervalSince1970: 0) }
  )
}

private func memory(
  id: Int64,
  text: String,
  sensitivity: Sensitivity = .normal,
  importance: Importance
) -> MemoryItem {
  MemoryItem(
    id: id,
    text: text,
    kind: .project,
    sensitivity: sensitivity,
    importance: importance,
    source: .owner,
    sessionId: nil,
    createdAt: Date(timeIntervalSince1970: Double(id))
  )
}

private final class FakeWorkspace: WorkspaceReading, @unchecked Sendable {
  enum FileState {
    case present(String)
    case overCap(count: Int)

    var loadedFile: LoadedFile {
      switch self {
      case .present(let text):
        LoadedFile(outcome: .present, text: text, graphemeCount: text.count)
      case .overCap(let count):
        LoadedFile(outcome: .overCap, text: "", graphemeCount: count)
      }
    }
  }

  private let files: [WorkspaceFile: FileState]
  private let skills: [SkillDescriptor]

  init(files: [WorkspaceFile: FileState] = [:], skills: [SkillDescriptor] = []) {
    self.files = files
    self.skills = skills
  }

  func load(file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
    files[file]?.loadedFile ?? .missing
  }

  func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile {
    .missing
  }

  func scanSkills() -> SkillScanResult {
    SkillScanResult(descriptors: skills, warnings: [])
  }
}

private final class FakeMemoryStore: MemoryStore, @unchecked Sendable {
  private let items: [MemoryItem]
  private(set) var fetchRankedCalls: [Bool] = []

  init(items: [MemoryItem] = []) {
    self.items = items
  }

  func append(_ newItem: NewMemoryItem, now: Date) throws -> MemoryItem {
    throw StoreError.unexpected("not used")
  }

  func list(kind: MemoryKind?, limit: Int) throws -> [MemoryItem] { [] }
  func get(id: Int64) throws -> MemoryItem? { nil }
  func delete(id: Int64) throws -> Bool { false }

  func fetchRanked(excludeSensitive: Bool, limit: Int) throws -> [MemoryItem] {
    fetchRankedCalls.append(excludeSensitive)
    return Array(items.prefix(limit))
  }
}

private final class FakeRetriever: Retriever, @unchecked Sendable {
  struct Call: Sendable, Equatable {
    let query: String
    let currentSessionId: Int64
    let windowStartMessageId: Int64?
    let excludedMessageIds: [Int64]
    let limit: Int
  }

  private let hits: [RecallHit]
  private(set) var calls: [Call] = []

  init(hits: [RecallHit] = []) {
    self.hits = hits
  }

  func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws -> [RecallHit] {
    calls.append(
      Call(
        query: query,
        currentSessionId: currentSessionId,
        windowStartMessageId: windowStartMessageId,
        excludedMessageIds: excludedMessageIds,
        limit: limit
      )
    )
    return Array(hits.prefix(limit))
  }
}
