import ClawCore
import Foundation

extension ContextRowID {
  /// The grapheme cap this row is assembled under, or nil when it is uncapped. The four system rows
  /// carry no cap, and neither does the lessons row — its content is already capped at three
  /// lessons and 1536 bytes when the set is built. The four truncatable rows are scaled against
  /// whatever the fixed sections left.
  public func resolve(in budget: ContextBudget, residualGraphemes: Int?) -> Int? {
    switch self {
    case .policy, .systemWorkspace, .tools, .metadata, .lessons:
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
    guard let residualGraphemes else {
      return absolute
    }

    let total = budget.itemsCap + budget.historyCap + budget.recallCap + budget.skillsCap
    guard total > 0, residualGraphemes > 0 else {
      return 0
    }

    let scaled = Int((Double(absolute) / Double(total) * Double(residualGraphemes)).rounded(.down))
    return min(absolute, scaled)
  }
}

public struct RowSpec: Sendable, Equatable, Identifiable {
  public let id: ContextRowID
  public let tier: ContextTier
  public let priority: ContextPriority
  public let truncatable: Bool

  public init(
    id: ContextRowID,
    tier: ContextTier,
    priority: ContextPriority,
    truncatable: Bool
  ) {
    self.id = id
    self.tier = tier
    self.priority = priority
    self.truncatable = truncatable
  }
}

public enum ContextRowPolicy {
  public static let specs: [RowSpec] = [
    RowSpec(
      id: .policy,
      tier: .system,
      priority: ContextPriority(0),
      truncatable: false
    ),
    RowSpec(
      id: .systemWorkspace,
      tier: .system,
      priority: ContextPriority(10),
      truncatable: false
    ),
    RowSpec(
      id: .tools,
      tier: .system,
      priority: ContextPriority(20),
      truncatable: false
    ),
    RowSpec(
      id: .metadata,
      tier: .system,
      priority: ContextPriority(30),
      truncatable: false
    ),
    RowSpec(
      id: .lessons,
      tier: .untrustedLabeled,
      priority: ContextPriority(35),
      truncatable: false
    ),
    RowSpec(
      id: .userFile,
      tier: .untrustedLabeled,
      priority: ContextPriority(40),
      truncatable: false
    ),
    RowSpec(
      id: .memoryFile,
      tier: .untrustedLabeled,
      priority: ContextPriority(50),
      truncatable: false
    ),
    RowSpec(
      id: .memoryItems,
      tier: .untrustedLabeled,
      priority: ContextPriority(60),
      truncatable: true
    ),
    RowSpec(
      id: .history,
      tier: .mixed,
      priority: ContextPriority(70),
      truncatable: true
    ),
    RowSpec(
      id: .recall,
      tier: .untrustedLabeled,
      priority: ContextPriority(80),
      truncatable: true
    ),
    RowSpec(
      id: .skills,
      tier: .untrustedLabeled,
      priority: ContextPriority(90),
      truncatable: true
    ),
  ]
}
