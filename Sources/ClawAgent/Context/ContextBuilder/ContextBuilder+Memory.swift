import ClawCore
import Foundation

// MARK: - Memory and Recall Sections

extension ContextBuilder {
  func memoryItemsSection(
    excludeSensitive: Bool,
    residual: Int
  ) -> FittableSection? {
    let cap = cap(for: .memoryItems, residual: residual)
    guard cap > 0 else {
      return nil
    }

    let fetched: [MemoryItem]
    do {
      fetched = try memoryStore.fetchRanked(
        excludeSensitive: excludeSensitive,
        limit: Self.memoryFetchLimit
      )
    } catch {
      warn("memory_items read failed: \(error)")
      return nil
    }

    let ranked = MemoryRanker.rank(
      items: fetched,
      excludeSensitive: excludeSensitive,
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
        restrictToSessionId: recallRestriction(for: snapshot, sessionId: sessionId),
        windowStartMessageId: snapshot.windowStartMessageId,
        excludedMessageIds: snapshot.historyMessageIds,
        limit: Self.recallCandidateLimit
      )
    } catch {
      warn("message recall failed: \(error)")
      return nil
    }

    let selected = CandidateCapRecallCutoff.select(
      hits: hits,
      limit: Self.recallInjectionLimit
    )
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
}

// MARK: - Recall Selection

private extension ContextBuilder {
  /// A group topic recalls only its own past; a DM keeps its reach across the owner's sessions.
  func recallRestriction(for snapshot: SessionContextSnapshot, sessionId: Int64) -> Int64? {
    switch SessionKey.mode(from: snapshot.sessionKey) {
    case .direct: nil
    case .group: sessionId
    }
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
}
