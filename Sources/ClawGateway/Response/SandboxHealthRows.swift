import ClawCore

public enum SandboxDoctorStatus: Sendable, Equatable {
  case disabled
  case linuxDeferred
  case configOnly(availability: BackendAvailability)
  case daemonManaged(availability: BackendAvailability)
  case live(health: SandboxHealth)
  case unavailable(reason: String)

  public static func atBoot(
    execEnabled: Bool,
    health: SandboxHealth?,
    unavailableReason: String?
  ) -> SandboxDoctorStatus {
    guard execEnabled else {
      return .disabled
    }

    guard let health else {
      return .unavailable(
        reason: unavailableReason ?? "sandbox was not ready at daemon startup"
      )
    }

    return .live(health: health)
  }
}

public enum SandboxHealthRows {
  static let shape = DoctorRowShape(prefix: "sandbox", group: .sandbox)

  public static func admittingRow(_ admitting: Bool) -> DoctorReport.Check {
    flag(key: "admitting", value: admitting)
  }

  public static func rows(for status: SandboxDoctorStatus) -> [DoctorReport.Check] {
    switch status {
    case .disabled:
      return [headline(value: "disabled by CLAW_EXEC_ENABLED", ok: true)]
    case .linuxDeferred:
      return [headline(value: "execute_code awaits the Linux backend", ok: true)]
    case .configOnly(let availability):
      return configOnlyRows(availability)
    case .daemonManaged(let availability):
      return daemonManagedRows(availability)
    case .live(let health):
      return liveRows(health)
    case .unavailable(let reason):
      return unavailableRows(reason: reason)
    }
  }
}

// MARK: - Version-Only Rows

private extension SandboxHealthRows {
  static func configOnlyRows(_ availability: BackendAvailability) -> [DoctorReport.Check] {
    switch availability {
    case .available(let engineVersion):
      return availableVersionRows(engineVersion)
        + [check(key: "canary", value: "deferred until live daemon startup", ok: true)]
    case .unavailable(let reason):
      return unavailableVersionRows(reason)
    }
  }

  static func daemonManagedRows(_ availability: BackendAvailability) -> [DoctorReport.Check] {
    switch availability {
    case .available(let engineVersion):
      return availableVersionRows(engineVersion)
        + [check(key: "canary", value: "owned by the running daemon", ok: true)]
    case .unavailable(let reason):
      return unavailableVersionRows(reason)
    }
  }

  static func availableVersionRows(_ engineVersion: String) -> [DoctorReport.Check] {
    [
      flag(key: "available", value: true),
      flag(key: "os_ok", value: true),
      check(
        key: "engine_version",
        value: "\(engineVersion) (minimum 1.0.0)",
        ok: true
      ),
      flag(key: "version_ok", value: true),
    ]
  }

  static func unavailableVersionRows(_ reason: String) -> [DoctorReport.Check] {
    [
      flag(key: "available", value: false),
      check(key: "os_ok", value: "unknown", ok: false),
      check(
        key: "engine_version",
        value: "unknown (minimum 1.0.0)",
        ok: false
      ),
      flag(key: "version_ok", value: false),
      check(key: "last_error", value: reason, ok: false),
    ]
  }
}

// MARK: - Live Rows

private extension SandboxHealthRows {
  static func unavailableRows(reason: String) -> [DoctorReport.Check] {
    [
      flag(key: "available", value: false),
      check(key: "os_ok", value: "unknown", ok: false),
      check(
        key: "engine_version",
        value: "unknown (minimum 1.0.0)",
        ok: false
      ),
      flag(key: "version_ok", value: false),
      check(key: "image_digest_ok", value: "not run", ok: false),
      check(key: "caps_empty", value: "not run", ok: false),
      check(key: "net_isolated", value: "not run", ok: false),
      check(key: "caps_match", value: "not run", ok: false),
      check(key: "reaper_ok", value: "not run", ok: false),
      check(key: "rootfs_ro", value: "not run", ok: false),
      check(key: "staging_ro", value: "not run", ok: false),
      check(key: "interpreters_ok", value: "not run", ok: false),
      check(key: "last_error", value: reason, ok: false),
    ]
  }

  static func liveRows(_ health: SandboxHealth) -> [DoctorReport.Check] {
    [
      flag(key: "available", value: health.available),
      flag(key: "os_ok", value: health.osOK),
      check(
        key: "engine_version",
        value: "\(health.engineVersion ?? "unknown") (minimum 1.0.0)",
        ok: health.engineVersion != nil
      ),
      flag(key: "version_ok", value: health.versionOK),
      flag(key: "image_digest_ok", value: health.imageDigestOK),
      flag(key: "caps_empty", value: health.capsEmpty),
      flag(key: "net_isolated", value: health.netIsolated),
      flag(key: "caps_match", value: health.capsMatch),
      flag(key: "reaper_ok", value: health.reaperOK),
      flag(key: "rootfs_ro", value: health.rootfsRO),
      flag(key: "staging_ro", value: health.stagingRO),
      flag(key: "interpreters_ok", value: health.interpretersOK),
      check(
        key: "last_error",
        value: health.lastError ?? "none",
        ok: health.lastError == nil
      ),
    ]
  }

  static func headline(value: String, ok: Bool) -> DoctorReport.Check {
    shape.row(value: value, ok: ok)
  }

  static func flag(key: String, value: Bool) -> DoctorReport.Check {
    shape.flag(key, value: value)
  }

  static func check(key: String, value: String, ok: Bool) -> DoctorReport.Check {
    shape.row(key, value: value, ok: ok)
  }
}
