import Foundation

/// The doctor/status health table.
/// Holds a list of named checks; `ok` is the conjunction of all of them.
/// Renders as a human table or machine-readable JSON.
public struct DoctorReport: Sendable {
  public struct Check: Sendable, Codable, Equatable {
    public let key: String
    public let value: String
    public let ok: Bool
  }

  public private(set) var checks: [Check]

  public init(checks: [Check] = []) {
    self.checks = checks
  }

  public var ok: Bool { checks.allSatisfy(\.ok) }

  public mutating func add(key: String, value: String, ok: Bool = true) {
    checks.append(Check(key: key, value: value, ok: ok))
  }

  public func renderText() -> String {
    let keyWidth = checks.map(\.key.count).max() ?? 0
    return checks.map { check in
      let marker = check.ok ? "ok" : "FAIL"
      let paddedKey = check.key.padding(toLength: keyWidth, withPad: " ", startingAt: 0)
      return "[\(marker)] \(paddedKey) \(check.value)"
    }.joined(separator: "\n")
  }

  public func renderJSON() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let payload = DoctorReportPayload(ok: ok, checks: checks)
    let data = (try? encoder.encode(payload)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}

private struct DoctorReportPayload: Encodable {
  let ok: Bool
  let checks: [DoctorReport.Check]
}
