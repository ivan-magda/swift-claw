/// Reasons must be redacted by the caller before persistence or diagnostics.
public enum JournalOutcome: Codable, Sendable, Equatable {
  case written
  case empty
  case invalidSummary(redactedReason: String)
  case failed(redactedReason: String)
  case skipped(redactedReason: String)
  case cancelled
  case interrupted
}
