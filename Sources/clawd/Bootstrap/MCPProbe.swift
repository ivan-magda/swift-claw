import ClawCore
import ClawMCP
import ClawSecrets
import Foundation
import Logging

// MARK: - Session Factory

/// The one place a production MCP session is built. The daemon's boot resolution and both operator
/// probes go through it, so what an owner probes is wired exactly like what the daemon will boot
/// with — a probe that passed against a differently-built session would prove nothing.
enum MCPSessionFactory {
  static func make(
    server: MCPServerConfig,
    token: String?,
    http: any HTTPExecuting & HTTPStreaming,
    logger: Logger
  ) -> MCPServerSession {
    MCPServerSession(
      config: server,
      transportFactory: MCPStreamableHTTPTransportFactory(
        server: server,
        token: token,
        http: http,
        logger: logger
      ),
      clientVersion: ClawdVersion.current,
      logger: logger
    )
  }
}

// MARK: - Probe

/// The live half of the MCP health surface: connect, initialize, count the tools, hang up.
///
/// It answers in the same `MCPServerOutcome` vocabulary the daemon records when it pins its catalog,
/// so `clawd mcp probe`, a full `clawd doctor` run, and the daemon's own report read one row shape.
/// The only difference between them is when the servers were contacted.
enum MCPProbe {
  /// The logger a one-shot probe runs under. Quiet by design: the report already carries why a
  /// server failed, and a transport warning interleaved into stdout would read as part of it.
  static func quietLogger() -> Logger {
    var logger = Logger(label: "claw.mcp.probe")
    logger.logLevel = .critical
    return logger
  }

  static func run(
    servers: [MCPServerConfig],
    credentials: [String: MCPCredentialLoad],
    http: any HTTPExecuting & HTTPStreaming,
    logger: Logger
  ) async -> [MCPServerOutcome] {
    guard servers.isEmpty == false else {
      return []
    }

    let sessions = servers.map { server in
      MCPSessionFactory.make(
        server: server,
        token: credentials[server.name]?.token,
        http: http,
        logger: logger
      )
    }

    let outcomes = await MCPCatalogResolver.resolve(sessions: sessions).outcomes

    // A probe owns nothing past its answer, so every session it opened is hung up — including the
    // ones that answered. The resolver closes only the failures, because a daemon keeps the rest.
    for session in sessions {
      await session.disconnect()
    }

    return outcomes
  }
}
