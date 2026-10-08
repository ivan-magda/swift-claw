import Foundation

public struct JournalStartRequest: Sendable {
  public let sourceIDs: [String]
  public let scope: JournalScope
  public let day: JournalDay
  public let sessionID: Int64
  public let providerCallID: ProviderCallID
  public let estimate: ProviderUsageAccountant.PreflightEstimate
  public let conservativeUsage: ProviderUsage
  public let budget: RunBudget
  public let costPolicy: LLMCostPolicy

  public init(
    sourceIDs: [String],
    scope: JournalScope,
    day: JournalDay,
    sessionID: Int64,
    providerCallID: ProviderCallID,
    estimate: ProviderUsageAccountant.PreflightEstimate,
    conservativeUsage: ProviderUsage,
    budget: RunBudget,
    costPolicy: LLMCostPolicy
  ) {
    self.sourceIDs = sourceIDs
    self.scope = scope
    self.day = day
    self.sessionID = sessionID
    self.providerCallID = providerCallID
    self.estimate = estimate
    self.conservativeUsage = conservativeUsage
    self.budget = budget
    self.costPolicy = costPolicy
  }
}

public struct JournalBatch: Codable, Sendable, Equatable {
  public let id: UUID
  public let sourceIDs: [String]
  public let scope: JournalScope
  public let day: JournalDay
  public let sessionID: Int64
  public let providerCallID: ProviderCallID

  public init(
    id: UUID,
    sourceIDs: [String],
    scope: JournalScope,
    day: JournalDay,
    sessionID: Int64,
    providerCallID: ProviderCallID
  ) {
    self.id = id
    self.sourceIDs = sourceIDs
    self.scope = scope
    self.day = day
    self.sessionID = sessionID
    self.providerCallID = providerCallID
  }
}

public enum JournalStartOutcome: Sendable, Equatable {
  case started(JournalBatch)
  case deferred(cap: String)
  case obsolete
}

public struct JournalStatus: Sendable, Equatable {
  public let pendingCount: Int
  public let lastOutcome: JournalOutcome?
  public let lastOutcomeAt: Date?
  public let skippedCount: Int
  public let interruptedCount: Int
  public let lastRedactedError: String?

  public init(
    pendingCount: Int,
    lastOutcome: JournalOutcome?,
    lastOutcomeAt: Date?,
    skippedCount: Int,
    interruptedCount: Int,
    lastRedactedError: String?
  ) {
    self.pendingCount = pendingCount
    self.lastOutcome = lastOutcome
    self.lastOutcomeAt = lastOutcomeAt
    self.skippedCount = skippedCount
    self.interruptedCount = interruptedCount
    self.lastRedactedError = lastRedactedError
  }
}
