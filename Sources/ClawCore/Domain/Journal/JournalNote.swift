public struct JournalNote: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case decision
    case result
    case followUp = "follow_up"
  }

  public enum Attribution: String, Codable, Sendable, CaseIterable {
    case owner
    case assistantReport = "assistant_report"
    case workerReport = "worker_report"
    case observedOperation = "observed_operation"
  }

  private enum CodingKeys: String, CodingKey {
    case kind, attribution, text
    case sourceIDs = "source_ids"
  }

  public let kind: Kind
  public let attribution: Attribution
  public let text: String
  public let sourceIDs: [String]

  /// Summary validation checks note bounds, source membership and supporting typed evidence.
  public init(kind: Kind, attribution: Attribution, text: String, sourceIDs: [String]) {
    self.kind = kind
    self.attribution = attribution
    self.text = text
    self.sourceIDs = sourceIDs
  }
}

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
