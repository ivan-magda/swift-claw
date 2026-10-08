import ClawCore
import Foundation

// MARK: - Recent Owner Journal

extension ContextBuilder {
  func journalSection(
    snapshot: SessionContextSnapshot,
    origin: RunOrigin,
    ownerNotices: inout [String]
  ) -> FittableSection? {
    // Seeded access grants and legacy session keys do not establish journal ownership.
    guard let scope = journalPolicy.scope,
          snapshot.sessionKey == SessionKey.telegramDM(chatID: scope.ownerUserID),
          origin == .interactive,
          let journalFiles,
          let timeZone = TimeZone(identifier: scope.timeZoneID)
    else {
      return nil
    }

    let today = JournalDay.containing(now(), timeZone: timeZone)
    let units = [today, today.previous(in: timeZone)].compactMap { day -> SectionUnit? in
      let loaded = journalFiles.load(day: day)
      switch loaded.outcome {
      case .present:
        guard !loaded.text.isEmpty else {
          return nil
        }
        return SectionUnit(
          id: day.isoDate,
          content: "## memory/\(day.isoDate).md\n\(loaded.text)",
          canTruncate: true
        )
      case .missing:
        return nil
      case .unreadable, .overCap:
        let reason =
          loaded.outcome == .overCap ? "exceeds the file size limit" : "could not be read"
        ownerNotices.append("⚠ `memory/\(day.isoDate).md` \(reason); left out this turn.")
        return nil
      }
    }
    guard !units.isEmpty else {
      return nil
    }

    // This cap is independent of the proportional memory/history/recall/skills caps. The fitter
    // spends any remaining space by priority, favoring today's suffix over yesterday's notes.
    return section(id: .journal, units: units)
  }
}
