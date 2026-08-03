import ClawCore
import ClawMCP
import Foundation

// MARK: - MCP Catalog Resolution

extension DaemonBuilder {
  /// The remote half of the tool catalog, pinned for this boot: the tools the registry will
  /// advertise, and what became of each server while they were collected.
  struct MCPStack {
    let tools: [any Tool]
    let catalog: ResolvedMCPCatalog

    static let empty = MCPStack(tools: [], catalog: .empty)
  }

  /// Opens one session per enabled server and resolves the catalog it contributes.
  ///
  /// Nothing here can fail the boot. A server that is unreachable, hostile, or oversized is skipped
  /// with its reason recorded, and the daemon comes up with the built-ins plus whatever answered.
  func resolveMCPStack() async -> MCPStack {
    let servers = mcp.config.enabledServers
    guard servers.isEmpty == false else {
      return .empty
    }

    var sessions: [MCPServerSession] = []
    var byServer: [String: MCPServerSession] = [:]
    for server in servers {
      let session = makeSession(for: server)
      sessions.append(session)
      byServer[server.name] = session
    }

    let catalog = await MCPCatalogResolver.resolve(sessions: sessions)
    let redactor = SecretRedactor(secretValues: redactionValues)

    // The adapter calls through the SAME session that discovered the tool, so a call reuses the
    // live connection the handshake already paid for.
    let tools: [any Tool] = catalog.tools.compactMap { resolved -> (any Tool)? in
      guard let session = byServer[resolved.coordinate.server] else {
        return nil
      }
      return MCPTool(resolved: resolved, session: session, redactor: redactor, logger: logger)
    }

    return MCPStack(tools: tools, catalog: catalog)
  }

  private func makeSession(for server: MCPServerConfig) -> MCPServerSession {
    MCPSessionFactory.make(
      server: server,
      token: mcp.token(for: server.name),
      http: toolExecutor,
      logger: logger
    )
  }
}
