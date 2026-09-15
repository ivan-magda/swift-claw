import ClawCore
import ServiceLifecycle

/// Keeps the sandbox backend in the ServiceGroup shutdown graph. The service performs no periodic
/// work; its only effect is awaiting the backend's cancellation-safe teardown before it exits.
public struct SandboxLifecycleService: Service {
  private let maintenance: any SandboxMaintenance

  public init(maintenance: any SandboxMaintenance) {
    self.maintenance = maintenance
  }

  public func run() async throws {
    // Parks until the group shuts down or the task is cancelled; both exits tear the backend down.
    try? await gracefulShutdown()
    await maintenance.shutdown()
  }
}
