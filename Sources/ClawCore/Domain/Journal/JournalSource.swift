import Foundation

/// A support-only proposal. Capture redacts and shortens text before constructing it.
public struct JournalProposal: Codable, Sendable, Equatable {
  public let sourceID: String
  public let text: String

  public init(sourceID: String, text: String) throws {
    try JournalSource.validateID(sourceID)
    try JournalSource.validateText(text, field: "proposal", limit: JournalLimits.proposalGraphemes)
    self.sourceID = sourceID
    self.text = text
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      sourceID: container.decode(String.self, forKey: .sourceID),
      text: container.decode(String.self, forKey: .text)
    )
  }
}

/// Typed evidence supplied by production code, never inferred from observation prose.
public struct JournalEvidence: Codable, Sendable, Equatable {
  public enum Outcome: Codable, Sendable, Equatable {
    case tool(ToolObservationStatus)
    case coder(CoderJobState)
    case publication(CoderPublication)
    case workerReportedChecks
  }

  public let outcome: Outcome
  public let jobID: UUID?
  public let name: String
  public let detail: String?

  public init(outcome: Outcome, jobID: UUID? = nil, name: String, detail: String? = nil) throws {
    try JournalSource.validateText(
      name,
      field: "evidence.name",
      limit: JournalLimits.evidenceFieldGraphemes
    )
    if let detail {
      try JournalSource.validateText(
        detail,
        field: "evidence.detail",
        limit: JournalLimits.evidenceFieldGraphemes
      )
    }
    if case .publication(let publication) = outcome {
      let url: String? =
        switch publication {
        case .absent:
          nil
        case .confirmed(let url):
          url
        case .unknown(let reportedURL):
          reportedURL
        }
      if let url {
        try JournalSource.validateText(
          url,
          field: "evidence.publicationURL",
          limit: JournalLimits.evidenceFieldGraphemes
        )
      }
    }
    self.outcome = outcome
    self.jobID = jobID
    self.name = name
    self.detail = detail
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      outcome: container.decode(Outcome.self, forKey: .outcome),
      jobID: container.decodeIfPresent(UUID.self, forKey: .jobID),
      name: container.decode(String.self, forKey: .name),
      detail: container.decodeIfPresent(String.self, forKey: .detail)
    )
  }
}

/// A bounded durable source. Redaction and head/tail shortening belong to capture.
public struct JournalSource: Codable, Sendable, Equatable {
  public let id: String
  public let scope: JournalScope
  public let sessionID: Int64
  public let occurredAt: Date
  public let day: JournalDay
  public let ownerText: String
  public let assistantText: String
  public let supportingProposal: JournalProposal?
  public let coderJobID: UUID?
  public let evidence: [JournalEvidence]

  public init(
    id: String,
    scope: JournalScope,
    sessionID: Int64,
    occurredAt: Date,
    day: JournalDay,
    ownerText: String,
    assistantText: String,
    supportingProposal: JournalProposal? = nil,
    coderJobID: UUID? = nil,
    evidence: [JournalEvidence] = []
  ) throws {
    try Self.validateID(id)
    try Self.validateText(ownerText, field: "ownerText", limit: JournalLimits.ownerTextGraphemes)
    try Self.validateText(
      assistantText,
      field: "assistantText",
      limit: JournalLimits.assistantTextGraphemes
    )
    guard evidence.count <= JournalLimits.evidenceEntries else {
      throw JournalValueError.tooManyEvidenceEntries
    }
    self.id = id
    self.scope = scope
    self.sessionID = sessionID
    self.occurredAt = occurredAt
    self.day = day
    self.ownerText = ownerText
    self.assistantText = assistantText
    self.supportingProposal = supportingProposal
    self.coderJobID = coderJobID
    self.evidence = evidence

    guard try JSONEncoder().encode(self).count <= JournalLimits.storedSourceBytes else {
      throw JournalValueError.sourceTooLarge
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(String.self, forKey: .id),
      scope: container.decode(JournalScope.self, forKey: .scope),
      sessionID: container.decode(Int64.self, forKey: .sessionID),
      occurredAt: container.decode(Date.self, forKey: .occurredAt),
      day: container.decode(JournalDay.self, forKey: .day),
      ownerText: container.decode(String.self, forKey: .ownerText),
      assistantText: container.decode(String.self, forKey: .assistantText),
      supportingProposal: container.decodeIfPresent(
        JournalProposal.self,
        forKey: .supportingProposal
      ),
      coderJobID: container.decodeIfPresent(UUID.self, forKey: .coderJobID),
      evidence: container.decode([JournalEvidence].self, forKey: .evidence)
    )
  }
}

// MARK: - Durable Payload Validation

fileprivate extension JournalSource {
  static func validateID(_ id: String) throws {
    if id.hasPrefix("message:"), let messageID = Int64(id.dropFirst("message:".count)),
       messageID > 0
    {
      return
    }
    if id.hasPrefix("coder:"), UUID(uuidString: String(id.dropFirst("coder:".count))) != nil {
      return
    }
    throw JournalValueError.invalidSourceID
  }

  static func validateText(_ text: String, field: String, limit: Int) throws {
    guard text.count <= limit else {
      throw JournalValueError.textTooLong(field: field)
    }
  }
}

/// Archive input is redacted before capture constructs the bounded durable proposal.
public struct JournalExchangeInput: Sendable, Equatable {
  public struct Proposal: Sendable, Equatable {
    public let sourceID: String
    public let text: String

    public init(sourceID: String, text: String) {
      self.sourceID = sourceID
      self.text = text
    }
  }

  public let admission: JournalExchangeAdmission
  public let sessionID: Int64
  public let triggerMessageID: Int64
  public let ownerText: String
  public let supportingProposal: Proposal?

  public init(
    admission: JournalExchangeAdmission,
    sessionID: Int64,
    triggerMessageID: Int64,
    ownerText: String,
    supportingProposal: Proposal?
  ) {
    self.admission = admission
    self.sessionID = sessionID
    self.triggerMessageID = triggerMessageID
    self.ownerText = ownerText
    self.supportingProposal = supportingProposal
  }
}
