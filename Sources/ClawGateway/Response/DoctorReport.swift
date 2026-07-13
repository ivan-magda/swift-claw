import Foundation

public enum DoctorGroup: String, Sendable, Codable, Equatable, CaseIterable {
  case config
  case database
  case llmRuns = "llm_runs"
  case spend
  case storage
  case scheduler
  case approvals
  case connectivity
  case sandbox

  public var title: String {
    switch self {
    case .config: "Config"
    case .database: "Database"
    case .llmRuns: "LLM & Runs"
    case .spend: "Spend"
    case .storage: "Storage"
    case .scheduler: "Scheduler"
    case .approvals: "Approvals"
    case .connectivity: "Connectivity"
    case .sandbox: "Sandbox"
    }
  }
}

/// The doctor/status health table.
/// Holds a list of named checks, each tagged with the `DoctorGroup` it belongs to;
/// `ok` is the conjunction of all of them.
/// Renders as a grouped human table or machine-readable JSON.
public struct DoctorReport: Sendable {
  public struct Check: Sendable, Codable, Equatable {
    public let key: String
    public let value: String
    public let ok: Bool
    public let group: DoctorGroup
    public let isHeadline: Bool

    public init(
      key: String,
      value: String,
      ok: Bool,
      group: DoctorGroup,
      isHeadline: Bool = false
    ) {
      self.key = key
      self.value = value
      self.ok = ok
      self.group = group
      self.isHeadline = isHeadline
    }
  }

  public private(set) var checks: [Check]

  public init(checks: [Check] = []) {
    self.checks = checks
  }

  public var ok: Bool { checks.allSatisfy(\.ok) }

  public mutating func add(
    key: String,
    value: String,
    ok: Bool = true,
    group: DoctorGroup,
    headline: Bool = false
  ) {
    checks.append(Check(key: key, value: value, ok: ok, group: group, isHeadline: headline))
  }

  public mutating func add(contentsOf newChecks: [Check]) {
    checks.append(contentsOf: newChecks)
  }

  public func renderText() -> String {
    let sections = DoctorGroup.allCases.compactMap { group -> String? in
      let rows = checks.filter { $0.group == group }

      guard !rows.isEmpty else {
        return nil
      }

      return renderSection(group: group, rows: rows)
    }

    return sections.joined(separator: "\n\n")
  }

  public func renderTelegramSummary() -> String {
    let failingCount = checks.count { !$0.ok }
    let verdict =
      failingCount == 0
      ? "clawd: all systems healthy"
      : "clawd: \(failingCount) \(failingCount == 1 ? "check" : "checks") failing"

    let sections = DoctorGroup.allCases.compactMap { group -> String? in
      let rows = checks.filter { $0.group == group }

      guard !rows.isEmpty else {
        return nil
      }

      return summarySection(group: group, rows: rows)
    }

    return ([verdict, ""] + sections).joined(separator: "\n")
  }

  public func renderJSON() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let payload = DoctorReportPayload(ok: ok, checks: checks)
    let data = (try? encoder.encode(payload)) ?? Data("{}".utf8)

    return String(bytes: data, encoding: .utf8) ?? "{}"
  }
}

private extension DoctorReport {
  static let headerStatusColumn = 40

  func renderSection(group: DoctorGroup, rows: [Check]) -> String {
    let keyWidth = rows.map(\.key.count).max() ?? 0

    let allOK = rows.allSatisfy(\.ok)
    let header = renderHeader(title: group.title, ok: allOK)
    let body = rows.map { row in
      renderRow(row, keyWidth: keyWidth)
    }

    return ([header] + body).joined(separator: "\n")
  }

  func renderHeader(title: String, ok: Bool) -> String {
    let status = ok ? "ok" : "FAIL"
    let dotCount = max(1, Self.headerStatusColumn - title.count - 1)
    let fill = String(repeating: ".", count: dotCount)
    return "\(title) \(fill) \(status)"
  }

  func renderRow(_ check: Check, keyWidth: Int) -> String {
    let marker = check.ok ? "  " : "✗ "
    let paddedKey = check.key.padding(toLength: keyWidth, withPad: " ", startingAt: 0)
    return "  \(marker)\(paddedKey)  \(check.value)"
  }

  static let summaryValueLimit = 200

  func summarySection(group: DoctorGroup, rows: [Check]) -> String {
    let groupOK = rows.allSatisfy(\.ok)

    let headlines = rows.filter { row in
      row.isHeadline && row.ok
    }.map { row in
      "\(Self.shortKey(row.key)) \(row.value)"
    }
    let header = (["\(group.title): \(groupOK ? "ok" : "FAIL")"] + headlines)
      .joined(separator: " · ")

    var lines = [header]
    for row in rows where !row.ok {
      lines.append("  \(row.key): \(Self.truncatedValue(row.value))")
    }

    return lines.joined(separator: "\n")
  }

  /// The key's last dotted component — the group line already names the subsystem.
  static func shortKey(_ key: String) -> String {
    key.split(separator: ".").last.map(String.init) ?? key
  }

  static func truncatedValue(_ value: String) -> String {
    if value.count > summaryValueLimit {
      return value.prefix(summaryValueLimit - 1) + "…"
    }
    return value
  }
}

private struct DoctorReportPayload: Encodable {
  let ok: Bool
  let checks: [DoctorReport.Check]
}
