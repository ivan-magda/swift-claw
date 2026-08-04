import Foundation

public struct SkillDescriptor: Sendable, Equatable, Identifiable {
  public let name: String
  public let description: String
  public let directory: URL

  public var id: String { name }

  public init(name: String, description: String, directory: URL) {
    self.name = name
    self.description = description
    self.directory = directory
  }
}

public enum ContextRowID: String, Sendable, Equatable, CaseIterable {
  case policy
  case systemWorkspace
  case tools
  case metadata
  case userFile
  case memoryFile
  case memoryItems
  case history
  case recall
  case skills
}

public enum ContextTier: Sendable, Equatable {
  case system
  case untrustedLabeled
  case mixed
}

public struct ContextPriority: Sendable, Equatable, Comparable, Hashable {
  public let rawValue: Int

  public init(_ rawValue: Int) {
    self.rawValue = rawValue
  }

  public static func < (lhs: ContextPriority, rhs: ContextPriority) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct Section: Sendable, Equatable, Identifiable {
  public let id: ContextRowID
  public let tier: ContextTier
  public let priority: ContextPriority
  public let truncatable: Bool
  public let cap: Int?
  public let content: String

  public init(
    id: ContextRowID,
    tier: ContextTier,
    priority: ContextPriority,
    truncatable: Bool,
    cap: Int?,
    content: String
  ) {
    self.id = id
    self.tier = tier
    self.priority = priority
    self.truncatable = truncatable
    self.cap = cap
    self.content = content
  }
}

public struct ContextBudget: Sendable, Equatable {
  public let inputCapGraphemes: Int
  public let userFileCap: Int
  public let memoryFileCap: Int
  public let itemsCap: Int
  public let historyCap: Int
  public let recallCap: Int
  public let skillsCap: Int
  public let recallHitCap: Int

  public init(
    inputCapGraphemes: Int,
    userFileCap: Int,
    memoryFileCap: Int,
    itemsCap: Int,
    historyCap: Int,
    recallCap: Int,
    skillsCap: Int,
    recallHitCap: Int
  ) {
    self.inputCapGraphemes = inputCapGraphemes
    self.userFileCap = userFileCap
    self.memoryFileCap = memoryFileCap
    self.itemsCap = itemsCap
    self.historyCap = historyCap
    self.recallCap = recallCap
    self.skillsCap = skillsCap
    self.recallHitCap = recallHitCap
  }

  public static let `default` = ContextBudget(
    inputCapGraphemes: TokenEstimator.graphemeBudget(
      forInputTokens: RunBudget.default.maxInputTokens
    ),
    userFileCap: 1_375,
    memoryFileCap: 2_200,
    itemsCap: 1_500,
    historyCap: 6_000,
    recallCap: 2_000,
    skillsCap: 4_000,
    recallHitCap: 400
  )
}

public struct BuildResult: Sendable, Equatable {
  public let messages: [ChatMessage]
  public let ownerNotices: [String]
  public let hasPrivateDataAccess: Bool
  /// The per-run prompt/workspace fingerprint; "" only for test doubles that do not
  /// exercise the approval fabric — `ContextBuilder.assemble` always sets the real value.
  public let policyVersion: String

  public init(
    messages: [ChatMessage],
    ownerNotices: [String],
    hasPrivateDataAccess: Bool,
    policyVersion: String = ""
  ) {
    self.messages = messages
    self.ownerNotices = ownerNotices
    self.hasPrivateDataAccess = hasPrivateDataAccess
    self.policyVersion = policyVersion
  }
}

public struct RecallScore: Sendable, Equatable, Comparable, Hashable {
  public let value: Double

  public init(sqliteBM25: Double) {
    value = -sqliteBM25
  }

  public init(value: Double) {
    self.value = value
  }

  public static func < (lhs: RecallScore, rhs: RecallScore) -> Bool {
    lhs.value < rhs.value
  }
}

public struct RecallHit: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let sessionId: Int64
  public let role: MessageRole
  public let content: String
  public let score: RecallScore
  public let createdAt: Date

  public init(
    id: Int64,
    sessionId: Int64,
    role: MessageRole,
    content: String,
    score: RecallScore,
    createdAt: Date
  ) {
    self.id = id
    self.sessionId = sessionId
    self.role = role
    self.content = content
    self.score = score
    self.createdAt = createdAt
  }
}

public struct LabeledContext: Sendable, Equatable {
  private static let fenceTag = "claw-untrusted"
  private static let defusedFenceTag = "claw-untrusted-escaped"

  public let label: String
  public let content: String
  public let nonce: String

  public init(label: String, content: String, nonce: String) {
    self.label = label
    self.content = content
    self.nonce = nonce
  }

  public func render() -> String {
    """
    <\(Self.fenceTag) nonce="\(nonce)" label="\(label)">
    \(Self.defusingFenceTags(in: content))
    </\(Self.fenceTag) nonce="\(nonce)">
    """
  }

  private static func defusingFenceTags(in content: String) -> String {
    content.replacingOccurrences(
      of: fenceTag,
      with: defusedFenceTag,
      options: [.caseInsensitive]
    )
  }
}
