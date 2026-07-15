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
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42, origin: .interactive)

    // then
    #expect(result.messages.map(\.role) == [.system, .user, .user, .assistant])
    let system = result.messages[0].content
    #expect(system.contains("system policy"))
    #expect(system.contains("soul text"))
    #expect(system.contains("agent rules"))
    #expect(system.contains("tool policy"))
    #expect(system.contains("1970-01-01T00:00:00Z"))
    #expect(system.contains("owner profile") == false)
    #expect(system.contains("truncated") == false)

    let untrusted = result.messages[1].content
    #expect(untrusted.contains("label=\"USER.md\""))
    #expect(untrusted.contains("owner profile"))
    #expect(untrusted.contains("label=\"MEMORY.md\""))
    #expect(untrusted.contains("curated memory"))
    #expect(result.messages.dropFirst(2).map(\.content) == ["hello", "hi"])
    #expect(result.hasPrivateDataAccess)
    #expect(result.ownerNotices.isEmpty)
  }

  @Test func policyVersionFoldsTheStaticSubhashWithTheRawPromptMaterials() throws {
    // given — the RAW file texts (pre "## path" wrapping) fold into the injected static sub-hash
    let builder = makeBuilder(
      policyStaticSubhash: "static-sub-hash",
      workspace: FakeWorkspace(
        files: [
          .soul: .present("soul text"),
          .agents: .present("agent rules"),
          .tools: .present("tool policy"),
        ]
      )
    )
    let snapshot = SessionContextSnapshot(
      history: [],
      historyMessageIds: [],
      windowStartMessageId: 0,
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 1, origin: .interactive)

    // then — combined = first 16 hex over [staticSubhash, systemPrompt, soul, agents, tools]
    let expected = PolicyFingerprint.combined(
      staticSubhash: "static-sub-hash",
      promptMaterials: [
        "system policy", "proactive policy", "soul text", "agent rules", "tool policy",
      ]
    )
    #expect(result.policyVersion == expected)
    #expect(result.policyVersion.count == 16)
  }

  @Test func currentPolicyVersionMatchesTheAssembledFingerprint() throws {
    // given — the recompute seam (§6.3) must equal the value `assemble` produces, by construction
    let builder = makeBuilder(
      policyStaticSubhash: "sub",
      workspace: FakeWorkspace(
        files: [.soul: .present("s"), .agents: .present("a"), .tools: .present("t")]
      )
    )
    let snapshot = SessionContextSnapshot(
      history: [],
      historyMessageIds: [],
      windowStartMessageId: 0,
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let standalone = builder.currentPolicyVersion()
    let assembled = try builder.assemble(snapshot: snapshot, sessionId: 1, origin: .interactive)
      .policyVersion

    // then
    #expect(standalone == assembled)
  }

  @Test func missingPromptFilesFoldInAsEmpty() {
    // given — no workspace files; only the systemPrompt contributes to class 1
    let builder = makeBuilder(policyStaticSubhash: "sub", workspace: FakeWorkspace(files: [:]))

    // when
    let version = builder.currentPolicyVersion()

    // then — missing/unreadable files hash as "" (spec §3.2)
    #expect(
      version
        == PolicyFingerprint.combined(
          staticSubhash: "sub",
          promptMaterials: ["system policy", "proactive policy", "", "", ""]
        )
    )
  }

  @Test func editingAPromptFileChangesThePolicyVersion() {
    // given / when — a strict-inequality voider (§3.2)
    let before = makeBuilder(
      policyStaticSubhash: "sub",
      workspace: FakeWorkspace(files: [.soul: .present("v1")])
    ).currentPolicyVersion()
    let after = makeBuilder(
      policyStaticSubhash: "sub",
      workspace: FakeWorkspace(files: [.soul: .present("v2")])
    ).currentPolicyVersion()

    // then
    #expect(before != after)
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
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42, origin: .interactive)

    // then
    #expect(result.messages.count == 1)
    #expect(result.messages[0].role == .system)
    #expect(result.messages[0].content.contains("MEMORY.md") == false)
    #expect(result.ownerNotices.count == 1)
    let notice = try #require(result.ownerNotices.first)
    #expect(notice.contains("MEMORY.md"))  // which file to trim
    // actual/cap graphemes — the load-bearing overflow figure
    #expect(notice.contains("2201/2200"))
    #expect(result.hasPrivateDataAccess == false)
  }

  @Test
  func taintedSnapshotExcludesHighSensitivityMemoryAndSetsPrivateAccessForInjectedItems() throws {
    // given
    let high = memory(id: 1, text: "secret", sensitivity: .high, importance: .high)
    let normal = memory(id: 2, text: "normal fact", sensitivity: .normal, importance: .normal)
    let memoryStore = FakeMemoryStore(items: [high, normal])
    let builder = makeBuilder(memoryStore: memoryStore)
    let snapshot = SessionContextSnapshot(
      history: [StoredMessage(role: .user, content: "question", provenance: .trusted)],
      historyMessageIds: [44],
      windowStartMessageId: 0,
      isTainted: true,
      hasPrivateData: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42, origin: .interactive)

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
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42, origin: .interactive)

    // then
    #expect(retriever.calls.count == 1)
    let call = try #require(retriever.calls.first)
    #expect(call.query == "latest query")  // the latest user message, not older history
    #expect(call.currentSessionId == 42)
    #expect(call.windowStartMessageId == 7)
    #expect(call.excludedMessageIds == [10, 11, 12])  // current history excluded from recall
    // the recall candidate limit from its source of truth, not the literal 20
    #expect(call.limit == ContextBuilder.recallCandidateLimit)
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
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42, origin: .interactive)

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
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42, origin: .interactive)

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
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42, origin: .interactive)

    // then
    #expect(result.messages.suffix(1).map(\.content) == ["newest"])
    #expect(result.messages.contains(where: { message in message.content == "o" }) == false)
    #expect(result.messages[0].content.contains("[…earlier conversation truncated]"))
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
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42, origin: .interactive)

    // then
    #expect(result.messages.last?.role == .user)
    #expect(result.messages.last?.content == "what is the meaning of this")
  }

  @Test(arguments: [RunOrigin.scheduled, RunOrigin.heartbeat])
  func proactiveOriginSelectsTheProactivePromptAndSkipsRecall(origin: RunOrigin) throws {
    // given — recall hits that a proactive run must never consult
    let retriever = FakeRetriever(
      hits: [
        RecallHit(
          id: 90,
          sessionId: 2,
          role: .user,
          content: "owner DM about arming this schedule",
          score: RecallScore(value: 10),
          createdAt: Date(timeIntervalSince1970: 90)
        )
      ]
    )
    let builder = makeBuilder(retriever: retriever)
    let snapshot = SessionContextSnapshot(
      history: [
        StoredMessage(role: .user, content: "follow the tournament daily", provenance: .trusted)
      ],
      historyMessageIds: [10],
      windowStartMessageId: 0,
      isTainted: false,
      hasPrivateData: false
    )

    // when
    let result = try builder.assemble(snapshot: snapshot, sessionId: 42, origin: origin)

    // then — the proactive policy rides the system tier; the retriever is never consulted
    #expect(result.messages[0].content.contains("proactive policy"))
    #expect(result.messages[0].content.contains("system policy") == false)
    #expect(retriever.calls.isEmpty)
    #expect(
      result.messages.contains { message in
        message.content.contains("label=\"recall\"")
      } == false
    )
    #expect(result.messages.last?.content == "follow the tournament daily")
  }
}

// MARK: - Provider Replay State

extension ContextBuilderTests {
  /// Deliberately not valid UTF-8, so a renderer that stringified the blob into prompt text would
  /// leave detectable bytes behind rather than silently succeed.
  static let replayPayload = Data([0x00, 0xC3, 0x28, 0xFF, 0xFE])
  static let replayState = ProviderExchangeState(
    issuer: "openai-chatgpt-responses-v1:zzzsecretissuer",
    payload: replayPayload
  )

  /// A window whose assistant anchor proposed a tool call, ran it, and answered — one row of each
  /// kind the renderer can meet, with state on the anchors alone.
  private func statefulSnapshot() -> SessionContextSnapshot {
    SessionContextSnapshot(
      history: [
        StoredMessage(role: .user, content: "fetch the page", provenance: .trusted),
        StoredMessage(
          role: .assistant,
          content: "on it",
          provenance: .trusted,
          toolCallsJSON: #"[{"id":"c1","name":"web_fetch","arguments":"{}"}]"#,
          providerState: Self.replayState
        ),
        StoredMessage(
          role: .tool,
          content: "raw page text",
          provenance: .untrusted,
          toolCallId: "c1"
        ),
        StoredMessage(
          role: .assistant,
          content: "here is the summary",
          provenance: .trusted,
          providerState: Self.replayState
        ),
      ],
      historyMessageIds: [10, 11, 12, 13],
      windowStartMessageId: 0,
      isTainted: false,
      hasPrivateData: false
    )
  }

  @Test func assistantAnchorsCarryTheirProviderStateOntoTheWire() throws {
    // given
    let builder = makeBuilder()

    // when
    let result = try builder.assemble(
      snapshot: statefulSnapshot(),
      sessionId: 42,
      origin: .interactive
    )

    // then — the route that minted the state gets it back on exactly the messages it belongs to
    #expect(result.messages.map(\.role) == [.system, .user, .assistant, .tool, .assistant])
    #expect(result.messages[2].providerState == Self.replayState)
    #expect(result.messages[4].providerState == Self.replayState)
    for message in result.messages where message.role != .assistant {
      #expect(message.providerState == nil)
    }
  }

  @Test func providerStateNeverBecomesPromptContent() throws {
    // given — a retriever that would surface the same window text again, and a recall query drawn
    // from it, so every text-bearing seam of one assembly is covered at once
    let builder = makeBuilder(
      retriever: FakeRetriever(
        hits: [
          RecallHit(
            id: 99,
            sessionId: 2,
            role: .assistant,
            content: "an older answer",
            score: RecallScore(value: 10),
            createdAt: Date(timeIntervalSince1970: 0)
          )
        ]
      )
    )

    // when
    let result = try builder.assemble(
      snapshot: statefulSnapshot(),
      sessionId: 42,
      origin: .interactive
    )

    // then — the bytes are carried, never rendered: no message's text holds the issuer or the
    // payload, whatever tier it belongs to
    for message in result.messages {
      #expect(message.content.contains("zzzsecretissuer") == false)
      #expect(Data(message.content.utf8).range(of: Self.replayPayload) == nil)
    }
    #expect(result.messages.contains { message in message.content.contains("raw page text") })
    #expect(
      result.ownerNotices.allSatisfy { notice in notice.contains("zzzsecretissuer") == false }
    )
  }

  @Test func historyHygienePreservesTheStateOfAnAnchorItKeeps() throws {
    // given — the sanitizer is the last seam between a loaded row and the wire
    let history = statefulSnapshot().history

    // when
    let sanitized = HistoryHygiene.sanitize(history)

    // then
    #expect(sanitized.count == 4)
    #expect(sanitized[1].providerState == Self.replayState)
    #expect(sanitized[3].providerState == Self.replayState)
  }
}

private func makeBuilder(
  policyStaticSubhash: String = "",
  workspace: FakeWorkspace = FakeWorkspace(),
  memoryStore: FakeMemoryStore = FakeMemoryStore(),
  retriever: FakeRetriever = FakeRetriever(),
  budget: ContextBudget = .default
) -> ContextBuilder {
  ContextBuilder(
    systemPrompt: "system policy",
    proactiveSystemPrompt: "proactive policy",
    workspace: workspace,
    memoryStore: memoryStore,
    retriever: retriever,
    recallCutoff: CandidateCapRecallCutoff(),
    budget: budget,
    policyStaticSubhash: policyStaticSubhash,
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

  func append(_ newItem: NewMemoryItem, now: Date) throws(StoreError) -> MemoryItem {
    throw StoreError.unexpected("not used")
  }

  func list(kind: MemoryKind?, limit: Int) throws(StoreError) -> [MemoryItem] { [] }
  func get(id: Int64) throws(StoreError) -> MemoryItem? { nil }
  func delete(id: Int64) throws(StoreError) -> Bool { false }

  func fetchRanked(excludeSensitive: Bool, limit: Int) throws(StoreError) -> [MemoryItem] {
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
  ) throws(StoreError) -> [RecallHit] {
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
