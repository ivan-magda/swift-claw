import ClawCore
import Foundation

// MARK: - Skills Index

extension ContextBuilder {
  /// Scans before consulting the cap: an authoring fault is the owner's to fix whether or not this
  /// turn had room for the index, and a zero cap is left to the fitter so the drop is announced.
  func skillsSection(residual: Int, ownerNotices: inout [String]) -> FittableSection? {
    let scan = workspace.scanSkills()
    for warning in scan.warnings {
      warn("skills scan warning: \(warning)")
      if case .unreadableSkillsDirectory = warning {
        // Ordinary turns scan repeatedly; a transient I/O failure stays in diagnostics and logs
        // instead of notifying the owner on every message.
        continue
      }
      ownerNotices.append("⚠ \(warning.ownerFacingReason)")
    }

    let units = scan.descriptors.map { descriptor in
      SectionUnit(
        id: Self.skillUnitID(for: descriptor.name),
        content: WorkspaceSkills.indexLine(for: descriptor),
        canTruncate: false
      )
    }
    guard units.isEmpty == false else {
      return nil
    }

    return section(
      id: .skills,
      cap: cap(for: .skills, residual: residual),
      dropMarker: .showingCount(noun: "skills"),
      units: units
    )
  }

  /// A skills row too big for its cap comes back shrunk, but one whose cap admits nothing at all is
  /// gone from `fitted` entirely — the case the owner most needs told, so it reads as every skill
  /// dropped rather than as no skills installed.
  func droppedSkillsNotice(fitted: [FittedSection], requested: [FittableSection]) -> String? {
    guard let source = requested.first(where: { section in section.id == .skills }) else {
      return nil
    }

    let fittedSkills = fitted.first { section in
      section.id == .skills
    }
    let dropped =
      (fittedSkills?.droppedUnitIDs ?? source.units.map(\.id))
      .map(Self.skillName(fromUnitID:))
    guard dropped.isEmpty == false else {
      return nil
    }

    let names = dropped.map { name in
      "`\(name)`"
    }.joined(separator: ", ")

    return "⚠ Skills index over budget; left out this turn: \(names). Trim their descriptions."
  }
}

// MARK: - Skill Unit Identity

private extension ContextBuilder {
  static let skillUnitIDPrefix = "skill-"

  static func skillUnitID(for name: String) -> String {
    "\(skillUnitIDPrefix)\(name)"
  }

  static func skillName(fromUnitID unitID: String) -> String {
    String(unitID.dropFirst(skillUnitIDPrefix.count))
  }
}
