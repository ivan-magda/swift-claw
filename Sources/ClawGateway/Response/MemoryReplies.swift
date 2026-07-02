import ClawCore
import Foundation

/// Owner-facing copy for `/remember` and `/memory` (spec §8.3/§9): terse, mobile-first, provenance
/// on the line. Pure rendering - no store or transport knowledge.
public enum MemoryReplies {
  /// A screenful on mobile; the review list never tries to show everything (spec §9).
  public static let reviewListLimit = 20

  static let snippetCapGraphemes = 60

  public static var rememberUsage: String {
    "Usage: /remember [\(kindNames):] <text>"
  }

  public static var memoryUsage: String {
    "Usage: /memory [\(kindNames)] | /memory show <id> | /memory delete <id>"
  }

  public static let nothingToSave = "Nothing to save after normalization."
  public static let cancelled = "Cancelled."

  /// Terminal owner-write failure copy (spec §12): the pending intent was cleared; re-issue.
  public static let saveFailed =
    "Couldn't save that — nothing was written. Please try /remember again."
  public static let deleteFailed =
    "Couldn't delete that — nothing was changed. Please try /memory delete again."

  /// `id` is nil only if a `MemoryCommandStore` violates its newlyClaimed-implies-item contract;
  /// the ack degrades instead of crashing the router.
  public static func saved(id: Int64?) -> String {
    guard let id else { return "Saved." }
    return "Saved memory \(id)."
  }

  public static func deleted(id: Int64) -> String {
    "Deleted memory \(id)."
  }

  public static func notFound(id: Int64) -> String {
    "No memory with id \(id)."
  }

  public static func emptyReview(kind: MemoryKind?) -> String {
    guard let kind else { return "No memories yet. Use /remember to save one." }
    return "No \(kind.rawValue) memories yet."
  }

  /// Grouped by kind (declaration order), each line `id · «short text» · source · date · ⚠`
  /// (spec §9). Items keep the store's most-recent-first order within their group.
  public static func reviewList(items: [MemoryItem]) -> String {
    let limitedItems = Array(items.prefix(reviewListLimit))
    var lines: [String] = []

    for kind in MemoryKind.allCases {
      let groupedItems = limitedItems.filter { $0.kind == kind }
      guard groupedItems.isEmpty == false else { continue }

      lines.append("\(kind.rawValue):")
      for item in groupedItems {
        lines.append(reviewLine(item))
      }
    }

    return lines.joined(separator: "\n")
  }

  /// Full text and full provenance: kind, source, session, created, sensitivity (spec §9).
  public static func showItem(_ item: MemoryItem) -> String {
    let sessionText = item.sessionId.map(String.init) ?? "none"
    let lines = [
      "Memory \(item.id) — \(item.kind.rawValue)",
      "source: \(item.source.rawValue) · session: \(sessionText)",
      "created: \(dayString(item.createdAt)) · sensitivity: \(item.sensitivity.rawValue)",
      "",
      item.text,
    ]
    return lines.joined(separator: "\n")
  }

  public static func deleteConfirmPrompt(item: MemoryItem) -> String {
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
    let dated = "\(base) · \(dayString(item.createdAt))"
    guard item.sensitivity == .high else { return dated }
    return "\(dated) · ⚠"
  }

  private static func snippet(_ text: String) -> String {
    guard text.count > snippetCapGraphemes else { return text }
    return String(text.prefix(snippetCapGraphemes)) + "…"
  }

  private static func dayString(_ date: Date) -> String {
    date.formatted(dayFormat)
  }

  /// `yyyy-MM-dd` in UTC. `ISO8601FormatStyle` is Sendable; a static `DateFormatter` is not.
  private static let dayFormat = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
}
