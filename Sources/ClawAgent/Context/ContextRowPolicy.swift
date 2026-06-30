import ClawCore
import Foundation

public enum ContextRowCap: Sendable, Equatable {
  case none
  case userFile
  case memoryFile
  case memoryItems
  case history
  case recall
  case skills

  public func resolve(in budget: ContextBudget, residualGraphemes: Int?) -> Int? {
    switch self {
    case .none:
      nil
    case .userFile:
      budget.userFileCap
    case .memoryFile:
      budget.memoryFileCap
    case .memoryItems:
      scaledTruncatableCap(
        absolute: budget.itemsCap,
        budget: budget,
        residualGraphemes: residualGraphemes
      )
    case .history:
      scaledTruncatableCap(
        absolute: budget.historyCap,
        budget: budget,
        residualGraphemes: residualGraphemes
      )
    case .recall:
      scaledTruncatableCap(
        absolute: budget.recallCap,
        budget: budget,
        residualGraphemes: residualGraphemes
      )
    case .skills:
      scaledTruncatableCap(
        absolute: budget.skillsCap,
        budget: budget,
        residualGraphemes: residualGraphemes
      )
    }
  }

  private func scaledTruncatableCap(
    absolute: Int,
    budget: ContextBudget,
    residualGraphemes: Int?
  ) -> Int {
    guard let residualGraphemes else { return absolute }

    let total = budget.itemsCap + budget.historyCap + budget.recallCap + budget.skillsCap
    guard total > 0, residualGraphemes > 0 else { return 0 }

    let scaled = Int((Double(absolute) / Double(total) * Double(residualGraphemes)).rounded(.down))
    return min(absolute, scaled)
  }
}

public struct RowSpec: Sendable, Equatable, Identifiable {
  public let id: ContextRowID
  public let tier: ContextTier
  public let priority: ContextPriority
  public let truncatable: Bool
  public let cap: ContextRowCap

  public init(
    id: ContextRowID,
    tier: ContextTier,
    priority: ContextPriority,
    truncatable: Bool,
    cap: ContextRowCap
  ) {
    self.id = id
    self.tier = tier
    self.priority = priority
    self.truncatable = truncatable
    self.cap = cap
  }
}

public enum ContextRowPolicy {
  public static let specs: [RowSpec] = [
    RowSpec(
      id: .policy,
      tier: .system,
      priority: ContextPriority(0),
      truncatable: false,
      cap: .none
    ),
    RowSpec(
      id: .systemWorkspace,
      tier: .system,
      priority: ContextPriority(10),
      truncatable: false,
      cap: .none
    ),
    RowSpec(
      id: .tools,
      tier: .system,
      priority: ContextPriority(20),
      truncatable: false,
      cap: .none
    ),
    RowSpec(
      id: .metadata,
      tier: .system,
      priority: ContextPriority(30),
      truncatable: false,
      cap: .none
    ),
    RowSpec(
      id: .userFile,
      tier: .untrustedLabeled,
      priority: ContextPriority(40),
      truncatable: false,
      cap: .userFile
    ),
    RowSpec(
      id: .memoryFile,
      tier: .untrustedLabeled,
      priority: ContextPriority(50),
      truncatable: false,
      cap: .memoryFile
    ),
    RowSpec(
      id: .memoryItems,
      tier: .untrustedLabeled,
      priority: ContextPriority(60),
      truncatable: true,
      cap: .memoryItems
    ),
    RowSpec(
      id: .history,
      tier: .mixed,
      priority: ContextPriority(70),
      truncatable: true,
      cap: .history
    ),
    RowSpec(
      id: .recall,
      tier: .untrustedLabeled,
      priority: ContextPriority(80),
      truncatable: true,
      cap: .recall
    ),
    RowSpec(
      id: .skills,
      tier: .untrustedLabeled,
      priority: ContextPriority(90),
      truncatable: true,
      cap: .skills
    ),
  ]
}
