import Foundation

/// One subsystem's doctor rows: every row keyed under a single prefix and filed under a single
/// group. A second subsystem states its prefix once instead of repeating both on every row, which
/// is what keeps two row sets from drifting into different shapes.
public struct DoctorRowShape: Sendable, Equatable {
  public let prefix: String
  public let group: DoctorGroup

  public init(prefix: String, group: DoctorGroup) {
    self.prefix = prefix
    self.group = group
  }

  /// - Parameter suffix: nil keys the row on the bare prefix — the subsystem's own headline row.
  public func row(_ suffix: String? = nil, value: String, ok: Bool = true) -> DoctorReport.Check {
    DoctorReport.Check(
      key: suffix.map { "\(prefix).\($0)" } ?? prefix,
      value: value,
      ok: ok,
      group: group
    )
  }

  /// A boolean row, where the value failing the check and the value being false are the same thing.
  public func flag(_ suffix: String? = nil, value: Bool) -> DoctorReport.Check {
    row(suffix, value: value ? "true" : "false", ok: value)
  }
}
