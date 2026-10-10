import ClawCore

public struct SandboxBootstrapResult: Sendable {
  public let backend: (any ExecutionBackend)?
  public let maintenance: (any SandboxMaintenance)?
  public let health: SandboxHealth?
  public let unavailableReason: String?

  public init(
    backend: (any ExecutionBackend)?,
    maintenance: (any SandboxMaintenance)?,
    health: SandboxHealth?,
    unavailableReason: String?
  ) {
    self.backend = backend
    self.maintenance = maintenance
    self.health = health
    self.unavailableReason = unavailableReason
  }
}

public struct SandboxBootstrapper: Sendable {
  /// Why code execution is off when it is enabled but no backend could be built for this host.
  /// `clawd doctor` reports the same words without starting the daemon.
  package static let backendNotConfiguredReason = "sandbox backend is not configured"

  private let enabled: Bool
  private let backend: (any ExecutionBackend)?
  private let maintenance: (any SandboxMaintenance)?

  public init(
    enabled: Bool,
    backend: (any ExecutionBackend)?,
    maintenance: (any SandboxMaintenance)?
  ) {
    self.enabled = enabled
    self.backend = backend
    self.maintenance = maintenance
  }

  public func prepare() async -> SandboxBootstrapResult {
    guard enabled else {
      return SandboxBootstrapResult(
        backend: nil,
        maintenance: nil,
        health: nil,
        unavailableReason: "code execution is disabled"
      )
    }

    guard let backend, let maintenance else {
      return SandboxBootstrapResult(
        backend: nil,
        maintenance: nil,
        health: nil,
        unavailableReason: Self.backendNotConfiguredReason
      )
    }

    switch await backend.probe() {
    case .unavailable(let reason):
      return SandboxBootstrapResult(
        backend: nil,
        maintenance: maintenance,
        health: nil,
        unavailableReason: reason
      )
    case .available:
      break
    }

    let health = await maintenance.prepare()
    guard health.isReady else {
      return SandboxBootstrapResult(
        backend: nil,
        maintenance: maintenance,
        health: health,
        unavailableReason: health.lastError ?? "sandbox hardening canary failed"
      )
    }

    return SandboxBootstrapResult(
      backend: backend,
      maintenance: maintenance,
      health: health,
      unavailableReason: nil
    )
  }
}
