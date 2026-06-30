import ClawCore
import ClawWorkspace
import Foundation

public struct ContextBuilder: Sendable {
  public static let memoryFetchLimit = 100
  public static let recallCandidateLimit = 20
  public static let recallInjectionLimit = 5

  private let systemPrompt: String
  private let workspace: any WorkspaceReading
  private let memoryStore: any MemoryStore
  private let retriever: any Retriever
  private let recallCutoff: any RecallCutoff
  private let budget: ContextBudget
  private let now: @Sendable () -> Date
  private let warn: @Sendable (String) -> Void

  public init(
    systemPrompt: String,
    workspace: any WorkspaceReading,
    memoryStore: any MemoryStore,
    retriever: any Retriever,
    recallCutoff: any RecallCutoff = CandidateCapRecallCutoff(),
    budget: ContextBudget,
    now: @escaping @Sendable () -> Date = Date.init,
    warn: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.systemPrompt = systemPrompt
    self.workspace = workspace
    self.memoryStore = memoryStore
    self.retriever = retriever
    self.recallCutoff = recallCutoff
    self.budget = budget
    self.now = now
    self.warn = warn
  }

  public static func assemble(
    systemPrompt: String,
    history: [StoredMessage],
    inputCapGraphemes: Int
  ) -> [ChatMessage] {
    var inputCappedMessages = [StoredMessage]()
    inputCappedMessages.reserveCapacity(history.count)

    var isBudgetExhausted = false
    var budget = inputCapGraphemes - systemPrompt.count

    for (index, message) in history.reversed().enumerated() {
      budget -= message.content.count

      if budget < 0 && index > 0 {
        isBudgetExhausted = true
        break
      }

      inputCappedMessages.append(message)
    }

    let budgetExhaustedMarker = "\n\n[…earlier conversation truncated]"
    let systemMessage = ChatMessage(
      role: .system,
      content: isBudgetExhausted ? systemPrompt + budgetExhaustedMarker : systemPrompt
    )

    return [systemMessage]
      + inputCappedMessages.reversed().map { message in
        ChatMessage(role: message.role, content: message.content)
      }
  }

  public func assemble(
    snapshot: SessionContextSnapshot,
    sessionId: Int64
  ) throws -> BuildResult {
    var ownerNotices: [String] = []
    let fixedSections = buildFixedSections(ownerNotices: &ownerNotices)
    let residual = residualAfterFixedSections(fixedSections)
    let truncatableSections = buildTruncatableSections(
      snapshot: snapshot,
      sessionId: sessionId,
      residual: residual
    )

    let fitted = try BudgetFitter.fitWithUnits(
      fixedSections + truncatableSections,
      budget: budget
    )
    let messages = renderMessages(fitted: fitted, snapshot: snapshot)

    return BuildResult(
      messages: messages,
      ownerNotices: ownerNotices,
      hasPrivateDataAccess: hasPrivateDataAccess(fitted)
    )
  }

  private func buildFixedSections(ownerNotices: inout [String]) -> [FittableSection] {
    [
      section(
        id: .policy,
        units: [
          SectionUnit(
            id: "policy",
            content: systemPrompt,
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
      workspaceSection(id: .tools, files: [.tools], cap: nil, ownerNotices: &ownerNotices),
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

  private func buildTruncatableSections(
    snapshot: SessionContextSnapshot,
    sessionId: Int64,
    residual: Int
  ) -> [FittableSection] {
    [
      memoryItemsSection(snapshot: snapshot, residual: residual),
      historySection(snapshot: snapshot, residual: residual),
      recallSection(snapshot: snapshot, sessionId: sessionId, residual: residual),
      skillsSection(residual: residual),
    ].compactMap { $0 }
  }

  private func workspaceSection(
    id: ContextRowID,
    files: [WorkspaceFile],
    cap: Int?,
    ownerNotices: inout [String]
  ) -> FittableSection? {
    let units = files.compactMap { file -> SectionUnit? in
      let loaded = workspace.load(file: file, maxGraphemes: cap)
      switch loaded.outcome {
      case .present:
        guard loaded.text.isEmpty == false else { return nil }
        return SectionUnit(
          id: file.relativePath,
          content: "## \(file.relativePath)\n\(loaded.text)",
          canTruncate: false
        )
      case .overCap:
        if let cap {
          let notice =
            "⚠ `\(file.relativePath)` is \(loaded.graphemeCount)/\(cap) "
            + "— edit it to trim; left out this turn."
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

    guard units.isEmpty == false else { return nil }
    return section(id: id, units: units)
  }

  private func memoryItemsSection(
    snapshot: SessionContextSnapshot,
    residual: Int
  ) -> FittableSection? {
    let cap = cap(for: .memoryItems, residual: residual)
    guard cap > 0 else { return nil }

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
    guard units.isEmpty == false else { return nil }
    return section(id: .memoryItems, cap: cap, units: units)
  }

  private func historySection(snapshot: SessionContextSnapshot, residual: Int) -> FittableSection? {
    let cap = cap(for: .history, residual: residual)
    guard cap > 0 else { return nil }

    let units = snapshot.history.enumerated().reversed().map { index, message in
      SectionUnit(id: "history-\(index)", content: message.content, canTruncate: false)
    }
    guard units.isEmpty == false else { return nil }
    return section(id: .history, cap: cap, units: units)
  }

  private func recallSection(
    snapshot: SessionContextSnapshot,
    sessionId: Int64,
    residual: Int
  ) -> FittableSection? {
    let cap = cap(for: .recall, residual: residual)
    guard cap > 0, let query = latestUserMessage(in: snapshot.history) else { return nil }

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
      guard content.isEmpty == false else { return nil }
      return SectionUnit(id: "recall-\(hit.id)", content: content, canTruncate: true)
    }
    guard units.isEmpty == false else { return nil }
    return section(id: .recall, cap: cap, units: units)
  }

  private func skillsSection(residual: Int) -> FittableSection? {
    let cap = cap(for: .skills, residual: residual)
    guard cap > 0 else { return nil }

    let scan = workspace.scanSkills()
    for warning in scan.warnings {
      warn("skills scan warning: \(warning)")
    }

    let units = scan.descriptors.map { descriptor in
      SectionUnit(
        id: "skill-\(descriptor.name)",
        content: "- \(descriptor.name): \(descriptor.description)",
        canTruncate: false
      )
    }
    guard units.isEmpty == false else { return nil }
    return section(id: .skills, cap: cap, units: units)
  }

  private func section(
    id: ContextRowID,
    cap: Int? = nil,
    units: [SectionUnit]
  ) -> FittableSection {
    let spec = spec(for: id)
    return FittableSection(
      id: spec.id,
      tier: spec.tier,
      priority: spec.priority,
      truncatable: spec.truncatable,
      cap: cap ?? spec.cap.resolve(in: budget, residualGraphemes: nil),
      units: units
    )
  }

  private func cap(for id: ContextRowID, residual: Int) -> Int {
    spec(for: id).cap.resolve(in: budget, residualGraphemes: residual) ?? Int.max
  }

  private func residualAfterFixedSections(_ sections: [FittableSection]) -> Int {
    let required =
      sections
      .filter { section in !section.truncatable }
      .map { section in section.units.map(\.content).joined(separator: "\n").count }
      .reduce(0, +)
    return max(0, budget.inputCapGraphemes - required)
  }

  private func renderMessages(
    fitted: [FittedSection],
    snapshot: SessionContextSnapshot
  ) -> [ChatMessage] {
    let systemContent =
      fitted
      .filter { section in section.tier == .system }
      .map(\.content)
      .joined(separator: "\n\n")
    var messages = [ChatMessage(role: .system, content: systemContent)]

    let untrusted =
      fitted
      .filter { section in section.tier == .untrustedLabeled }
      .map { section in
        LabeledContextFactory.make(label: label(for: section.id), content: section.content).render()
      }
      .joined(separator: "\n\n")
    if untrusted.isEmpty == false {
      messages.append(ChatMessage(role: .user, content: untrusted))
    }

    messages.append(contentsOf: fittedHistoryMessages(fitted: fitted, snapshot: snapshot))
    return messages
  }

  private func fittedHistoryMessages(
    fitted: [FittedSection],
    snapshot: SessionContextSnapshot
  ) -> [ChatMessage] {
    guard let historySection = fitted.first(where: { section in section.id == .history }) else {
      return []
    }

    let keptIDs = Set(historySection.units.map(\.id))
    return snapshot.history.enumerated().compactMap { index, message in
      guard keptIDs.contains("history-\(index)") else { return nil }
      return ChatMessage(role: message.role, content: message.content)
    }
  }

  private func hasPrivateDataAccess(_ fitted: [FittedSection]) -> Bool {
    fitted.contains { section in
      section.id == .userFile || section.id == .memoryFile || section.id == .memoryItems
    }
  }

  private func latestUserMessage(in history: [StoredMessage]) -> String? {
    history.last { message in message.role == .user }?.content
  }

  private func cappedRecallContent(_ content: String) -> String {
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

  private func label(for id: ContextRowID) -> String {
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
      "skills"
    case .policy, .systemWorkspace, .tools, .metadata, .history:
      id.rawValue
    }
  }

  private func spec(for id: ContextRowID) -> RowSpec {
    guard let spec = ContextRowPolicy.specs.first(where: { spec in spec.id == id }) else {
      preconditionFailure("missing context row spec for \(id)")
    }
    return spec
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }
}
