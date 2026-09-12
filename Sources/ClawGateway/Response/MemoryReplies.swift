import ClawCore
import Foundation

/// Owner-facing copy for `/remember` and `/memory`: terse, mobile-first, provenance on the line.
/// Pure rendering - no store or transport knowledge.
enum MemoryReplies {
  /// A screenful on mobile; the review list never tries to show everything.
  static let reviewListLimit = 20

  static let snippetCapGraphemes = 60

  static var rememberUsage: String {
    "Usage: /remember [\(kindNames):] <text>"
  }

  static var memoryUsage: String {
    "Usage: /memory [\(kindNames)] | /memory show <id> | /memory delete <id>"
  }

  static let nothingToSave = "No savable text."
  static let cancelled = "Cancelled."

  /// Terminal owner-write failure copy: the pending intent was cleared; re-issue.
  static let saveFailed =
    "Couldn't save it. Nothing was written. Run /remember again."
  static let deleteFailed =
    "Couldn't delete it. Nothing changed. Run /memory delete <id> again."

  /// `id` is nil only if a `MemoryCommandStore` violates its newlyClaimed-implies-item contract;
  /// the ack degrades instead of crashing the router.
  static func saved(id: Int64?) -> String {
    if let id {
      return "Saved memory \(id)."
    }
    return "Saved."
  }

  static func deleted(id: Int64) -> String {
    "Deleted memory \(id)."
  }

  static func notFound(id: Int64) -> String {
    "No memory with id \(id)."
  }

  static func emptyReview(kind: MemoryKind?) -> String {
    if let kind {
      return "No \(kind.rawValue) memories yet."
    }
    return "No memories yet. Use /remember to save one."
  }

  /// Grouped by kind (declaration order), each line `id · «short text» · source · date · ⚠`.
  /// Items keep the store's most-recent-first order within their group.
  static func reviewList(items: [MemoryItem]) -> String {
    let limitedItems = Array(items.prefix(reviewListLimit))
    var lines: [String] = []

    for kind in MemoryKind.allCases {
      let groupedItems = limitedItems.filter { $0.kind == kind }
      guard groupedItems.isEmpty == false else {
        continue
      }

      lines.append("\(kind.rawValue):")
      for item in groupedItems {
        lines.append(reviewLine(item))
      }
    }

    return lines.joined(separator: "\n")
  }

  /// Full text and full provenance: kind, source, session, created, sensitivity.
  static func showItem(_ item: MemoryItem) -> String {
    let sessionText = item.sessionId.map(String.init) ?? "none"
    let lines = [
      "Memory \(item.id): \(item.kind.rawValue)",
      "source: \(item.source.rawValue) · session: \(sessionText)",
      "created: \(formattedDayString(item.createdAt)) · sensitivity: \(item.sensitivity.rawValue)",
      "",
      item.text,
    ]
    return lines.joined(separator: "\n")
  }

  static func deleteConfirmPrompt(item: MemoryItem) -> String {
    let lines = [
      "Delete memory \(item.id)?",
      "«\(item.text)»",
      "Reply yes to delete, no to cancel.",
    ]
    return lines.joined(separator: "\n")
  }

  private static var kindNames: String {
    MemoryKind.allCases.map(\.rawValue).joined(separator: "|")
  }

  private static func reviewLine(_ item: MemoryItem) -> String {
    let base = "\(item.id) · «\(snippet(item.text))» · \(item.source.rawValue)"
    let dated = "\(base) · \(formattedDayString(item.createdAt))"

    guard item.sensitivity == .high else {
      return dated
    }

    return "\(dated) · ⚠"
  }

  private static func snippet(_ text: String) -> String {
    guard text.count > snippetCapGraphemes else {
      return text
    }
    return String(text.prefix(snippetCapGraphemes)) + "…"
  }

  private static func formattedDayString(_ date: Date) -> String {
    date.wallClockDay(in: .gmt)
  }
}
