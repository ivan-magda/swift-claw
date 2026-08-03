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
    /// Every session this boot opened, including the ones that contributed no tool and so are held
    /// by no adapter. Carried so shutdown can hang up on all of them, not just the ones in use.
    let sessions: [MCPServerSession]

    static let empty = MCPStack(tools: [], catalog: .empty, sessions: [])
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

    let sessions = servers.map(makeSession(for:))
    let catalog = await MCPCatalogResolver.resolve(sessions: sessions)
    let redactor = SecretRedactor(secretValues: redactionValues)

    // Walked from the sessions rather than looked up per tool: the adapter has to call through the
    // SAME session that discovered the tool — that is what reuses the connection the handshake
    // already paid for — and starting from the session is what makes handing it the wrong one, or
    // dropping a tool whose session went missing, unrepresentable. Config order survives both hops.
    let byServer = Dictionary(grouping: catalog.tools) { resolved in
      resolved.coordinate.server
    }
    let tools: [any Tool] = sessions.flatMap { session in
      (byServer[session.config.name] ?? []).map { resolved in
        MCPTool(resolved: resolved, session: session, redactor: redactor, logger: logger)
      }
    }

    return MCPStack(tools: tools, catalog: catalog, sessions: sessions)
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
