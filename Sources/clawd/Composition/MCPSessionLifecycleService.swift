import ClawMCP
import ServiceLifecycle

/// Keeps the boot's MCP sessions in the ServiceGroup shutdown graph.
///
/// It does no periodic work; it exists so that every session the catalog resolution opened is hung
/// up before the process goes away. A session is a resource on someone else's server — the spec's
/// `DELETE` is how we say we are done with it — and it has to be sent while the tool HTTP client is
/// still open, which is what a service gets and the dependent-cleanup sequence after it does not.
struct MCPSessionLifecycleService: Service {
  static let idleInterval: Duration = .seconds(3600)

  private let sessions: [MCPServerSession]
  private let clock: any Clock<Duration>

  init(sessions: [MCPServerSession], clock: any Clock<Duration> = ContinuousClock()) {
    self.sessions = sessions
    self.clock = clock
  }

  func run() async throws {
    await cancelWhenGracefulShutdown {
      while !Task.isCancelled {
        do {
          try await clock.sleep(for: Self.idleInterval)
        } catch {
          break
        }
      }
    }

    for session in sessions {
      await session.disconnect()
    }
  }
}
