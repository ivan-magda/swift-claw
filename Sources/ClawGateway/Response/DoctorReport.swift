import Foundation

public enum DoctorGroup: String, Sendable, Codable, Equatable, CaseIterable {
  case config
  case database
  case llmRuns = "llm_runs"
  case context
  case spend
  case storage
  case scheduler
  case approvals
  case connectivity
  case mcp
  case sandbox
  case hostShell = "host_shell"

  public var title: String {
    switch self {
    case .config: "Config"
    case .database: "Database"
    case .llmRuns: "LLM & Runs"
    case .context: "Context"
    case .spend: "Spend"
    case .storage: "Storage"
    case .scheduler: "Scheduler"
    case .approvals: "Approvals"
    case .connectivity: "Connectivity"
    case .mcp: "MCP"
    case .sandbox: "Sandbox"
    case .hostShell: "Host Shell"
    }
  }
}

/// Distinguishes a successful health read, including empty values, from an unreadable source.
public enum HealthValue<Value: Sendable>: Sendable {
  case available(Value)
  case unavailable
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
    nonEmptyGroups()
      .map { renderSection(group: $0.group, rows: $0.rows) }
      .joined(separator: "\n\n")
  }

  public func renderTelegramSummary() -> String {
    let failingCount = checks.count { !$0.ok }
    let verdict =
      failingCount == 0
      ? "clawd: all systems healthy"
      : "clawd: \(failingCount) \(failingCount == 1 ? "check" : "checks") failing"

    let sections = nonEmptyGroups().map { summarySection(group: $0.group, rows: $0.rows) }

    return ([verdict, ""] + sections).joined(separator: "\n")
  }

  /// One group on its own, every row included. The whole-report summary prints only failures under
  /// each heading, which is right when a dozen groups compete for one message; a reply asking about a
  /// single subsystem is asking to read its rows.
  public func renderTelegramGroup(_ group: DoctorGroup) -> String {
    let rows = checks.filter { $0.group == group }
    guard rows.isEmpty == false else {
      return "\(group.title): nothing reported"
    }

    let header = "\(group.title): \(rows.allSatisfy(\.ok) ? "ok" : "FAIL")"
    let lines = rows.map { row in
      "\(row.ok ? "" : "✗ ")\(row.key): \(Self.truncatedValue(row.value))"
    }
    return ([header] + lines).joined(separator: "\n")
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

  /// The groups with at least one check, paired with their rows, in `DoctorGroup.allCases`
  /// order — the shared partition behind both the text table and the Telegram summary.
  func nonEmptyGroups() -> [(group: DoctorGroup, rows: [Check])] {
    DoctorGroup.allCases.compactMap { group in
      let rows = checks.filter { $0.group == group }
      return rows.isEmpty ? nil : (group: group, rows: rows)
    }
  }

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

extension DoctorReport.Check {
  static let storeReadFailureValue = "unreadable (db read failed)"

  static func storeRead<Value: Sendable>(
    _ read: HealthValue<Value>,
    key: String,
    group: DoctorGroup,
    isHeadline: Bool = false,
    render: (Value) -> String
  ) -> DoctorReport.Check {
    switch read {
    case .available(let value):
      return DoctorReport.Check(
        key: key,
        value: render(value),
        ok: true,
        group: group,
        isHeadline: isHeadline
      )
    case .unavailable:
      return DoctorReport.Check(
        key: key,
        value: storeReadFailureValue,
        ok: false,
        group: group,
        isHeadline: isHeadline
      )
    }
  }
}
