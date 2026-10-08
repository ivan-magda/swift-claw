import ClawCore
import Foundation

// MARK: - Recent Owner Journal

extension ContextBuilder {
  func journalSection(
    snapshot: SessionContextSnapshot,
    origin: RunOrigin,
    ownerNotices: inout [String]
  ) -> FittableSection? {
    guard let scope = journalPolicy.scope,
          snapshot.sessionKey == SessionKey.telegramDM(chatID: scope.ownerUserID),
          origin == .interactive
    else {
      return nil
    }

    guard let journalFiles,
          let timeZone = TimeZone(identifier: scope.timeZoneID)
    else {
      return nil
    }

    let today = JournalDay.containing(now(), timeZone: timeZone)
    let yesterday = today.previous(in: timeZone)
    var units: [SectionUnit] = []

    for day in [today, yesterday] {
      let path = "memory/\(day.isoDate).md"
      let journal = journalFiles.load(day: day)

      switch journal.outcome {
      case .present:
        guard !journal.text.isEmpty else {
          continue
        }

        units.append(
          SectionUnit(
            id: day.isoDate,
            content: "## \(path)\n\(journal.text)",
            canTruncate: true
          )
        )
      case .missing:
        continue
      case .unreadable:
        ownerNotices.append("⚠ `\(path)` could not be read; left out this turn.")
      case .overCap:
        ownerNotices.append("⚠ `\(path)` exceeds the file size limit; left out this turn.")
      }
    }

    guard !units.isEmpty else {
      return nil
    }

    return section(id: .journal, units: units)
  }
}
