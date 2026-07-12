import ClawCore
import ServiceLifecycle

/// Keeps the sandbox backend in the ServiceGroup shutdown graph. The service performs no periodic
/// work; its only effect is awaiting the backend's cancellation-safe teardown before it exits.
public struct SandboxLifecycleService: Service {
  public static let idleInterval: Duration = .seconds(3600)

  private let maintenance: any SandboxMaintenance
  private let clock: any Clock<Duration>

  public init(
    maintenance: any SandboxMaintenance,
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.maintenance = maintenance
    self.clock = clock
  }

  public func run() async throws {
    await cancelWhenGracefulShutdown {
      while Task.isCancelled == false {
        do {
          try await clock.sleep(for: Self.idleInterval)
        } catch {
          break
        }
      }
    }
    await maintenance.shutdown()
  }
}
