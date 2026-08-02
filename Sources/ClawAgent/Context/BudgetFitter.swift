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

/// How a row announces the units the budget dropped. The row owns the wording so the fitter stays
/// row-agnostic, and the rendered line is cost-accounted inside the row's cap like any other unit.
public enum DropMarker: Sendable, Equatable {
  case none
  /// Renders as `(showing 1 of 4 skills)`; the noun names what was counted.
  case showingCount(noun: String)

  func line(kept: Int, total: Int) -> String? {
    switch self {
    case .none:
      nil
    case .showingCount(let noun):
      "(showing \(kept) of \(total) \(noun))"
    }
  }
}

public struct FittableSection: Sendable, Equatable, Identifiable {
  public let id: ContextRowID
  public let tier: ContextTier
  public let priority: ContextPriority
  public let truncatable: Bool
  public let cap: Int?
  public let dropMarker: DropMarker
  public let units: [SectionUnit]

  public init(
    id: ContextRowID,
    tier: ContextTier,
    priority: ContextPriority,
    truncatable: Bool,
    cap: Int?,
    dropMarker: DropMarker = .none,
    units: [SectionUnit]
  ) {
    self.id = id
    self.tier = tier
    self.priority = priority
    self.truncatable = truncatable
    self.cap = cap
    self.dropMarker = dropMarker
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
  /// The ids of the source units the budget left out, in source order.
  public let droppedUnitIDs: [String]

  public var content: String {
    renderUnits(units)
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

  fileprivate init(source: FittableSection, units: [SectionUnit], droppedUnitIDs: [String] = []) {
    self.id = source.id
    self.tier = source.tier
    self.priority = source.priority
    self.truncatable = source.truncatable
    self.cap = source.cap
    self.units = units
    self.droppedUnitIDs = droppedUnitIDs
  }
}

public enum BudgetFitterError: Error, Equatable {
  case nonTruncatableRowsExceedInputCap(required: Int, cap: Int)
}

public enum BudgetFitter {
  public static let truncationMarker = TextTruncation.marker
  /// The id carried by a row's drop-marker line, so consumers can tell it from a real unit.
  public static let dropMarkerUnitID = "drop-marker"

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
    // The newest history unit is kept even when it alone exceeds the residual (see `fittedRow`),
    // so the squeezed total can legitimately overshoot the residual by this floor.
    let historyFloorCount =
      ordered.first { section in section.id == .history }?.units.first?.content.count ?? 0
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
      precondition(cappedTotal <= max(residual, historyFloorCount))
    }

    let fixedSections = nonTruncatable.map { section in
      FittedSection(source: section, units: section.units)
    }
    let fittedSections = fittedRows.map { row in
      FittedSection(source: row.source, units: row.units, droppedUnitIDs: row.droppedUnitIDs)
    }

    return (fixedSections + fittedSections).sorted { first, second in
      first.priority < second.priority
    }
  }

  private static func fittedRow(for section: FittableSection, maxCount: Int) -> FittedRow? {
    // The newest history unit is the current turn; it is non-droppable even when it alone
    // exceeds the budget, so the model always sees the message it is answering. Flooring the
    // budget at its size means it is admitted whole on the first iteration; later units still
    // obey the contiguous newest-first stop rule.
    let historyFloor = section.id == .history ? (section.units.first?.content.count ?? 0) : 0
    let effectiveMax = max(maxCount, historyFloor)
    guard effectiveMax > 0 else {
      return nil
    }

    var kept: [SectionUnit] = []
    var used = 0

    for unit in section.units {
      let separatorCount = kept.isEmpty ? 0 : 1
      let wholeCount = separatorCount + unit.content.count

      if used + wholeCount <= effectiveMax {
        kept.append(unit)
        used += wholeCount
        continue
      }

      guard unit.canTruncate else {
        if keepsContiguousPrefix(section.id) {
          break
        }
        continue
      }

      let available = effectiveMax - used - separatorCount
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

    return markedRow(for: section, kept: kept, maxCount: effectiveMax)
  }

  /// Rows whose units mean something in order: history must stay a contiguous newest-first window,
  /// and the skills index drops as a prefix so its "N of M" marker describes a real slice.
  private static func keepsContiguousPrefix(_ id: ContextRowID) -> Bool {
    id == .history || id == .skills
  }

  /// Appends the row's drop marker when the budget left units out, buying its room by giving back
  /// kept units — the marker has to fit inside the same cap as the content it describes.
  private static func markedRow(
    for section: FittableSection,
    kept: [SectionUnit],
    maxCount: Int
  ) -> FittedRow? {
    var kept = kept

    while kept.isEmpty == false {
      let droppedIDs = droppedUnitIDs(in: section, kept: kept)
      guard
        droppedIDs.isEmpty == false,
        let marker = section.dropMarker.line(kept: kept.count, total: section.units.count)
      else {
        return FittedRow(source: section, units: kept, droppedUnitIDs: droppedIDs)
      }

      if renderUnits(kept).count + 1 + marker.count <= maxCount {
        return FittedRow(
          source: section,
          units: kept
            + [SectionUnit(id: dropMarkerUnitID, content: marker, canTruncate: false)],
          droppedUnitIDs: droppedIDs
        )
      }

      kept.removeLast()
    }

    return nil
  }

  private static func droppedUnitIDs(in section: FittableSection, kept: [SectionUnit]) -> [String] {
    // Kept units carry their source id even when truncated in place, so ids alone decide.
    let keptIDs = Set(kept.map(\.id))
    return section.units.map(\.id).filter { id in keptIDs.contains(id) == false }
  }

  private static func renderedCount(_ section: FittableSection) -> Int {
    renderUnits(section.units).count
  }
}

private struct FittedRow: Equatable {
  let source: FittableSection
  let units: [SectionUnit]
  let droppedUnitIDs: [String]

  var content: String {
    renderUnits(units)
  }
}

private func renderUnits(_ units: [SectionUnit]) -> String {
  units.map(\.content).joined(separator: "\n")
}
