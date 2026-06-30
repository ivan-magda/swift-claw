import ClawCore
import Foundation

public struct SectionUnit: Sendable, Equatable {
  public let id: String
  public let content: String
  public let canTruncate: Bool

  public init(id: String = "", content: String, canTruncate: Bool) {
    self.id = id
    self.content = content
    self.canTruncate = canTruncate
  }
}

public struct FittableSection: Sendable, Equatable, Identifiable {
  public let id: ContextRowID
  public let tier: ContextTier
  public let priority: ContextPriority
  public let truncatable: Bool
  public let cap: Int?
  public let units: [SectionUnit]

  public init(
    id: ContextRowID,
    tier: ContextTier,
    priority: ContextPriority,
    truncatable: Bool,
    cap: Int?,
    units: [SectionUnit]
  ) {
    self.id = id
    self.tier = tier
    self.priority = priority
    self.truncatable = truncatable
    self.cap = cap
    self.units = units
  }
}

public struct FittedSection: Sendable, Equatable, Identifiable {
  public let id: ContextRowID
  public let tier: ContextTier
  public let priority: ContextPriority
  public let truncatable: Bool
  public let cap: Int?
  public let units: [SectionUnit]

  public var content: String {
    Self.render(units: units)
  }

  public var section: Section {
    Section(
      id: id,
      tier: tier,
      priority: priority,
      truncatable: truncatable,
      cap: cap,
      content: content
    )
  }

  fileprivate init(source: FittableSection, units: [SectionUnit]) {
    id = source.id
    tier = source.tier
    priority = source.priority
    truncatable = source.truncatable
    cap = source.cap
    self.units = units
  }

  private static func render(units: [SectionUnit]) -> String {
    units.map(\.content).joined(separator: "\n")
  }
}

public enum BudgetFitterError: Error, Equatable {
  case nonTruncatableRowsExceedInputCap(required: Int, cap: Int)
}

public enum BudgetFitter {
  public static let truncationMarker = "…[truncated]"

  public static func fit(
    _ sections: [FittableSection],
    budget: ContextBudget
  ) throws -> [Section] {
    try fitWithUnits(sections, budget: budget).map(\.section)
  }

  public static func fitWithUnits(
    _ sections: [FittableSection],
    budget: ContextBudget
  ) throws -> [FittedSection] {
    let ordered = sections.sorted { first, second in
      first.priority < second.priority
    }
    let nonTruncatable = ordered.filter { section in !section.truncatable }
    let truncatable = ordered.filter(\.truncatable)
    let required = nonTruncatable.map(renderedCount).reduce(0, +)

    guard required <= budget.inputCapGraphemes else {
      throw BudgetFitterError.nonTruncatableRowsExceedInputCap(
        required: required,
        cap: budget.inputCapGraphemes
      )
    }

    let residual = budget.inputCapGraphemes - required
    let cappedRows = truncatable.compactMap { section -> FittedRow? in
      let maxCount = min(section.cap ?? Int.max, renderedCount(section))
      return fittedRow(for: section, maxCount: maxCount)
    }
    var fittedRows = cappedRows
    var cappedTotal = fittedRows.map(\.content.count).reduce(0, +)

    if cappedTotal > residual {
      var excess = cappedTotal - residual
      for index in fittedRows.indices.reversed() where excess > 0 {
        let current = fittedRows[index]
        let targetCount = max(0, current.content.count - excess)

        if let shrunk = fittedRow(for: current.source, maxCount: targetCount) {
          excess -= current.content.count - shrunk.content.count
          fittedRows[index] = shrunk
        } else {
          excess -= current.content.count
          fittedRows.remove(at: index)
        }
      }
      cappedTotal = fittedRows.map(\.content.count).reduce(0, +)
      precondition(cappedTotal <= residual)
    }

    let fixedSections = nonTruncatable.map { section in
      FittedSection(source: section, units: section.units)
    }
    let fittedSections = fittedRows.map { row in
      FittedSection(source: row.source, units: row.units)
    }

    return (fixedSections + fittedSections).sorted { first, second in
      first.priority < second.priority
    }
  }

  private static func fittedRow(for section: FittableSection, maxCount: Int) -> FittedRow? {
    guard maxCount > 0 else {
      return nil
    }

    var kept: [SectionUnit] = []
    var used = 0

    for unit in section.units {
      let separatorCount = kept.isEmpty ? 0 : 1
      let wholeCount = separatorCount + unit.content.count

      if used + wholeCount <= maxCount {
        kept.append(unit)
        used += wholeCount
        continue
      }

      guard unit.canTruncate else {
        if section.id == .history {
          break
        }
        continue
      }

      let available = maxCount - used - separatorCount
      guard available >= truncationMarker.count + 1 else {
        continue
      }

      let prefixCount = available - truncationMarker.count
      let prefix = String(unit.content.prefix(prefixCount))
      kept.append(
        SectionUnit(id: unit.id, content: prefix + truncationMarker, canTruncate: unit.canTruncate)
      )
      break
    }

    guard !kept.isEmpty else {
      return nil
    }

    return FittedRow(source: section, units: kept)
  }

  private static func renderedCount(_ section: FittableSection) -> Int {
    render(units: section.units).count
  }

  private static func render(units: [SectionUnit]) -> String {
    units.map(\.content).joined(separator: "\n")
  }
}

private struct FittedRow: Equatable {
  let source: FittableSection
  let units: [SectionUnit]

  var content: String {
    units.map(\.content).joined(separator: "\n")
  }
}
