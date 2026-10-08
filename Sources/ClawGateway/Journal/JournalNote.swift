/// Summary validation checks note bounds, source membership and supporting typed evidence.
struct JournalNote: Codable, Sendable, Equatable {
  enum Kind: String, Codable, Sendable, CaseIterable {
    case decision
    case result
    case followUp = "follow_up"
  }

  enum Attribution: String, Codable, Sendable, CaseIterable {
    case owner
    case assistantReport = "assistant_report"
    case workerReport = "worker_report"
    case observedOperation = "observed_operation"
  }

  private enum CodingKeys: String, CodingKey {
    case kind, attribution, text
    case sourceIDs = "source_ids"
  }

  let kind: Kind
  let attribution: Attribution
  let text: String
  let sourceIDs: [String]
}
