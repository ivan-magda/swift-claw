/// Synchronous dated-file IO; mutations run inside the caller's shared WorkspaceMutationGate.
public protocol JournalFiles: Sendable {
  /// Failed loads yield no consumable text and never throw.
  func load(day: JournalDay) -> JournalFileSnapshot
  func append(day: JournalDay, text: String) throws
  func delete(day: JournalDay) throws
  func recentDays(limit: Int) throws -> [JournalDay]
}

public struct JournalFileSnapshot: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    case present
    case missing
    case unreadable
    case overCap
  }

  public let day: JournalDay
  public let text: String
  public let outcome: Outcome

  public init(day: JournalDay, text: String, outcome: Outcome) {
    self.day = day
    self.text = text
    self.outcome = outcome
  }
}

/// Safe diagnostics contain only reasons, never file contents or underlying filesystem errors.
public enum JournalFileError: Error, Sendable, Equatable {
  case pathRefused
  case unreadable
  case overCap
  case writeFailed
  case deleteFailed
  case listingFailed
}
