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
  public struct Row: Sendable, Equatable {
    public let key: String
    public let value: String
    public let ok: Bool

    public init(key: String, value: String, ok: Bool) {
      self.key = key
      self.value = value
      self.ok = ok
    }
  }

  public static func admittingRow(_ admitting: Bool) -> Row {
    flag(key: "sandbox.admitting", value: admitting)
  }

  public static func rows(for status: SandboxDoctorStatus) -> [Row] {
    switch status {
    case .disabled:
      return [Row(key: "sandbox", value: "disabled by CLAW_EXEC_ENABLED", ok: true)]
    case .linuxDeferred:
      return [Row(key: "sandbox", value: "execute_code awaits the Linux backend", ok: true)]
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
  static func configOnlyRows(_ availability: BackendAvailability) -> [Row] {
    switch availability {
    case .available(let engineVersion):
      return availableVersionRows(engineVersion)
        + [Row(key: "sandbox.canary", value: "deferred until live daemon startup", ok: true)]
    case .unavailable(let reason):
      return unavailableVersionRows(reason)
    }
  }

  static func daemonManagedRows(_ availability: BackendAvailability) -> [Row] {
    switch availability {
    case .available(let engineVersion):
      return availableVersionRows(engineVersion)
        + [Row(key: "sandbox.canary", value: "owned by the running daemon", ok: true)]
    case .unavailable(let reason):
      return unavailableVersionRows(reason)
    }
  }

  static func availableVersionRows(_ engineVersion: String) -> [Row] {
    [
      flag(key: "sandbox.available", value: true),
      flag(key: "sandbox.os_ok", value: true),
      Row(
        key: "sandbox.engine_version",
        value: "\(engineVersion) (minimum 1.0.0)",
        ok: true
      ),
      flag(key: "sandbox.version_ok", value: true),
    ]
  }

  static func unavailableVersionRows(_ reason: String) -> [Row] {
    [
      flag(key: "sandbox.available", value: false),
      Row(key: "sandbox.os_ok", value: "unknown", ok: false),
      Row(
        key: "sandbox.engine_version",
        value: "unknown (minimum 1.0.0)",
        ok: false
      ),
      flag(key: "sandbox.version_ok", value: false),
      Row(key: "sandbox.last_error", value: reason, ok: false),
    ]
  }
}

// MARK: - Live Rows

private extension SandboxHealthRows {
  static func unavailableRows(reason: String) -> [Row] {
    [
      flag(key: "sandbox.available", value: false),
      Row(key: "sandbox.os_ok", value: "unknown", ok: false),
      Row(
        key: "sandbox.engine_version",
        value: "unknown (minimum 1.0.0)",
        ok: false
      ),
      flag(key: "sandbox.version_ok", value: false),
      Row(key: "sandbox.image_digest_ok", value: "not run", ok: false),
      Row(key: "sandbox.caps_empty", value: "not run", ok: false),
      Row(key: "sandbox.net_isolated", value: "not run", ok: false),
      Row(key: "sandbox.caps_match", value: "not run", ok: false),
      Row(key: "sandbox.reaper_ok", value: "not run", ok: false),
      Row(key: "sandbox.rootfs_ro", value: "not run", ok: false),
      Row(key: "sandbox.staging_ro", value: "not run", ok: false),
      Row(key: "sandbox.interpreters_ok", value: "not run", ok: false),
      Row(key: "sandbox.last_error", value: reason, ok: false),
    ]
  }

  static func liveRows(_ health: SandboxHealth) -> [Row] {
    [
      flag(key: "sandbox.available", value: health.available),
      flag(key: "sandbox.os_ok", value: health.osOK),
      Row(
        key: "sandbox.engine_version",
        value: "\(health.engineVersion ?? "unknown") (minimum 1.0.0)",
        ok: health.engineVersion != nil
      ),
      flag(key: "sandbox.version_ok", value: health.versionOK),
      flag(key: "sandbox.image_digest_ok", value: health.imageDigestOK),
      flag(key: "sandbox.caps_empty", value: health.capsEmpty),
      flag(key: "sandbox.net_isolated", value: health.netIsolated),
      flag(key: "sandbox.caps_match", value: health.capsMatch),
      flag(key: "sandbox.reaper_ok", value: health.reaperOK),
      flag(key: "sandbox.rootfs_ro", value: health.rootfsRO),
      flag(key: "sandbox.staging_ro", value: health.stagingRO),
      flag(key: "sandbox.interpreters_ok", value: health.interpretersOK),
      Row(
        key: "sandbox.last_error",
        value: health.lastError ?? "none",
        ok: health.lastError == nil
      ),
    ]
  }

  static func flag(key: String, value: Bool) -> Row {
    Row(key: key, value: value ? "true" : "false", ok: value)
  }
}
