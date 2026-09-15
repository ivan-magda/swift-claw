import ClawMCP
import ServiceLifecycle

/// Keeps the boot's MCP sessions in the ServiceGroup shutdown graph.
///
/// It does no periodic work; it exists so that every session the catalog resolution opened is hung
/// up before the process goes away. A session is a resource on someone else's server — the spec's
/// `DELETE` is how we say we are done with it — and it has to be sent while the tool HTTP client is
/// still open, which is what a service gets and the dependent-cleanup sequence after it does not.
struct MCPSessionLifecycleService: Service {
  private let sessions: [MCPServerSession]

  init(sessions: [MCPServerSession]) {
    self.sessions = sessions
  }

  func run() async throws {
    // Parks until the group shuts down or the task is cancelled; both exits hang up the sessions.
    try? await gracefulShutdown()

    for session in sessions {
      await session.disconnect()
    }
  }
}
