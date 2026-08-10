import ClawCore
import Foundation

/// One exchange-grouping unit: an assistant anchor (`tool_calls`) plus its tool rows, or a single
/// plain conversational message. The atomic droppable unit — never a partial exchange on the wire.
private struct HistoryGroup {
  let id: String
  let messages: [StoredMessage]
}

public struct ContextBuilder: Sendable {
  public static let memoryFetchLimit = 100
  public static let recallCandidateLimit = 20
  public static let recallInjectionLimit = 5

  private static let historyTruncatedMarker = "\n\n[…earlier conversation truncated]"
  private static let skillUnitIDPrefix = "skill-"

  static let untrustedUserLabel = "untrusted_user_message"

  private let systemPrompt: String
  private let proactiveSystemPrompt: String

  private let workspace: any WorkspaceReading
  private let memoryStore: any MemoryStore
  private let retriever: any Retriever
  private let recallCutoff: any RecallCutoff
  private let budget: ContextBudget
  private let fenceLabels: ToolFenceLabels

  private let policyStaticSubhash: String

  private let now: @Sendable () -> Date
  private let warn: @Sendable (String) -> Void

  public init(
    systemPrompt: String,
    proactiveSystemPrompt: String = SystemPrompt.proactive,
    workspace: any WorkspaceReading,
    memoryStore: any MemoryStore,
    retriever: any Retriever,
    recallCutoff: any RecallCutoff = CandidateCapRecallCutoff(),
    budget: ContextBudget,
    fenceLabels: ToolFenceLabels = .undeclared,
    policyStaticSubhash: String = "",
    now: @escaping @Sendable () -> Date = Date.init,
    warn: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.systemPrompt = systemPrompt
    self.proactiveSystemPrompt = proactiveSystemPrompt

    self.workspace = workspace
    self.memoryStore = memoryStore
    self.retriever = retriever
    self.recallCutoff = recallCutoff
    self.budget = budget
    self.fenceLabels = fenceLabels

    self.policyStaticSubhash = policyStaticSubhash

    self.now = now
    self.warn = warn
  }

  public func assemble(
    snapshot: SessionContextSnapshot,
    sessionId: Int64,
    origin: RunOrigin
  ) throws -> BuildResult {
    var ownerNotices: [String] = []

    let fixedSections = buildFixedSections(origin: origin, ownerNotices: &ownerNotices)
    let residual = residualAfterFixedSections(fixedSections)
    let truncatableSections = buildTruncatableSections(
      snapshot: snapshot,
      sessionId: sessionId,
      origin: origin,
      residual: residual,
      ownerNotices: &ownerNotices
    )

    let fitted = try BudgetFitter.fitWithUnits(
      fixedSections + truncatableSections,
      budget: budget
    )
    if let notice = droppedSkillsNotice(fitted: fitted, requested: truncatableSections) {
      ownerNotices.append(notice)
    }
    let messages = renderMessages(fitted: fitted, snapshot: snapshot)

    return BuildResult(
      messages: messages,
      ownerNotices: ownerNotices,
      hasPrivateDataAccess: hasPrivateDataAccess(fitted),
      policyVersion: currentPolicyVersion()
    )
  }
}

// MARK: - Section Assembly

private extension ContextBuilder {
  func buildFixedSections(
    origin: RunOrigin,
    ownerNotices: inout [String]
  ) -> [FittableSection] {
    [
      section(
        id: .policy,
        units: [
          SectionUnit(
            id: "policy",
            content: origin.isProactive ? proactiveSystemPrompt : systemPrompt,
            canTruncate: false
          )
        ]
      ),
      workspaceSection(
        id: .systemWorkspace,
        files: [.soul, .agents],
        cap: nil,
        ownerNotices: &ownerNotices
      ),
      workspaceSection(
        id: .tools,
        files: [.tools],
        cap: nil,
        ownerNotices: &ownerNotices
      ),
      section(
        id: .metadata,
        units: [
          SectionUnit(
            id: "metadata-time",
            content: "Current time: \(Self.iso8601(now()))",
            canTruncate: false
          )
        ]
      ),
      workspaceSection(
        id: .userFile,
        files: [.user],
        cap: budget.userFileCap,
        ownerNotices: &ownerNotices
      ),
      workspaceSection(
        id: .memoryFile,
        files: [.memory],
        cap: budget.memoryFileCap,
        ownerNotices: &ownerNotices
      ),
    ].compactMap { $0 }
  }

  func buildTruncatableSections(
    snapshot: SessionContextSnapshot,
    sessionId: Int64,
    origin: RunOrigin,
    residual: Int,
    ownerNotices: inout [String]
  ) -> [FittableSection] {
    [
      memoryItemsSection(snapshot: snapshot, residual: residual),
      historySection(snapshot: snapshot, residual: residual),
      // Proactive runs never recall: the retriever's dedup excludes only the CURRENT window,
      // so after a per-fire window reset a recall search would resurface exactly the prior-fire
      // turns (and the owner's DM chat about arming the job) that the reset fenced off.
      origin.isProactive
        ? nil
        : recallSection(snapshot: snapshot, sessionId: sessionId, residual: residual),
      skillsSection(residual: residual, ownerNotices: &ownerNotices),
    ].compactMap { $0 }
  }

  func workspaceSection(
    id: ContextRowID,
    files: [WorkspaceFile],
    cap: Int?,
    ownerNotices: inout [String]
  ) -> FittableSection? {
    let units = files.compactMap { file -> SectionUnit? in
      let loaded = workspace.load(file: file, maxGraphemes: cap)

      switch loaded.outcome {
      case .present:
        if !loaded.text.isEmpty {
          return SectionUnit(
            id: file.relativePath,
            content: "## \(file.relativePath)\n\(loaded.text)",
            canTruncate: false
          )
        }
        return nil
      case .overCap:
        if let cap {
          let notice = """
            ⚠ `\(file.relativePath)` is \(loaded.graphemeCount)/\(cap) \
            — edit it to trim; left out this turn.
            """
          ownerNotices.append(notice)
        } else {
          warn("Workspace file \(file.relativePath) exceeded an uncapped load")
        }
        return nil
      case .missing:
        return nil
      case .unreadable:
        warn("Workspace file \(file.relativePath) could not be read")
        return nil
      }
    }

    guard units.isEmpty == false else {
      return nil
    }

    return section(id: id, units: units)
  }

  func memoryItemsSection(
    snapshot: SessionContextSnapshot,
    residual: Int
  ) -> FittableSection? {
    let cap = cap(for: .memoryItems, residual: residual)
    guard cap > 0 else {
      return nil
    }

    let fetched: [MemoryItem]
    do {
      fetched = try memoryStore.fetchRanked(
        excludeSensitive: snapshot.isTainted,
        limit: Self.memoryFetchLimit
      )
    } catch {
      warn("memory_items read failed: \(error)")
      return nil
    }

    let ranked = MemoryRanker.rank(
      items: fetched,
      excludeSensitive: snapshot.isTainted,
      cap: cap
    )
    let units = ranked.map { item in
      SectionUnit(id: "memory-\(item.id)", content: item.text, canTruncate: false)
    }

    guard units.isEmpty == false else {
      return nil
    }

    return section(id: .memoryItems, cap: cap, units: units)
  }

  func historySection(snapshot: SessionContextSnapshot, residual: Int) -> FittableSection? {
    // No `cap > 0` early-return: even when fixed sections leave a zero residual, the newest
    // history unit (the current turn) must reach the fitter, which keeps it as a non-droppable
    // floor so the model always sees the message it is answering.
    let cap = cap(for: .history, residual: residual)
    let groups = historyGroups(from: snapshot.history)

    let units = groups.reversed().map { group in
      SectionUnit(
        id: group.id,
        content: group.messages.map { message in
          message.content + (message.toolCallsJSON ?? "")
        }.joined(separator: "\n"),
        canTruncate: false
      )
    }

    guard units.isEmpty == false else {
      return nil
    }

    return section(id: .history, cap: cap, units: units)
  }

  /// Groups sanitized history so each exchange is ONE atomic droppable unit. Group ids are stable
  /// per assembly ("history-<index of the group's first row>").
  func historyGroups(from history: [StoredMessage]) -> [HistoryGroup] {
    let sanitized = HistoryHygiene.sanitize(history)
    var groups: [HistoryGroup] = []
    var index = 0

    while index < sanitized.count {
      let message = sanitized[index]
      let anchorCalls = message.toolCallsJSON.map(ToolCallCoding.decode) ?? []

      guard message.role == .assistant, anchorCalls.isEmpty == false else {
        groups.append(HistoryGroup(id: "history-\(index)", messages: [message]))
        index += 1
        continue
      }

      var grouped = [message]
      var cursor = index + 1

      while cursor < sanitized.count, sanitized[cursor].role == .tool {
        grouped.append(sanitized[cursor])
        cursor += 1
      }

      groups.append(HistoryGroup(id: "history-\(index)", messages: grouped))
      index = cursor
    }

    return groups
  }

  func recallSection(
    snapshot: SessionContextSnapshot,
    sessionId: Int64,
    residual: Int
  ) -> FittableSection? {
    let cap = cap(for: .recall, residual: residual)
    guard cap > 0,
      let query = latestUserMessage(in: snapshot.history)
    else {
      return nil
    }

    let hits: [RecallHit]
    do {
      hits = try retriever.searchRelevantMessages(
        query: query,
        currentSessionId: sessionId,
        windowStartMessageId: snapshot.windowStartMessageId,
        excludedMessageIds: snapshot.historyMessageIds,
        limit: Self.recallCandidateLimit
      )
    } catch {
      warn("message recall failed: \(error)")
      return nil
    }

    let selected = recallCutoff.select(hits: hits, limit: Self.recallInjectionLimit)
    let units = selected.compactMap { hit -> SectionUnit? in
      let content = cappedRecallContent(hit.content)
      return content.isEmpty
        ? nil
        : SectionUnit(id: "recall-\(hit.id)", content: content, canTruncate: true)
    }

    guard units.isEmpty == false else {
      return nil
    }

    return section(id: .recall, cap: cap, units: units)
  }

  func latestUserMessage(in history: [StoredMessage]) -> String? {
    history.last { message in
      message.role == .user
    }?.content
  }

  func cappedRecallContent(_ content: String) -> String {
    guard content.count > budget.recallHitCap else {
      return content
    }

    let marker = BudgetFitter.truncationMarker
    guard budget.recallHitCap > marker.count else {
      return ""
    }

    let prefixCount = budget.recallHitCap - marker.count

    return String(content.prefix(prefixCount)) + marker
  }

  /// Scans before consulting the cap: an authoring fault is the owner's to fix whether or not this
  /// turn had room for the index, and a zero cap is left to the fitter so the drop is announced.
  func skillsSection(residual: Int, ownerNotices: inout [String]) -> FittableSection? {
    let scan = workspace.scanSkills()
    for warning in scan.warnings {
      warn("skills scan warning: \(warning)")
      if case .unreadableSkillsDirectory = warning {
        // Ordinary turns scan repeatedly; a transient I/O failure stays in diagnostics and logs
        // instead of notifying the owner on every message.
        continue
      }
      ownerNotices.append("⚠ \(warning.ownerFacingReason)")
    }

    let units = scan.descriptors.map { descriptor in
      SectionUnit(
        id: Self.skillUnitID(for: descriptor.name),
        content: WorkspaceSkills.indexLine(for: descriptor),
        canTruncate: false
      )
    }
    guard units.isEmpty == false else {
      return nil
    }

    return section(
      id: .skills,
      cap: cap(for: .skills, residual: residual),
      dropMarker: .showingCount(noun: "skills"),
      units: units
    )
  }

  /// A skills row too big for its cap comes back shrunk, but one whose cap admits nothing at all is
  /// gone from `fitted` entirely — the case the owner most needs told, so it reads as every skill
  /// dropped rather than as no skills installed.
  func droppedSkillsNotice(fitted: [FittedSection], requested: [FittableSection]) -> String? {
    guard let source = requested.first(where: { section in section.id == .skills }) else {
      return nil
    }

    let fittedSkills = fitted.first { section in
      section.id == .skills
    }
    let dropped =
      (fittedSkills?.droppedUnitIDs ?? source.units.map(\.id))
      .map(Self.skillName(fromUnitID:))
    guard dropped.isEmpty == false else {
      return nil
    }

    let names = dropped.map { name in
      "`\(name)`"
    }.joined(separator: ", ")

    return "⚠ Skills index over budget; left out this turn: \(names). Trim their descriptions."
  }

  static func skillUnitID(for name: String) -> String {
    "\(skillUnitIDPrefix)\(name)"
  }

  static func skillName(fromUnitID unitID: String) -> String {
    String(unitID.dropFirst(skillUnitIDPrefix.count))
  }

  static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }
}

// MARK: - Policy Fingerprint

public extension ContextBuilder {
  /// The system-tier prompt materials in the pinned order (ARCHITECTURE.md §11), RAW (pre "## path"
  /// wrapping), folded into the injected static sub-hash. Reused verbatim at pick-up (the
  /// persisted `policy_version`, stamped by `TurnRunner`) and recomputed at callback resolution so
  /// the two can never diverge. BOTH prompt variants fold in — the recompute seams are zero-argument
  /// closures with no run (hence no origin) in scope, so the fingerprint must be origin-independent;
  /// an edit to either variant conservatively invalidates parked approvals. `public` because
  /// `TurnRunner` (ClawGateway) stamps with it cross-module and `assemble` returns it — a `private`
  /// helper would be invisible to both the stamp seam and `@testable`.
  func currentPolicyVersion() -> String {
    PolicyFingerprint.combined(
      staticSubhash: policyStaticSubhash,
      promptMaterials: [
        systemPrompt,
        proactiveSystemPrompt,
        rawPromptText(.soul),
        rawPromptText(.agents),
        rawPromptText(.tools),
      ]
    )
  }
}

private extension ContextBuilder {
  /// The uncapped raw file text for a system-tier prompt file; missing/unreadable folds in as "".
  /// Uncapped because these files load uncapped in `buildFixedSections`.
  func rawPromptText(_ file: WorkspaceFile) -> String {
    let loadedFile = workspace.load(file: file, maxGraphemes: nil)
    switch loadedFile.outcome {
    case .present:
      return loadedFile.text
    case .overCap, .missing, .unreadable:
      return ""
    }
  }
}

// MARK: - Row Spec & Budget Helpers

private extension ContextBuilder {
  func section(
    id: ContextRowID,
    cap: Int? = nil,
    dropMarker: DropMarker = .none,
    units: [SectionUnit]
  ) -> FittableSection {
    let spec = spec(for: id)
    return FittableSection(
      id: spec.id,
      tier: spec.tier,
      priority: spec.priority,
      truncatable: spec.truncatable,
      cap: cap ?? spec.cap.resolve(in: budget, residualGraphemes: nil),
      dropMarker: dropMarker,
      units: units
    )
  }

  func cap(for id: ContextRowID, residual: Int) -> Int {
    spec(for: id).cap.resolve(in: budget, residualGraphemes: residual) ?? Int.max
  }

  func residualAfterFixedSections(_ sections: [FittableSection]) -> Int {
    let required =
      sections
      .filter { section in
        !section.truncatable
      }
      .map { section in
        section.units.map(\.content).joined(separator: "\n").count
      }
      .reduce(0, +)
    return max(0, budget.inputCapGraphemes - required)
  }

  func spec(for id: ContextRowID) -> RowSpec {
    guard let spec = ContextRowPolicy.specs.first(where: { spec in spec.id == id }) else {
      preconditionFailure("missing context row spec for \(id)")
    }
    return spec
  }
}

// MARK: - Message Rendering

private extension ContextBuilder {
  func renderMessages(
    fitted: [FittedSection],
    snapshot: SessionContextSnapshot
  ) -> [ChatMessage] {
    let historyMessages = fittedHistoryMessages(fitted: fitted, snapshot: snapshot)
    // Compare GROUPS, not raw rows: one unit per group by construction, so a kept-unit-count
    // shortfall against the full group count means an exchange (or plain row) was dropped.
    let keptHistoryGroupCount = Set(
      fitted.first { section in
        section.id == .history
      }?.units.map(\.id) ?? []
    ).count
    let historyWasTruncated = keptHistoryGroupCount < historyGroups(from: snapshot.history).count

    let systemContent =
      fitted
      .filter { section in
        section.tier == .system
      }
      .map(\.content)
      .joined(separator: "\n\n")
      + (historyWasTruncated ? Self.historyTruncatedMarker : "")
    var messages = [ChatMessage(role: .system, content: systemContent)]

    let untrusted =
      fitted
      .filter { section in
        section.tier == .untrustedLabeled
      }
      .map { section in
        LabeledContextFactory.make(
          label: label(for: section.id),
          content: section.content
        ).render()
      }
      .joined(separator: "\n\n")
    if untrusted.isEmpty == false {
      messages.append(ChatMessage(role: .user, content: untrusted))
    }

    messages.append(contentsOf: historyMessages)
    return messages
  }

  /// The one render seam for both native assistant anchors (with decoded `toolCalls`) and fenced
  /// tool rows (labeled by the owning anchor's declared fence label). Kept groups come from the
  /// fitter verbatim — one `SectionUnit` per group — so this only re-expands each surviving
  /// group's rows.
  func fittedHistoryMessages(
    fitted: [FittedSection],
    snapshot: SessionContextSnapshot
  ) -> [ChatMessage] {
    guard let historySection = fitted.first(where: { section in section.id == .history }) else {
      return []
    }

    let keptIDs = Set(historySection.units.map(\.id))
    let groups = historyGroups(from: snapshot.history)
    var rendered: [ChatMessage] = []

    for group in groups where keptIDs.contains(group.id) {
      // The anchor's id→name map labels each tool row's fence. A provider-authored response could
      // duplicate a tool_call id, and the name a row resolves to now decides how much the prompt
      // trusts its content — so a duplicated id names nobody and its rows fall back to the
      // unattributed label, rather than the first declaration lending them its fence.
      let anchorCalls = group.messages.first?.toolCallsJSON.map(ToolCallCoding.decode) ?? []
      let callsPerId = anchorCalls.reduce(into: [String: Int]()) { counts, call in
        counts[call.id, default: 0] += 1
      }
      let namesByCallId = Dictionary(
        uniqueKeysWithValues:
          anchorCalls
          .filter { call in
            callsPerId[call.id] == 1
          }
          .map { call in
            (call.id, call.name)
          }
      )

      for message in group.messages {
        switch message.role {
        case .tool:
          let label =
            message.toolCallId
            .flatMap { callId in
              namesByCallId[callId]
            }
            .map(fenceLabels.label(forToolNamed:))
            ?? ToolFenceLabels.unattributed
          rendered.append(
            ChatMessage(
              role: .tool,
              content: LabeledContextFactory.make(
                label: label,
                content: message.content
              ).render(),
              toolCallId: message.toolCallId
            )
          )
        case .assistant:
          rendered.append(
            ChatMessage(
              role: .assistant,
              content: message.content,
              toolCalls: message.toolCallsJSON.map(ToolCallCoding.decode) ?? [],
              providerState: message.providerState
            )
          )
        case .user:
          rendered.append(userMessage(from: message))
        case .system:
          rendered.append(ChatMessage(role: .system, content: message.content))
        }
      }
    }

    return rendered
  }

  /// Provenance decides the fence and nothing else. The image rides on every user row, trusted or
  /// not: gating it on provenance would let a single change of tier drop an image with no error and
  /// no failing test.
  func userMessage(from message: StoredMessage) -> ChatMessage {
    var body = message.content
    if message.provenance == .untrusted {
      body = LabeledContextFactory.make(
        label: Self.untrustedUserLabel,
        content: message.content
      ).render()
    }

    // Outside the fence, deliberately: this is our own assertion about system state, and fencing it
    // would label our words as sender-supplied input.
    if photoBytesAreMissing(message) {
      body += "\n\(ImageMarkers.unavailable)"
    }

    let parts: [MessageContent.Part] =
      message.image.map { image in
        [.image(image), .text(body)]
      } ?? [.text(body)]
    return ChatMessage(role: .user, content: MessageContent(parts: parts))
  }

  /// True when a row records a photo whose bytes did not survive to assembly — evicted under cache
  /// pressure, dropped by the replay budget, or lost to a restart. Image bytes are never persisted,
  /// so the stored marker is the only evidence left. Provenance is deliberately not consulted, for
  /// the same reason the image itself rides on every tier.
  func photoBytesAreMissing(_ message: StoredMessage) -> Bool {
    guard message.image == nil else {
      return false
    }
    return ImageMarkers.marksPhoto(message.content)
  }

  func hasPrivateDataAccess(_ fitted: [FittedSection]) -> Bool {
    fitted.contains { section in
      section.id == .userFile || section.id == .memoryFile || section.id == .memoryItems
    }
  }

  func label(for id: ContextRowID) -> String {
    switch id {
    case .userFile:
      "USER.md"
    case .memoryFile:
      "MEMORY.md"
    case .memoryItems:
      "memory_items"
    case .recall:
      "recall"
    case .skills:
      WorkspaceSkills.fenceLabel
    case .policy, .systemWorkspace, .tools, .metadata, .history:
      id.rawValue
    }
  }
}
