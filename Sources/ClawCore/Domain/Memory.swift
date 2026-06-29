import Foundation

public enum MemoryKind: String, Sendable, Equatable, CaseIterable {
  case user
  case feedback
  case project
  case reference
}

public enum Sensitivity: String, Sendable, Equatable, CaseIterable {
  case normal
  case high
}

public enum Importance: Int, Sendable, Equatable, Comparable, CaseIterable {
  case low = 0
  case normal = 1
  case high = 2

  public static func < (lhs: Importance, rhs: Importance) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public enum MemorySource: String, Sendable, Equatable {
  case owner
}

public struct MemoryItem: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let text: String
  public let kind: MemoryKind
  public let sensitivity: Sensitivity
  public let importance: Importance
  public let source: MemorySource
  public let sessionId: Int64?
  public let createdAt: Date

  public init(
    id: Int64,
    text: String,
    kind: MemoryKind,
    sensitivity: Sensitivity,
    importance: Importance,
    source: MemorySource,
    sessionId: Int64?,
    createdAt: Date
  ) {
    self.id = id
    self.text = text
    self.kind = kind
    self.sensitivity = sensitivity
    self.importance = importance
    self.source = source
    self.sessionId = sessionId
    self.createdAt = createdAt
  }
}

public struct NewMemoryItem: Sendable, Equatable {
  public let text: String
  public let kind: MemoryKind
  public let sensitivity: Sensitivity
  public let importance: Importance
  public let source: MemorySource
  public let sessionId: Int64?

  public init(
    text: String,
    kind: MemoryKind,
    sensitivity: Sensitivity = .normal,
    importance: Importance = .normal,
    source: MemorySource = .owner,
    sessionId: Int64?
  ) {
    self.text = text
    self.kind = kind
    self.sensitivity = sensitivity
    self.importance = importance
    self.source = source
    self.sessionId = sessionId
  }
}
