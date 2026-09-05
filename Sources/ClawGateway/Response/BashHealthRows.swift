import ClawCore

/// What doctor can say about host shell execution. `unavailable` is the state the owner most needs
/// named: they asked for the tool and did not get it.
public enum BashDoctorStatus: Sendable, Equatable {
  case disabled
  case unavailable(shellPath: String, reason: String)
  case ready(shellPath: String, defaultTimeoutSeconds: Int, maxTimeoutSeconds: Int)

  /// Resolved from the same probe registration reads, so an absent tool always has a row saying why.
  public static func resolve(config: BashConfig) -> BashDoctorStatus {
    guard config.enabled else {
      return .disabled
    }

    switch HostShellProbe.availability(shellPath: config.shellPath) {
    case .available:
      return .ready(
        shellPath: config.shellPath,
        defaultTimeoutSeconds: config.defaultTimeoutSeconds,
        maxTimeoutSeconds: config.maxTimeoutSeconds
      )
    case .unavailable(let reason):
      return .unavailable(shellPath: config.shellPath, reason: reason)
    }
  }
}

public enum BashHealthRows {
  static let shape = DoctorRowShape(prefix: "bash", group: .hostShell)

  public static func rows(for status: BashDoctorStatus) -> [DoctorReport.Check] {
    switch status {
    case .disabled:
      return [shape.row(value: "disabled by CLAW_BASH_ENABLED")]
    case .unavailable(let shellPath, let reason):
      return [
        shape.flag("available", value: false),
        shape.row("shell", value: shellPath, ok: false),
        shape.row("last_error", value: reason, ok: false),
      ]
    case .ready(let shellPath, let defaultTimeoutSeconds, let maxTimeoutSeconds):
      return [
        shape.flag("available", value: true),
        shape.row("shell", value: shellPath),
        shape.row(
          "timeout",
          value: "\(defaultTimeoutSeconds)s default (maximum \(maxTimeoutSeconds)s)"
        ),
      ]
    }
  }
}
