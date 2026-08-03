import ClawCore
import ClawGateway
import ClawMCP
import ClawSecrets

// MARK: - MCP Health Rows

/// The one builder behind both MCP health surfaces.
///
/// `clawd doctor` runs in its own process while the daemon may not even be up, so it can only read
/// what is on disk — the catalog and the token store — and prints `rows` alone. The running daemon
/// prints the same rows plus what each server actually contributed when it pinned its catalog,
/// which nothing outside that process can know.
enum MCPDoctorRows {
  static func rows(
    config: MCPConfig,
    credentials: [String: MCPCredentialLoad]
  ) -> [DoctorReport.Check] {
    guard config.servers.isEmpty == false else {
      return [row(key: "mcp", value: "no servers configured", ok: true)]
    }

    let summary = "\(config.servers.count) configured, \(config.enabledServers.count) enabled"
    return [row(key: "mcp", value: summary, ok: true)]
      + config.servers.map { server in
        serverRow(server, load: credentials[server.name] ?? .absent)
      }
  }

  /// What each server contributed at boot — the answer to "why is that server's tool missing?".
  static func bootRows(outcomes: [MCPServerOutcome]) -> [DoctorReport.Check] {
    outcomes.map { outcome in
      switch outcome.status {
      case .ok(let toolCount):
        return row(key: "mcp.\(outcome.server).tools", value: "\(toolCount)", ok: true)
      case .skipped(let reason):
        return row(key: "mcp.\(outcome.server).tools", value: "skipped: \(reason)", ok: false)
      }
    }
  }

  /// A failure that stopped the rows above from being built at all.
  static func failureRow(_ message: String) -> DoctorReport.Check {
    row(key: "mcp", value: message, ok: false)
  }

  /// Nothing was contacted, and why. A catalog whose servers are all disabled is a state an owner
  /// chose, so it reads as a fact rather than a failure.
  static func nothingProbedRow(config: MCPConfig) -> DoctorReport.Check {
    row(
      key: "mcp",
      value: config.servers.isEmpty ? "no servers configured" : "no enabled servers to probe",
      ok: true
    )
  }

  /// Names tokens left behind by servers the catalog no longer declares. Nothing can send them —
  /// the binding comes from the config — so this is a cleanup hint, not a failure, and the owner
  /// needs the names because `clear-token` is the only thing that removes them.
  static func orphanTokenRow(storedServers: [String], config: MCPConfig) -> DoctorReport.Check? {
    let configured = Set(config.servers.map(\.name))
    let orphans = storedServers.filter { configured.contains($0) == false }.sorted()
    guard orphans.isEmpty == false else {
      return nil
    }
    return row(
      key: "mcp.unbound_tokens",
      value:
        "\(orphans.joined(separator: ", ")) — not in the config; clawd mcp clear-token removes",
      ok: true
    )
  }
}

// MARK: - Server Rows

private extension MCPDoctorRows {
  static func serverRow(_ server: MCPServerConfig, load: MCPCredentialLoad) -> DoctorReport.Check {
    let fields = [
      server.url.absoluteString,
      server.enabled ? "enabled" : "disabled",
      tokenState(load),
      filterState(server.tools),
    ]
    return row(
      key: "mcp.\(server.name)",
      value: fields.joined(separator: " · "),
      ok: load != .boundToDifferentURL
    )
  }

  /// A missing token is not a failure — a server may need no auth at all. A token minted for another
  /// URL is: it will never be sent, and only the owner can repair it.
  static func tokenState(_ load: MCPCredentialLoad) -> String {
    switch load {
    case .absent:
      return "no token"
    case .token:
      return "token set"
    case .boundToDifferentURL:
      return "token bound to a different URL; re-run clawd mcp set-token"
    }
  }

  static func filterState(_ filter: MCPToolFilter) -> String {
    guard filter.include.isEmpty else {
      return "include: \(filter.include.joined(separator: ", "))"
    }
    guard filter.exclude.isEmpty else {
      return "exclude: \(filter.exclude.joined(separator: ", "))"
    }
    return "all tools"
  }

  static func row(key: String, value: String, ok: Bool) -> DoctorReport.Check {
    DoctorReport.Check(key: key, value: value, ok: ok, group: .mcp)
  }
}
