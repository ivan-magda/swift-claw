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
    let system = result.messages[0].content.text
    #expect(system.contains("system policy"))
    #expect(system.contains("soul text"))
    #expect(system.contains("agent rules"))
    #expect(system.contains("tool policy"))
    #expect(system.contains("1970-01-01T00:00:00Z"))
    #expect(system.contains("owner profile") == false)
    #expect(system.contains("truncated") == false)

    let untrusted = result.messages[1].content.text
    #expect(untrusted.contains("label=\"USER.md\""))
    #expect(untrusted.contains("owner profile"))
    #expect(untrusted.contains("label=\"MEMORY.md\""))
    #expect(untrusted.contains("curated memory"))
    #expect(result.messages.dropFirst(2).map(\.content.text) == ["hello", "hi"])
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
    #expect(result.messages[0].content.text.contains("MEMORY.md") == false)
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
      .content.text
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
      .content.text
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
      .content.text
    #expect(untrusted.contains("label=\"skills\""))
    #expect(untrusted.contains("- summarize: Summarize owner-provided text."))
    // The model names a skill, never a path — printing one would invite it to type one back.
    #expect(untrusted.contains("/tmp/skills") == false)
    #expect(untrusted.contains("showing") == false)
    #expect(result.hasPrivateDataAccess == false)
    #expect(result.ownerNotices.isEmpty)
  }

  @Test func rejectedSkillManifestsSurfaceToTheOwnerAsNotices() throws {
    // given
    let builder = makeBuilder(
      workspace: FakeWorkspace(
        skills: [
          SkillDescriptor(
            name: "summarize",
            description: "Summarize owner-provided text.",
            directory: URL(fileURLWithPath: "/tmp/skills/summarize")
          )
        ],
        skillWarnings: [
          .invalidSkillManifest(skill: "no-frontmatter"),
          .invalidSkillName(directory: "Shouting", name: "Shouting"),
          .skillNameDirectoryMismatch(directory: "triage", name: "triage-mail"),
          .duplicateSkillName(name: "deploy", directories: ["deploy", "deploy-copy"]),
          .escapingSkillDirectory(directory: "linked-out"),
          .skillsDirectoryOutsideWorkspace,
          .unreadableSkillsDirectory,
        ]
      )
    )

    // when
    let result = try builder.assemble(
      snapshot: emptySnapshot(),
      sessionId: 42,
      origin: .interactive
    )

    // then — one notice per authoring fault; the I/O fault stays in the log
    #expect(result.ownerNotices.count == 6)
    #expect(result.ownerNotices[0].contains("`no-frontmatter`"))
    #expect(result.ownerNotices[1].contains("`Shouting`"))
    #expect(result.ownerNotices[2].contains("`triage-mail`"))
    #expect(result.ownerNotices[3].contains("`deploy-copy`"))
    #expect(result.ownerNotices[4].contains("`linked-out`"))
    #expect(result.ownerNotices[5].contains("all skills skipped"))
    let untrusted = try #require(result.messages.first { message in message.role == .user })
      .content.text
    #expect(untrusted.contains("- summarize: Summarize owner-provided text."))
  }

  @Test func skillsDroppedByTheBudgetAreNamedInAnOwnerNotice() throws {
    // given — the skills cap admits the first index line plus the drop marker, not the second
    let budget = ContextBudget(
      inputCapGraphemes: 4_000,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 1,
      historyCap: 1,
      recallCap: 1,
      skillsCap: 40,
      recallHitCap: 1
    )
    let builder = makeBuilder(
      workspace: FakeWorkspace(
        skills: [
          SkillDescriptor(
            name: "alpha",
            description: "one",
            directory: URL(fileURLWithPath: "/tmp/skills/alpha")
          ),
          SkillDescriptor(
            name: "bravo",
            description: String(repeating: "b", count: 31),
            directory: URL(fileURLWithPath: "/tmp/skills/bravo")
          ),
        ]
      ),
      budget: budget
    )

    // when
    let result = try builder.assemble(
      snapshot: emptySnapshot(),
      sessionId: 42,
      origin: .interactive
    )

    // then
    let untrusted = try #require(result.messages.first { message in message.role == .user })
      .content.text
    #expect(untrusted.contains("- alpha: one"))
    #expect(untrusted.contains("(showing 1 of 2 skills)"))
    #expect(result.ownerNotices.count == 1)
    let notice = try #require(result.ownerNotices.first)
    #expect(notice.contains("`bravo`"))
    #expect(notice.contains("`alpha`") == false)
  }

  @Test func aSkillsIndexTheBudgetCannotAffordAtAllStillReachesTheOwner() throws {
    // given — a cap that admits no index line at all, so the whole row leaves the prompt
    let budget = ContextBudget(
      inputCapGraphemes: 4_000,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 1,
      historyCap: 1,
      recallCap: 1,
      skillsCap: 0,
      recallHitCap: 1
    )
    let builder = makeBuilder(
      workspace: FakeWorkspace(
        skills: [
          SkillDescriptor(
            name: "alpha",
            description: "one",
            directory: URL(fileURLWithPath: "/tmp/skills/alpha")
          ),
          SkillDescriptor(
            name: "bravo",
            description: "two",
            directory: URL(fileURLWithPath: "/tmp/skills/bravo")
          ),
        ]
      ),
      budget: budget
    )

    // when
    let result = try builder.assemble(
      snapshot: emptySnapshot(),
      sessionId: 42,
      origin: .interactive
    )

    // then — a missing index reads as "every skill dropped", never as "no skills installed"
    let untrusted = result.messages.first { message in message.role == .user }?.content.text ?? ""
    #expect(untrusted.contains("label=\"skills\"") == false)
    let notice = try #require(result.ownerNotices.first)
    #expect(notice.contains("`alpha`"))
    #expect(notice.contains("`bravo`"))
  }

  @Test func rejectedSkillManifestsSurfaceEvenWhenTheIndexHasNoBudget() throws {
    // given — an authoring fault is the owner's to fix whether or not the index fit this turn
    let budget = ContextBudget(
      inputCapGraphemes: 4_000,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 1,
      historyCap: 1,
      recallCap: 1,
      skillsCap: 0,
      recallHitCap: 1
    )
    let builder = makeBuilder(
      workspace: FakeWorkspace(
        skillWarnings: [.invalidSkillManifest(skill: "no-frontmatter")]
      ),
      budget: budget
    )

    // when
    let result = try builder.assemble(
      snapshot: emptySnapshot(),
      sessionId: 42,
      origin: .interactive
    )

    // then
    #expect(result.ownerNotices.count == 1)
    #expect(try #require(result.ownerNotices.first).contains("`no-frontmatter`"))
  }

  @Test(arguments: [RunOrigin.scheduled, RunOrigin.heartbeat])
  func proactiveRunsStillSeeTheSkillsIndex(origin: RunOrigin) throws {
    // given — the activation protocol has to hold on a fire with nobody watching
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

    // when
    let result = try builder.assemble(snapshot: emptySnapshot(), sessionId: 42, origin: origin)

    // then
    let untrusted = try #require(result.messages.first { message in message.role == .user })
      .content.text
    #expect(untrusted.contains("label=\"skills\""))
    #expect(untrusted.contains("- summarize: Summarize owner-provided text."))
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
    #expect(result.messages.suffix(2).map(\.content.text) == ["middle", "new"])
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
    #expect(result.messages.suffix(1).map(\.content.text) == ["newest"])
    #expect(result.messages.contains(where: { message in message.content.text == "o" }) == false)
    #expect(result.messages[0].content.text.contains("[…earlier conversation truncated]"))
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
    #expect(result.messages.last?.content.text == "what is the meaning of this")
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
    #expect(result.messages[0].content.text.contains("proactive policy"))
    #expect(result.messages[0].content.text.contains("system policy") == false)
    #expect(retriever.calls.isEmpty)
    #expect(
      result.messages.contains { message in
        message.content.text.contains("label=\"recall\"")
      } == false
    )
    #expect(result.messages.last?.content.text == "follow the tournament daily")
  }
}

// MARK: - Provider Replay State

extension ContextBuilderTests {
  /// Deliberately not valid UTF-8, so a renderer that stringified the blob into prompt text would
  /// mangle it rather than round-trip it.
  static let replayPayload = Data([0x00, 0xC3, 0x28, 0xFF, 0xFE])

  // The lossy conversion is the point here: the failable initializer the rule prefers returns nil
  // for these bytes, which would assert nothing at all.
  // swiftlint:disable optional_data_string_conversion

  /// The payload as a leak would actually expose it. Searching prompt text for the raw bytes can
  /// never fail — a `String`'s UTF-8 view cannot emit `0xFF`/`0xFE` — so non-exposure is asserted
  /// against the lossy form a stringifying renderer really produces, replacement chars and all.
  static let replayPayloadAsLossyText = String(decoding: replayPayload, as: UTF8.self)

  // swiftlint:enable optional_data_string_conversion

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

    // then — the bytes are carried, never rendered, whatever tier the message belongs to
    for message in result.messages {
      #expect(message.content.text.contains("zzzsecretissuer") == false)
      #expect(message.content.text.contains(Self.replayPayloadAsLossyText) == false)
    }
    #expect(result.messages.contains { message in message.content.text.contains("raw page text") })
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

private func emptySnapshot() -> SessionContextSnapshot {
  SessionContextSnapshot(
    history: [],
    historyMessageIds: [],
    windowStartMessageId: 0,
    isTainted: false,
    hasPrivateData: false
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
  private let skillWarnings: [WorkspaceWarning]

  init(
    files: [WorkspaceFile: FileState] = [:],
    skills: [SkillDescriptor] = [],
    skillWarnings: [WorkspaceWarning] = []
  ) {
    self.files = files
    self.skills = skills
    self.skillWarnings = skillWarnings
  }

  func load(file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
    files[file]?.loadedFile ?? .missing
  }

  func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile {
    .missing
  }

  func scanSkills() -> SkillScanResult {
    SkillScanResult(descriptors: skills, warnings: skillWarnings)
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
