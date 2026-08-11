import ClawCore

/// A read-only owner view of one complete workspace skill scan.
public struct SkillDiagnostics: Sendable, Equatable {
  public let scan: SkillScanResult
  public let skillsCap: Int

  public init(scan: SkillScanResult, skillsCap: Int) {
    self.scan = scan
    self.skillsCap = skillsCap
  }

  public var acceptedCount: Int {
    scan.descriptors.count
  }

  public var rejectedCount: Int {
    scan.warnings.count
  }

  public var completeIndexGraphemes: Int {
    WorkspaceSkills.completeIndexGraphemeCount(for: scan.descriptors)
  }

  public var fitsSkillsCap: Bool {
    completeIndexGraphemes <= skillsCap
  }

  public func render() -> String {
    let accepted = scan.descriptors.map { descriptor in
      WorkspaceSkills.indexLine(for: descriptor)
    }
    let rejected = scan.warnings.map { warning in
      "- \(warning.ownerFacingReason)"
    }

    return [
      Self.section(title: "Accepted", count: acceptedCount, lines: accepted),
      Self.section(title: "Rejected", count: rejectedCount, lines: rejected),
    ].joined(separator: "\n\n")
  }
}

private extension SkillDiagnostics {
  static func section(title: String, count: Int, lines: [String]) -> String {
    let body = lines.isEmpty ? ["None."] : lines
    return (["\(title) (\(count))"] + body).joined(separator: "\n")
  }
}
